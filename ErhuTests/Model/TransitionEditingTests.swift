@testable import Erhu
import XCTest

final class TransitionEditingTests: XCTestCase {
    private let playlist = CollectionRef.playlist(3)
    private let fade = TransitionSpec(durationMs: 4_000)
    private let rise = TransitionSpec.preset(.rise)

    private func studioTrack(_ song: Int64, _ position: Int) -> StudioTrack {
        StudioTrack(song: Song(id: song, title: "t\(song)", artist: "a", album: "b", durationMs: 200_000, path: "\(song).mp3"),
                    occurrence: TrackOccurrence(song, position))
    }

    private lazy var t1 = studioTrack(1, 0)
    private lazy var t2 = studioTrack(2, 1)
    private lazy var t3 = studioTrack(3, 2)
    private lazy var t1Again = studioTrack(1, 3)

    private func config(_ pairs: [TransitionPairKey: TransitionChoice] = [:]) -> TransitionConfig {
        TransitionConfig(global: GlobalTransitionSettings(masterEnabled: true, defaultChoice: .custom(fade)), pairs: pairs)
    }

    private func key(_ a: StudioTrack, _ b: StudioTrack) -> TransitionPairKey {
        TransitionPairKey(collection: playlist, from: a.occurrence, to: b.occurrence)
    }

    private func points(_ spec: TransitionSpec, _ role: TransitionRole) -> [CurvePoint] {
        TransitionEditing.curveOf(spec, role).points
    }

    func testPlotActivationEntersCustomFromOffOrDefaultAndIsOneUndoableEdit() {
        let pair = studioPairs(playlist, tracks: [t1, t2], config: TransitionConfig())[0]
        for choice in [TransitionChoice.inherit, .off] {
            var cfg = TransitionConfig()
            cfg.pairs[pair.key] = choice
            var draft = EditorDraft.open(.pair(pair), config: cfg)
            XCTAssertNil(draft.shown)
            draft.activateCurveEditing()
            XCTAssertEqual(draft.selectedCard, .preset(.custom))
            XCTAssertEqual(draft.spec.curve, .custom)
            XCTAssertNotNil(draft.shown)
            XCTAssertTrue(draft.isDirty)
            XCTAssertEqual(draft.undo.count, 1)
            let activated = draft
            draft.activateCurveEditing()
            XCTAssertEqual(draft, activated)
            draft.undoLast()
            XCTAssertEqual(draft.choice, choice)
            XCTAssertFalse(draft.isDirty)
        }
    }

    func testPlotActivationPreservesInheritedEQFiltersAndSourceCues() {
        var inherited = TransitionSpec.preset(.blend)
        inherited.durationMs = 4000
        inherited.outgoingCutMs = 3000
        inherited.incomingStartMs = 6000
        var cfg = TransitionConfig()
        cfg.global.defaultChoice = .custom(inherited)
        let pair = studioPairs(playlist, tracks: [t1, t2], config: cfg)[0]
        var draft = EditorDraft.open(.pair(pair), config: cfg)
        draft.activateCurveEditing()
        XCTAssertEqual(draft.selectedCard, .preset(.custom))
        XCTAssertEqual(draft.spec.bassSwap, inherited.bassSwap)
        XCTAssertEqual(draft.spec.filter, inherited.filter)
        XCTAssertEqual(draft.spec.outgoingCutMs, 3000)
        XCTAssertEqual(draft.spec.incomingStartMs, 6000)
        XCTAssertEqual(draft.spec.durationMs, 4000)
    }

