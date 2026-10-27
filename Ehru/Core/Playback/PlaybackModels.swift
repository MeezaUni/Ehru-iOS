import Foundation

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off = "OFF"
    case one = "ONE"
    case all = "ALL"

    /// Off → all → one → off (the Now Playing button).
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

enum PlaybackStatus: Sendable {
    case idle
    case buffering
    case playing
    case paused
}

/// One entry of the play queue. [id] is unique per entry, so duplicates of a song stay distinct
/// (Android used the Media3 timeline window uid for this).
struct QueueEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let song: Song
    /// The album or playlist this entry was started from, and which occurrence it is.
    let origin: QueueOrigin?

    init(song: Song, origin: QueueOrigin? = nil, id: UUID = UUID()) {
        self.id = id
        self.song = song
        self.origin = origin
    }
}

/// One track that actually started playing during the current session. [entryId] is unique
/// within the session, so the same song played twice gives two entries.
struct QueueHistoryEntry: Identifiable, Hashable, Sendable {
    let entryId: Int64
    let song: Song
    let playedAtMs: Int64

    var id: Int64 { entryId }
}

/// Temporary A–B loop of the current track. A and B are set separately; the loop can only be
/// enabled once both are set with A before B. It belongs to one queue entry and is never persisted.
struct AbLoopState: Equatable, Sendable {
    let songId: Int64
    var startMs: Int64?
    var endMs: Int64?
    var enabled = false

    var isComplete: Bool { startMs != nil && endMs != nil }
}

/// Result of an A–B loop command, for the message shown to the user.
enum AbLoopEdit: Equatable, Sendable {
    case ok
    /// Nothing is playing.
    case noTrack
    /// A would not be at least a second before B.
    case aNotBeforeB
    /// Enabling needs both markers, A before B, on the current track.
    case notReady
    /// The player cannot schedule the loop.
    case unsupported
}

/// What the screens see of playback (Android's PlaybackState).
struct PlaybackState: Equatable, Sendable {
    var queue: [QueueEntry] = []
    /// Index of the current entry in [queue], or -1 when the queue is empty.
    var currentIndex = -1
    var status: PlaybackStatus = .idle
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var shuffleModeEnabled = false
    var repeatMode: RepeatMode = .off
    /// Tracks that started playing this session, most recent first.
    var history: [QueueHistoryEntry] = []
    var abLoop: AbLoopState?

    var currentEntry: QueueEntry? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    var currentSong: Song? { currentEntry?.song }
    var currentCollection: CollectionRef? { currentEntry?.origin?.collection }
    var isPlaying: Bool { status == .playing }

    /// Index of the entry that plays next in this repeat mode, or -1.
    var nextIndex: Int { PlayOrder.next(after: currentIndex, count: queue.count, repeatMode: repeatMode, userSkip: true) ?? -1 }
    var previousIndex: Int { PlayOrder.previous(before: currentIndex, count: queue.count, repeatMode: repeatMode) ?? -1 }
    var nextSong: Song? { queue.indices.contains(nextIndex) ? queue[nextIndex].song : nil }
    var previousSong: Song? { queue.indices.contains(previousIndex) ? queue[previousIndex].song : nil }
}

