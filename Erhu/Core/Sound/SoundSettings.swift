import Foundation

/// The equaliser's fixed layout (same as Android's CustomEqAudioProcessor).
enum Equalizer {
    static let bandCount = 8
    static let minBandCount = 4
    static let defaultQ: Float = 1.414
    static let minQ: Float = 0.5
    static let maxQ: Float = 5.0
    static let minFreqHz: Float = 20
    static let maxFreqHz: Float = 18_000
    static let minGainDb: Float = -15
    static let maxGainDb: Float = 15
    static let bandFrequencies: [Float] = [60, 150, 400, 1000, 2400, 6000, 12000, 16000]
    /// Above this share of the sample rate a band is skipped.
    static let maxBandToSampleRateRatio: Float = 0.45
}

struct BandConfig: Equatable, Codable {
    var frequencyHz: Float
    var gainDb: Float
    var q: Float = Equalizer.defaultQ
    var filterType: FilterType = .peaking
}

struct EqPreset: Equatable, Codable, Identifiable {
    let id: String
    var name: String
    var bandGains: [Float]
    var bandFrequencies: [Float] = Equalizer.bandFrequencies
    var bandQs: [Float] = Array(repeating: Equalizer.defaultQ, count: Equalizer.bandCount)
    var filterTypes: [FilterType] = Array(repeating: .peaking, count: Equalizer.bandCount)
    var isCustom = false

    static let flat = EqPreset(id: "preset_flat", name: "Flat", bandGains: [0, 0, 0, 0, 0, 0, 0, 0])
    static let bassBooster = EqPreset(id: "preset_bass_booster", name: "Bass Booster", bandGains: [6, 5, 3, 1, 0, 0, 0, 0])
    static let trebleBooster = EqPreset(id: "preset_treble_booster", name: "Treble Booster", bandGains: [0, 0, 0, 0, 1, 3, 5, 6])
    static let rock = EqPreset(id: "preset_rock", name: "Rock", bandGains: [5, 3, -1, -2, 1, 3, 5, 6])
    static let pop = EqPreset(id: "preset_pop", name: "Pop", bandGains: [-1, 1, 3, 4, 4, 3, 1, -1])
    static let jazz = EqPreset(id: "preset_jazz", name: "Jazz", bandGains: [3, 2, 1, 2, -1, -1, 2, 3])
    static let vocal = EqPreset(id: "preset_vocal", name: "Vocal", bandGains: [-2, -1, 2, 5, 4, 2, 0, -2])
    static let acoustic = EqPreset(id: "preset_acoustic", name: "Acoustic", bandGains: [4, 3, 1, 2, 2, 3, 3, 2])

    static let defaults = [flat, bassBooster, trebleBooster, rock, pop, jazz, vocal, acoustic]
}

struct SoundSettings: Equatable, Codable {
    var isEqEnabled = true
    var bands: [BandConfig] = SoundSettings.defaultBands()
    var activeBandCount = Equalizer.bandCount
    var selectedBandIndex = 0
    var activePresetId = EqPreset.flat.id
    var customPresets: [EqPreset] = []

    var allPresets: [EqPreset] { EqPreset.defaults + customPresets }

    static func defaultBands() -> [BandConfig] {
        Equalizer.bandFrequencies.map { BandConfig(frequencyHz: $0, gainDb: 0) }
    }

    /// Anything a stored file could hold that the app could not have produced is repaired
    /// (Android's PersistedSoundSettings.toSoundSettings).
    func repaired() -> SoundSettings {
        let count = Equalizer.bandCount
        let customs = customPresets
            .filter { $0.bandGains.count == count && !$0.id.isBlank }
            .map { preset -> EqPreset in
                var p = preset
                if p.bandFrequencies.count != count { p.bandFrequencies = Equalizer.bandFrequencies }
                if p.bandQs.count != count { p.bandQs = Array(repeating: Equalizer.defaultQ, count: count) }
                if p.filterTypes.count != count { p.filterTypes = Array(repeating: .peaking, count: count) }
                p.isCustom = true
                return p
            }
        var out = self
        out.bands = bands.count == count ? bands : SoundSettings.defaultBands()
        out.customPresets = customs
        out.activeBandCount = activeBandCount.clamped(Equalizer.minBandCount, count)
        out.selectedBandIndex = selectedBandIndex.clamped(0, out.activeBandCount - 1)
        let known = Set((EqPreset.defaults + customs).map(\.id))
        if !known.contains(activePresetId) { out.activePresetId = EqPreset.flat.id }
        return out
    }
}
