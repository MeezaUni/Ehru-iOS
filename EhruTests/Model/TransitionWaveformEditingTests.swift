import XCTest
@testable import Ehru

final class TransitionWaveformEditingTests: XCTestCase {
    private func makeTiming(_ spec: TransitionSpec = TransitionSpec()) throws -> PairTransitionTiming {
        try XCTUnwrap(PairTransitionTiming(spec: spec, outgoingMs: 180_000, incomingMs: 180_000))
    }

    func testFitFocusesOnTheOverlapAndZoomPreservesTheFingerAnchor() throws {
        let timing = try makeTiming()
        let fit = TransitionWaveformViewport(timing: timing, zoom: 1)
        XCTAssertEqual(fit.startMs, -250)
        XCTAssertEqual(fit.durationMs, 2500)
        let zoomed = fit.zoomed(timing: timing, zoom: 4, anchor: 0.25)
        XCTAssertEqual(zoomed.durationMs, 625)
        XCTAssertEqual(zoomed.time(at: 0.25), fit.time(at: 0.25), accuracy: 1e-6)
        XCTAssertEqual(zoomed.fraction(at: zoomed.time(at: 0.75)), 0.75, accuracy: 1e-6)
    }

    func testViewNavigationAndInvalidZoomStayWithinAvailableContext() throws {
        let timing = try makeTiming()
        let bounds = TransitionWaveformViewport.bounds(timing)
        let left = TransitionWaveformViewport(timing: timing, zoom: 8, focusMs: -100_000)
        let right = TransitionWaveformViewport(timing: timing, zoom: 8, focusMs: 100_000)
        XCTAssertEqual(left.startMs, bounds.lowerBound)
        XCTAssertEqual(right.endMs, bounds.upperBound)
        XCTAssertEqual(TransitionWaveformViewport(timing: timing, zoom: .nan, focusMs: .infinity),
                       TransitionWaveformViewport(timing: timing, zoom: 1))
    }

    func testEachLaneMovesOnlyItsOwnCueWithoutCompoundingUpdates() throws {
        var base = TransitionSpec()
        base.outgoingCutMs = 4000
        base.incomingStartMs = 6000
        let view = TransitionWaveformViewport(timing: try makeTiming(base), zoom: 1)
        let out = TransitionWaveformDrag(base: base, role: .outgoing, viewport: view, width: 250)
        let inc = TransitionWaveformDrag(base: base, role: .incoming, viewport: view, width: 250)
        let outMoved = out.shifted(points: 25, outgoingMs: 180_000, incomingMs: 180_000)
        let inMoved = inc.shifted(points: 25, outgoingMs: 180_000, incomingMs: 180_000)
        XCTAssertEqual(outMoved.outgoingCutMs, 4250)
        XCTAssertEqual(outMoved.incomingStartMs, 6000)
        XCTAssertEqual(inMoved.outgoingCutMs, 4000)
        XCTAssertEqual(inMoved.incomingStartMs, 5750)
        XCTAssertEqual(out.shifted(points: 25, outgoingMs: 180_000, incomingMs: 180_000), outMoved)
        XCTAssertEqual(out.shifted(points: -25, outgoingMs: 180_000, incomingMs: 180_000).outgoingCutMs, 3750)
        XCTAssertEqual(inc.shifted(points: -25, outgoingMs: 180_000, incomingMs: 180_000).incomingStartMs, 6250)
        let oldPlan = try makeTiming(base).plan
        let newPlan = try makeTiming(outMoved).plan
        XCTAssertEqual(newPlan.startAtMs, oldPlan.startAtMs - 250)
        XCTAssertEqual(newPlan.incomingStartMs, oldPlan.incomingStartMs)
        XCTAssertEqual(try makeTiming(inMoved).plan.incomingStartMs, oldPlan.incomingStartMs - 250)
    }

    func testZoomIncreasesCuePrecisionAndLargeDragsRespectTrackLimits() throws {
        var base = TransitionSpec()
        base.outgoingCutMs = 4000
        base.incomingStartMs = 6000
        let view = TransitionWaveformViewport(timing: try makeTiming(base), zoom: 8)
        let out = TransitionWaveformDrag(base: base, role: .outgoing, viewport: view, width: 250)
        let inc = TransitionWaveformDrag(base: base, role: .incoming, viewport: view, width: 250)
        XCTAssertEqual(out.shifted(points: 40, outgoingMs: 180_000, incomingMs: 180_000).outgoingCutMs, 4050)
        XCTAssertEqual(inc.shifted(points: 40, outgoingMs: 180_000, incomingMs: 180_000).incomingStartMs, 5950)
        XCTAssertEqual(out.shifted(points: 1_000_000, outgoingMs: 180_000, incomingMs: 180_000).outgoingCutMs, 179_000)
        XCTAssertEqual(inc.shifted(points: 1_000_000, outgoingMs: 180_000, incomingMs: 180_000).incomingStartMs, 0)
        XCTAssertEqual(inc.shifted(points: -1_000_000, outgoingMs: 180_000, incomingMs: 180_000).incomingStartMs, 179_000)
        XCTAssertEqual(out.shifted(points: .nan, outgoingMs: 180_000, incomingMs: 180_000), base)
    }

