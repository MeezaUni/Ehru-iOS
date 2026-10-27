import AVFoundation
import Foundation

/// What an on-device tempo analysis concluded.
enum TempoEstimate: Equatable {
    /// [bpm] was found in [sectionsAgreeing] of the [sections] analysed stretches of the song.
    case found(bpm: Int, sectionsAgreeing: Int, sections: Int)
    /// No dependable tempo; nothing should be written then.
    case uncertain(String)
}

/// Estimates a song's tempo from its audio, on the device (no upload, no model), as on Android:
/// 1. an onset-strength envelope (spectral flux of the log spectrum per ~10 ms, local average removed);
/// 2. its autocorrelation over beat periods of 50–220 BPM, weighted towards 120 BPM, which settles most
///    half / double time choices; when the other octave scores almost as well, that stretch gives no tempo;
/// 3. the song is analysed in 20 s stretches, and a tempo is reported only when most of them agree within 3 %.
/// No tempo is better than a wrong one.
enum TempoEstimator {
    static let minBpm = 50.0
    static let maxBpm = 220.0
    static let sectionSeconds = 20
    private static let minSectionSeconds = 8
    private static let frame = 1024
    private static let hopSeconds = 0.0116
    private static let logGain: Float = 10
    private static let averageSeconds = 0.5
    private static let priorCenterBpm = 120.0
    private static let priorWidthOctaves = 0.7
    private static let octaveMargin = 0.8
    private static let minPeriodicity = 0.2
    private static let agreement = 0.03
    private static let octaveTolerance = 0.06

    static func estimate(_ samples: [Float], sampleRate: Int) -> TempoEstimate {
        let sectionLength = sectionSeconds * sampleRate
        guard sectionLength > 0 else { return .uncertain("Too little audio to measure a tempo") }
        let sections = stride(from: 0, to: samples.count, by: sectionLength)
            .map { Array(samples[$0..<min(samples.count, $0 + sectionLength)]) }
            .filter { $0.count >= minSectionSeconds * sampleRate }
        guard !sections.isEmpty else { return .uncertain("Too little audio to measure a tempo") }
        let results = sections.map { sectionTempo($0, sampleRate: sampleRate) }
        var tempos: [Double] = []
        var ambiguous: [(Double, Double)] = []
        for result in results {
            switch result {
            case .beat(let bpm): tempos.append(bpm)
            case .octaveAmbiguous(let bpm, let alternative): ambiguous.append((bpm, alternative))
            case .noBeat: break
            }
        }
        var best: Double?
        var bestCount = -1
        for candidate in tempos {
            let count = tempos.filter { close($0, candidate) }.count
            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }
        let agreeing = best.map { b in tempos.filter { close($0, b) } } ?? []
        let needed = sections.count == 1 ? 1 : sections.count / 2 + 1
        if agreeing.count >= needed {
            let average = agreeing.reduce(0, +) / Double(agreeing.count)
            return .found(bpm: Int(average.rounded()), sectionsAgreeing: agreeing.count, sections: sections.count)
        }
        if let pair = ambiguous.first {
            return .uncertain("Half-time / double-time ambiguity: \(Int(pair.0.rounded())) or \(Int(pair.1.rounded())) BPM")
        }
        if tempos.isEmpty { return .uncertain("No steady beat found") }
        let shown = tempos.map { String(Int($0.rounded())) }.joined(separator: ", ")
        let octaveSplit = tempos.contains { a in tempos.contains { b in abs(b / a - 2) < octaveTolerance * 2 } }
        return .uncertain(octaveSplit
            ? "Half-time / double-time ambiguity between parts of the song (\(shown) BPM)"
            : "The tempo differs between parts of the song (\(shown) BPM)")
    }

