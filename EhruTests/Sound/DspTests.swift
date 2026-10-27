import AVFoundation
import XCTest
@testable import Ehru

/// Runs a kernel over mono float audio the way the engine would, in one or more buffers.
private func run(_ kernel: RenderKernel, _ input: [Float], sampleRate: Double, startSampleTime: Double = 0,
                 hostTime: UInt64? = nil, chunk: Int = 512) -> [Float] {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    kernel.prepare(sampleRate: sampleRate, channels: 1)
    var output: [Float] = []
    var offset = 0
    while offset < input.count {
        let frames = min(chunk, input.count - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = input[offset + i] }
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = startSampleTime + Double(offset)
        timestamp.mFlags = .sampleTimeValid
        if let hostTime {
            timestamp.mHostTime = hostTime
            timestamp.mFlags.insert(.hostTimeValid)
        }
        kernel.process(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: frames, timestamp: &timestamp)
        output += (0..<frames).map { buffer.floatChannelData![0][$0] }
        offset += frames
    }
    return output
}

final class TransitionAutomationTests: XCTestCase {
    private let linear = TransitionSpec(durationMs: 100, curve: .linear)

    func testAutomationsFollowSpecRampAndLeadIn() {
        let inc = TransitionAutomation(role: .incoming, spec: linear, durationMs: 1_000)
        XCTAssertEqual(0.25, inc.gainAt(250), accuracy: 1e-6)
        XCTAssertTrue(inc.isFinished(1_000))
        XCTAssertFalse(inc.isFinished(999))
        let out = TransitionAutomation(role: .outgoing, spec: linear, durationMs: 1_000, entryRampMs: 40)
        XCTAssertEqual(0, out.gainAt(0), accuracy: 1e-6)
        XCTAssertEqual(0.5 * (1 - 0.02), out.gainAt(20), accuracy: 1e-6)
        XCTAssertEqual(0, out.gainAt(5_000), accuracy: 1e-6)
        XCTAssertFalse(out.isFinished(5_000))
        let leadOut = TransitionAutomation(role: .outgoing, spec: linear, durationMs: 1_000, leadInMs: 3_000)
        XCTAssertEqual(1, leadOut.gainAt(1_000))
        XCTAssertEqual(0.5, leadOut.gainAt(3_500), accuracy: 1e-6)
        XCTAssertEqual(0, TransitionAutomation(role: .incoming, spec: linear, durationMs: 1_000, leadInMs: 3_000).gainAt(1_000))
    }
}

final class TransitionStageKernelTests: XCTestCase {
    private let linear = TransitionSpec(durationMs: 100, curve: .linear)
    private let rate = 1_000.0 // 1 frame per ms keeps the arithmetic readable

    private func constant(_ frames: Int) -> [Float] { Array(repeating: 0.5, count: frames) }

    func testIdleIsUnityAndArmedIncomingFadesFromItsStart() {
        let kernel = TransitionStageKernel()
        XCTAssertEqual(0.5, run(kernel, constant(4), sampleRate: rate)[3])
        kernel.arm(TransitionAutomation(role: .incoming, spec: linear, durationMs: 100), startHostTime: 0)
        XCTAssertTrue(kernel.isEngaged)
        let faded = run(kernel, constant(200), sampleRate: rate, hostTime: 0)
        XCTAssertEqual(0, faded[0])
        XCTAssertEqual(0.25, faded[50], accuracy: 1e-5)
        XCTAssertEqual(0.5, faded[150], accuracy: 1e-6)
        XCTAssertFalse(kernel.isEngaged)
    }

    func testCustomCurveExecutedPointByPoint() {
        let custom = TransitionSpec(
            durationMs: 100, preset: .custom, curve: .custom,
            outgoingCurve: .of((0, 1), (0.5, 0.2), (1, 0)), incomingCurve: .of((0, 0.5), (0.25, 0.5), (1, 1))
        )
        let incoming = TransitionStageKernel()
        incoming.arm(TransitionAutomation(role: .incoming, spec: custom, durationMs: 100), startHostTime: 0)
        let out = run(incoming, Array(repeating: 1, count: 100), sampleRate: rate, hostTime: 0)
        XCTAssertEqual(0.5, out[10], accuracy: 1e-5)
        XCTAssertEqual(0.7467, out[62], accuracy: 2e-4)
        let outgoing = TransitionStageKernel()
        outgoing.arm(TransitionAutomation(role: .outgoing, spec: custom, durationMs: 100), startHostTime: 0)
        XCTAssertEqual(0.2, run(outgoing, Array(repeating: 1, count: 100), sampleRate: rate, hostTime: 0)[50], accuracy: 1e-5)
    }

