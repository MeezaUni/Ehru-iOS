import AVFoundation
import Foundation

/// Uses exactly the same plan as playback. No beat grid or harmonic key is inferred here.
struct PairTransitionTiming: Equatable {
    let plan: Planned
    let leadMs: Int64
    let tailMs: Int64

    init?(spec: TransitionSpec, outgoingMs: Int64, incomingMs: Int64) {
        guard let plan = TransitionPlanner.plan(BoundaryInfo(spec: spec, nextIndex: 1, repeatMode: .off,
                                                           abLoopEnabled: false, outgoingDurationMs: outgoingMs,
                                                           incomingDurationMs: incomingMs)).planned else { return nil }
        self.plan = plan
        leadMs = min(1_500, plan.startAtMs)
        tailMs = min(1_500, max(incomingMs - plan.incomingStartMs - Int64(plan.durationMs), 0))
    }

    var totalMs: Int64 { leadMs + Int64(plan.durationMs) + tailMs }
    var outgoingRange: Range<Int64> { (plan.startAtMs - leadMs)..<(plan.startAtMs + Int64(plan.durationMs)) }
    var incomingRange: Range<Int64> { plan.incomingStartMs..<(plan.incomingStartMs + Int64(plan.durationMs) + tailMs) }

    func sourceTime(_ role: TransitionRole, elapsedMs: Double) -> Double {
        Double(role == .outgoing ? plan.startAtMs : plan.incomingStartMs) + elapsedMs
    }

    func automation(_ role: TransitionRole) -> TransitionAutomation {
        TransitionAutomation(role: role, spec: plan.spec, durationMs: plan.durationMs)
    }
}

struct TransitionAudioSlice: Equatable, Sendable {
    /// Absolute linear PCM levels, not independently normalised for visual effect.
    let peaks: [Float]
    let rms: [Float]
    let startMs: Double
    let durationMs: Double
    let sampleRate: Double
    let channels: Int
    let peak: Float
    let meanRMS: Float

    static func dbFS(_ amplitude: Float) -> String {
        amplitude > 0 && amplitude.isFinite ? String(format: "%.1f dBFS", 20 * log10(amplitude)) : "−∞ dBFS"
    }
}

/// Channel energy is measured separately, so opposite-phase stereo never cancels the waveform.
struct TransitionSampleAccumulator {
    private var peaks: [Float]
    private var energy: [Double]
    private var samples: [Int]
    private let frames: Int64

    init(bins: Int, frames: Int64) {
        self.frames = frames
        peaks = Array(repeating: 0, count: bins)
        energy = Array(repeating: 0, count: bins)
        samples = Array(repeating: 0, count: bins)
    }

    mutating func add(_ channels: [UnsafePointer<Float>], count: Int, offset: Int64) {
        guard frames > 0, !peaks.isEmpty else { return }
        for i in 0..<count {
            let bin = min(Int((offset + Int64(i)) * Int64(peaks.count) / frames), peaks.count - 1)
            for channel in channels {
                let value = channel[i]
                guard value.isFinite else { continue }
                peaks[bin] = max(peaks[bin], abs(value))
                energy[bin] += Double(value) * Double(value)
                samples[bin] += 1
            }
        }
    }

    func result(startMs: Double, durationMs: Double, sampleRate: Double, channels: Int) -> TransitionAudioSlice? {
        let count = samples.reduce(0, +)
        guard count > 0 else { return nil }
        return TransitionAudioSlice(peaks: peaks,
                                    rms: energy.indices.map { samples[$0] > 0 ? Float(sqrt(energy[$0] / Double(samples[$0]))) : 0 },
                                    startMs: startMs, durationMs: durationMs, sampleRate: sampleRate, channels: channels,
                                    peak: peaks.max() ?? 0, meanRMS: Float(sqrt(energy.reduce(0, +) / Double(count))))
    }
}

/// Only the visible pair's short cue windows are decoded, at utility priority, with cancellation.
/// The small cache is invalidated by the actual file size/mtime, including tag edits.
actor TransitionAnalysisStore {
    static let shared = TransitionAnalysisStore()
    struct Key: Hashable {
        let url: URL
        let start: Int64
        let end: Int64
        let size: Int64
        let modified: Date
    }
    private var cache: [Key: TransitionAudioSlice] = [:]

    func slice(url: URL, range: Range<Int64>) async -> TransitionAudioSlice? {
        guard !Task.isCancelled, range.lowerBound >= 0, range.count > 0, range.count <= 20_000,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else { return nil }
        let key = Key(url: url, start: range.lowerBound, end: range.upperBound, size: size.int64Value, modified: date)
        if let cached = cache[key] { return cached }
        let worker = Task.detached(priority: .utility) { Self.decode(url: url, range: range) }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, let result else { return nil }
        if cache.count >= 8 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    static func decode(url: URL, range: Range<Int64>, bins: Int = 480) -> TransitionAudioSlice? {
        guard bins > 0, bins <= 2048, range.lowerBound >= 0, range.count > 0, range.count <= 20_000,
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, format.channelCount > 0 else { return nil }
        let start = AVAudioFramePosition((Double(range.lowerBound) * rate / 1000).rounded())
        let end = AVAudioFramePosition((Double(range.upperBound) * rate / 1000).rounded())
        // A mismatched/truncated file is unavailable, never stretched to match the requested time.
        guard start >= 0, end <= file.length + 1, end > start,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return nil }
        let stop = min(end, file.length)
        let frames = stop - start
        var accumulator = TransitionSampleAccumulator(bins: bins, frames: frames)
        file.framePosition = start
        var read: Int64 = 0
        while read < frames {
            if Task.isCancelled { return nil }
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, frames - read))) }
            catch { return nil }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { return nil }
            let channels = (0..<Int(format.channelCount)).map { UnsafePointer(data[$0]) }
            accumulator.add(channels, count: Int(buffer.frameLength), offset: read)
            read += Int64(buffer.frameLength)
        }
        return accumulator.result(startMs: Double(start) * 1000 / rate, durationMs: Double(frames) * 1000 / rate,
                                  sampleRate: rate, channels: Int(format.channelCount))
    }
}
