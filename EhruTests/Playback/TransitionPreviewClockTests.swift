import XCTest
@testable import Ehru

final class TransitionPreviewClockTests: XCTestCase {
    private func makeTiming() throws -> PairTransitionTiming {
        try XCTUnwrap(PairTransitionTiming(spec: TransitionSpec(), outgoingMs: 60_000, incomingMs: 60_000))
    }

    func testPlayheadComesOnlyFromRenderedAudioAndIncludesLeadIn() throws {
        let clock = TransitionPreviewClock(timing: try makeTiming())
        XCTAssertNil(clock.position(outgoingElapsedMs: nil, incomingElapsedMs: nil, latencyMs: 80))
        XCTAssertNil(clock.position(outgoingElapsedMs: -1, incomingElapsedMs: -.infinity, latencyMs: 80))
        XCTAssertEqual(clock.position(outgoingElapsedMs: 500, incomingElapsedMs: nil, latencyMs: 80), -1080)
        XCTAssertEqual(clock.position(outgoingElapsedMs: 750, incomingElapsedMs: nil, latencyMs: 80), -830)
        // A UI refresh without new render samples cannot advance the line.
        XCTAssertEqual(clock.position(outgoingElapsedMs: 750, incomingElapsedMs: nil, latencyMs: 80), -830)
    }

    func testIncomingRenderClockTakesOverContinuouslyAndOutlivesOutgoingDeck() throws {
        let clock = TransitionPreviewClock(timing: try makeTiming())
        let before = clock.position(outgoingElapsedMs: 1500, incomingElapsedMs: nil, latencyMs: 120)
        let handover = clock.position(outgoingElapsedMs: 1500, incomingElapsedMs: 0, latencyMs: 120)
        XCTAssertEqual(before, handover)
        XCTAssertEqual(handover, -120)
        XCTAssertEqual(clock.position(outgoingElapsedMs: 2000, incomingElapsedMs: -1, latencyMs: 120), 380)
        XCTAssertEqual(clock.position(outgoingElapsedMs: nil, incomingElapsedMs: 2200, latencyMs: 120), 2080)
        XCTAssertEqual(clock.position(outgoingElapsedMs: nil, incomingElapsedMs: 2600, latencyMs: 120), 2480)
    }

    func testRouteLatencyAndBoundsDoNotCreateFakeProgress() throws {
        let clock = TransitionPreviewClock(timing: try makeTiming())
        XCTAssertEqual(clock.position(outgoingElapsedMs: 0, incomingElapsedMs: nil, latencyMs: 200), -1500)
        XCTAssertEqual(clock.position(outgoingElapsedMs: nil, incomingElapsedMs: 1000, latencyMs: 250), 750)
        XCTAssertEqual(clock.position(outgoingElapsedMs: nil, incomingElapsedMs: 1000, latencyMs: .nan), 1000)
        XCTAssertEqual(clock.position(outgoingElapsedMs: nil, incomingElapsedMs: 1000, latencyMs: -20), 1000)
        XCTAssertEqual(clock.position(outgoingElapsedMs: nil, incomingElapsedMs: 20_000, latencyMs: 0), 3500)
        XCTAssertNil(clock.position(outgoingElapsedMs: .nan, incomingElapsedMs: .infinity, latencyMs: 0))
    }

    func testFitIncludesEntireAuditionAndCutPreviewHasNoInventedOverlap() throws {
        let timing = try makeTiming()
        let fit = TransitionWaveformViewport(timing: timing, zoom: 1, includesPreviewContext: true)
        XCTAssertEqual(fit.startMs, -1500)
        XCTAssertEqual(fit.endMs, 3500)
        XCTAssertEqual(fit.durationMs, Double(timing.totalMs))
        let zoomed = fit.zoomed(timing: timing, zoom: 4, anchor: 0.3)
        XCTAssertEqual(zoomed.time(at: 0.3), fit.time(at: 0.3), accuracy: 1e-6)
        let cut = try XCTUnwrap(PairTransitionTiming(spec: nil, outgoingMs: 60_000, incomingMs: 60_000))
        XCTAssertFalse(cut.hasOverlap)
        XCTAssertEqual(cut.plan.durationMs, 0)
        XCTAssertEqual(cut.outgoingRange, 58_500..<60_000)
        XCTAssertEqual(cut.incomingRange, 0..<1500)
        XCTAssertEqual(cut.gainAt(.outgoing, elapsedMs: -1), 1)
        XCTAssertEqual(cut.gainAt(.outgoing, elapsedMs: 0), 0)
        XCTAssertEqual(cut.gainAt(.incoming, elapsedMs: -1), 0)
        XCTAssertEqual(cut.gainAt(.incoming, elapsedMs: 0), 1)
        let view = TransitionWaveformViewport(timing: cut, zoom: 1)
        XCTAssertEqual(view.durationMs, 3000)
        XCTAssertEqual(view.fraction(at: 0), 0.5)
    }
}