    func testOutgoingHoldsBeforeItsStartThenEndsSilent() {
        let kernel = TransitionStageKernel()
        // Starts 0.1 s (100 frames) after the first rendered buffer.
        kernel.arm(
            TransitionAutomation(role: .outgoing, spec: linear.with(curve: .equalPower), durationMs: 100),
            startHostTime: TransitionStageKernel.hostTicks(forSeconds: 0.1)
        )
        let out = run(kernel, Array(repeating: 1, count: 300), sampleRate: rate, hostTime: 0)
        XCTAssertEqual(1, out[50], accuracy: 1e-6) // before the start: full level
        XCTAssertEqual(0.7071, out[150], accuracy: 1e-3)
        XCTAssertEqual(0, out[299])
        XCTAssertTrue(kernel.isSilent)
    }

    func testCancelReturnsToUnity() {
        let kernel = TransitionStageKernel()
        kernel.arm(TransitionAutomation(role: .incoming, spec: linear, durationMs: 1_000), startHostTime: 0)
        _ = run(kernel, constant(30), sampleRate: rate, hostTime: 0)
        kernel.cancel()
        XCTAssertEqual(0.5, run(kernel, constant(1), sampleRate: rate)[0])
        XCTAssertFalse(kernel.isEngaged)
    }

    private func sineRms(_ kernel: TransitionStageKernel, hz: Double, totalMs: Int, fromMs: Int, toMs: Int) -> Double {
        let sr = 48_000.0
        let frames = Int(sr) * totalMs / 1_000
        let input = (0..<frames).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / sr)) }
        let out = run(kernel, input, sampleRate: sr, hostTime: 0)
        let from = Int(sr) * fromMs / 1_000
        let to = Int(sr) * toMs / 1_000
        let sum = out[from..<to].reduce(0.0) { $0 + Double($1 * $1) }
        return sqrt(sum / Double(to - from))
    }

    func testBassSwapRemovesIncomingBassUntilTheSwap() {
        let swap = TransitionSpec(durationMs: 1_000, curve: .linear, bassSwap: true)
        func incoming() -> TransitionStageKernel {
            let k = TransitionStageKernel()
            k.arm(TransitionAutomation(role: .incoming, spec: swap, durationMs: 1_000), startHostTime: 0)
            return k
        }
        let bassBefore = sineRms(incoming(), hz: 60, totalMs: 1_000, fromMs: 200, toMs: 300)
        let trebleBefore = sineRms(incoming(), hz: 4_000, totalMs: 1_000, fromMs: 200, toMs: 300)
        XCTAssertLessThan(bassBefore, trebleBefore * 0.25)
        let bassAfter = sineRms(incoming(), hz: 60, totalMs: 1_000, fromMs: 700, toMs: 800)
        let trebleAfter = sineRms(incoming(), hz: 4_000, totalMs: 1_000, fromMs: 700, toMs: 800)
        XCTAssertEqual(trebleAfter, bassAfter, accuracy: trebleAfter * 0.1)
    }

    func testLowPassSweepDarkensTheOutgoingTrack() {
        let spec = TransitionSpec(durationMs: 1_000, curve: .linear, filter: .lowPassOut)
        func outgoing() -> TransitionStageKernel {
            let k = TransitionStageKernel()
            k.arm(TransitionAutomation(role: .outgoing, spec: spec, durationMs: 1_000), startHostTime: 0)
            return k
        }
        // Near the end the treble is far quieter than the (equally faded) bass.
        let treble = sineRms(outgoing(), hz: 6_000, totalMs: 1_000, fromMs: 850, toMs: 900)
        let bass = sineRms(outgoing(), hz: 100, totalMs: 1_000, fromMs: 850, toMs: 900)
        XCTAssertLessThan(treble, bass * 0.3)
    }
}