    func testACompletedWaveformDragIsOneUndoableEdit() throws {
        var config = TransitionConfig()
        config.global.defaultChoice = .custom(TransitionSpec())
        var draft = EditorDraft.open(.global, config: config)
        let initial = draft.spec
        let session = TransitionWaveformDrag(base: initial, role: .outgoing,
                                             viewport: TransitionWaveformViewport(timing: try makeTiming(initial), zoom: 1), width: 250)
        let moved = session.shifted(points: 50, outgoingMs: 180_000, incomingMs: 180_000)
        XCTAssertFalse(draft.isDirty) // Transient finger movement does not touch the draft.
        draft.edit { _ in moved }
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.undo.count, 1)
        draft.undoLast()
        XCTAssertEqual(draft.spec, initial)
        XCTAssertFalse(draft.isDirty)
    }

    func testBufferedSourceAudioIsBoundedAndDoesNotChangeAuditionTiming() throws {
        var spec = TransitionSpec()
        spec.durationMs = 12_000
        spec.outgoingCutMs = 20_000
        spec.incomingStartMs = 20_000
        let timing = try makeTiming(spec)
        let out = timing.analysisRange(.outgoing, outgoingMs: 180_000, incomingMs: 180_000)
        let inc = timing.analysisRange(.incoming, outgoingMs: 180_000, incomingMs: 180_000)
        XCTAssertEqual(out, 144_000..<164_000)
        XCTAssertEqual(inc, 16_000..<36_000)
        XCTAssertEqual(out.count, 20_000)
        XCTAssertEqual(inc.count, 20_000)
        XCTAssertEqual(timing.outgoingRange.upperBound, 160_000)
        XCTAssertEqual(timing.plan.incomingStartMs, 20_000)
    }

    func testDisplayHeightNeverChangesSourceMeasurementsAndKeepsSilenceSilent() {
        let slice = TransitionAudioSlice(peaks: [0.05, 0.1], rms: [0.025, 0.05], startMs: 0, durationMs: 1000,
                                         sampleRate: 44_100, channels: 2, peak: 0.1, meanRMS: 0.04)
        XCTAssertEqual(TransitionWaveformHeight.auto.gain(visiblePeak: slice.peak), 8.5, accuracy: 1e-6)
        XCTAssertEqual(TransitionWaveformHeight.auto.gain(visiblePeak: 0), 1)
        XCTAssertEqual(slice.peak, 0.1)
        XCTAssertEqual(slice.meanRMS, 0.04)
        XCTAssertEqual(slice.peaks, [0.05, 0.1])
    }

    func testOnWaveformVolumeHandlesUseTheSameTimeAndGainAsPlayback() throws {
        let spec = TransitionEditing.setCurve(TransitionSpec(), .custom)
        let timing = try makeTiming(spec)
        let view = TransitionWaveformViewport(timing: timing, zoom: 1)
        let layout = TransitionCurveLayout(viewport: view, durationMs: Double(timing.plan.durationMs), size: CGSize(width: 300, height: 320))
        for role in [TransitionRole.outgoing, .incoming] {
            let controls = TransitionEditing.curveOf(spec, role).points
            for (index, control) in controls.enumerated() {
                let position = layout.position(control, role: role)
                let value = layout.value(at: position, role: role)
                XCTAssertEqual(value.t, control.t, accuracy: 1e-6)
                XCTAssertEqual(value.gain, timing.automation(role).gainAt(Double(control.t) * Double(timing.plan.durationMs)), accuracy: 1e-5)
                XCTAssertEqual(layout.nearest(position, spec: spec), TransitionCurveHandle(role: role, index: index))
            }
        }
    }

    func testCurveDraggingKeepsTheOtherLaneAndCuesAndCommitsOneUndoStep() throws {
        var base = TransitionEditing.setCurve(TransitionSpec(), .custom)
        base.outgoingCutMs = 4000
        base.incomingStartMs = 6000
        let timing = try makeTiming(base)
        let layout = TransitionCurveLayout(viewport: TransitionWaveformViewport(timing: timing, zoom: 1),
                                           durationMs: Double(timing.plan.durationMs), size: CGSize(width: 300, height: 320))
        let handle = TransitionCurveHandle(role: .incoming, index: 2)
        let session = TransitionCurveDrag(base: base, handle: handle, layout: layout)
        XCTAssertEqual(session.moved(translation: .zero), base)
        let movement = CGSize(width: 12, height: -11)
        let updated = session.moved(translation: movement)
        XCTAssertEqual(updated, session.moved(translation: movement))
        XCTAssertNotEqual(updated.incomingCurve, base.incomingCurve)
        XCTAssertEqual(updated.outgoingCurve, base.outgoingCurve)
        XCTAssertEqual(updated.incomingStartMs, 6000)
        XCTAssertEqual(updated.outgoingCutMs, 4000)
        XCTAssertEqual(updated.durationMs, base.durationMs)
        XCTAssertTrue(try XCTUnwrap(updated.incomingCurve).isValid(.incoming))
        let points = try XCTUnwrap(updated.incomingCurve).points
        let updatedTiming = try makeTiming(updated)
        XCTAssertEqual(updatedTiming.automation(.incoming).gainAt(Double(points[2].t) * Double(updatedTiming.plan.durationMs)), points[2].gain, accuracy: 1e-5)
        XCTAssertEqual(session.moved(translation: CGSize(width: .nan, height: 0)), base)
        var config = TransitionConfig()
        config.global.defaultChoice = .custom(base)
        var draft = EditorDraft.open(.global, config: config)
        draft.edit { _ in updated }
        XCTAssertEqual(draft.undo.count, 1)
        draft.undoLast()
        XCTAssertEqual(draft.spec, base)
    }

}
