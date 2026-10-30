import XCTest
@testable import Erhu

final class TransitionResolverTests: XCTestCase {
    private let album = CollectionRef.album(7)
    private let playlist = CollectionRef.playlist(7)
    private let global = TransitionSpec(durationMs: 1_000)
    private let albumSpec = TransitionSpec(durationMs: 4_000, preset: .bassSwap, bassSwap: true)
    private let pairSpec = TransitionSpec(durationMs: 8_000, curve: .linear)

    private func origin(_ collection: CollectionRef, _ song: Int64, slot: Int? = nil) -> QueueOrigin {
        QueueOrigin(collection: collection, occurrence: TrackOccurrence(song, slot))
    }

    private var a1: QueueOrigin { origin(album, 1) }
    private var a2: QueueOrigin { origin(album, 2) }
    private var pairKey: TransitionPairKey { TransitionPairKey(collection: album, from: a1.occurrence, to: a2.occurrence) }

    private func config(master: Bool = true, defaultChoice: TransitionChoice? = nil,
                        collection: TransitionChoice? = nil, pair: TransitionChoice? = nil) -> TransitionConfig {
        TransitionConfig(
            global: GlobalTransitionSettings(masterEnabled: master, defaultChoice: defaultChoice ?? .custom(global)),
            collections: collection.map { [album: $0] } ?? [:],
            pairs: pair.map { [pairKey: $0] } ?? [:]
        )
    }

    private func resolve(_ config: TransitionConfig, _ from: QueueOrigin?? = .none, _ to: QueueOrigin?? = .none) -> ResolvedTransition {
        TransitionResolver.resolve(config, outgoing: from ?? a1, incoming: to ?? a2)
    }

    func testMasterOffDisablesEverything() {
        let r = resolve(config(master: false, collection: .custom(albumSpec), pair: .custom(pairSpec)))
        XCTAssertNil(r.spec)
        XCTAssertEqual(.masterOff, r.source)
    }

    func testPairBeatsCollectionBeatsGlobal() {
        let all = config(collection: .custom(albumSpec), pair: .custom(pairSpec))
        XCTAssertEqual(pairSpec, resolve(all).spec)
        XCTAssertEqual(.pair, resolve(all).source)
        XCTAssertEqual(albumSpec, resolve(config(collection: .custom(albumSpec))).spec)
        XCTAssertEqual(global, resolve(config()).spec)
        XCTAssertEqual(.globalDefault, resolve(config()).source)
    }

    func testExplicitOffNeverFallsThrough() {
        let pairOff = resolve(config(collection: .custom(albumSpec), pair: .off))
        XCTAssertNil(pairOff.spec)
        XCTAssertEqual(.pair, pairOff.source)
        let albumOff = resolve(config(collection: .off))
        XCTAssertNil(albumOff.spec)
        XCTAssertEqual(.collection, albumOff.source)
        XCTAssertEqual(pairSpec, resolve(config(collection: .off, pair: .custom(pairSpec))).spec)
    }

    func testOrdinaryQueuesUseGlobalDefault() {
        let c = config(collection: .custom(albumSpec), pair: .custom(pairSpec))
        XCTAssertEqual(global, resolve(c, .some(nil), .some(nil)).spec)
        XCTAssertEqual(global, resolve(c, a1, .some(nil)).spec)
        XCTAssertEqual(global, resolve(c, a1, origin(playlist, 2)).spec)
        XCTAssertNil(resolve(config(defaultChoice: .off), .some(nil), .some(nil)).spec)
    }

    func testInheritingEverywhereMeansGlobal() {
        let c = config(collection: .inherit, pair: .inherit)
        XCTAssertEqual(global, resolve(c).spec)
        XCTAssertEqual(c.collection(album), .inherit)
        XCTAssertEqual(global, TransitionResolver.collectionDefault(c, collection: album))
        XCTAssertEqual(albumSpec, TransitionResolver.collectionDefault(config(collection: .custom(albumSpec)), collection: album))
    }