/// Which entry follows which (Media3's play order; the queue itself is shuffled physically).
/// For navigation (skip buttons, the "next" shown on screen) repeat one counts as off, as in Media3.
enum PlayOrder {
    /// The entry after [index]. A track ending on its own ([userSkip] false) is replayed in repeat
    /// one; repeat all wraps round. nil when nothing follows.
    static func next(after index: Int, count: Int, repeatMode: RepeatMode, userSkip: Bool) -> Int? {
        guard count > 0, index >= 0 else { return nil }
        if repeatMode == .one && !userSkip { return index }
        if index + 1 < count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    static func previous(before index: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0, index >= 0 else { return nil }
        if index > 0 { return index - 1 }
        return repeatMode == .all ? count - 1 : nil
    }
}

/// The upcoming part of a queue (everything after [currentIndex]) in a new random order, or nil when
/// fewer than two entries are upcoming. The current and already-played part stays where it is.
func shuffledUpcoming<T>(_ queue: [T], currentIndex: Int, using generator: inout some RandomNumberGenerator) -> [T]? {
    let start = max(currentIndex + 1, 0)
    guard queue.count - start >= 2 else { return nil }
    return Array(queue[start...]).shuffled(using: &generator)
}

func shuffledUpcoming<T>(_ queue: [T], currentIndex: Int) -> [T]? {
    var generator = SystemRandomNumberGenerator()
    return shuffledUpcoming(queue, currentIndex: currentIndex, using: &generator)
}

/// Where the upcoming part of a queue of [queueSize] entries starts: right after the current entry.
func upcomingStart(queueSize: Int, currentIndex: Int) -> Int {
    queueSize == 0 ? 0 : currentIndex.clamped(0, queueSize - 1) + 1
}

/// A queue entry taken out of the queue, kept so it can be put back exactly where it was.
struct QueueRemoval<T> {
    let index: Int
    let item: T
}

/// Undo stack of queue removals, newest last. Undoing in reverse order restores every position.
struct QueueRemovals<T> {
    private var stack: [QueueRemoval<T>] = []
    private let capacity: Int

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    var count: Int { stack.count }

    mutating func push(index: Int, item: T) {
        stack.append(QueueRemoval(index: index, item: item))
        while stack.count > capacity { stack.removeFirst() }
    }

    mutating func pop() -> QueueRemoval<T>? { stack.popLast() }

    /// The queue was replaced as a whole: old positions mean nothing any more.
    mutating func clear() { stack.removeAll() }
}

/// Playback state persisted across launches (Android's PersistedPlaybackState).
struct PersistedPlaybackState: Codable, Equatable {
    var queueSongIds: [Int64] = []
    var currentIndex = 0
    var positionMs: Int64 = 0
    var shuffleModeEnabled = false
    var repeatMode: RepeatMode = .off
    /// Where each entry was started from ([QueueOrigin.key]), parallel to [queueSongIds]; "" for none.
    var queueCollectionKeys: [String] = []
}

struct RestoredQueue: Equatable {
    let songs: [Song]
    let startIndex: Int
    let startPositionMs: Int64
    /// Where each restored entry was started from (parallel to [songs]); nil = an ordinary entry.
    var origins: [QueueOrigin?] = []
}

/// Rebuilds a playable queue from a saved snapshot and the songs that still exist ([available], any
/// order). Deleted songs are dropped; if the current one is gone, playback restarts at the next
/// surviving song (or the first one) from position 0.
func buildRestoredQueue(_ state: PersistedPlaybackState, available: [Song]) -> RestoredQueue? {
    guard !state.queueSongIds.isEmpty else { return nil }
    let byId = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var songs: [Song] = []
    var origins: [QueueOrigin?] = []
    var restoredCurrent = -1
    var nextSurviving = -1
    for (originalIndex, id) in state.queueSongIds.enumerated() {
        guard let song = byId[id] else { continue }
        if originalIndex == state.currentIndex {
            restoredCurrent = songs.count
        } else if originalIndex > state.currentIndex && nextSurviving == -1 {
            nextSurviving = songs.count
        }
        songs.append(song)
        let key = state.queueCollectionKeys.indices.contains(originalIndex) ? state.queueCollectionKeys[originalIndex] : nil
        origins.append(QueueOrigin.fromKey(key, songId: id))
    }
    guard !songs.isEmpty else { return nil }
    if restoredCurrent >= 0 {
        return RestoredQueue(songs: songs, startIndex: restoredCurrent, startPositionMs: max(state.positionMs, 0), origins: origins)
    }
    return RestoredQueue(songs: songs, startIndex: max(nextSurviving, 0), startPositionMs: 0, origins: origins)
}

/// Tracks played during this session. A track is recorded once each time it becomes current AND
/// actually plays: skipping through tracks while paused, seeking and queue edits add nothing.
/// Kept in memory only, newest first, up to [capacity] entries.
final class SessionHistory {
    private let now: () -> Int64
    private let capacity: Int
    private var pending: Song?
    private var nextId: Int64 = 1
    private(set) var entries: [QueueHistoryEntry] = []

