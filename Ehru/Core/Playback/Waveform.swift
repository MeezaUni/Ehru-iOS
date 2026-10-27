import AVFoundation
import Foundation

/// Loading state of a track's waveform. Playback never depends on it.
enum WaveformLoad: Equatable {
    case loading
    /// [levels] are evenly spaced over the track's duration, each 0..1 (loudest part = 1).
    case ready([Float])
    /// Missing file, unsupported codec or no audio.
    case unavailable
}

/// Mapping between track time and a position on a waveform; both ends are exact.
enum WaveformTimeline {
    static func fractionOf(_ positionMs: Int64, _ durationMs: Int64) -> Float {
        durationMs <= 0 ? 0 : Float(min(max(Double(positionMs) / Double(durationMs), 0), 1))
    }

    static func positionAt(_ fraction: Float, _ durationMs: Int64) -> Int64 {
        durationMs <= 0 ? 0 : Int64((Double(min(max(fraction, 0), 1)) * Double(durationMs)).rounded())
    }
}

/// Reduces decoded PCM to a fixed number of amplitude bins while it streams in, so no decoded audio
/// is kept: each frame is downmixed to mono and its energy added to the bin its time falls in.
/// [finish] gives each bin's RMS, normalised so the loudest bin is 1.
struct WaveformAccumulator {
    private let bins: Int
    private let durationUs: Int64
    private var sumSquares: [Double]
    private var counts: [Int]
    private var frames: Int64 = 0

    init(bins: Int, durationUs: Int64) {
        precondition(bins > 0 && durationUs > 0, "bins and duration must be positive")
        self.bins = bins
        self.durationUs = durationUs
        sumSquares = Array(repeating: 0, count: bins)
        counts = Array(repeating: 0, count: bins)
    }

    /// Deinterleaved float channels, [frameCount] frames, the first at [firstFrame] of the track.
    mutating func add(channels: [UnsafePointer<Float>], frameCount: Int, firstFrame: Int64, sampleRate: Double) {
        guard !channels.isEmpty, sampleRate > 0 else { return }
        let channelCount = Float(channels.count)
        for frame in 0..<frameCount {
            var mono: Float = 0
            for channel in channels { mono += channel[frame] }
            mono /= channelCount
            if !mono.isFinite { continue }
            let timeUs = Double(firstFrame + Int64(frame)) * 1_000_000 / sampleRate
            let bin = min(max(Int(timeUs * Double(bins) / Double(durationUs)), 0), bins - 1)
            sumSquares[bin] += Double(mono * mono)
            counts[bin] += 1
        }
        frames += Int64(frameCount)
    }

    /// Levels 0..1 per bin, or nil when no audio frame was seen at all.
    func finish() -> [Float]? {
        if frames == 0 { return nil }
        let rms = (0..<bins).map { counts[$0] == 0 ? Float(0) : Float((sumSquares[$0] / Double(counts[$0])).squareRoot()) }
        guard let peak = rms.max(), peak > 0 else { return Array(repeating: 0, count: bins) }
        return rms.map { min(max($0 / peak, 0), 1) }
    }
}

/// One byte per level (0..255): the compact form kept in the cache.
func levelBytes(_ levels: [Float]) -> Data { Data(levels.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }) }

func levels(fromBytes data: Data) -> [Float] { data.map { Float($0) / 255 } }

/// Waveforms of tracks, made from their decoded audio and cached in the library database. Only a
/// requested track is processed, one decode at a time off the main thread; concurrent requests for
/// the same song share one decode. A cached waveform is used while the file's path, size and
/// modification time are unchanged.
actor WaveformStore {
    static let bins = 480
    static let formatVersion = 1

    private let database: LibraryDatabase
    private var inFlight: [Int64: Task<[Float]?, Never>] = [:]

    init(database: LibraryDatabase) { self.database = database }

    func waveform(_ song: Song) async -> WaveformLoad {
        guard let source = Self.fingerprint(song) else { return .unavailable }
        if let cached = try? database.cachedWaveform(songId: song.id), cached.sourceUri == song.path, cached.fileSize == source.size,
           cached.dateModified == source.modified, cached.formatVersion == Self.formatVersion, cached.levels.count == Self.bins {
            return .ready(levels(fromBytes: cached.levels))
        }
        if let running = inFlight[song.id] { return await running.value.map { .ready($0) } ?? .unavailable }
        let url = song.url
        let task = Task.detached(priority: .utility) { Self.decode(url, bins: Self.bins) }
        inFlight[song.id] = task
        let result = await task.value
        inFlight[song.id] = nil
        guard let result else { return .unavailable }
        try? database.storeWaveform(songId: song.id, sourceUri: song.path, fileSize: source.size, dateModified: source.modified,
                                    formatVersion: Self.formatVersion, levels: levelBytes(result))
        return .ready(result)
    }

    private static func fingerprint(_ song: Song) -> (size: Int64, modified: Int64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: song.url.path),
              let size = attributes[.size] as? Int64 ?? (attributes[.size] as? Int).map(Int64.init) else { return nil }
        let modified = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return (size, modified)
    }

    /// Decodes [url] once, streaming its PCM into the bins.
    static func decode(_ url: URL, bins: Int) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let total = file.length
        guard total > 0, rate > 0 else { return nil }
        var accumulator = WaveformAccumulator(bins: bins, durationUs: Int64(Double(total) / rate * 1_000_000))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return nil }
        var position: Int64 = 0
        while position < total {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let data = buffer.floatChannelData else { return nil }
            let channels = (0..<Int(format.channelCount)).map { UnsafePointer(data[$0]) }
            accumulator.add(channels: channels, frameCount: count, firstFrame: position, sampleRate: rate)
            position += Int64(count)
        }
        return accumulator.finish()
    }
}
