import Foundation

/// What the equaliser stage reports about itself right now.
struct EqRuntimeState: Equatable {
    let enabled: Bool
    /// The engine configured it for the current audio.
    let configured: Bool
    let sampleRateHz: Int?
    let channelCount: Int?
    let allGainsZero: Bool
}

enum StageStatus: String {
    case active = "Active"
    case bypassed = "Bypassed"
    case off = "Off"
    case idle = "Not in use"
}

struct BandDescription: Equatable {
    let frequencyHz: Float
    let gainDb: Float
    let q: Float
    let type: FilterType
    /// Above 45% of the sample rate the processor skips the band.
    let skippedAtThisSampleRate: Bool
}

struct EqStage: Equatable {
    let status: StageStatus
    let reason: String
    let activeBands: [BandDescription]
}

enum ClippingRisk: String {
    case none = "None from the app"
    case low = "Low"
    case moderate = "Moderate"
    case high = "High"
}

/// A prediction from the EQ settings, not a measurement.
struct HeadroomEstimate: Equatable {
    let maxBoostDb: Float
    let atFrequencyHz: Float?
    let risk: ClippingRisk
    let advice: String
}

/// Pure description of the app's own processing; it never changes it.
enum DspDiagnostics {
    private static let defaultSampleRate = 48_000
    private static let sweepPoints = 240
    private static let minSweepHz: Float = 20
    private static let maxSweepHz: Float = 20_000

    static func eqStage(_ runtime: EqRuntimeState, settings: SoundSettings) -> EqStage {
        let rate = runtime.sampleRateHz ?? defaultSampleRate
        let bands = settings.bands.prefix(settings.activeBandCount).map {
            BandDescription(frequencyHz: $0.frequencyHz, gainDb: $0.gainDb, q: $0.q, type: $0.filterType,
                            skippedAtThisSampleRate: $0.frequencyHz >= Float(rate) * Equalizer.maxBandToSampleRateRatio)
        }
        let status: StageStatus
        let reason: String
        if !runtime.enabled {
            (status, reason) = (.off, "Turned off in Audio & Equalizer")
        } else if !runtime.configured {
            (status, reason) = (.idle, "Not configured for the current audio (nothing playing yet)")
        } else if runtime.allGainsZero {
            (status, reason) = (.bypassed, "All gains are 0 dB: audio passes through unchanged")
        } else {
            (status, reason) = (.active, "Filtering the audio with \(bands.count) bands")
        }
        return EqStage(status: status, reason: reason, activeBands: Array(bands))
    }

    static func headroom(_ stage: EqStage, sampleRateHz: Int?) -> HeadroomEstimate {
        guard stage.status == .active else {
            return HeadroomEstimate(maxBoostDb: 0, atFrequencyHz: nil, risk: .none,
                                    advice: "The app is not adding gain, so its processing adds no clipping risk.")
        }
        let rate = sampleRateHz ?? defaultSampleRate
        let filters = stage.activeBands.filter { !$0.skippedAtThisSampleRate }.map { band -> BiquadFilter in
            var filter = BiquadFilter()
            filter.configure(centerFrequency: band.frequencyHz, sampleRate: rate, gainInDb: band.gainDb, q: band.q, type: band.type)
            return filter
        }
        var maxDb = -Float.infinity
        var atHz = minSweepHz
        let top = min(maxSweepHz, Float(rate) / 2)
        for i in 0..<sweepPoints {
            let hz = exp(log(minSweepHz) + (log(top) - log(minSweepHz)) * Float(i) / Float(sweepPoints - 1))
            let db = filters.reduce(0) { $0 + $1.frequencyResponse(hz, sampleRate: rate) }
            if db > maxDb {
                maxDb = db
                atHz = hz
            }
        }
        let boost = max(maxDb, 0)
        let risk: ClippingRisk = boost <= 0.05 ? .none : boost <= 3 ? .low : boost <= 6 ? .moderate : .high
        let advice: String
        if risk == .none {
            advice = "The EQ only cuts, so it cannot push audio over full scale."
        } else {
            let at = atHz >= 1000 ? String(format: "%.1f kHz", atHz / 1000) : "\(Int(atHz)) Hz"
            advice = String(format: "The EQ raises up to %+.1f dB around %@. Loud, already-mastered music can exceed full scale there; "
                + "the EQ then clips those samples. The app has no preamp, so to keep headroom lower the boosted bands or cut the "
                + "others by about %.1f dB.", boost, at, boost)
        }
        return HeadroomEstimate(maxBoostDb: boost, atFrequencyHz: risk == .none ? nil : atHz, risk: risk, advice: advice)
    }
}
