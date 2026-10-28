import AVFoundation
import XCTest
@testable import Ehru

final class TransitionAnalysisTests: XCTestCase {
    func testCueWindowsAndAutomationMatchPlaybackPlanner() throws {
        var spec = TransitionSpec.preset(.blend)
        spec.durationMs = 4000
        spec.outgoingCutMs = 7000
        spec.incomingStartMs = 8000
        let timing = try XCTUnwrap(PairTransitionTiming(spec: spec, outgoingMs: 60_000, incomingMs: 90_000))
        XCTAssertEqual(timing.plan.startAtMs, 49_000)
        XCTAssertEqual(timing.outgoingRange, 47_500..<53_000)
        XCTAssertEqual(timing.incomingRange, 8_000..<13_500)
        XCTAssertEqual(timing.totalMs, 7000)
        for time in [0.0, 1000, 2000, 4000] {
            for role in [TransitionRole.outgoing, .incoming] {
                XCTAssertEqual(timing.automation(role).gainAt(time), spec.gain(role, Float(time / 4000)), accuracy: 1e-6)
                XCTAssertEqual(timing.automation(role).bassDbAt(time), spec.bassDb(role, Float(time / 4000)), accuracy: 1e-6)
                XCTAssertEqual(timing.automation(role).filterAt(time), spec.filter.settingAt(role, Float(time / 4000)))
            }
        }
        XCTAssertNil(PairTransitionTiming(spec: spec, outgoingMs: 0, incomingMs: 90_000))
        XCTAssertNil(PairTransitionTiming(spec: spec, outgoingMs: 7100, incomingMs: 90_000))
    }

    func testMeasurementsKeepAbsoluteAmplitudeAndOppositePhaseStereoEnergy() throws {
        var accumulator = TransitionSampleAccumulator(bins: 2, frames: 4)
        let left: [Float] = [0.25, 0.25, 0.5, 0.5]
        let right = left.map { -$0 }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in accumulator.add([l.baseAddress!, r.baseAddress!], count: 4, offset: 0) }
        }
        let result = try XCTUnwrap(accumulator.result(startMs: 0, durationMs: 4, sampleRate: 1000, channels: 2))
        XCTAssertEqual(result.peaks, [0.25, 0.5])
        XCTAssertEqual(result.rms, [0.25, 0.5])
        XCTAssertEqual(result.peak, 0.5)
        XCTAssertEqual(result.meanRMS, Float(sqrt(0.15625)), accuracy: 1e-6)
        XCTAssertEqual(TransitionAudioSlice.dbFS(0), "−∞ dBFS")
    }

    func testDecodesOnlyRequestedAudioWindowAndRefusesTruncatedWindows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<16_000 {
            buffer.floatChannelData![0][index] = index < 8000 ? 0.1 : 0.5
            buffer.floatChannelData![1][index] = -(index < 8000 ? 0.1 : 0.5)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let slice = try XCTUnwrap(TransitionAnalysisStore.decode(url: url, range: 1000..<2000, bins: 4))
        XCTAssertEqual(slice.startMs, 1000, accuracy: 0.01)
        XCTAssertEqual(slice.durationMs, 1000, accuracy: 0.01)
        XCTAssertEqual(slice.channels, 2)
        XCTAssertEqual(slice.meanRMS, 0.5, accuracy: 1e-6)
        XCTAssertEqual(slice.peaks, [0.5, 0.5, 0.5, 0.5])
        XCTAssertNil(TransitionAnalysisStore.decode(url: url, range: 1500..<2500))
        XCTAssertNil(TransitionAnalysisStore.decode(url: url, range: 0..<21_000))
    }
}
