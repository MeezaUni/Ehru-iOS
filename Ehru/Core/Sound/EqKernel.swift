import AudioToolbox
import Foundation
import os

/// The user's equaliser on the audio thread: up to 8 cookbook biquads per channel (Android's
/// CustomEqAudioProcessor). Settings come from the main thread through a lock the audio thread
/// only ever *tries*; if it is busy, the previous coefficients play one more buffer.
final class EqKernel: RenderKernel, @unchecked Sendable {
    struct Parameters: Equatable {
        var enabled = true
        var gains: [Float] = Array(repeating: 0, count: Equalizer.bandCount)
        var frequencies: [Float] = Equalizer.bandFrequencies
        var qs: [Float] = Array(repeating: Equalizer.defaultQ, count: Equalizer.bandCount)
        var types: [FilterType] = Array(repeating: .peaking, count: Equalizer.bandCount)
        var activeCount = Equalizer.bandCount

        var isFlat: Bool { gains.allSatisfy { $0 == 0 } }

        init() {}

        init(_ settings: SoundSettings) {
            enabled = settings.isEqEnabled
            gains = settings.bands.map { $0.gainDb.clamped(Equalizer.minGainDb, Equalizer.maxGainDb) }
            frequencies = settings.bands.map { $0.frequencyHz.clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz) }
            qs = settings.bands.map { $0.q.clamped(Equalizer.minQ, Equalizer.maxQ) }
            types = settings.bands.map(\.filterType)
            activeCount = settings.activeBandCount.clamped(Equalizer.minBandCount, Equalizer.bandCount)
        }
    }

    private let pending = OSAllocatedUnfairLock<Parameters?>(initialState: nil)
    private let published = OSAllocatedUnfairLock(initialState: RuntimeState())

    // Audio thread only.
    private var parameters = Parameters()
    private var filters: [[BiquadFilter]] = []
    private var sampleRate = 44_100
    private var channels = 0
    private var needsConfigure = true

    struct RuntimeState: Equatable {
        var configured = false
        var sampleRateHz: Int?
        var channelCount: Int?
    }

    func apply(_ settings: SoundSettings) {
        pending.withLock { $0 = Parameters(settings) }
    }

    /// What the stage is doing now, for the audio inspector.
    func runtimeState(settings: SoundSettings) -> EqRuntimeState {
        let state = published.withLock { $0 }
        return EqRuntimeState(
            enabled: settings.isEqEnabled,
            configured: state.configured,
            sampleRateHz: state.sampleRateHz,
            channelCount: state.channelCount,
            allGainsZero: settings.bands.allSatisfy { $0.gainDb == 0 }
        )
    }

    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = Int(sampleRate)
        self.channels = channels
        filters = Array(repeating: Array(repeating: BiquadFilter(), count: Equalizer.bandCount), count: channels)
        needsConfigure = true
        published.withLock { $0 = RuntimeState(configured: true, sampleRateHz: Int(sampleRate), channelCount: channels) }
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, timestamp: UnsafePointer<AudioTimeStamp>) {
        if let next = pending.withLockIfAvailable({ value -> Parameters? in
            defer { value = nil }
            return value
        }) ?? nil {
            if next.enabled != parameters.enabled { resetFilters() }
            parameters = next
            needsConfigure = true
        }
        guard parameters.enabled, !parameters.isFlat, filters.count == buffers.count else { return }
        if needsConfigure { configure() }
        for channel in 0..<buffers.count {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            filters[channel].withUnsafeMutableBufferPointer { bands in
                for i in 0..<frames {
                    var sample = data[i]
                    for b in 0..<bands.count {
                        sample = bands[b].process(sample)
                    }
                    data[i] = sample.clamped(-1, 1)
                }
            }
        }
    }

    private func configure() {
        needsConfigure = false
        for channel in filters.indices {
            for b in 0..<Equalizer.bandCount {
                let usable = b < parameters.activeCount
                    && parameters.frequencies[b] < Float(sampleRate) * Equalizer.maxBandToSampleRateRatio
                filters[channel][b].configure(
                    centerFrequency: parameters.frequencies[b], sampleRate: sampleRate,
                    gainInDb: usable ? parameters.gains[b] : 0, q: parameters.qs[b], type: parameters.types[b]
                )
            }
        }
    }

    private func resetFilters() {
        for channel in filters.indices {
            for b in filters[channel].indices { filters[channel][b].reset() }
        }
    }

    /// The combined response in dB at each of [frequencies] (for drawing the EQ curve).
    static func response(of settings: SoundSettings, at frequencies: [Float], sampleRate: Int = 44_100) -> [Float] {
        let filters = settings.bands.enumerated().map { index, band -> BiquadFilter in
            var filter = BiquadFilter()
            filter.configure(
                centerFrequency: band.frequencyHz, sampleRate: sampleRate,
                gainInDb: index < settings.activeBandCount ? band.gainDb : 0, q: band.q, type: band.filterType
            )
            return filter
        }
        return frequencies.map { hz in filters.reduce(0) { $0 + $1.frequencyResponse(hz, sampleRate: sampleRate) } }
    }
}
