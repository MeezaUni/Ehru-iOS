import Foundation

enum VisualizerMode: String, CaseIterable, Codable {
    case spectrumBars = "SPECTRUM_BARS"
    case circularSpectrum = "CIRCULAR_SPECTRUM"
    case oscilloscope = "OSCILLOSCOPE"

    var label: String {
        switch self {
        case .spectrumBars: "Spectrum bars"
        case .circularSpectrum: "Circular spectrum"
        case .oscilloscope: "Oscilloscope"
        }
    }
}

/// How strongly the visualizer reacts: how much loudness range fills the display.
enum VisualizerSensitivity: String, CaseIterable, Codable {
    case low = "LOW"
    case normal = "NORMAL"
    case high = "HIGH"
}

/// How quickly levels follow the music.
enum VisualizerSmoothing: String, CaseIterable, Codable {
    case responsive = "RESPONSIVE"
    case balanced = "BALANCED"
    case smooth = "SMOOTH"
}

struct VisualizerSettings: Equatable, Codable {
    var mode: VisualizerMode = .spectrumBars
    var sensitivity: VisualizerSensitivity = .normal
    var smoothing: VisualizerSmoothing = .balanced
    var reduceMotion = false
}

enum VisualizerStatus {
    /// Showing the music that is playing.
    case active
    /// Playback paused or stopped: levels settle to rest.
    case paused
    /// Playing, no samples yet.
    case waiting
    /// Playing, but nothing arrives.
    case unavailable
}

/// One visualizer's analysis: reads the most recent window of what the engine played, turns it
/// into smoothed spectrum levels and a normalised waveform. The tap sits right before the output,
/// so a fixed output latency (reported by the audio session) locates the sample being heard.
final class VisualizerEngine {
    static let defaultBands = 48
    static let wavePoints = 256
    private static let waveWindow = 1024
    private static let waveStep = waveWindow / wavePoints
    private static let waveRestFactor: Float = 0.85
    private static let unavailableAfter: TimeInterval = 2

    let bandCount: Int
    private let tap: AudioTap
    private let smoother: LevelSmoother
    private var target: [Float]
    private var samples = [Float](repeating: 0, count: SpectrumAnalyzer.defaultFftSize)
    private var waveSamples = [Float](repeating: 0, count: VisualizerEngine.waveWindow)
    private var waveNormalized = [Float](repeating: 0, count: VisualizerEngine.waveWindow)
    private let waveGain = WaveformGain()
    private var analyzer: SpectrumAnalyzer?
    private var dynamicRangeDb = SpectrumAnalyzer.defaultDynamicRangeDb
    private var lastTime: TimeInterval = 0
    private var waitingSince: TimeInterval = 0

    private(set) var waveform = [Float](repeating: 0, count: VisualizerEngine.wavePoints)
    private(set) var status: VisualizerStatus = .waiting
    var spectrum: [Float] { smoother.values }
    var bandCenterHz: [Float]? { analyzer?.bandCenterHz }

    /// Seconds between a sample reaching the tap and it being heard.
    var outputLatency: TimeInterval = 0.05

    init(tap: AudioTap, bandCount: Int = VisualizerEngine.defaultBands) {
        self.tap = tap
        self.bandCount = bandCount
        smoother = LevelSmoother(size: bandCount)
        target = Array(repeating: 0, count: bandCount)
    }

    func apply(_ settings: VisualizerSettings) {
        let (attack, release): (Float, Float)
        switch settings.smoothing {
        case .responsive: (attack, release) = (0.02, 0.12)
        case .balanced: (attack, release) = (LevelSmoother.defaultAttack, LevelSmoother.defaultRelease)
        case .smooth: (attack, release) = (0.08, 0.5)
        }
        smoother.attackSeconds = attack
        smoother.releaseSeconds = settings.reduceMotion ? release * 1.6 : release
        switch settings.sensitivity {
        case .low: dynamicRangeDb = 60
        case .normal: dynamicRangeDb = SpectrumAnalyzer.defaultDynamicRangeDb
        case .high: dynamicRangeDb = 38
        }
        analyzer?.dynamicRangeDb = dynamicRangeDb
    }

    func update(now: TimeInterval, isPlaying: Bool) {
        let elapsed = lastTime == 0 ? 0 : Float(now - lastTime)
        lastTime = now
        let heard = isPlaying && readHeardWindow()
        status = statusFor(isPlaying: isPlaying, heard: heard, now: now)
        if heard {
            let active = analyzerFor(tap.currentSampleRate)
            active.analyze(samples, into: &target, elapsedSeconds: elapsed)
            waveGain.normalize(waveSamples, count: Self.waveWindow, into: &waveNormalized, elapsedSeconds: elapsed)
            for i in 0..<Self.wavePoints { waveform[i] = waveNormalized[i * Self.waveStep] }
        } else {
            for i in target.indices { target[i] = 0 }
            for i in waveform.indices { waveform[i] *= Self.waveRestFactor }
        }
        smoother.update(target, elapsedSeconds: elapsed)
    }

    func reset() {
        smoother.clear()
        for i in waveform.indices { waveform[i] = 0 }
        waveGain.reset()
        analyzer?.reset()
        lastTime = 0
        waitingSince = 0
    }

    private func statusFor(isPlaying: Bool, heard: Bool, now: TimeInterval) -> VisualizerStatus {
        if !isPlaying || heard {
            waitingSince = 0
            return heard ? .active : .paused
        }
        if waitingSince == 0 { waitingSince = now }
        return now - waitingSince > Self.unavailableAfter ? .unavailable : .waiting
    }

    private func readHeardWindow() -> Bool {
        let rate = tap.currentSampleRate
        guard rate > 0, tap.lastWriteTime > 0 else { return false }
        let latencyFrames = Int64(outputLatency * Double(rate))
        let ok = tap.read(into: &samples, count: samples.count, framesBeforeNewest: latencyFrames)
        if ok {
            for i in 0..<Self.waveWindow { waveSamples[i] = samples[samples.count - Self.waveWindow + i] }
        }
        return ok
    }

    private func analyzerFor(_ sampleRate: Int) -> SpectrumAnalyzer {
        if let analyzer, analyzer.sampleRate == sampleRate { return analyzer }
        let made = SpectrumAnalyzer(sampleRate: sampleRate, bandCount: bandCount)
        made.dynamicRangeDb = dynamicRangeDb
        analyzer = made
        return made
    }
}
