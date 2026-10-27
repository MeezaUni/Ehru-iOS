import Foundation

/// In-place radix-2 FFT of a fixed [size] (a power of two). Tables are computed once.
final class Fft {
    let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosTable = (0..<size / 2).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<size / 2).map { Float(-sin(2 * Double.pi * Double($0) / Double(size))) }
        let bits = size.trailingZeroBitCount
        reversed = (0..<size).map { i in
            var r = 0
            for b in 0..<bits where i & (1 << b) != 0 { r |= 1 << (bits - 1 - b) }
            return r
        }
    }

    func transform(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<size {
            let j = reversed[i]
            if j > i {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var half = 1
        while half < size {
            let step = size / (half * 2)
            var start = 0
            while start < size {
                for k in 0..<half {
                    let wr = cosTable[k * step]
                    let wi = sinTable[k * step]
                    let a = start + k
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += half * 2
            }
            half *= 2
        }
    }
}

/// Turns a window of mono samples into [bandCount] levels (0..1), log-spaced from [minHz] to
/// [maxHz] (capped below Nyquist). Each level is the band's mean power in dB mapped over a
/// [dynamicRangeDb] window under an adaptive reference that follows the loudest recent band.
/// Below [silenceDb] (RMS) every level is 0: nothing is invented.
final class SpectrumAnalyzer {
    static let defaultFftSize = 4096
    static let defaultMinHz: Float = 40
    static let defaultMaxHz: Float = 16_000
    static let defaultDynamicRangeDb: Float = 50
    static let defaultSilenceDb: Float = -70
    static let defaultReferenceDecay: Float = 6
    private static let nyquistMargin: Float = 0.95
    private static let initialReferenceDb: Float = -20
    private static let minReferenceDb: Float = -40
    private static let minDb: Float = -200
    private static let tiny = 1e-12

    let sampleRate: Int
    let bandCount: Int
    let windowSize: Int
    private let fft: Fft
    private let window: [Float]
    private let windowPowerGain: Float
    private var re: [Float]
    private var im: [Float]
    private var bandDb: [Float]
    private var referenceDb = SpectrumAnalyzer.initialReferenceDb
    private var bandStart: [Int]
    private var bandEnd: [Int]
    private(set) var bandCenterHz: [Float]

    var dynamicRangeDb = SpectrumAnalyzer.defaultDynamicRangeDb
    var silenceDb = SpectrumAnalyzer.defaultSilenceDb
    var referenceDecayDbPerSecond = SpectrumAnalyzer.defaultReferenceDecay

    init(sampleRate: Int, bandCount: Int, fftSize: Int = SpectrumAnalyzer.defaultFftSize,
         minHz: Float = SpectrumAnalyzer.defaultMinHz, maxHz: Float = SpectrumAnalyzer.defaultMaxHz) {
        precondition(sampleRate > 0 && bandCount > 0)
        self.sampleRate = sampleRate
        self.bandCount = bandCount
        windowSize = fftSize
        fft = Fft(size: fftSize)
        window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1))) }
        windowPowerGain = window.reduce(0) { $0 + $1 * $1 }
        re = Array(repeating: 0, count: fftSize)
        im = Array(repeating: 0, count: fftSize)
        bandDb = Array(repeating: 0, count: bandCount)
        bandStart = Array(repeating: 0, count: bandCount)
        bandEnd = Array(repeating: 0, count: bandCount)
        bandCenterHz = Array(repeating: 0, count: bandCount)
        let binHz = Float(sampleRate) / Float(fftSize)
        let nyquistBin = fftSize / 2
        let top = min(maxHz, Float(sampleRate) / 2 * Self.nyquistMargin)
        let logMin = log(minHz)
        let logMax = log(max(top, minHz * 2))
        for b in 0..<bandCount {
            let loHz = exp(logMin + (logMax - logMin) * Float(b) / Float(bandCount))
            let hiHz = exp(logMin + (logMax - logMin) * Float(b + 1) / Float(bandCount))
            let lo = Int((loHz / binHz).rounded()).clamped(1, nyquistBin - 1)
            let hi = Int((hiHz / binHz).rounded()).clamped(lo + 1, nyquistBin)
            bandStart[b] = lo
            bandEnd[b] = hi
            bandCenterHz[b] = Float(lo + hi - 1) / 2 * binHz
        }
    }

    /// Analyses the first [windowSize] values of [samples] into [out] (0..1). Returns false for silence.
    @discardableResult
    func analyze(_ samples: [Float], into out: inout [Float], elapsedSeconds: Float) -> Bool {
        var sumSquares = 0.0
        for i in 0..<windowSize {
            let s = samples[i]
            sumSquares += Double(s * s)
            re[i] = s * window[i]
            im[i] = 0
        }
        let rmsDb = Float(10 * log10(sumSquares / Double(windowSize) + Self.tiny))
        decayReference(elapsedSeconds)
        if rmsDb < silenceDb {
            for b in 0..<bandCount { out[b] = 0 }
            return false
        }
        fft.transform(&re, &im)
        var loudest = Self.minDb
        for b in 0..<bandCount {
            var power: Float = 0
            for k in bandStart[b]..<bandEnd[b] { power += re[k] * re[k] + im[k] * im[k] }
            let meanPower = power / Float(bandEnd[b] - bandStart[b]) * 2 / windowPowerGain / Float(windowSize)
            let db = Float(10 * log10(Double(meanPower) + Self.tiny))
            bandDb[b] = db
            if db > loudest { loudest = db }
        }
        if loudest > referenceDb { referenceDb = loudest }
        let floor = referenceDb - dynamicRangeDb
        for b in 0..<bandCount { out[b] = ((bandDb[b] - floor) / dynamicRangeDb).clamped(0, 1) }
        return true
    }

    private func decayReference(_ elapsedSeconds: Float) {
        referenceDb = max(Self.minReferenceDb, referenceDb - referenceDecayDbPerSecond * elapsedSeconds.clamped(0, 1))
    }

    /// Forgets the loudness history (new track, seek).
    func reset() {
        referenceDb = Self.initialReferenceDb
    }
}