    init(now: @escaping () -> Int64, capacity: Int = 200) {
        self.now = now
        self.capacity = capacity
    }

    /// A new item became current ([song] nil: none). Returns true when [entries] changed.
    @discardableResult
    func onItemBecameCurrent(_ song: Song?, isPlaying: Bool) -> Bool {
        pending = song
        return isPlaying ? onPlaybackStarted() : false
    }

    /// Playback started or resumed. Returns true when [entries] changed.
    @discardableResult
    func onPlaybackStarted() -> Bool {
        guard let song = pending else { return false }
        pending = nil
        entries = Array(([QueueHistoryEntry(entryId: nextId, song: song, playedAtMs: now())] + entries).prefix(capacity))
        nextId += 1
        return true
    }

    func find(_ entryId: Int64) -> QueueHistoryEntry? { entries.first { $0.entryId == entryId } }
}

/// Turns player events into listening events for Sound Capsule. A play is one start of a song that
/// was actually listened to for at least half of its length (real playing time, not the position).
/// Listening time is the same playing time, recorded when the player stops, moves on, or at a checkpoint.
final class ListeningTracker {
    /// Share of a song that must actually be heard for the listen to count as a play.
    static let playedFraction = 0.5

    private let elapsedRealtime: () -> Int64
    private let onPlayCounted: (Int64) -> Void
    private let onListened: (Int64, Int64) -> Void
    private var songId: Int64?
    private var durationMs: Int64 = 0
    private var heardMs: Int64 = 0
    private var counted = true
    private var segmentStart: Int64?

    init(elapsedRealtime: @escaping () -> Int64, onPlayCounted: @escaping (Int64) -> Void, onListened: @escaping (Int64, Int64) -> Void) {
        self.elapsedRealtime = elapsedRealtime
        self.onPlayCounted = onPlayCounted
        self.onListened = onListened
    }

    /// The player moved to [songId] (nil: no current item): a new listen begins.
    func onItemChanged(_ songId: Int64?, durationMs: Int64, isPlaying: Bool) {
        closeSegment()
        self.songId = songId
        self.durationMs = durationMs
        heardMs = 0
        counted = songId == nil
        if isPlaying { openSegment() }
    }

    func onPlayingChanged(_ isPlaying: Bool, durationMs: Int64) {
        updateDuration(durationMs)
        if isPlaying { openSegment() } else { closeSegment() }
    }

    /// While playing (the position poll): counts the listen as soon as it reaches half the song.
    func onProgress(durationMs: Int64) {
        updateDuration(durationMs)
        let open = segmentStart.map { elapsedRealtime() - $0 } ?? 0
        countIfHeard(heardMs + open)
    }

    /// The queue played to its end: playing the song again is a new listen.
    func onEnded() {
        closeSegment()
        heardMs = 0
        counted = songId == nil
    }

    /// Records the listening time so far (bounds what a killed app can lose).
    func checkpoint() {
        guard segmentStart != nil else { return }
        closeSegment()
        openSegment()
    }

    private func updateDuration(_ durationMs: Int64) {
        if durationMs > 0 { self.durationMs = durationMs }
    }

    private func openSegment() {
        guard songId != nil, segmentStart == nil else { return }
        segmentStart = elapsedRealtime()
    }

    private func closeSegment() {
        guard let start = segmentStart else { return }
        segmentStart = nil
        let segment = elapsedRealtime() - start
        if let id = songId, segment > 0 {
            heardMs += segment
            onListened(id, segment)
            countIfHeard(heardMs)
        }
    }

