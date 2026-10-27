import XCTest
@testable import Ehru

final class WaveformTests: XCTestCase {
    func testLevelsFollowLoudnessOverTimeAndThePeakIsOne() {
        // One second at 1 kHz: a quiet first half, a loud second half, two channels.
        let rate = 1_000.0
        let quiet = [Float](repeating: 0.1, count: 500)
        let loud = [Float](repeating: 0.8, count: 500)
        let samples = quiet + loud
        var accumulator = WaveformAccumulator(bins: 4, durationUs: 1_000_000)
        samples.withUnsafeBufferPointer { pointer in
            accumulator.add(channels: [pointer.baseAddress!, pointer.baseAddress!], frameCount: samples.count, firstFrame: 0, sampleRate: rate)
        }
        let levels = accumulator.finish()!
        XCTAssertEqual(4, levels.count)
        XCTAssertEqual(0.125, levels[0], accuracy: 1e-4)
        XCTAssertEqual(1, levels[3], accuracy: 1e-6)
    }

    func testNoAudioIsNoWaveformAndSilenceIsFlat() {
        XCTAssertNil(WaveformAccumulator(bins: 3, durationUs: 1_000).finish())
        let silence = [Float](repeating: 0, count: 10)
        var accumulator = WaveformAccumulator(bins: 2, durationUs: 10_000)
        silence.withUnsafeBufferPointer { accumulator.add(channels: [$0.baseAddress!], frameCount: 10, firstFrame: 0, sampleRate: 1_000) }
        XCTAssertEqual([0, 0], accumulator.finish())
    }

    func testLevelsRoundTripThroughTheirBytes() {
        let original: [Float] = [0, 0.5, 1]
        let restored = levels(fromBytes: levelBytes(original))
        for (a, b) in zip(original, restored) { XCTAssertEqual(a, b, accuracy: 1 / 255) }
    }

    func testTimelineEndsAreExact() {
        XCTAssertEqual(0, WaveformTimeline.fractionOf(-5, 1000))
        XCTAssertEqual(1, WaveformTimeline.fractionOf(2000, 1000))
        XCTAssertEqual(1000, WaveformTimeline.positionAt(1.5, 1000))
        XCTAssertEqual(0, WaveformTimeline.positionAt(0.5, 0))
    }

    func testBarsTakeTheLoudestLevelOfEachSlice() {
        XCTAssertEqual([0.5, 0.9], WaveformSeekBar.barLevels([0.1, 0.5, 0.9, 0.2], 2))
        XCTAssertEqual([0.12, 0.12, 0.12], WaveformSeekBar.barLevels(nil, 3))
    }
}