    private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= agreement * b }

    private enum SectionTempo {
        case beat(Double)
        case octaveAmbiguous(Double, Double)
        case noBeat
    }

    private static func sectionTempo(_ samples: [Float], sampleRate: Int) -> SectionTempo {
        let hop = max(1, Int((Double(sampleRate) * hopSeconds).rounded()))
        let framesPerSecond = Double(sampleRate) / Double(hop)
        let envelope = onsetEnvelope(samples, hop: hop, framesPerSecond: framesPerSecond)
        let minLag = max(Int(60 * framesPerSecond / maxBpm), 1)
        let maxLag = Int(60 * framesPerSecond / minBpm) + 1
        guard envelope.count >= maxLag * 4 else { return .noBeat }
        let acf = autocorrelation(envelope, lags: min(envelope.count / 2, 2 * maxLag + 2))
        guard acf[0] > 0 else { return .noBeat }
        func bpmAt(_ lag: Double) -> Double { 60 * framesPerSecond / lag }
        let lags = minLag...min(maxLag, acf.count - 2)
        guard !lags.isEmpty else { return .noBeat }
        func score(_ lag: Int) -> Double { acf[lag] * prior(bpmAt(Double(lag))) }
        var peak = lags.lowerBound
        for lag in lags where score(lag) > score(peak) { peak = lag }
        guard acf[peak] / acf[0] >= minPeriodicity else { return .noBeat }
        // The same beat at half or double speed is a rival when it scores almost as well.
        var rival: Int?
        for center in [peak * 2, peak / 2] {
            for lag in (center - 1)...(center + 1) where lags.contains(lag) {
                if rival == nil || score(lag) > score(rival!) { rival = lag }
            }
        }
        if let rival, score(rival) > octaveMargin * score(peak) {
            return .octaveAmbiguous(bpmAt(Double(peak)), bpmAt(Double(rival)))
        }
        // Parabolic interpolation around the peak: a fractional beat period.
        let left = acf[peak - 1], mid = acf[peak], right = acf[peak + 1]
        let denominator = left - 2 * mid + right
        let offset = denominator < 0 ? (0.5 * (left - right) / denominator).clamped(-0.5, 0.5) : 0
        let bpm = bpmAt(Double(peak) + offset)
        return (minBpm...maxBpm).contains(bpm) ? .beat(bpm) : .noBeat
    }

    private static func prior(_ bpm: Double) -> Double {
        let octaves = log(bpm / priorCenterBpm) / log(2.0) / priorWidthOctaves
        return exp(-0.5 * octaves * octaves)
    }

    /// Spectral flux per hop, minus its moving average, half-wave rectified, then centred.
    private static func onsetEnvelope(_ samples: [Float], hop: Int, framesPerSecond: Double) -> [Double] {
        let frames = samples.count < frame ? 0 : (samples.count - frame) / hop + 1
        guard frames >= 2 else { return [] }
        let window = (0..<frame).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frame))) }
        let fft = RadixTwoFFT(size: frame)
        let bins = frame / 2
        var previous = [Float](repeating: 0, count: bins)
        var current = [Float](repeating: 0, count: bins)
        var flux = [Double](repeating: 0, count: frames)
        var real = [Float](repeating: 0, count: frame)
        var imaginary = [Float](repeating: 0, count: frame)
        for f in 0..<frames {
            let start = f * hop
            for i in 0..<frame {
                real[i] = samples[start + i] * window[i]
                imaginary[i] = 0
            }
            fft.transform(&real, &imaginary)
            for k in 0..<bins { current[k] = log(1 + logGain * (real[k] * real[k] + imaginary[k] * imaginary[k]).squareRoot()) }
            if f > 0 {
                var sum = 0.0
                for k in 0..<bins { sum += Double(max(0, current[k] - previous[k])) }
                flux[f] = sum
            }
            swap(&previous, &current)
        }
        let half = max(1, Int((averageSeconds * framesPerSecond / 2).rounded()))
        var rectified = [Double](repeating: 0, count: frames)
        var sum = 0.0
        var lo = 0
        var hi = -1
        for i in 0..<frames {
            while hi < min(frames - 1, i + half) {
                hi += 1
                sum += flux[hi]
            }
            while lo < i - half {
                sum -= flux[lo]
                lo += 1
            }
            rectified[i] = max(0, flux[i] - sum / Double(hi - lo + 1))
        }
        let mean = rectified.reduce(0, +) / Double(frames)
        return rectified.map { $0 - mean }
    }

    private static func autocorrelation(_ x: [Double], lags: Int) -> [Double] {
        (0..<lags).map { lag in
            var sum = 0.0
            for i in 0..<(x.count - lag) { sum += x[i] * x[i + lag] }
            return sum / Double(x.count - lag)
        }
    }
}