final class EqTests: XCTestCase {
    func testPeakingBandBoostsItsFrequency() {
        var settings = SoundSettings()
        settings.bands[3].gainDb = 6
        let response = EqKernel.response(of: settings, at: [1_000, 60, 16_000])
        XCTAssertEqual(6, response[0], accuracy: 0.3)
        XCTAssertEqual(0, response[1], accuracy: 0.5)
    }

    func testKernelLeavesFlatAudioUntouchedAndFiltersBoostedAudio() {
        let kernel = EqKernel()
        let input = (0..<4_800).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        XCTAssertEqual(input, run(kernel, input, sampleRate: 48_000))
        var settings = SoundSettings()
        settings.bands[3].gainDb = 6
        kernel.apply(settings)
        let boosted = run(kernel, input, sampleRate: 48_000)
        let rms = sqrt(boosted[2_400...].reduce(0.0) { $0 + Double($1 * $1) } / 2_400)
        XCTAssertEqual(0.25 / sqrt(2) * 2, rms, accuracy: 0.02) // +6 dB ≈ ×2
        settings.isEqEnabled = false
        kernel.apply(settings)
        XCTAssertEqual(input, run(kernel, input, sampleRate: 48_000))
    }

    func testRepairedSettings() {
        var broken = SoundSettings()
        broken.bands = [BandConfig(frequencyHz: 60, gainDb: 3)]
        broken.activePresetId = "custom_deleted"
        broken.activeBandCount = 99
        broken.selectedBandIndex = 50
        broken.customPresets = [
            EqPreset(id: "custom_ok", name: "Ok", bandGains: Array(repeating: 1, count: 8)),
            EqPreset(id: "custom_short", name: "Short", bandGains: [1]),
            EqPreset(id: "", name: "No id", bandGains: Array(repeating: 1, count: 8)),
        ]
        let repaired = broken.repaired()
        XCTAssertEqual(SoundSettings.defaultBands(), repaired.bands)
        XCTAssertEqual(EqPreset.flat.id, repaired.activePresetId)
        XCTAssertEqual(8, repaired.activeBandCount)
        XCTAssertEqual(7, repaired.selectedBandIndex)
        XCTAssertEqual(["custom_ok"], repaired.customPresets.map(\.id))
        XCTAssertTrue(repaired.customPresets[0].isCustom)
        XCTAssertEqual(SoundSettings(), SoundSettings().repaired())
    }

    private func runtime(enabled: Bool = true, configured: Bool = true, flat: Bool = false, rate: Int? = 48_000) -> EqRuntimeState {
        EqRuntimeState(enabled: enabled, configured: configured, sampleRateHz: rate, channelCount: 2, allGainsZero: flat)
    }

    private func settings(_ gains: Float...) -> SoundSettings {
        var s = SoundSettings()
        for (i, gain) in gains.enumerated() { s.bands[i].gainDb = gain }
        return s
    }

    func testStageReflectsTheProcessor() {
        let boosted = settings(6)
        XCTAssertEqual(.active, DspDiagnostics.eqStage(runtime(), settings: boosted).status)
        XCTAssertEqual(.off, DspDiagnostics.eqStage(runtime(enabled: false), settings: boosted).status)
        XCTAssertEqual(.idle, DspDiagnostics.eqStage(runtime(configured: false), settings: boosted).status)
        XCTAssertEqual(.bypassed, DspDiagnostics.eqStage(runtime(flat: true), settings: settings()).status)
    }

    func testBandsSkippedAtLowSampleRates() {
        var high = SoundSettings()
        high.bands[7] = BandConfig(frequencyHz: 16_000, gainDb: 6)
        XCTAssertTrue(DspDiagnostics.eqStage(runtime(rate: 32_000), settings: high).activeBands[7].skippedAtThisSampleRate)
        XCTAssertFalse(DspDiagnostics.eqStage(runtime(rate: 48_000), settings: high).activeBands[7].skippedAtThisSampleRate)
    }