/// Time-based attack/release smoothing of displayed levels: rises quickly, falls slowly.
final class LevelSmoother {
    static let defaultAttack: Float = 0.04
    static let defaultRelease: Float = 0.25
    private static let maxStep: Float = 0.25

    private(set) var values: [Float]
    var attackSeconds: Float
    var releaseSeconds: Float

    init(size: Int, attackSeconds: Float = LevelSmoother.defaultAttack, releaseSeconds: Float = LevelSmoother.defaultRelease) {
        values = Array(repeating: 0, count: size)
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
    }

    func update(_ target: [Float], elapsedSeconds: Float) {
        let dt = elapsedSeconds.clamped(0, Self.maxStep)
        let attack = 1 - exp(-dt / attackSeconds)
        let release = 1 - exp(-dt / releaseSeconds)
        for i in values.indices {
            let t = target[i].clamped(0, 1)
            let v = values[i]
            values[i] = (v + (t - v) * (t > v ? attack : release)).clamped(0, 1)
        }
    }

    func clear() {
        for i in values.indices { values[i] = 0 }
    }
}

/// Peak-following gain for the oscilloscope: quiet music still shows a readable wave.
final class WaveformGain {
    static let defaultDecay: Float = 1.5
    /// Below this the wave is drawn at its true (small) size: silence stays flat.
    private static let minPeak: Float = 0.05
    private var peak = WaveformGain.minPeak
    var decayPerSecond: Float

    init(decayPerSecond: Float = WaveformGain.defaultDecay) {
        self.decayPerSecond = decayPerSecond
    }

    func normalize(_ samples: [Float], count: Int, into out: inout [Float], elapsedSeconds: Float) {
        var framePeak: Float = 0
        for i in 0..<count { framePeak = max(framePeak, abs(samples[i])) }
        peak = max(max(framePeak, Self.minPeak), peak * exp(-decayPerSecond * elapsedSeconds.clamped(0, 1)))
        let gain = 1 / peak
        for i in 0..<count { out[i] = (samples[i] * gain).clamped(-1, 1) }
    }

    func reset() {
        peak = Self.minPeak
    }
}