/// In-place iterative radix-2 FFT of a power-of-two size.
struct RadixTwoFFT {
    let size: Int
    private let levels: Int
    private let cosTable: [Float]
    private let sinTable: [Float]

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        levels = size.trailingZeroBitCount
        cosTable = (0..<(size / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<(size / 2)).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
    }

    func transform(_ real: inout [Float], _ imaginary: inout [Float]) {
        for i in 0..<size {
            let j = Int(UInt32(i).bitReversed >> UInt32(32 - levels))
            if j > i {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }
        var length = 2
        while length <= size {
            let halfLength = length / 2
            let step = size / length
            for i in stride(from: 0, to: size, by: length) {
                for j in 0..<halfLength {
                    let k = j * step
                    let a = i + j
                    let b = a + halfLength
                    let tr = real[b] * cosTable[k] + imaginary[b] * sinTable[k]
                    let ti = -real[b] * sinTable[k] + imaginary[b] * cosTable[k]
                    real[b] = real[a] - tr
                    imaginary[b] = imaginary[a] - ti
                    real[a] += tr
                    imaginary[a] += ti
                }
            }
            length *= 2
        }
    }
}

extension UInt32 {
    /// The bits in reverse order.
    var bitReversed: UInt32 {
        var value = self
        var result: UInt32 = 0
        for _ in 0..<32 {
            result = (result << 1) | (value & 1)
            value >>= 1
        }
        return result
    }
}

/// Mono samples of a stretch of a file, reduced to about 11 kHz (plenty for beats).
enum TempoAudio {
    static let analysisSeconds = TempoEstimator.sectionSeconds * 3
    private static let startFraction = 0.25
    private static let targetRate = 11_025.0

    /// Decodes [analysisSeconds] from a quarter of the way in (past most intros). Throws when the
    /// file can't be decoded. Everything stays on the device.
    static func decode(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate > 0, channels > 0 else { throw TagWriteError.unreadable("no audio format") }
        let window = AVAudioFramePosition(Double(analysisSeconds) * rate)
        let start = max(0, min(AVAudioFramePosition(Double(file.length) * startFraction), file.length - window))
        file.framePosition = start
        let step = max(1, Int(rate / targetRate))
        var out: [Float] = []
        out.reserveCapacity(Int(window) / step + 1)
        var sum: Float = 0
        var summed = 0
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw TagWriteError.unreadable("no buffer") }
        var remaining = min(window, file.length - start)
        while remaining > 0 {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining)))
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<frames {
                var mono: Float = 0
                for c in 0..<channels { mono += data[c][i] }
                sum += mono / Float(channels)
                summed += 1
                if summed == step {
                    out.append(sum / Float(step))
                    sum = 0
                    summed = 0
                }
            }
            remaining -= AVAudioFramePosition(frames)
        }
        return (out, Int(rate) / step)
    }
}

/// Outcome of looking for a track's tempo.
enum BpmLookup: Equatable {
    case found(FoundBpm)
    /// Every source answered, none with a dependable tempo.
    case notFound(String)
    /// No source could be asked.
    case failed(String)
}

