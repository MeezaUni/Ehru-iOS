import Foundation

enum FilterType: String, CaseIterable, Codable {
    case peaking = "PEAKING"
    case lowShelf = "LOW_SHELF"
    case highShelf = "HIGH_SHELF"
}

/// Biquad IIR filter from Robert Bristow-Johnson's Audio EQ Cookbook (same maths as Android).
struct BiquadFilter {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    private(set) var frequency: Float = 1000
    private(set) var gainDb: Float = 0
    private(set) var qFactor: Float = 1.414
    private(set) var filterType: FilterType = .peaking

    mutating func configure(centerFrequency: Float, sampleRate: Int, gainInDb: Float, q: Float = 1.414, type: FilterType = .peaking) {
        frequency = centerFrequency
        gainDb = gainInDb
        qFactor = q
        filterType = type
        guard gainInDb != 0, sampleRate > 0 else {
            b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
            return
        }
        let a = pow(10.0, Double(gainInDb) / 40.0)
        let w0 = 2.0 * Double.pi * Double(centerFrequency) / Double(sampleRate)
        let cosW0 = cos(w0)
        let rawB0, rawB1, rawB2, rawA0, rawA1, rawA2: Double
        switch type {
        case .peaking:
            let alpha = sin(w0) / (2.0 * Double(max(q, 0.1)))
            rawB0 = 1 + alpha * a
            rawB1 = -2 * cosW0
            rawB2 = 1 - alpha * a
            rawA0 = 1 + alpha / a
            rawA1 = -2 * cosW0
            rawA2 = 1 - alpha / a
        case .lowShelf, .highShelf:
            let inside = max((a + 1 / a) * (1 / Double(max(q, 0.1)) - 1) + 2, 0)
            let alpha = sin(w0) / 2 * sqrt(inside)
            let beta = 2 * sqrt(max(a, 0.0001)) * alpha
            if type == .lowShelf {
                rawB0 = a * ((a + 1) - (a - 1) * cosW0 + beta)
                rawB1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
                rawB2 = a * ((a + 1) - (a - 1) * cosW0 - beta)
                rawA0 = (a + 1) + (a - 1) * cosW0 + beta
                rawA1 = -2 * ((a - 1) + (a + 1) * cosW0)
                rawA2 = (a + 1) + (a - 1) * cosW0 - beta
            } else {
                rawB0 = a * ((a + 1) + (a - 1) * cosW0 + beta)
                rawB1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
                rawB2 = a * ((a + 1) + (a - 1) * cosW0 - beta)
                rawA0 = (a + 1) - (a - 1) * cosW0 + beta
                rawA1 = 2 * ((a - 1) - (a + 1) * cosW0)
                rawA2 = (a + 1) - (a - 1) * cosW0 - beta
            }
        }
        b0 = Float(rawB0 / rawA0)
        b1 = Float(rawB1 / rawA0)
        b2 = Float(rawB2 / rawA0)
        a1 = Float(rawA1 / rawA0)
        a2 = Float(rawA2 / rawA0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        if !y.isFinite {
            reset()
            return x
        }
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    /** Gain in dB of the configured filter at [targetFrequency]. */
    func frequencyResponse(_ targetFrequency: Float, sampleRate: Int) -> Float {
        if gainDb == 0 || sampleRate <= 0 { return 0 }
        let w = 2.0 * Double.pi * Double(targetFrequency) / Double(sampleRate)
        let (cosW, cos2W, sinW, sin2W) = (cos(w), cos(2 * w), sin(w), sin(2 * w))
        let (fb0, fb1, fb2, fa1, fa2) = (Double(b0), Double(b1), Double(b2), Double(a1), Double(a2))
        let numReal = fb0 + fb1 * cosW + fb2 * cos2W
        let numImag = -fb1 * sinW - fb2 * sin2W
        let denReal = 1.0 + fa1 * cosW + fa2 * cos2W
        let denImag = -fa1 * sinW - fa2 * sin2W
        let denMagSq = denReal * denReal + denImag * denImag
        if denMagSq == 0 { return 0 }
        return Float(10 * log10((numReal * numReal + numImag * numImag) / denMagSq))
    }
}

/// A second-order Butterworth high- or low-pass (Q = 1/√2), for filter sweeps. Reconfiguring keeps
/// the state, so a cutoff moving in small steps sweeps smoothly.
struct PassFilter {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    private static let butterworthQ = 0.7071067811865476
    private static let minCutoffHz: Float = 10
    private static let maxCutoffFraction: Float = 0.45

    mutating func configure(_ type: PassType, cutoffHz: Float, sampleRate: Int) {
        let nyquistSafe = Float(sampleRate) * Self.maxCutoffFraction
        let w0 = 2.0 * Double.pi * Double(cutoffHz.clamped(Self.minCutoffHz, nyquistSafe)) / Double(sampleRate)
        let cosW = cos(w0)
        let alpha = sin(w0) / (2.0 * Self.butterworthQ)
        let a0 = 1.0 + alpha
        let nb0, nb1: Double
        switch type {
        case .lowPass:
            nb0 = (1 - cosW) / 2
            nb1 = 1 - cosW
        case .highPass:
            nb0 = (1 + cosW) / 2
            nb1 = -(1 + cosW)
        }
        b0 = Float(nb0 / a0)
        b1 = Float(nb1 / a0)
        b2 = b0
        a1 = Float(-2 * cosW / a0)
        a2 = Float((1 - alpha) / a0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        if !y.isFinite {
            reset()
            return x
        }
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }
}