    func testPairsAreOrderedAndOccurrenceSpecific() {
        let c = config(defaultChoice: .off, pair: .custom(pairSpec))
        XCTAssertEqual(pairSpec, resolve(c, a1, a2).spec)
        XCTAssertNil(resolve(c, a2, a1).spec)
        let p1 = origin(playlist, 1, slot: 0)
        let p2 = origin(playlist, 2, slot: 1)
        let p1again = origin(playlist, 1, slot: 5)
        let key = TransitionPairKey(collection: playlist, from: p1.occurrence, to: p2.occurrence)
        let pc = TransitionConfig(global: GlobalTransitionSettings(masterEnabled: true, defaultChoice: .off), pairs: [key: .custom(pairSpec)])
        XCTAssertEqual(pairSpec, TransitionResolver.resolve(pc, outgoing: p1, incoming: p2).spec)
        XCTAssertNil(TransitionResolver.resolve(pc, outgoing: p1again, incoming: p2).spec)
    }

    func testKeysRoundTripAndRejectMalformed() {
        let key = TransitionPairKey(collection: playlist, from: TrackOccurrence(12, 3), to: TrackOccurrence(12, 9))
        XCTAssertEqual(key, TransitionPairKey.fromKey(key.key))
        XCTAssertEqual(pairKey, TransitionPairKey.fromKey(pairKey.key))
        for bad in [nil, "", "album:7", "album:7|s1", "album:7|s1>", "album:7|x1>s2", "artist:1|s1>s2", "album:7|s1@x>s2"] as [String?] {
            XCTAssertNil(TransitionPairKey.fromKey(bad), bad ?? "nil")
        }
        XCTAssertEqual(QueueOrigin(collection: playlist, occurrence: TrackOccurrence(4, 2)), QueueOrigin.fromKey("playlist:7#s4@2", songId: 4))
        XCTAssertEqual(QueueOrigin(collection: album, occurrence: TrackOccurrence(9)), QueueOrigin.fromKey("album:7", songId: 9))
        XCTAssertNil(QueueOrigin.fromKey("", songId: 9))
    }

    func testLinearAndEqualPowerCurves() {
        for curve in [TransitionCurve.linear, .equalPower] {
            XCTAssertEqual(1, CurveMath.gain(curve, role: .outgoing, t: 0))
            XCTAssertEqual(0, CurveMath.gain(curve, role: .outgoing, t: 1))
            XCTAssertEqual(0, CurveMath.gain(curve, role: .incoming, t: 0))
            XCTAssertEqual(1, CurveMath.gain(curve, role: .incoming, t: 1))
        }
        for i in 0...10 {
            let t = Float(i) / 10
            let o = CurveMath.gain(.equalPower, role: .outgoing, t: t)
            let n = CurveMath.gain(.equalPower, role: .incoming, t: t)
            XCTAssertEqual(1, o * o + n * n, accuracy: 1e-5)
            XCTAssertEqual(1, CurveMath.gain(.linear, role: .outgoing, t: t) + CurveMath.gain(.linear, role: .incoming, t: t), accuracy: 1e-6)
        }
    }

    func testCustomCurveValidation() {
        let out = VolumeCurve.of((0, 1), (0.5, 0.8), (1, 0))
        XCTAssertTrue(out.isValid(.outgoing))
        XCTAssertEqual(0.9, out.gainAt(0.25), accuracy: 1e-6)
        XCTAssertFalse(VolumeCurve.of((0, 1), (0.6, 0.5), (0.4, 0.5), (1, 0)).isValid(.outgoing))
        XCTAssertFalse(VolumeCurve.of((0, 1), (0.5, 1.4), (1, 0)).isValid(.outgoing))
        XCTAssertFalse(VolumeCurve.of((0, 0.7), (1, 0)).isValid(.outgoing))
        XCTAssertFalse(VolumeCurve.of((0, 0), (1, 0.5)).isValid(.incoming))
        XCTAssertFalse(VolumeCurve.of((0.1, 0), (1, 1)).isValid(.incoming))
        XCTAssertFalse(VolumeCurve.of((0, .nan), (1, 1)).isValid(.incoming))
        let broken = TransitionSpec(curve: .custom, outgoingCurve: .of((0, 0.2), (1, 0)), incomingCurve: .of((0, 0), (1, 1)))
        XCTAssertEqual(.equalPower, broken.sanitized().curve)
        XCTAssertNil(broken.sanitized().outgoingCurve)
    }

