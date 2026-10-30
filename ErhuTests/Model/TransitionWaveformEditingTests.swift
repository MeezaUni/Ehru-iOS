import XCTest
@testable import Erhu

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
        XCTAssertEqual(session.moved(translation: CGSize(width: CGFloat.nan, height: 0)), base)
        var config = TransitionConfig()
        config.global.defaultChoice = .custom(base)
        var draft = EditorDraft.open(.global, config: config)
        draft.edit { _ in updated }
        XCTAssertEqual(draft.undo.count, 1)
        draft.undoLast()
        XCTAssertEqual(draft.spec, base)
    }


    func testTechnicalPointValuesConvertDecibelsToTheActualEngineCurve() throws {
        var base = TransitionEditing.setCurve(TransitionSpec(), .custom)
        base.outgoingCutMs = 2000
        base.incomingStartMs = 3000
        let handle = TransitionCurveHandle(role: .incoming, index: 2)
        let updated = TransitionPointPrecision.updated(base, handle: handle, durationMs: 2000,
                                                       timeMs: 1100, gainDb: -6, silence: false)
        let point = try XCTUnwrap(updated.incomingCurve).points[2]
        XCTAssertEqual(point.t, 0.55, accuracy: 1e-6)
        XCTAssertEqual(point.gain, 0.5011872, accuracy: 1e-6)
        XCTAssertEqual(try makeTiming(updated).automation(.incoming).gainAt(1100), point.gain, accuracy: 1e-6)
        XCTAssertEqual(updated.outgoingCurve, base.outgoingCurve)
        XCTAssertEqual(updated.outgoingCutMs, 2000)
        XCTAssertEqual(updated.incomingStartMs, 3000)
        let silent = TransitionPointPrecision.updated(base, handle: handle, durationMs: 2000,
                                                      timeMs: 1100, gainDb: -6, silence: true)
        XCTAssertEqual(try XCTUnwrap(silent.incomingCurve).points[2].gain, 0)
        let fixed = TransitionPointPrecision.updated(base, handle: TransitionCurveHandle(role: .outgoing, index: 0),
                                                     durationMs: 2000, timeMs: 1000, gainDb: -6, silence: true)
        XCTAssertEqual(try XCTUnwrap(fixed.outgoingCurve).points.first, CurvePoint(t: 0, gain: 1))
        XCTAssertEqual(TransitionPointPrecision.updated(base, handle: handle, durationMs: 2000,
                                                        timeMs: .nan, gainDb: 0, silence: false), base)
    }

    func testDirectLineHitsUseTheRenderedVolumeEQAndFilterGeometry() throws {
        var spec = TransitionSpec.preset(.blend)
        spec.bassSwap = true
        spec.filter = .highPassInLowPassOut
        let timing = try makeTiming(spec)
        let layout = TransitionCurveLayout(viewport: TransitionWaveformViewport(timing: timing, zoom: 1),
                                           durationMs: Double(timing.plan.durationMs), size: CGSize(width: 300, height: 320))
        // Hit segments, not just existing dots; this works independently of the selected tool.
        let volume = layout.position(time: 0.23, level: spec.gain(.outgoing, 0.23), role: .outgoing)
        XCTAssertEqual(layout.nearestLine(volume, spec: spec, showsEQ: false, showsFilter: false), .volume(.outgoing))
        let bass = try XCTUnwrap(layout.effectHandle(.bass(.incoming), spec: spec))
        XCTAssertEqual(layout.nearestLine(bass, spec: spec, showsEQ: true, showsFilter: true), .bass(.incoming))
        let cutoff = try XCTUnwrap(spec.filterSetting(.outgoing, 0.75))
        let filter = layout.position(time: 0.75, level: TransitionCurveLayout.frequencyLevel(cutoff.hz), role: .outgoing)
        XCTAssertEqual(layout.nearestLine(filter, spec: spec, showsEQ: true, showsFilter: true), .filter(.outgoing))
        XCTAssertNotEqual(layout.nearestLine(filter, spec: spec, showsEQ: true, showsFilter: false), .filter(.outgoing))
        XCTAssertNil(layout.nearestLine(CGPoint(x: 5, y: 5), spec: spec, showsEQ: true, showsFilter: true))
        let inactive = TransitionSpec()
        XCTAssertNil(layout.effectHandle(.filter(.outgoing), spec: inactive))
        XCTAssertNotEqual(layout.nearestLine(bass, spec: inactive, showsEQ: true, showsFilter: true), .bass(.incoming))
    }

    func testEffectDragsChangeRealAutomationWithoutMovingAudioOrTheOtherFilter() throws {
        var base = TransitionSpec.preset(.blend)
        base.bassSwap = true
        base.outgoingCutMs = 3000
        base.incomingStartMs = 4000
        let timing = try makeTiming(base)
        let layout = TransitionCurveLayout(viewport: TransitionWaveformViewport(timing: timing, zoom: 1),
                                           durationMs: Double(timing.plan.durationMs), size: CGSize(width: 300, height: 320))
        let eqSession = TransitionEffectDrag(base: base, target: .bass(.incoming), layout: layout)
        let eq = eqSession.moved(translation: CGSize(width: 24, height: -30))
        XCTAssertEqual(eq.bassSwapAt, 0.6, accuracy: 1e-6)
        XCTAssertNotEqual(try makeTiming(eq).automation(.incoming).bassDbAt(1000), timing.automation(.incoming).bassDbAt(1000))
        let session = TransitionEffectDrag(base: base, target: .filter(.incoming), layout: layout)
        XCTAssertEqual(session.moved(translation: .zero), base)
        XCTAssertEqual(session.moved(translation: CGSize(width: CGFloat.nan, height: 0)), base)
        let movement = CGSize(width: 24, height: -24)
        let updated = session.moved(translation: movement)
        XCTAssertEqual(updated, session.moved(translation: movement))
        XCTAssertEqual(updated.incomingFilterAt ?? 0, 0.6, accuracy: 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(updated.incomingFilterHz), 20)
        let automation = try makeTiming(updated).automation(.incoming)
        XCTAssertEqual(try XCTUnwrap(automation.filterAt(1200)).hz, try XCTUnwrap(updated.incomingFilterHz), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(automation.filterAt(2000)).hz, 20, accuracy: 0.001)
        XCTAssertEqual(updated.outgoingFilterAt, base.outgoingFilterAt)
        XCTAssertEqual(updated.outgoingFilterHz, base.outgoingFilterHz)
        for step in 0...20 {
            let t = Float(step) / 20
            XCTAssertEqual(updated.filterSetting(.outgoing, t), base.filterSetting(.outgoing, t))
        }
        XCTAssertEqual(updated.outgoingCutMs, 3000)
        XCTAssertEqual(updated.incomingStartMs, 4000)
        XCTAssertEqual(updated.bassSwapAt, base.bassSwapAt)
        XCTAssertEqual(updated.outgoingCurve, base.outgoingCurve)
        XCTAssertEqual(updated.incomingCurve, base.incomingCurve)
        var config = TransitionConfig()
        config.global.defaultChoice = .custom(base)
        var draft = EditorDraft.open(.global, config: config)
        XCTAssertFalse(draft.isDirty)
        draft.edit { _ in updated }
        XCTAssertEqual(draft.undo.count, 1)
        draft.undoLast()
        XCTAssertEqual(draft.spec, base)
    }

    func testSavedFilterKneesRoundTripAndOlderPresetsRetainTheirExactAutomation() throws {
        for filter in TransitionFilter.allCases {
            var legacy = TransitionSpec()
            legacy.filter = filter
            let data = try JSONEncoder().encode(legacy)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(fields["incomingFilterAt"])
            XCTAssertNil(fields["outgoingFilterHz"])
            let decoded = try JSONDecoder().decode(TransitionSpec.self, from: data)
            for role in [TransitionRole.outgoing, .incoming] {
                for step in -1...21 {
                    let t = Float(step) / 20
                    XCTAssertEqual(decoded.filterSetting(role, t), filter.settingAt(role, t))
                }
            }
        }
        let custom = TransitionEditing.setFilterKnee(TransitionSpec.preset(.melt), role: .outgoing, t: 0.7, hz: 2400)
        XCTAssertEqual(custom.preset, .custom)
        XCTAssertEqual(try JSONDecoder().decode(TransitionSpec.self, from: JSONEncoder().encode(custom)), custom)
        XCTAssertEqual(try XCTUnwrap(custom.filterSetting(.outgoing, 0.7)).hz, 2400, accuracy: 0.01)
        let reset = TransitionEditing.setFilter(custom, .lowPassOut)
        XCTAssertNil(reset.outgoingFilterAt)
        XCTAssertNil(reset.outgoingFilterHz)
        XCTAssertEqual(reset.filterSetting(.outgoing, 0.7), TransitionFilter.lowPassOut.settingAt(.outgoing, 0.7))
        var invalid = custom
        invalid.outgoingFilterAt = .nan
        invalid.outgoingFilterHz = .infinity
        XCTAssertNil(invalid.sanitized().outgoingFilterAt)
        XCTAssertNil(invalid.sanitized().outgoingFilterHz)
    }

}