    private func countIfHeard(_ heard: Int64) {
        guard let id = songId, !counted, durationMs > 0 else { return }
        if Double(heard) >= Double(durationMs) * Self.playedFraction {
            counted = true
            onPlayCounted(id)
        }
    }
}

/// Something scheduled that can be called off.
struct Cancellable {
    let cancel: () -> Void
}

/// Calls [onReached] whenever playback of queue entry [index] reaches [positionMs], every time it
/// does, until cancelled. Driven by media time.
typealias LoopScheduler = (_ index: Int, _ positionMs: Int64, _ onReached: @escaping () -> Void) -> Cancellable

/// The player as the loop sees it.
protocol LoopPlayer: AnyObject {
    var currentSongId: Int64? { get }
    var currentIndex: Int { get }
    var positionMs: Int64 { get }
    var durationMs: Int64 { get }
    func seekTo(_ positionMs: Int64)
}

/// A–B loop of the current track. Reaching B seeks back to A; the schedule lives in the playback
/// layer, so it keeps working with the screen off. Any change of the current entry other than a
/// repeat of the same entry clears the loop. Every scheduled callback checks a generation number,
/// the enabled flag and the current song before acting.
final class AbLoopController {
    /// Shortest loop: also the guard against seeking back and forth in a tight loop.
    static let minLoopMs: Int64 = 1_000
    /// B stays at least this far before the end of the track.
    static let endGuardMs: Int64 = 250

    private let scheduler: LoopScheduler?
    private unowned let player: LoopPlayer
    private let onStateChanged: (AbLoopState?) -> Void
    private(set) var state: AbLoopState?
    private var scheduled: Cancellable?
    private var generation = 0

    init(scheduler: LoopScheduler?, player: LoopPlayer, onStateChanged: @escaping (AbLoopState?) -> Void) {
        self.scheduler = scheduler
        self.player = player
        self.onStateChanged = onStateChanged
    }

    @discardableResult
    func setStart() -> AbLoopEdit {
        guard let base = currentBase() else { return .noTrack }
        let position = max(player.positionMs, 0)
        guard isValidRange(position, base.endMs) else { return .aNotBeforeB }
        var next = base
        next.startMs = position
        return apply(next)
    }

    @discardableResult
    func setEnd() -> AbLoopEdit {
        guard let base = currentBase() else { return .noTrack }
        let duration = player.durationMs
        // B must come before the very end, or the track could finish before the loop returns.
        let position = duration > 0 ? min(player.positionMs, duration - Self.endGuardMs) : player.positionMs
        guard position > 0, isValidRange(base.startMs, position) else { return .aNotBeforeB }
        var next = base
        next.endMs = position
        return apply(next)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> AbLoopEdit {
        guard enabled else {
            if var current = state {
                current.enabled = false
                _ = apply(current)
            }
            return .ok
        }
        guard let current = state, current.songId == player.currentSongId,
              current.isComplete, isValidRange(current.startMs, current.endMs)
        else { return .notReady }
        guard scheduler != nil else { return .unsupported }
        var next = current
        next.enabled = true
        let result = apply(next)
        // Already past B: start the loop at A instead of waiting for the next pass.
        if player.positionMs >= current.endMs! { player.seekTo(current.startMs!) }
        return result
    }

    func clear() {
        guard state != nil else { return }
        cancelSchedule()
        state = nil
        onStateChanged(nil)
    }

    /// The current entry changed; [sameEntryRepeated]: the same entry started again (repeat one).
    func onEntryChanged(sameEntryRepeated: Bool) {
        if !sameEntryRepeated { clear() }
    }

    private func currentBase() -> AbLoopState? {
        guard let songId = player.currentSongId else { return nil }
        if let state, state.songId == songId { return state }
        return AbLoopState(songId: songId)
    }

    private func apply(_ next: AbLoopState) -> AbLoopEdit {
        cancelSchedule()
        state = next
        if let scheduler, next.enabled, let start = next.startMs, let end = next.endMs {
            let mine = generation
            let songId = next.songId
            scheduled = scheduler(player.currentIndex, end) { [weak self] in
                guard let self, self.isLive(mine, songId: songId) else { return }
                self.player.seekTo(start)
            }
        }
        onStateChanged(next)
        return .ok
    }

    private func cancelSchedule() {
        generation += 1
        scheduled?.cancel()
        scheduled = nil
    }

    private func isLive(_ mine: Int, songId: Int64) -> Bool {
        mine == generation && player.currentSongId == songId && state?.enabled == true && state?.songId == songId
    }

    /// A at least [minLoopMs] before B; true while either is still unset.
    private func isValidRange(_ start: Int64?, _ end: Int64?) -> Bool {
        guard let start, let end else { return true }
        return end - start >= Self.minLoopMs
    }
}