    func testDurationsAndPresets() {
        XCTAssertEqual(500, TransitionSpec(durationMs: 10).sanitized().durationMs)
        XCTAssertEqual(12_000, TransitionSpec(durationMs: 99_000).sanitized().durationMs)
        XCTAssertEqual(2_400, TransitionSpec(durationMs: 2_430).sanitized().durationMs)
        XCTAssertEqual("0.5 s", TransitionSpec.durationLabel(500))
        let rise = TransitionSpec.preset(.rise, base: TransitionSpec(durationMs: 6_000))
        XCTAssertEqual(6_000, rise.durationMs)
        XCTAssertGreaterThan(rise.gain(.outgoing, 0.5), CurveMath.gain(.linear, role: .outgoing, t: 0.5))
        let swap = TransitionSpec.preset(.bassSwap)
        XCTAssertTrue(swap.bassSwap)
        XCTAssertEqual(TransitionSpec.bassCutDb, swap.bassDb(.incoming, 0.2))
        XCTAssertEqual(0, swap.bassDb(.incoming, 0.8))
        XCTAssertEqual(0, swap.bassDb(.outgoing, 0.2))
        XCTAssertEqual(TransitionSpec.bassCutDb, swap.bassDb(.outgoing, 0.8))
        XCTAssertEqual(0, TransitionSpec().bassDb(.incoming, 0.1))
    }
}

final class TransitionShapesTests: XCTestCase {
    private let base = TransitionSpec(durationMs: 4_000)

    func testEveryVolumeShapeIsValidAndRecognised() {
        for shape in VolumeShape.allCases {
            let spec = shape.applyTo(base)
            XCTAssertEqual(spec, spec.sanitized(), shape.rawValue)
            XCTAssertEqual(shape, VolumeShape.of(spec))
            XCTAssertEqual(4_000, spec.durationMs)
        }
        let overlap = VolumeShape.overlap.applyTo(base)
        XCTAssertEqual(1, overlap.gain(.outgoing, 0.5))
        XCTAssertEqual(1, overlap.gain(.incoming, 0.5))
        let centerCut = VolumeShape.centerCut.applyTo(base)
        XCTAssertEqual(1, centerCut.gain(.outgoing, 0.4))
        XCTAssertEqual(0, centerCut.gain(.incoming, 0.4))
        XCTAssertEqual(0, centerCut.gain(.outgoing, 0.6))
        XCTAssertEqual(1, VolumeShape.cutInFadeOut.applyTo(base).gain(.incoming, 0))
    }

    func testEqMovesSetSwapPoint() {
        XCTAssertNil(EqMove.none.swapAt)
        for move in EqMove.allCases {
            XCTAssertEqual(move, EqMove.of(move.applyTo(base)))
        }
        var custom = base
        custom.bassSwap = true
        custom.bassSwapAt = 0.33
        XCTAssertNil(EqMove.of(custom))
        XCTAssertEqual(EqMove.none, EqMove.of(base))
    }

    func testFilterSweeps() {
        let inOut = TransitionFilter.highPassInOut
        XCTAssertTrue(inOut.affects(.incoming) && inOut.affects(.outgoing))
        XCTAssertEqual(TransitionFilter.highPassThinHz, inOut.settingAt(.incoming, 0)!.hz, accuracy: 0.5)
        XCTAssertEqual(TransitionFilter.highPassOpenHz, inOut.settingAt(.incoming, 0.5)!.hz, accuracy: 0.01)
        XCTAssertEqual(TransitionFilter.highPassOpenHz, inOut.settingAt(.incoming, 1)!.hz, accuracy: 0.01)
        XCTAssertEqual(TransitionFilter.highPassOpenHz, inOut.settingAt(.outgoing, 0.3)!.hz, accuracy: 0.01)
        XCTAssertEqual(TransitionFilter.highPassThinHz, inOut.settingAt(.outgoing, 1)!.hz, accuracy: 0.5)
        let lowPass = TransitionFilter.highPassInLowPassOut.settingAt(.outgoing, 1)!
        XCTAssertEqual(.lowPass, lowPass.type)
        XCTAssertEqual(TransitionFilter.lowPassDarkHz, lowPass.hz, accuracy: 0.5)
        XCTAssertNil(TransitionFilter.highPassIn.settingAt(.outgoing, 0.9))
        XCTAssertNil(TransitionFilter.none.settingAt(.incoming, 0.1))
    }