    func testHeadroomFollowsTheCurve() {
        let estimate = DspDiagnostics.headroom(DspDiagnostics.eqStage(runtime(), settings: settings(0, 0, 0, 6)), sampleRateHz: 48_000)
        XCTAssertEqual(6, estimate.maxBoostDb, accuracy: 0.3)
        XCTAssertEqual(1_000, estimate.atFrequencyHz!, accuracy: 150)
        XCTAssertTrue(estimate.risk == .moderate || estimate.risk == .high)
        XCTAssertTrue(estimate.advice.contains("no preamp"))
        let cutOnly = DspDiagnostics.headroom(DspDiagnostics.eqStage(runtime(), settings: settings(-6, -3)), sampleRateHz: 48_000)
        XCTAssertEqual(.none, cutOnly.risk)
        XCTAssertNil(cutOnly.atFrequencyHz)
        let off = DspDiagnostics.headroom(DspDiagnostics.eqStage(runtime(enabled: false), settings: settings(12)), sampleRateHz: 48_000)
        XCTAssertEqual(0, off.maxBoostDb)
        XCTAssertEqual(.high, DspDiagnostics.headroom(DspDiagnostics.eqStage(runtime(), settings: settings(12, 12)), sampleRateHz: 48_000).risk)
    }
}

final class VisualizerAnalysisTests: XCTestCase {
    private let rate = 48_000

