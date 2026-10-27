import AVFoundation
import Foundation

/// The app's audio graph (what ExoPlayer + its audio processors were on Android):
///
///     deck A: player node → transition stage ┐
///                                            ├→ mixer → equaliser → main mixer → output
///     deck B: player node → transition stage ┘                      └ tap (visualizer, meter)
///
/// One deck plays at a time; both play during a crossfade. Because both decks run on the same
/// render clock, the incoming track starts on the exact sample its fade-in begins, and the
/// outgoing track keeps playing on its own deck (no hand-over between players as on Android).
/// Consecutive tracks with the same format are queued back to back on one deck: gapless.
@MainActor
final class AudioEngine {
    /// One player node and its transition stage.
    final class Deck {
        let player = AVAudioPlayerNode()
        let stage = TransitionStageKernel()
        var stageUnit: AVAudioUnit?
        var format: AVAudioFormat?
        /// Segments scheduled on this deck since its last play(), in order.
        var segments: [Segment] = []
        /// Bumped whenever the deck is stopped, so callbacks of earlier schedules are ignored.
        var generation = 0
        /// The render clock may be unavailable after pausing the node.
        var pausedFrame: AVAudioFramePosition = 0
    }

    struct Segment {
        let entryId: UUID
        let file: AVAudioFile
        /// First frame of the file that plays.
        let fileStartFrame: AVAudioFramePosition
        let frameCount: AVAudioFrameCount
        /// Player sample time at which this segment starts (frames since the deck's play()).
        let deckStartFrame: AVAudioFramePosition
    }

    enum EngineError: Error {
        case notReady
        case unreadable(URL)
    }

    /// An entry played to its end on its own. Main thread.
    var onEntryFinished: ((UUID) -> Void)?
    /// The engine was rebuilt after a route or configuration change.
    var onConfigurationChange: (() -> Void)?

    let eqKernel = EqKernel()
    let tap = AudioTap()

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var eqUnit: AVAudioUnit?
    private let decks = [Deck(), Deck()]
    private var activeIndex = 0
    private(set) var isReady = false
    private var configurationObserver: NSObjectProtocol?

    var active: Deck { decks[activeIndex] }

    /// What the app hands to iOS after its processing (nil before the graph is built).
    var outputFormat: AVAudioFormat? { isReady ? engine.mainMixerNode.outputFormat(forBus: 0) : nil }
    /// The PCM format the playing file is decoded to, before the app's processing.
    var decodedFormat: AVAudioFormat? { currentSegment(active)?.file.processingFormat }
    var isRunning: Bool { engine.isRunning }
    /// Whether the equaliser and transition stages are in the graph (they are unless the audio units failed to load).
    var hasProcessing: Bool { eqUnit != nil }
    var other: Deck { decks[1 - activeIndex] }

    /// Builds the graph (the custom audio units are made asynchronously).
    func setUp() async {
        guard !isReady else { return }
        do {
            let eq = try await KernelAudioUnit.make(kernel: eqKernel)
            eqUnit = eq
            for deck in decks {
                deck.stageUnit = try await KernelAudioUnit.make(kernel: deck.stage)
            }
        } catch {
            NSLog("Ehru: audio units unavailable, playing without DSP: \(error)")
        }
        engine.attach(mixer)
        if let eqUnit { engine.attach(eqUnit) }
        for deck in decks {
            engine.attach(deck.player)
            if let unit = deck.stageUnit { engine.attach(unit) }
        }
        connectOutput()
        for (index, deck) in decks.enumerated() {
            connect(deck, bus: index, format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!)
        }
        engine.prepare()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        isReady = true
    }

    private func connectOutput() {
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: outputRate > 0 ? outputRate : 48_000, channels: 2)!
        if let eqUnit {
            engine.connect(mixer, to: eqUnit, format: format)
            engine.connect(eqUnit, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        let tap = self.tap
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            tap.write(buffer, time: Date().timeIntervalSince1970)
        }
    }

    private func connect(_ deck: Deck, bus: Int, format: AVAudioFormat) {
        if let unit = deck.stageUnit {
            engine.connect(deck.player, to: unit, format: format)
            engine.connect(unit, to: mixer, fromBus: 0, toBus: bus, format: format)
        } else {
            engine.connect(deck.player, to: mixer, fromBus: 0, toBus: bus, format: format)
        }
        deck.format = format
    }