    func testPresetsOnlyUseWhatTheEnginePlays() {
        let blend = TransitionSpec.preset(.blend, base: base)
        XCTAssertEqual(.overlap, VolumeShape.of(blend))
        XCTAssertEqual(.centerBassSwap, EqMove.of(blend))
        XCTAssertEqual(.highPassInOut, blend.filter)
        XCTAssertEqual(.lowPassOut, TransitionSpec.preset(.melt, base: base).filter)
        XCTAssertEqual(.centerCut, VolumeShape.of(TransitionSpec.preset(.slam, base: base)))
        XCTAssertEqual(.highPassIn, TransitionSpec.preset(.rise, base: base).filter)
        for preset in TransitionPreset.allCases {
            let spec = TransitionSpec.preset(preset, base: base)
            XCTAssertEqual(spec, spec.sanitized(), preset.rawValue)
            XCTAssertEqual(4_000, spec.durationMs)
        }
        let custom = TransitionSpec.preset(.custom, base: TransitionSpec.preset(.melt, base: base))
        XCTAssertEqual(.custom, custom.curve)
        XCTAssertEqual(.lowPassOut, custom.filter)
    }
}

final class GenresAndBpmTests: XCTestCase {
    func testGenresSplitNormalisedJoined() {
        XCTAssertEqual(["Rock"], Genres.parse("Rock"))
        XCTAssertEqual(["Electronic", "Synth-pop", "Alternative"], Genres.parse("Electronic; Synth-pop;Alternative"))
        XCTAssertEqual(["Electronic", "Synth pop"], Genres.parse("  Electronic ;  Synth   pop ; electronic ;"))
        XCTAssertEqual(["Rock", "Pop"], Genres.parse("Rock\u{0}Pop"))
        XCTAssertEqual("Electronic; Synth-pop", Genres.join([" Electronic", "Synth-pop", "SYNTH-POP", ""]))
        XCTAssertTrue(Genres.same("Rock;Pop", "rock; pop"))
        XCTAssertFalse(Genres.same("Rock; Pop", "Pop; Rock"))
    }

    func testSlashesAndAmpersandsStayWhole() {
        XCTAssertEqual(["Hip Hop/Rap", "R&B"], Genres.parse("Hip Hop/Rap; R&B"))
        XCTAssertEqual(["Drum & Bass"], Genres.parse("Drum & Bass"))
    }

    func testJunkGenresDropped() {
        XCTAssertEqual([], Genres.parse(nil))
        XCTAssertEqual([], Genres.parse(" ; ;"))
        XCTAssertEqual([], Genres.parse("Unknown; <unknown>; 12; (17)"))
        XCTAssertEqual([], Genres.parse(String(repeating: "x", count: 65)))
        XCTAssertNil(Genres.join(["", nil, "unknown genre"] as [String?]))
    }

    func testBpmTags() {
        XCTAssertEqual(128, parseBpmTag("128"))
        XCTAssertEqual(128, parseBpmTag("127.6"))
        XCTAssertEqual(128, parseBpmTag("127,6"))
        XCTAssertEqual(93, parseBpmTag(" 93 BPM"))
        XCTAssertNil(parseBpmTag("fast"))
        XCTAssertNil(parseBpmTag(""))
        XCTAssertEqual(0, parseBpmTag("0"))
        XCTAssertNil(usableBpm("0"))
        XCTAssertNil(usableBpm("2010"))
        XCTAssertEqual(40, usableBpm("40"))
        XCTAssertEqual(300, usableBpm("300"))
    }

    func testSearchNormalizer() {
        XCTAssertTrue(SearchNormalizer.matches("$ome $exy $ongs 4 U", "some sexy"))
        XCTAssertTrue(SearchNormalizer.matches("Beyoncé", "beyonce"))
        XCTAssertTrue(SearchNormalizer.matches("Mr. Lonely", "mr lonely"))
        XCTAssertFalse(SearchNormalizer.matches("Drake", "future"))
    }
}