/// Finds a track's tempo, most trustworthy source first: AcousticBrainz for a MusicBrainz match
/// (only the recording id is sent; its data stops in 2022), then an estimate from the file's own
/// audio, decoded and analysed on this device. Both are treated as estimates: they can land on half
/// or double time, so they never replace a BPM the file already has.
actor BpmFinder {
    private let client: HTTPClient
    private var byRecording: [String: Result<Int, ProviderError>] = [:]

    init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    func find(_ match: MetadataCandidate, file: URL) async -> BpmLookup {
        var reasons: [String] = []
        var failures = 0
        let recordingId = match.id.hasPrefix("mb_") ? String(match.id.dropFirst(3)) : nil
        if let recordingId {
            switch await measured(recordingId) {
            case .success(let bpm): return .found(FoundBpm(bpm: bpm, source: "AcousticBrainz", estimated: true))
            case .failure(let failure):
                if failure.status == .noResults { reasons.append(failure.message) } else {
                    failures += 1
                    reasons.append("AcousticBrainz lookup failed (\(failure.message))")
                }
            }
        } else {
            reasons.append("AcousticBrainz needs a MusicBrainz match")
        }
        do {
            let pcm = try await Task.detached(priority: .utility) { try TempoAudio.decode(file) }.value
            let estimate = await Task.detached(priority: .utility) { TempoEstimator.estimate(pcm.samples, sampleRate: pcm.sampleRate) }.value
            switch estimate {
            case .found(let bpm, let agreeing, let sections):
                return .found(FoundBpm(bpm: bpm, source: "on-device estimate, \(agreeing) of \(sections) sections agree", estimated: true))
            case .uncertain(let reason):
                reasons.append("on-device estimate: \(reason)")
            }
        } catch {
            failures += 1
            reasons.append("the audio couldn't be analysed (\(error.localizedDescription))")
        }
        let reason = reasons.joined(separator: "; ")
        return failures == (recordingId == nil ? 1 : 2) ? .failed(reason) : .notFound(reason)
    }

    /// AcousticBrainz's tempo for a recording, cached for the session (network errors aren't cached).
    private func measured(_ recordingId: String) async -> Result<Int, ProviderError> {
        if let cached = byRecording[recordingId] { return cached }
        do {
            let address = requestURL("https://acousticbrainz.org/api/v1/low-level", [("recording_ids", recordingId), ("features", "rhythm.bpm")])
            let (data, response) = try await client.get(address, headers: ["User-Agent": metadataUserAgent])
            try checkStatus(response)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let result = Self.bpm(fromAcousticBrainz: object, recordingId: recordingId)
            byRecording[recordingId] = result
            return result
        } catch {
            return .failure(classifyProviderFailure(error))
        }
    }

    /// The median of AcousticBrainz's analyses when they all agree within 3 %; analyses that
    /// disagree (often by half / double time) give none, rather than a pick.
    static func bpm(fromAcousticBrainz body: [String: Any], recordingId: String) -> Result<Int, ProviderError> {
        func none(_ reason: String) -> Result<Int, ProviderError> { .failure(ProviderError(status: .noResults, message: reason)) }
        guard let analyses = body[recordingId] as? [String: Any] else { return none("AcousticBrainz has no analysis of this recording") }
        let values = analyses.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { key -> Double? in
            ((analyses[key] as? [String: Any])?["rhythm"] as? [String: Any])?["bpm"] as? Double
        }.filter { plausibleBpm.contains(Int($0.rounded())) }
        guard !values.isEmpty else { return none("AcousticBrainz has no usable tempo for this recording") }
        let median = values.sorted()[values.count / 2]
        if values.contains(where: { abs($0 - median) > 0.03 * median }) {
            return none("AcousticBrainz's analyses disagree (\(values.map { String(Int($0.rounded())) }.joined(separator: ", ")) BPM)")
        }
        return .success(Int(median.rounded()))
    }
}