    private func startEngineIfNeeded() throws {
        if !engine.isRunning { try engine.start() }
    }

    var volume: Float {
        get { mixer.outputVolume }
        set { mixer.outputVolume = newValue.clamped(0, 1) }
    }

    // MARK: Playing

    /// Stops both decks and starts [url] (entry [entryId]) at [positionMs] on the active deck.
    func play(entryId: UUID, url: URL, positionMs: Int64, startPlaying: Bool) throws {
        guard isReady else { throw EngineError.notReady }
        guard let file = try? AVAudioFile(forReading: url) else { throw EngineError.unreadable(url) }
        stop(other)
        stop(active)
        other.stage.cancel()
        active.stage.cancel()
        let deck = active
        ensureFormat(deck, file.processingFormat)
        let start = AVAudioFramePosition(Double(positionMs) / 1000 * file.processingFormat.sampleRate)
        schedule(deck, entryId: entryId, file: file, from: start)
        if startPlaying {
            try startEngineIfNeeded()
            deck.player.play()
        }
    }

    /// Queues [url] right after what the active deck is playing, for a gapless boundary. False when
    /// the format differs (the boundary then needs a fresh start, a few milliseconds of gap).
    @discardableResult
    func queueGapless(entryId: UUID, url: URL) -> Bool {
        let deck = active
        guard deck.segments.count == 1, deck.segments[0].entryId != entryId,
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate == deck.format?.sampleRate,
              file.processingFormat.channelCount == deck.format?.channelCount
        else { return false }
        schedule(deck, entryId: entryId, file: file, from: 0)
        return true
    }

    /// Drops anything queued after the current segment of the active deck (the queue changed).
    /// Only possible by restarting at the current position.
    func dropQueuedAfterCurrent(currentEntry: UUID) {
        guard active.segments.count > 1, let segment = currentSegment(active), segment.entryId == currentEntry else { return }
        let positionMs = position(of: active, in: segment)
        let wasPlaying = active.player.isPlaying
        let url = segment.file.url
        try? play(entryId: segment.entryId, url: url, positionMs: positionMs, startPlaying: wasPlaying)
    }

    func pause() {
        for deck in decks where deck.player.isPlaying {
            deck.pausedFrame = playedFrames(deck)
            deck.player.pause()
        }
        // Stop rendering the DSP graph while retaining the scheduled segments.
        engine.pause()
    }

    /// Resumes the active deck (and an outgoing crossfade deck that is still sounding).
    func resume() throws {
        try startEngineIfNeeded()
        if active.segments.isEmpty == false { active.player.play() }
        if other.stage.isEngaged, !other.stage.isSilent, !other.segments.isEmpty { other.player.play() }
    }

    func stopAll() {
        stop(other)
        stop(active)
        engine.pause()
    }

    var isPlaying: Bool { active.player.isPlaying }

    /// Seeks within the active deck's current entry.
    func seek(entryId: UUID, url: URL, toMs positionMs: Int64) throws {
        let wasPlaying = active.player.isPlaying
        stop(other)
        try play(entryId: entryId, url: url, positionMs: positionMs, startPlaying: wasPlaying)
    }

    // MARK: Crossfades

    /// Starts [url] on the other deck at host time [startHostTime], fading in, while the active deck
    /// fades out from the same moment. The other deck becomes the active one.
    func crossfade(to entryId: UUID, url: URL, incomingStartMs: Int64, spec: TransitionSpec, durationMs: Int,
                   startHostTime: UInt64) throws {
        guard let file = try? AVAudioFile(forReading: url) else { throw EngineError.unreadable(url) }
        let outgoing = active
        let incoming = other
        stop(incoming)
        ensureFormat(incoming, file.processingFormat)
        let start = AVAudioFramePosition(Double(incomingStartMs) / 1000 * file.processingFormat.sampleRate)
        schedule(incoming, entryId: entryId, file: file, from: start)
        // Nothing may follow the outgoing track on its own deck any more.
        outgoing.segments = Array(outgoing.segments.prefix(1))
        outgoing.stage.arm(TransitionAutomation(role: .outgoing, spec: spec, durationMs: durationMs), startHostTime: startHostTime)
        incoming.stage.arm(TransitionAutomation(role: .incoming, spec: spec, durationMs: durationMs), startHostTime: startHostTime)
        try startEngineIfNeeded()
        incoming.player.play(at: AVAudioTime(hostTime: startHostTime))
        activeIndex = 1 - activeIndex
    }