    func testPairsFollowTheOrderAndSettingsStayWithTheirExactPair() {
        let cfg = config([key(t1, t2): .custom(rise), key(t2, t3): .off])
        let pairs = studioPairs(playlist, tracks: [t1, t2, t3], config: cfg)
        XCTAssertEqual(pairs.map(\.key), [key(t1, t2), key(t2, t3)])
        XCTAssertEqual(pairs[0].resolved, rise)
        XCTAssertNil(pairs[1].resolved)
        XCTAssertEqual(pairLabel(pairs[0].choice), "Rise")
        XCTAssertEqual(pairLabel(pairs[1].choice), "Off")

        // Reordered: 3, 1, 2 — the 1→2 setting is still on 1→2; the new 3→1 pair inherits.
        let reordered = studioPairs(playlist, tracks: [t3, t1, t2], config: cfg)
        XCTAssertEqual(pairLabel(reordered[0].choice), "Auto")
        XCTAssertEqual(reordered[0].resolved, fade)
        XCTAssertEqual(reordered[1].choice, .custom(rise))

        // Removing track 2: 1→3 is a new pair (inherits); nothing is carried over by position.
        let removed = studioPairs(playlist, tracks: [t1, t3], config: cfg)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].choice, .inherit)

        // Inserting a track between 1 and 2: both new pairs inherit.
        let inserted = studioPairs(playlist, tracks: [t1, t3, t2], config: cfg)
        XCTAssertTrue(inserted.allSatisfy { $0.choice == .inherit })
        XCTAssertTrue(studioPairs(playlist, tracks: [], config: cfg).isEmpty)
        XCTAssertTrue(studioPairs(playlist, tracks: [t1], config: cfg).isEmpty)
    }

    func testDuplicateOccurrencesOfOneSongKeepSeparateTransitions() {
        let cfg = config([key(t1, t2): .custom(rise)])
        let pairs = studioPairs(playlist, tracks: [t1, t2, t1Again, t2], config: cfg)
        XCTAssertEqual(pairs[0].choice, .custom(rise))
        XCTAssertEqual(pairs[2].choice, .inherit)
        XCTAssertEqual(Set(pairs.map(\.key)).count, 3)
    }

    func testDraggingRespectsTimeOrderBoundsAndFixedEndLevels() {
        var spec = TransitionEditing.setCurve(fade, .custom)
        XCTAssertEqual(spec.curve, .custom)
        // Interior point pushed past its neighbour and above full level: clamped.
        spec = TransitionEditing.movePoint(spec, .outgoing, index: 1, t: 0.9, gain: 3)
        let moved = points(spec, .outgoing)
        XCTAssertLessThan(moved[1].t, moved[2].t)
        XCTAssertEqual(moved[1].gain, 1)
        // End points keep their time; the outgoing start/end and the incoming end keep their level.
        spec = TransitionEditing.movePoint(spec, .outgoing, index: 0, t: 0.4, gain: 0.2)
        XCTAssertEqual(points(spec, .outgoing)[0].t, 0)
        XCTAssertEqual(points(spec, .outgoing)[0].gain, 1)
        let incomingBefore = points(spec, .incoming)
        spec = TransitionEditing.movePoint(spec, .incoming, index: 0, t: 0, gain: 0.3) // the incoming start may move
        XCTAssertEqual(points(spec, .incoming)[0].gain, 0.3)
        XCTAssertEqual(points(spec, .incoming).count, incomingBefore.count)
        // Editing one curve never changed the other.
        XCTAssertEqual(Array(points(spec, .outgoing).dropFirst()), Array(moved.dropFirst()))
        XCTAssertEqual(spec.preset, .custom)
        XCTAssertEqual(spec, spec.sanitized())
    }

    func testPointsCanBeAddedUpToTheLimitAndInteriorPointsRemoved() {
        var spec = TransitionEditing.setCurve(fade, .custom)
        let before = points(spec, .incoming).count
        spec = TransitionEditing.addPoint(spec, .incoming, t: 0.33)
        XCTAssertEqual(points(spec, .incoming).count, before + 1)
        for i in 0..<10 { spec = TransitionEditing.addPoint(spec, .incoming, t: 0.05 + Float(i) * 0.09) }
        XCTAssertEqual(points(spec, .incoming).count, 8)
        XCTAssertEqual(TransitionEditing.removePoint(spec, .incoming, index: 0), spec) // end points stay
        spec = TransitionEditing.removePoint(spec, .incoming, index: 1)
        XCTAssertEqual(points(spec, .incoming).count, 7)
    }

    func testPresetsResetCurvesAndKeepTheDuration() {
        let edited = TransitionEditing.movePoint(TransitionEditing.setCurve(fade, .custom), .outgoing, index: 1, t: 0.2, gain: 0.4)
        let reset = TransitionEditing.applyPreset(edited, .fade)
        XCTAssertEqual(reset.durationMs, 4_000)
        XCTAssertNil(reset.outgoingCurve)
        XCTAssertEqual(reset.preset, .fade)
        XCTAssertTrue(TransitionEditing.applyPreset(reset, .bassSwap).bassSwap)
        XCTAssertEqual(TransitionEditing.setBassSwap(TransitionSpec.preset(.bassSwap), false).preset, .fade)
        XCTAssertEqual(TransitionEditing.setDuration(fade, 40_000).durationMs, 12_000)
        XCTAssertEqual(TransitionEditing.setBassSwapAt(fade, 2).bassSwapAt, 0.9)
    }

    func testNamedOptionsRelabelThePresetHonestly() {
        let blend = TransitionSpec.preset(.blend, base: fade)
        XCTAssertEqual(TransitionEditing.relabel(blend).preset, .blend)
        // Changing any part of a preset makes it Custom; changing it back restores the preset name.
        let changed = TransitionEditing.setFilter(blend, .none)
        XCTAssertEqual(changed.preset, .custom)
        XCTAssertEqual(TransitionEditing.setFilter(changed, .highPassInOut).preset, .blend)
        let swap = TransitionEditing.setEqMove(fade, .centerBassSwap)
        XCTAssertEqual(swap.preset, .bassSwap)
        XCTAssertEqual(TransitionEditing.setEqMove(swap, .none).preset, .fade)
        let slam = TransitionEditing.setVolumeShape(fade, .centerCut)
        XCTAssertEqual(slam.preset, .slam)
        XCTAssertEqual(VolumeShape.of(slam), .centerCut)
        // A custom swap point is kept and shown as custom.
        let custom = TransitionEditing.setBassSwapAt(fade, 0.3)
        XCTAssertTrue(custom.bassSwap)
        XCTAssertEqual(custom.bassSwapAt, 0.3)
        XCTAssertNil(EqMove.of(custom))
    }

    func testSlidingTheWaveformsMovesTheCuePointsWithinTheTracks() {
        var spec = TransitionEditing.shiftCue(fade, .outgoing, deltaMs: 5_000, outgoingDurationMs: 200_000, incomingDurationMs: 180_000)
        XCTAssertEqual(spec.outgoingCutMs, 5_000)
        spec = TransitionEditing.shiftCue(spec, .incoming, deltaMs: -8_000, outgoingDurationMs: 200_000, incomingDurationMs: 180_000)
        XCTAssertEqual(spec.incomingStartMs, 8_000)
        XCTAssertEqual(TransitionEditing.shiftCue(spec, .incoming, deltaMs: 60_000, outgoingDurationMs: 200_000, incomingDurationMs: 180_000).incomingStartMs, 0)
        XCTAssertEqual(TransitionEditing.shiftCue(spec, .outgoing, deltaMs: -60_000, outgoingDurationMs: 200_000, incomingDurationMs: 180_000).outgoingCutMs, 0)
        // At least a second of each track always plays.
        XCTAssertEqual(TransitionEditing.shiftCue(spec, .incoming, deltaMs: -999_999, outgoingDurationMs: 200_000, incomingDurationMs: 180_000).incomingStartMs, 179_000)
        // Presets keep the cue points: they belong to the pair.
        let blend = TransitionEditing.applyPreset(spec, .blend)
        XCTAssertEqual(blend.outgoingCutMs, 5_000)
        XCTAssertEqual(blend.incomingStartMs, 8_000)
        XCTAssertEqual(blend.preset, .blend)
    }

    // MARK: - Editor draft

    func testDraftOpensFromTheSavedLevelAndInheritsFromTheLevelAbove() {
        let pair = studioPairs(playlist, tracks: [t1, t2], config: config())[0]
        let draft = EditorDraft.open(.pair(pair), config: config())
        XCTAssertEqual(draft.mode, .inherit)
        XCTAssertEqual(draft.inherited, fade)
        XCTAssertEqual(draft.shown, fade)
        XCTAssertFalse(draft.isDirty)

        let global = EditorDraft.open(.global, config: config())
        XCTAssertEqual(global.mode, .custom)
        XCTAssertNil(global.inherited)
        XCTAssertEqual(global.spec, fade)
    }

    func testEditingAutoStartsFromTheInheritedTransitionAndUndoRestoresIt() {
        let pair = studioPairs(playlist, tracks: [t1, t2], config: config())[0]
        var draft = EditorDraft.open(.pair(pair), config: config())
        draft.edit { TransitionEditing.setEqMove($0, .centerBassSwap) }
        XCTAssertEqual(draft.mode, .custom)
        XCTAssertEqual(draft.spec.durationMs, 4_000) // tweaked the inherited 4 s fade
        XCTAssertEqual(draft.spec.preset, .bassSwap)
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.choice, .custom(draft.spec))

        draft.choose(.off)
        XCTAssertNil(draft.shown)
        XCTAssertEqual(draft.spec.preset, .bassSwap) // kept while off
        draft.choose(.off) // no change, nothing recorded
        XCTAssertEqual(draft.undo.count, 2)

        draft.undoLast()
        XCTAssertEqual(draft.mode, .custom)
        draft.undoLast()
        XCTAssertEqual(draft.mode, .inherit)
        XCTAssertFalse(draft.isDirty)
        draft.undoLast() // nothing left
        XCTAssertEqual(draft.mode, .inherit)
    }

    func testDragsRecordOneUndoStepAndTheHistoryIsCapped() {
        var draft = EditorDraft.open(.global, config: config())
        draft.beginDrag()
        for at: Float in [0.2, 0.5, 0.8] { draft.drag { TransitionEditing.setBassSwapAt($0, at) } }
        XCTAssertEqual(draft.undo.count, 1)
        XCTAssertEqual(draft.spec.bassSwapAt, 0.8, accuracy: 0.001)
        draft.undoLast()
        XCTAssertFalse(draft.spec.bassSwap)

        for ms in 0..<40 { draft.edit { TransitionEditing.setDuration($0, 1_000 + ms * 100) } }
        XCTAssertEqual(draft.undo.count, EditorDraft.undoLimit)
    }

    func testPresetCardsAndResetToPreset() {
        let collection = CollectionRef.album(7)
        var draft = EditorDraft.open(.collection(collection), config: config())
        XCTAssertEqual(draft.selectedCard, .auto)
        draft.choose(.preset(.melt))
        XCTAssertEqual(draft.selectedCard, .preset(.melt))
        XCTAssertEqual(draft.spec.filter, .lowPassOut)
        XCTAssertEqual(draft.spec.durationMs, 4_000)
        draft.edit { TransitionEditing.setFilter($0, .highPassIn) }
        XCTAssertEqual(draft.spec.preset, .custom)
        draft.resetToPreset()
        XCTAssertEqual(draft.spec.preset, .fade)
        XCTAssertEqual(draft.spec.filter, .none)
    }

    func testSummariesAndLabels() {
        XCTAssertEqual(specSummary(nil), "No crossfade")
        XCTAssertEqual(specSummary(fade), "Fade · 4 s")
        XCTAssertEqual(specSummary(TransitionSpec(durationMs: 2_400, preset: .slam)), "Slam · 2.4 s")
        XCTAssertEqual(pairLabel(.inherit), "Auto")
    }
}
