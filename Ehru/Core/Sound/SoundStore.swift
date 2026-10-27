import Foundation
import Observation

/// The equaliser settings (Android's SoundRepositoryImpl): every change reaches the audio path at
/// once, and is saved when it settles (a slider drag is written once, with its final value).
@MainActor
@Observable
final class SoundStore {
    private(set) var settings: SoundSettings
    @ObservationIgnored private let kernel: EqKernel
    @ObservationIgnored private let store = JSONStore<SoundSettings>(name: "sound.json")

    init(kernel: EqKernel) {
        self.kernel = kernel
        settings = store.load()?.repaired() ?? SoundSettings()
        kernel.apply(settings)
    }

    var runtimeState: EqRuntimeState { kernel.runtimeState(settings: settings) }

    func setEqEnabled(_ enabled: Bool) { change { $0.isEqEnabled = enabled } }

    func setBandGain(_ index: Int, _ gainDb: Float) {
        guard settings.bands.indices.contains(index) else { return }
        change { $0.bands[index].gainDb = gainDb.clamped(Equalizer.minGainDb, Equalizer.maxGainDb) }
    }

    func setBandFrequency(_ index: Int, _ hz: Float) {
        guard settings.bands.indices.contains(index) else { return }
        setBandFrequencyAndGain(index, hz, settings.bands[index].gainDb)
    }

    func setBandQ(_ index: Int, _ q: Float) {
        guard settings.bands.indices.contains(index) else { return }
        change { $0.bands[index].q = q.clamped(Equalizer.minQ, Equalizer.maxQ) }
    }

    func setFilterType(_ index: Int, _ type: FilterType) {
        guard settings.bands.indices.contains(index) else { return }
        change { $0.bands[index].filterType = type }
    }

    func setActiveBandCount(_ count: Int) {
        let safe = count.clamped(Equalizer.minBandCount, Equalizer.bandCount)
        change {
            $0.activeBandCount = safe
            $0.selectedBandIndex = $0.selectedBandIndex.clamped(0, safe - 1)
        }
    }

    /// Selecting a band is not a sound change: nothing is saved.
    func setSelectedBandIndex(_ index: Int) {
        settings.selectedBandIndex = index.clamped(0, settings.activeBandCount - 1)
    }

    /// Moves a band, pushing its neighbours along so the bands stay in order (5 % apart at least).
    func setBandFrequencyAndGain(_ index: Int, _ hz: Float, _ gainDb: Float) {
        guard settings.bands.indices.contains(index) else { return }
        change { settings in
            var bands = settings.bands
            bands[index].frequencyHz = hz.clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz)
            bands[index].gainDb = gainDb.clamped(Equalizer.minGainDb, Equalizer.maxGainDb)
            let minRatio: Float = 1.05
            var i = index + 1
            while i < settings.activeBandCount {
                let minAllowed = min(bands[i - 1].frequencyHz * minRatio, Equalizer.maxFreqHz)
                if bands[i].frequencyHz < minAllowed { bands[i].frequencyHz = minAllowed }
                i += 1
            }
            i = index - 1
            while i >= 0 {
                let maxAllowed = max(bands[i + 1].frequencyHz / minRatio, Equalizer.minFreqHz)
                if bands[i].frequencyHz > maxAllowed { bands[i].frequencyHz = maxAllowed }
                i -= 1
            }
            settings.bands = bands
        }
    }

    func applyPreset(_ id: String) {
        guard let preset = settings.allPresets.first(where: { $0.id == id }) else { return }
        change { settings in
            settings.activePresetId = id
            settings.bands = (0..<Equalizer.bandCount).map { i in
                BandConfig(
                    frequencyHz: preset.bandFrequencies.indices.contains(i) ? preset.bandFrequencies[i] : Equalizer.bandFrequencies[i],
                    gainDb: preset.bandGains.indices.contains(i) ? preset.bandGains[i] : 0,
                    q: preset.bandQs.indices.contains(i) ? preset.bandQs[i] : Equalizer.defaultQ,
                    filterType: preset.filterTypes.indices.contains(i) ? preset.filterTypes[i] : .peaking
                )
            }
        }
    }

    func resetToFlat() { applyPreset(EqPreset.flat.id) }

    func saveCustomPreset(_ name: String) {
        let trimmed = name.trimmed
        if trimmed.isEmpty { return }
        let preset = EqPreset(
            id: "custom_\(UUID().uuidString.lowercased())", name: trimmed, bandGains: settings.bands.map(\.gainDb),
            bandFrequencies: settings.bands.map(\.frequencyHz), bandQs: settings.bands.map(\.q), filterTypes: settings.bands.map(\.filterType),
            isCustom: true
        )
        change {
            $0.customPresets.append(preset)
            $0.activePresetId = preset.id
        }
    }

    func deleteCustomPreset(_ id: String) {
        guard settings.customPresets.contains(where: { $0.id == id }) else { return }
        change {
            $0.customPresets.removeAll { $0.id == id }
            if $0.activePresetId == id { $0.activePresetId = EqPreset.flat.id }
        }
        if settings.activePresetId == EqPreset.flat.id { applyPreset(EqPreset.flat.id) }
    }

    /// Saves at once (the app is going to the background).
    func persistNow() { store.saveNow(settings) }

    private func change(_ edit: (inout SoundSettings) -> Void) {
        edit(&settings)
        kernel.apply(settings)
        store.save(settings)
    }
}