    /// The outgoing deck of a crossfade, once its fade is over (or it ended), is stopped.
    func releaseFinishedOutgoing() {
        let deck = other
        guard !deck.segments.isEmpty, deck.stage.isSilent || !deck.stage.isEngaged else { return }
        stop(deck)
        deck.stage.cancel()
    }

    /// True while the outgoing deck of a crossfade is still sounding.
    var isCrossfading: Bool { other.player.isPlaying && other.stage.isEngaged && !other.stage.isSilent }

    /// Abandons a running crossfade: the outgoing deck stops, the incoming one plays unshaped.
    func cancelCrossfade() {
        stop(other)
        other.stage.cancel()
        active.stage.cancel()
    }

    // MARK: Position

    /// True when [entryId] is already queued to follow on the active deck (a gapless boundary).
    func hasQueued(_ entryId: UUID) -> Bool {
        active.segments.dropFirst().contains { $0.entryId == entryId }
    }

    /// The entry the active deck is playing now, and its position in ms.
    func currentPosition() -> (entryId: UUID, positionMs: Int64)? {
        guard let segment = currentSegment(active) else { return nil }
        return (segment.entryId, position(of: active, in: segment))
    }

    private func currentSegment(_ deck: Deck) -> Segment? {
        guard !deck.segments.isEmpty else { return nil }
        let played = playedFrames(deck)
        return deck.segments.last { $0.deckStartFrame <= played } ?? deck.segments.first
    }

    private func playedFrames(_ deck: Deck) -> AVAudioFramePosition {
        guard deck.player.isPlaying else { return deck.pausedFrame }
        guard let nodeTime = deck.player.lastRenderTime, let playerTime = deck.player.playerTime(forNodeTime: nodeTime) else { return deck.pausedFrame }
        return max(playerTime.sampleTime, 0)
    }

    private func position(of deck: Deck, in segment: Segment) -> Int64 {
        let frames = segment.fileStartFrame + min(max(playedFrames(deck) - segment.deckStartFrame, 0), AVAudioFramePosition(segment.frameCount))
        return Int64(Double(frames) / segment.file.processingFormat.sampleRate * 1000)
    }

    /// Seconds between audio leaving the engine and being heard (for the visualizer).
    var outputLatency: TimeInterval {
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration
    }

    var outputSampleRate: Double { engine.outputNode.outputFormat(forBus: 0).sampleRate }

    // MARK: Internals

    private func ensureFormat(_ deck: Deck, _ format: AVAudioFormat) {
        if deck.format?.sampleRate != format.sampleRate || deck.format?.channelCount != format.channelCount {
            let bus = deck === decks[0] ? 0 : 1
            connect(deck, bus: bus, format: format)
        }
    }

    private func schedule(_ deck: Deck, entryId: UUID, file: AVAudioFile, from startFrame: AVAudioFramePosition) {
        let start = startFrame.clamped(0, max(file.length - 1, 0))
        let count = AVAudioFrameCount(max(file.length - start, 1))
        let deckStart = deck.segments.last.map { $0.deckStartFrame + AVAudioFramePosition($0.frameCount) } ?? 0
        deck.segments.append(Segment(entryId: entryId, file: file, fileStartFrame: start, frameCount: count, deckStartFrame: deckStart))
        let generation = deck.generation
        deck.player.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self, weak deck] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let deck, deck.generation == generation else { return }
                    self.segmentFinished(deck, entryId: entryId)
                }
            }
        }
    }

    private func segmentFinished(_ deck: Deck, entryId: UUID) {
        if deck === other {
            // The outgoing side of a crossfade ran out: it is done.
            stop(deck)
            deck.stage.cancel()
            return
        }
        onEntryFinished?(entryId)
    }

    private func stop(_ deck: Deck) {
        deck.generation += 1
        deck.player.stop()
        deck.segments.removeAll()
        deck.pausedFrame = 0
    }

    private func handleConfigurationChange() {
        // The output changed (e.g. headphones, a new sample rate): rebuild the output side and let
        // the controller restart playback at its position.
        connectOutput()
        engine.prepare()
        onConfigurationChange?()
    }
}