    private func sine(_ hz: Double, _ amplitude: Double, count: Int = SpectrumAnalyzer.defaultFftSize) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / Double(rate))) }
    }

    func testFftFindsAPureTone() {
        let n = 1024
        let fft = Fft(size: n)
        var re = (0..<n).map { Float(sin(2 * Double.pi * 37 * Double($0) / Double(n))) }
        var im = [Float](repeating: 0, count: n)
        fft.transform(&re, &im)
        let magnitudes = (0..<n / 2).map { sqrt(re[$0] * re[$0] + im[$0] * im[$0]) }
        XCTAssertEqual(37, magnitudes.indices.max { magnitudes[$0] < magnitudes[$1] })
        XCTAssertEqual(Float(n) / 2, magnitudes[37], accuracy: 0.5)
        XCTAssertTrue(magnitudes.enumerated().allSatisfy { $0.offset == 37 || $0.element < 1e-2 })
    }

    func testBandsAreLogSpacedAndFollowTheSampleRate() {
        for sampleRate in [44_100, 48_000, 96_000, 22_050] {
            let centers = SpectrumAnalyzer(sampleRate: sampleRate, bandCount: 48).bandCenterHz
            XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $1 >= $0 })
            XCTAssertTrue((30...80).contains(centers.first!))
            XCTAssertLessThan(centers.last!, Float(sampleRate) / 2)
            XCTAssertLessThanOrEqual(centers.last!, 16_500)
        }
    }

    func testToneLightsItsBand() {
        let analyzer = SpectrumAnalyzer(sampleRate: rate, bandCount: 48)
        var out = [Float](repeating: 0, count: 48)
        for hz in [60.0, 1_000.0, 8_000.0] {
            analyzer.reset()
            analyzer.analyze(sine(hz, 0.5), into: &out, elapsedSeconds: 0)
            let loudest = out.indices.max { out[$0] < out[$1] }!
            XCTAssertLessThan(abs(Double(analyzer.bandCenterHz[loudest]) - hz) / hz, 0.25)
            XCTAssertGreaterThan(out[loudest], 0.5)
        }
    }

    func testSilenceProducesNoActivity() {
        let analyzer = SpectrumAnalyzer(sampleRate: rate, bandCount: 48)
        var out = [Float](repeating: 0.7, count: 48)
        XCTAssertFalse(analyzer.analyze([Float](repeating: 0, count: SpectrumAnalyzer.defaultFftSize), into: &out, elapsedSeconds: 0.016))
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
        let hiss = (0..<SpectrumAnalyzer.defaultFftSize).map { Float($0 % 2 == 0 ? 3e-5 : -3e-5) }
        XCTAssertFalse(analyzer.analyze(hiss, into: &out, elapsedSeconds: 0.016))
    }

    func testQuietAndLoudLookAlikeAfterAMoment() {
        func music(_ scale: Double) -> [Float] {
            (0..<SpectrumAnalyzer.defaultFftSize).map {
                Float(scale * (0.5 * sin(2 * Double.pi * 80 * Double($0) / 48_000) + 0.2 * sin(2 * Double.pi * 2_000 * Double($0) / 48_000)))
            }
        }
        let quiet = SpectrumAnalyzer(sampleRate: rate, bandCount: 32)
        let loud = SpectrumAnalyzer(sampleRate: rate, bandCount: 32)
        var outQuiet = [Float](repeating: 0, count: 32)
        var outLoud = [Float](repeating: 0, count: 32)
        for _ in 0..<5 {
            quiet.analyze(music(0.05), into: &outQuiet, elapsedSeconds: 1)
            loud.analyze(music(1.0), into: &outLoud, elapsedSeconds: 1)
        }
        XCTAssertGreaterThan(outQuiet.max()!, 0.9)
        for i in 0..<32 { XCTAssertEqual(outLoud[i], outQuiet[i], accuracy: 0.05, "band \(i)") }
    }

    func testSmootherRisesFastFallsSlowlyAndIgnoresFrameRate() {
        let smoother = LevelSmoother(size: 2, attackSeconds: 0.04, releaseSeconds: 0.25)
        smoother.update([1, 5], elapsedSeconds: 0.1)
        XCTAssertGreaterThan(smoother.values[0], 0.9)
        XCTAssertTrue((0.9...1).contains(smoother.values[1]))
        smoother.update([0, 0], elapsedSeconds: 0.1)
        XCTAssertTrue((0.6...0.75).contains(smoother.values[0]))
        let fast = LevelSmoother(size: 1)
        let slow = LevelSmoother(size: 1)
        for _ in 0..<60 { fast.update([0.8], elapsedSeconds: 1 / 60) }
        for _ in 0..<30 { slow.update([0.8], elapsedSeconds: 1 / 30) }
        XCTAssertEqual(fast.values[0], slow.values[0], accuracy: 1e-4)
    }

    func testWaveformGain() {
        let gain = WaveformGain()
        var out = [Float](repeating: 0, count: 512)
        gain.normalize(sine(440, 0.2, count: 512), count: 512, into: &out, elapsedSeconds: 0.016)
        XCTAssertEqual(1, out.max()!, accuracy: 0.05)
        gain.reset()
        gain.normalize([Float](repeating: 0, count: 512), count: 512, into: &out, elapsedSeconds: 0.016)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
        gain.reset()
        gain.normalize(sine(440, 0.01, count: 512), count: 512, into: &out, elapsedSeconds: 0.016)
        XCTAssertLessThan(out.max()!, 0.25)
    }

    func testTapCollectsOnlyWhileAcquiredAndIsBounded() {
        let tap = AudioTap()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            b.frameLength = AVAudioFrameCount(samples.count)
            for i in samples.indices {
                b.floatChannelData![0][i] = samples[i]
                b.floatChannelData![1][i] = samples[i]
            }
            return b
        }
        tap.write(buffer(sine(1_000, 0.5, count: 4_800)), time: 1)
        XCTAssertEqual(4_800, tap.framesWritten)
        var dest = [Float](repeating: 0, count: 1024)
        XCTAssertFalse(tap.read(into: &dest, count: 1024, framesBeforeNewest: 0))
        tap.acquire()
        for _ in 0..<40 { tap.write(buffer(sine(1_000, 0.5, count: 4_800)), time: 2) }
        XCTAssertTrue(tap.read(into: &dest, count: 1024, framesBeforeNewest: 0))
        XCTAssertEqual(0.5, dest.map(abs).max()!, accuracy: 0.01)
        XCTAssertTrue(tap.read(into: &dest, count: 1024, framesBeforeNewest: Int64(AudioTap.capacity) * 10))
        tap.release()
        XCTAssertFalse(tap.isCollecting)
        XCTAssertFalse(tap.read(into: &dest, count: 1024, framesBeforeNewest: 0))
    }
}

extension TransitionSpec {
    func with(curve: TransitionCurve) -> TransitionSpec {
        var copy = self
        copy.curve = curve
        return copy
    }
}
