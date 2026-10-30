import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Drives playback (Android's PlaybackControllerImpl + MusicPlaybackService). [state] is what every
/// screen reads; the queue lives here, the audio in [AudioEngine]. Lock screen, Control Center and
/// headphone commands act on the same state.
@MainActor
@Observable
final class PlayerController {
    private(set) var state = PlaybackState()
    /// The playing position, published on its own: it changes four times a second, and only the
    /// views showing progress should redraw for it (a menu open elsewhere would otherwise reset).
    let clock = PlaybackClock()

    @ObservationIgnored let engine = AudioEngine()
    @ObservationIgnored private let database: LibraryDatabase
    @ObservationIgnored let transitions: TransitionSettingsStore
    @ObservationIgnored private let persistence = JSONStore<PersistedPlaybackState>(name: "playback.json", debounce: .milliseconds(250))
    @ObservationIgnored private var removals = QueueRemovals<QueueEntry>()
    @ObservationIgnored private lazy var history = SessionHistory(now: { Int64(Date().timeIntervalSince1970 * 1000) })
    @ObservationIgnored private lazy var listening = ListeningTracker(
        elapsedRealtime: { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        onPlayCounted: { [weak self] id in self?.recordPlay(id) },
        onListened: { [weak self] id, ms in self?.recordListened(id, ms) }
    )
    @ObservationIgnored private lazy var abLoop = AbLoopController(
        scheduler: { [weak self] _, position, onReached in self?.scheduleLoop(at: position, onReached) ?? Cancellable {} },
        player: loopPlayer,
        onStateChanged: { [weak self] loop in
            self?.state.abLoop = loop
            self?.reevaluateTransition()
        }
    )
    @ObservationIgnored private lazy var loopPlayer = ControllerLoopPlayer(controller: self)
    @ObservationIgnored private var loopTarget: (positionMs: Int64, onReached: () -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    enum VisualMotion: Hashable { case carousel, presentation }
    @ObservationIgnored private var visualMotion: Set<VisualMotion> = []
    @ObservationIgnored private var nowPlayingUpdate: Task<Void, Never>?
    @ObservationIgnored private let albumHistoryQueue = DispatchQueue(label: "ehru.album-history", qos: .utility)
    @ObservationIgnored private var artworkWarmup: Task<Void, Never>?
    @ObservationIgnored private var fileWarmup: Task<Void, Never>?
    @ObservationIgnored private var restoreFinished = false
    @ObservationIgnored private var consecutiveErrors = 0
    @ObservationIgnored private var plannedTransition: (entryId: UUID, nextEntryId: UUID, plan: Planned)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkSongId: Int64?

    /// Media3's "previous restarts the song after 3 s".
    private static let restartThreshold: Int64 = 3_000
    private static let tickInterval: TimeInterval = 0.05
    /// Ticks between published positions (250 ms, Android's poll).
    private static let publishEvery = 5
    private static let persistEvery = 100
    private static let checkpointEvery = 1_200
    /// A transition is armed this far ahead of its start (the engine then starts it sample-exactly).
    private static let transitionLeadMs: Int64 = 400
    /// The next track is queued gaplessly once this little of the current one remains.
    private static let gaplessLeadMs: Int64 = 8_000

    init(database: LibraryDatabase, transitions: TransitionSettingsStore) {
        self.database = database
        self.transitions = transitions
        transitions.onChange = { [weak self] in self?.reevaluateTransition() }
        engine.onEntryFinished = { [weak self] id in self?.entryFinished(id) }
        engine.onConfigurationChange = { [weak self] in self?.restartAfterConfigurationChange() }
        configureAudioSession()
        configureRemoteCommands()
        observeAudioSession()
        Task {
            await engine.setUp()
            restorePersistedState()
        }
    }

    // MARK: Transport

    func play() {
        guard !state.queue.isEmpty else { return }
        if state.status == .idle || engine.currentPosition() == nil {
            startCurrent(at: state.positionMs, playing: true)
            return
        }
        activateAudioSession()
        do {
            try engine.resume()
            playingChanged(true)
        } catch {
            startCurrent(at: state.positionMs, playing: true)
        }
    }

    func pause() {
        refreshPosition()
        engine.pause()
        playingChanged(false)
    }

    func togglePlayPause() {
        state.isPlaying ? pause() : play()
    }

    /// Plays [songs] from [startIndex] as an ordinary queue.
    func playSongs(_ songs: [Song], startIndex: Int = 0) {
        playCollection(songs, startIndex: startIndex, origin: nil)
    }

    /// Plays [songs] as album or playlist [origin] (its transition settings apply); [slots] are the
    /// playlist positions (parallel), so duplicates stay distinct.
    func playCollection(_ songs: [Song], startIndex: Int, origin: CollectionRef?, slots: [Int]? = nil, source: PlaybackSource? = nil) {
        guard !songs.isEmpty else { return }
        let index = songs.indices.contains(startIndex) ? startIndex : 0
        consecutiveErrors = 0
        var order = Array(songs.indices)
        var playIndex = index
        if state.shuffleModeEnabled && songs.count > 1 {
            order = [index] + songs.indices.filter { $0 != index }.shuffled()
            playIndex = 0
        }
        let entries = order.map { i in
            QueueEntry(song: songs[i], origin: origin.map {
                QueueOrigin(collection: $0, occurrence: TrackOccurrence(songs[i].id, slots.flatMap { $0.indices.contains(i) ? $0[i] : nil }))
            }, source: source)
        }
        setQueue(entries, startIndex: playIndex)
        if case .playlist(let id)? = origin.map({ CollectionKindRef($0) }) { try? database.markPlaylistPlayed(id) }
        startCurrent(at: 0, playing: true)
    }

    func seek(to positionMs: Int64) {
        guard let entry = state.currentEntry else { return }
        let target = max(positionMs, 0)
        do {
            try engine.seek(entryId: entry.id, url: entry.song.url, toMs: target)
        } catch {
            handleError(entry)
            return
        }
        setPosition(target)
        reevaluateTransition()
        updateNowPlaying()
    }

    func skipNext() {
        guard let next = PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: true)
        else { return }
        moveTo(next, playing: state.isPlaying || state.status == .buffering, sameEntryRepeated: false)
    }

    /// Restarts the current song past the first few seconds, otherwise moves to the previous one.
    func skipPrevious() {
        if currentPositionMs() > Self.restartThreshold || state.previousIndex < 0 {
            seek(to: 0)
        } else {
            skipToPreviousItem()
        }
    }

    /// The previous song in play order, never a restart of the current one.
    func skipToPreviousItem() {
        guard let previous = PlayOrder.previous(before: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode)
        else { return }
        moveTo(previous, playing: state.isPlaying, sameEntryRepeated: false)
    }

    func skipToQueueItem(_ index: Int) {
        guard state.queue.indices.contains(index) else { return }
        moveTo(index, playing: true, sameEntryRepeated: false)
    }

    /// Shuffle is physical: turning it on puts the current entry first and shuffles the rest; turning
    /// it off keeps the order (as on Android).
    func setShuffleModeEnabled(_ enabled: Bool) {
        state.shuffleModeEnabled = enabled
        if enabled, state.queue.count > 1, let current = state.currentEntry {
            removals.clear()
            let rest = state.queue.enumerated().filter { $0.offset != state.currentIndex }.map(\.element).shuffled()
            state.queue = [current] + rest
            state.currentIndex = 0
            queueChanged()
        }
        persistState()
    }

    func setRepeatMode(_ mode: RepeatMode) {
        state.repeatMode = mode
        queueChanged()
        persistState()
    }

    func cycleRepeatMode() {
        setRepeatMode(state.repeatMode.next)
    }

    func setVolume(_ volume: Float) {
        engine.volume = volume
    }

    // MARK: Queue edits

    func playNext(_ song: Song, source: PlaybackSource? = nil) {
        let wasEmpty = state.queue.isEmpty
        let insertAt = wasEmpty ? 0 : min(state.currentIndex + 1, state.queue.count)
        state.queue.insert(QueueEntry(song: song, source: source), at: insertAt)
        if wasEmpty { state.currentIndex = 0 }
        queueChanged()
    }

    func addToQueue(_ song: Song, source: PlaybackSource? = nil) {
        let wasEmpty = state.queue.isEmpty
        state.queue.append(QueueEntry(song: song, source: source))
        if wasEmpty { state.currentIndex = 0 }
        queueChanged()
    }

    /// Removes the entry at [index]; [undoQueueRemoval] puts it back.
    func removeFromQueue(_ index: Int) {
        guard state.queue.indices.contains(index) else { return }
        let removingCurrent = index == state.currentIndex
        let entry = state.queue.remove(at: index)
        removals.push(index: index, item: entry)
        if state.queue.isEmpty {
            state.currentIndex = -1
            engine.stopAll()
            playingChanged(false)
            currentEntryChanged(sameEntryRepeated: false)
        } else if removingCurrent {
            state.currentIndex = min(index, state.queue.count - 1)
            startCurrent(at: 0, playing: state.isPlaying)
        } else if index < state.currentIndex {
            state.currentIndex -= 1
        }
        queueChanged()
    }

    /// Puts the most recently removed entry back at its original position. False when there is nothing to undo.
    @discardableResult
    func undoQueueRemoval() -> Bool {
        guard let removal = removals.pop() else { return false }
        let wasEmpty = state.queue.isEmpty
        let index = removal.index.clamped(0, state.queue.count)
        state.queue.insert(removal.item, at: index)
        if wasEmpty {
            state.currentIndex = 0
        } else if index <= state.currentIndex {
            state.currentIndex += 1
        }
        queueChanged()
        return true
    }

    /// Shuffles only the entries after the current one. False when fewer than two are upcoming.
    @discardableResult
    func shuffleUpcoming() -> Bool {
        guard let upcoming = shuffledUpcoming(state.queue, currentIndex: state.currentIndex) else { return false }
        let start = upcomingStart(queueSize: state.queue.count, currentIndex: state.currentIndex)
        state.queue.replaceSubrange(start..., with: upcoming)
        queueChanged()
        return true
    }

    /// Replaces the entries after the current one with [songs] (Smart Radio); the current song keeps playing.
    func replaceUpcoming(_ songs: [Song]) {
        removals.clear()
        let entries = songs.map { QueueEntry(song: $0) }
        if state.queue.isEmpty {
            setQueue(entries, startIndex: 0)
            return
        }
        let start = upcomingStart(queueSize: state.queue.count, currentIndex: state.currentIndex)
        state.queue.replaceSubrange(start..., with: entries)
        queueChanged()
    }

    /// Plays a session-history entry again, right after the current entry.
    func playFromHistory(_ entryId: Int64) {
        guard let song = history.find(entryId)?.song else { return }
        if state.queue.isEmpty {
            playSongs([song])
        } else {
            let target = min(state.currentIndex + 1, state.queue.count)
            state.queue.insert(QueueEntry(song: song), at: target)
            queueChanged()
            skipToQueueItem(target)
        }
    }

    func reorder(from: Int, to: Int) {
        guard state.queue.indices.contains(from), state.queue.indices.contains(to), from != to else { return }
        let current = state.currentEntry?.id
        let entry = state.queue.remove(at: from)
        state.queue.insert(entry, at: to)
        if let current { state.currentIndex = state.queue.firstIndex { $0.id == current } ?? state.currentIndex }
        queueChanged()
    }

    // MARK: A–B loop

    func setLoopStart() -> AbLoopEdit { abLoop.setStart() }
    func setLoopEnd() -> AbLoopEdit { abLoop.setEnd() }
    func setLoopEnabled(_ enabled: Bool) -> AbLoopEdit { abLoop.setEnabled(enabled) }
    func clearLoop() { abLoop.clear() }

    /// The engine's exact position right now, finer than [state]'s published one.
    func currentPositionMs() -> Int64 {
        guard let position = engine.currentPosition(), position.entryId == state.currentEntry?.id else { return state.positionMs }
        return position.positionMs
    }

    private func scheduleLoop(at positionMs: Int64, _ onReached: @escaping () -> Void) -> Cancellable {
        loopTarget = (positionMs, onReached)
        return Cancellable { [weak self] in self?.loopTarget = nil }
    }

    fileprivate func loopSeek(_ positionMs: Int64) {
        seek(to: positionMs)
    }

    // MARK: Internals

    private func setQueue(_ entries: [QueueEntry], startIndex: Int) {
        removals.clear()
        state.queue = entries
        state.currentIndex = entries.isEmpty ? -1 : startIndex.clamped(0, entries.count - 1)
        setPosition(0)
    }

    /// Starts the current entry at [positionMs] from a fresh engine start.
    private func startCurrent(at positionMs: Int64, playing: Bool) {
        guard let entry = state.currentEntry else { return }
        if playing && (!state.isPlaying || !engine.isRunning) { activateAudioSession() }
        do {
            try engine.play(entryId: entry.id, url: entry.song.url, positionMs: positionMs, startPlaying: playing)
            setPosition(positionMs)
            state.durationMs = entry.song.durationMs
            if playing { consecutiveErrors = 0 }
            currentEntryChanged(sameEntryRepeated: false)
            playingChanged(playing)
        } catch AudioEngine.EngineError.notReady {
            // The engine is still being built: the restore or the user's next tap starts it.
            state.status = .paused
        } catch {
            handleError(entry)
        }
    }

    private func moveTo(_ index: Int, playing: Bool, sameEntryRepeated: Bool) {
        engine.cancelCrossfade()
        state.currentIndex = index
        startCurrent(at: 0, playing: playing)
        if sameEntryRepeated { abLoop.onEntryChanged(sameEntryRepeated: true) }
    }

    /// An entry played to its end on the engine.
    private func entryFinished(_ entryId: UUID) {
        guard entryId == state.currentEntry?.id else { return }
        guard let next = PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: false)
        else {
            // End of the queue: back to the start of the last track, paused (Media3's ENDED).
            listening.onEnded()
            engine.stopAll()
            setPosition(0)
            playingChanged(false)
            state.status = .idle
            persistState()
            return
        }
        let repeated = next == state.currentIndex
        if !repeated, engine.hasQueued(state.queue[next].id) {
            // Gapless: the engine already plays it.
            state.currentIndex = next
            setPosition(0)
            state.durationMs = state.queue[next].song.durationMs
            currentEntryChanged(sameEntryRepeated: false)
        } else {
            state.currentIndex = next
            startCurrent(at: 0, playing: true)
            if repeated { abLoop.onEntryChanged(sameEntryRepeated: true) }
        }
    }

    /// A file that is gone or unreadable must not stall the queue: skip to the next entry, but give
    /// up after one full pass so a queue of broken files cannot loop forever.
    private func handleError(_ entry: QueueEntry) {
        NSLog("Ehru: cannot play \(entry.song.path)")
        consecutiveErrors += 1
        if consecutiveErrors < state.queue.count,
           let next = PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: true) {
            state.currentIndex = next
            startCurrent(at: 0, playing: true)
        } else {
            consecutiveErrors = 0
            engine.stopAll()
            playingChanged(false)
            state.status = .idle
        }
    }

    private func currentEntryChanged(sameEntryRepeated: Bool) {
        warmAdjacentFiles()
        let song = state.currentSong
        listening.onItemChanged(song?.id, durationMs: song?.durationMs ?? 0, isPlaying: state.isPlaying)
        if history.onItemBecameCurrent(song, isPlaying: state.isPlaying) { state.history = history.entries }
        abLoop.onEntryChanged(sameEntryRepeated: sameEntryRepeated)
        if let song, state.isPlaying { recordAlbumPlayed(song.id) }
        reevaluateTransition()
        updateNowPlaying()
        persistState()
    }

    private func playingChanged(_ playing: Bool) {
        let wasPlaying = state.isPlaying
        state.status = state.queue.isEmpty ? .idle : (playing ? .playing : .paused)
        listening.onPlayingChanged(playing, durationMs: state.durationMs)
        if playing {
            if history.onPlaybackStarted() { state.history = history.entries }
            if !wasPlaying, let song = state.currentSong { recordAlbumPlayed(song.id) }
            startTimer()
        } else {
            stopTimer()
            refreshPosition()
            persistState()
        }
        updateNowPlaying()
    }

    private func queueChanged() {
        warmAdjacentFiles()
        if state.currentEntry == nil { state.currentIndex = state.queue.isEmpty ? -1 : 0 }
        reevaluateTransition()
        persistState()
    }

    private func warmAdjacentFiles() {
        fileWarmup?.cancel()
        let previous = PlayOrder.previous(before: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode)
        let next = PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: true)
        let urls = [next, previous].compactMap { index -> URL? in
            guard let index, state.queue.indices.contains(index) else { return nil }
            let url = state.queue[index].song.url
            return url == state.currentSong?.url ? nil : url
        }
        fileWarmup = Task { [weak self] in await self?.engine.warmFiles(urls) }
        artworkWarmup?.cancel()
        artworkWarmup = Task {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        _ = await ArtworkLoader.shared.image(for: url, maxPixels: 600)
                    }
                }
            }
        }
    }

    // MARK: Position polling

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        ticks += 1
        let position = currentPositionMs()
        if ticks % Self.publishEvery == 0 {
            refreshPosition(publishState: false)
            listening.onProgress(durationMs: state.durationMs)
        }
        if ticks % Self.persistEvery == 0 { persistState() }
        if ticks % Self.checkpointEvery == 0 { listening.checkpoint() }
        if let target = loopTarget, position >= target.positionMs { target.onReached() }
        engine.releaseFinishedOutgoing()
        checkTransition(position: position)
        checkGapless(position: position)
    }

    /// While playing only [clock] moves; [state] keeps the position of the last seek, start or pause.
    private func refreshPosition(publishState: Bool = true) {
        let position = currentPositionMs()
        if clock.positionMs != position { clock.positionMs = position }
        if publishState { setPosition(position) }
        if let duration = state.currentSong?.durationMs, duration > 0, state.durationMs != duration { state.durationMs = duration }
    }

    private func setPosition(_ positionMs: Int64) {
        state.positionMs = positionMs
        clock.positionMs = positionMs
    }

    // MARK: Transitions

    /// Re-plans the boundary after the current entry (entry change, seek, queue edit, repeat, loop, settings).
    private func reevaluateTransition() {
        guard let current = state.currentEntry else {
            plannedTransition = nil
            return
        }
        let nextIndex = PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: true) ?? -1
        let next = state.queue.indices.contains(nextIndex) ? state.queue[nextIndex] : nil
        let spec = next.flatMap { transitions.resolve(outgoing: current.origin, incoming: $0.origin).spec }
        let info = BoundaryInfo(
            spec: spec, nextIndex: nextIndex, repeatMode: state.repeatMode, abLoopEnabled: state.abLoop?.enabled == true,
            outgoingDurationMs: current.song.durationMs, incomingDurationMs: next?.song.durationMs ?? 0
        )
        if let plan = TransitionPlanner.plan(info).planned, let next {
            plannedTransition = (current.id, next.id, plan)
        } else {
            plannedTransition = nil
        }
    }

    private func checkTransition(position: Int64) {
        guard let planned = plannedTransition, planned.entryId == state.currentEntry?.id, state.isPlaying else { return }
        let untilStart = planned.plan.startAtMs - position
        guard untilStart <= Self.transitionLeadMs else { return }
        plannedTransition = nil
        guard untilStart > 50, state.queue.indices.contains(planned.plan.nextIndex),
              state.queue[planned.plan.nextIndex].id == planned.nextEntryId
        else { return } // too late (e.g. seeked there): the boundary plays normally
        let next = state.queue[planned.plan.nextIndex]
        let startHost = mach_absolute_time() + TransitionStageKernel.hostTicks(forSeconds: Double(untilStart) / 1000)
        do {
            try engine.crossfade(
                to: next.id, url: next.song.url, incomingStartMs: planned.plan.incomingStartMs, spec: planned.plan.spec,
                durationMs: planned.plan.durationMs, startHostTime: startHost
            )
        } catch {
            return
        }
        // The queue moves on when the crossfade starts, as on Android.
        let delay = Double(untilStart) / 1000
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.state.queue.indices.contains(planned.plan.nextIndex),
                  self.state.queue[planned.plan.nextIndex].id == next.id else { return }
            self.state.currentIndex = planned.plan.nextIndex
            self.setPosition(planned.plan.incomingStartMs)
            self.state.durationMs = next.song.durationMs
            self.currentEntryChanged(sameEntryRepeated: false)
        }
    }

    private func checkGapless(position: Int64) {
        guard plannedTransition == nil, let current = state.currentEntry,
              current.song.durationMs - position <= Self.gaplessLeadMs,
              let nextIndex = PlayOrder.next(after: state.currentIndex, count: state.queue.count, repeatMode: state.repeatMode, userSkip: false),
              nextIndex != state.currentIndex
        else { return }
        let next = state.queue[nextIndex]
        if !engine.hasQueued(next.id) { engine.queueGapless(entryId: next.id, url: next.song.url) }
    }

    // MARK: Listening statistics

    private func recordPlay(_ songId: Int64) {
        let database = self.database
        Task.detached(priority: .utility) { try? database.recordPlay(songId: songId) }
    }

    private func recordListened(_ songId: Int64, _ ms: Int64) {
        let database = self.database
        Task.detached(priority: .utility) { try? database.addListened(songId: songId, ms: ms) }
    }

    // MARK: Persistence

    private func persistState() {
        guard restoreFinished else { return }
        persistence.save(PersistedPlaybackState(
            queueSongIds: state.queue.map(\.song.id),
            currentIndex: state.currentIndex,
            positionMs: currentPositionMs(),
            shuffleModeEnabled: state.shuffleModeEnabled,
            repeatMode: state.repeatMode,
            queueCollectionKeys: state.queue.map { $0.origin?.key ?? "" }, queueSources: state.queue.map(\.source)
        ))
    }

    /// Saves at once (the app is going to the background).
    func persistNow() {
        guard restoreFinished else { return }
        persistence.saveNow(PersistedPlaybackState(
            queueSongIds: state.queue.map(\.song.id), currentIndex: state.currentIndex, positionMs: currentPositionMs(),
            shuffleModeEnabled: state.shuffleModeEnabled, repeatMode: state.repeatMode,
            queueCollectionKeys: state.queue.map { $0.origin?.key ?? "" }, queueSources: state.queue.map(\.source)
        ))
    }

    private func restorePersistedState() {
        defer { restoreFinished = true }
        guard state.queue.isEmpty, let saved = persistence.load(),
              let restored = buildRestoredQueue(saved, available: (try? database.songs(ids: Array(Set(saved.queueSongIds)))) ?? []),
              state.queue.isEmpty
        else { return }
        let entries = restored.songs.enumerated().map { i, song in
            QueueEntry(song: song, origin: restored.origins.indices.contains(i) ? restored.origins[i] : nil,
                       source: restored.sources.indices.contains(i) ? restored.sources[i] : nil)
        }
        state.queue = entries
        state.currentIndex = restored.startIndex
        setPosition(restored.startPositionMs)
        state.durationMs = state.currentSong?.durationMs ?? 0
        state.shuffleModeEnabled = saved.shuffleModeEnabled
        state.repeatMode = saved.repeatMode
        state.status = .paused
        listening.onItemChanged(state.currentSong?.id, durationMs: state.durationMs, isPlaying: false)
        history.onItemBecameCurrent(state.currentSong, isPlaying: false)
        reevaluateTransition()
        updateNowPlaying()
    }

    private func restartAfterConfigurationChange() {
        guard state.currentEntry != nil else { return }
        let wasPlaying = state.isPlaying
        startCurrent(at: currentPositionMs(), playing: wasPlaying)
    }

    // MARK: Audio session, remote commands, Now Playing

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ArtworkLoader.didChange, object: nil, queue: .main) { [weak self] note in
            let path = note.object as? String
            MainActor.assumeIsolated {
                guard let self, path == self.state.currentSong?.url.path else { return }
                self.artworkSongId = nil
                self.updateNowPlaying()
            }
        })
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        })
        // Unplugging headphones pauses playback ("becoming noisy").
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, self?.state.isPlaying == true { self?.pause() }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.visualMotion.removeAll()
                self?.nowPlayingUpdate?.cancel()
                self?.nowPlayingUpdate = nil
                self?.publishNowPlaying()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.visualMotion.removeAll()
                self?.nowPlayingUpdate?.cancel()
                self?.nowPlayingUpdate = nil
                self?.publishNowPlaying()
                self?.listening.checkpoint()
                self?.persistNow()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateNowPlaying()
            }
        })
    }

    private func handleInterruption(type: UInt?, options: UInt?) {
        guard let type, let interruption = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch interruption {
        case .began:
            if state.isPlaying {
                pause()
            }
        case .ended:
            if AVAudioSession.InterruptionOptions(rawValue: options ?? 0).contains(.shouldResume) { play() }
        @unknown default:
            break
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = Int64(event.positionTime * 1000)
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func recordAlbumPlayed(_ songID: Int64) {
        let database = database
        albumHistoryQueue.async { try? database.recordAlbumOfSongPlayed(songID) }
    }

    func setVisualMotion(_ reason: VisualMotion, active: Bool) {
        if active { visualMotion.insert(reason) } else { visualMotion.remove(reason) }
        if visualMotion.isEmpty, nowPlayingUpdate != nil { updateNowPlaying() }
    }

    /// Coalesce duplicate state/artwork publications. During gestures, keep MediaPlayer IPC
    /// off the initial input frame; a bounded delay also guarantees updates on a held drag.
    private func updateNowPlaying() {
        nowPlayingUpdate?.cancel()
        let delayed = !visualMotion.isEmpty && UIApplication.shared.applicationState == .active
        nowPlayingUpdate = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(delayed ? 350 : 0)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.nowPlayingUpdate = nil
            self.publishNowPlaying()
        }
    }

    private func publishNowPlaying() {
        guard let song = state.currentSong else {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        if artworkSongId != song.id {
            artworkSongId = song.id
            let exact = ArtworkLoader.shared.cachedImage(for: song.url, maxPixels: 600)
            let cached = exact ?? ArtworkLoader.shared.cachedImage(for: song.url, maxPixels: 600, fallbackSizes: [1200, 400, 300, 150, 120, 80])
            artwork = cached.map(Self.makeArtwork)
            if exact == nil { loadArtwork(for: song) }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: Double(state.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(currentPositionMs()) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.isPlaying ? .playing : .paused
    }

    private func loadArtwork(for song: Song) {
        let url = song.url
        Task {
            let image = await ArtworkLoader.shared.image(for: url, maxPixels: 600)
            guard let image, self.state.currentSong?.id == song.id else { return }
            self.artwork = Self.makeArtwork(image)
            self.updateNowPlaying()
        }
    }

    /// Nonisolated: the system calls the image handler off the main thread.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

/// The controller as the A–B loop sees it.
@MainActor
private final class ControllerLoopPlayer: LoopPlayer {
    unowned let controller: PlayerController

    init(controller: PlayerController) {
        self.controller = controller
    }

    var currentSongId: Int64? { controller.state.currentSong?.id }
    var currentIndex: Int { controller.state.currentIndex }
    var positionMs: Int64 { controller.currentPositionMs() }
    var durationMs: Int64 { controller.state.durationMs }

    func seekTo(_ positionMs: Int64) { controller.loopSeek(positionMs) }
}

/// Pattern-matching helper for collection refs.
private enum CollectionKindRef {
    case album(Int64)
    case playlist(Int64)

    init(_ ref: CollectionRef) {
        self = ref.kind == .album ? .album(ref.id) : .playlist(ref.id)
    }
}

/// The live playing position (see [PlayerController.clock]).
@MainActor
@Observable
final class PlaybackClock {
    var positionMs: Int64 = 0
}
