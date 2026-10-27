import XCTest
@testable import Ehru

final class CreditTextTests: XCTestCase {
    func testCanonicalKeyFoldsCaseWidthNormalFormAndSpacing() {
        XCTAssertEqual("drake", CreditText.canonicalKey("  DRAKE "))
        XCTAssertEqual("drake", CreditText.canonicalKey("ＤＲＡＫＥ"))
        XCTAssertEqual(CreditText.canonicalKey("Beyoncé"), CreditText.canonicalKey("Beyonce\u{301}"))
        XCTAssertEqual("21 savage", CreditText.canonicalKey("21   Savage"))
        XCTAssertEqual("lil wayne", CreditText.canonicalKey("LIL WAYNE"))
    }

    func testSegmentsKeepOriginalOffsets() {
        let segments = CreditText.segmentsOf("Tyler/ The Creator")
        XCTAssertEqual(["Tyler", "The Creator"], segments.map(\.text))
        XCTAssertEqual(7, segments[1].start)
    }

    func testXAndAndAreSeparatorsOnlyWhenSpaced() {
        XCTAssertEqual(1, CreditText.segmentsOf("Lil Nas X").count)
        XCTAssertEqual(2, CreditText.segmentsOf("suicideboys x SHAKEWELL").count)
        XCTAssertEqual(2, CreditText.segmentsOf("Simon and Garfunkel").count)
        XCTAssertEqual(1, CreditText.segmentsOf("Anderson .Paak").count)
    }

    func testAdjacentDuplicateSegmentsCollapse() {
        let keys = CreditText.segmentsOf("S.P. Balasubrahmanyam, T.K. Pugazhendi, T.K. Pugazhendi, R.N. Jayagopal").map(\.key)
        XCTAssertEqual(["s.p. balasubrahmanyam", "t.k. pugazhendi", "r.n. jayagopal"], keys)
    }

    func testArtistTextFeatMarkerProducesFeaturedRun() {
        let runs = CreditText.runs("Drake feat. Future, Young Thug")
        XCTAssertEqual([false, true], runs.map(\.featured))
        XCTAssertEqual(["Future", "Young Thug"], runs[1].segments.map(\.text))
        XCTAssertEqual(["Future"], CreditText.runs("Drake (with Future)")[1].segments.map(\.text))
    }

    func testPunctuationOnlyTextHasNoRuns() {
        XCTAssertTrue(CreditText.runs(" / ").isEmpty)
        XCTAssertTrue(CreditText.runs(" & ").isEmpty)
    }

    func testBlockKeyIgnoresSeparators() {
        XCTAssertEqual(CreditText.blockKey("Tyler, The Creator"), CreditText.blockKey("Tyler/ The Creator"))
        XCTAssertEqual(
            CreditText.blockKey("Rex Orange County & Anna of the North"),
            CreditText.blockKey("Rex Orange County/Anna of the North")
        )
    }
}

final class EvidenceIndexTests: XCTestCase {
    private func track(_ id: Int64, _ artist: String, title: String? = nil, albumArtist: String? = nil) -> RawTrack {
        rawTrack(id, title ?? "t\(id)", artist, albumArtist, "A", Int(id), 1, "/m")
    }

    func testTwoSidedIndependence() {
        let index = EvidenceIndex.build([
            track(1, "21 Savage"), track(2, "Offset/Metro Boomin"),
            track(3, "21 Savage/Metro Boomin"), track(4, "Tyler/ The Creator"),
        ])
        XCTAssertTrue(index.independent("21 savage", "metro boomin"))
        XCTAssertFalse(index.independent("offset", "metro boomin"))
        XCTAssertFalse(index.independent("tyler", "the creator"))
    }

    func testTitleMarkerGivesBoundaryAndOwnRole() {
        let index = EvidenceIndex.build([track(7, "Offset/Metro Boomin", title: "Ric Flair Drip (with Metro Boomin)")])
        XCTAssertEqual([1], index.propagatedBoundaries(["offset", "metro boomin"]))
        XCTAssertEqual([2], index.propagatedBoundaries(["21 savage", "offset", "metro boomin"]))
        XCTAssertEqual(.primary, index.ownMarkerRole(songId: 7, boundary: 1))
        XCTAssertNil(index.ownMarkerRole(songId: 8, boundary: 1))
    }

    func testTitleMarkerComparedAsOneBlock() {
        let index = EvidenceIndex.build([track(1, "Kali Uchis/Tyler/ The Creator", title: "Song (feat. Tyler, The Creator)")])
        XCTAssertEqual([1], index.propagatedBoundaries(["kali uchis", "tyler", "the creator"]))
    }

    func testUnmatchedMarkerGivesNoEvidence() {
        let index = EvidenceIndex.build([
            track(1, "Tyler/ The Creator/Alexander Brettin/Jaden", title: "Pothole (feat. Jaden Smith)"),
            track(2, "A/B/C", title: "Song (feat. B) [with C]"),
        ])
        XCTAssertTrue(index.propagatedBoundaries(["tyler", "the creator", "alexander brettin", "jaden"]).isEmpty)
        XCTAssertEqual([2], index.propagatedBoundaries(["a", "b", "c"]))
    }

    func testStandaloneKeys() {
        let index = EvidenceIndex.build([track(1, "Kanye West"), track(2, "Kanye West/JAY-Z"), track(3, "")])
        XCTAssertEqual(["kanye west"], index.standaloneKeys)
    }

    func testAlbumArtistTagsAreObservations() {
        let index = EvidenceIndex.build([track(1, "A/B", albumArtist: "A"), track(2, "B")])
        XCTAssertTrue(index.independent("a", "b"))
    }
}

final class CreditResolverTests: XCTestCase {
    private func track(_ id: Int64, _ artist: String, title: String? = nil) -> RawTrack {
        rawTrack(id, title ?? "t\(id)", artist, nil, "A", Int(id), 1, "/m")
    }

    private struct C: Equatable {
        let text: String
        let role: CreditRole
        let unresolved: Bool
    }

    private func resolveIn(_ library: [RawTrack], _ id: Int64) -> [C] {
        CreditResolver(evidence: EvidenceIndex.build(library))
            .resolve(library.first { $0.songId == id }!)
            .map { C(text: $0.text, role: $0.role, unresolved: $0.isUnresolved) }
    }

    func testNoEvidenceKeepsOriginalTextUnresolved() {
        for name in ["Tyler/ The Creator", "nothing/nowhere.", "AC/DC", "Earth, Wind & Fire", "Mumford & Sons",
                     "Simon and Garfunkel", "Florence + The Machine", "suicideboys x SHAKEWELL"] {
            XCTAssertEqual([C(text: name, role: .primary, unresolved: true)], resolveIn([track(1, name)], 1), name)
        }
        XCTAssertEqual([C(text: "Guns N' Roses", role: .primary, unresolved: false)], resolveIn([track(1, "Guns N' Roses")], 1))
        XCTAssertEqual([C(text: "Lil Nas X", role: .primary, unresolved: false)], resolveIn([track(1, "Lil Nas X")], 1))
        XCTAssertEqual([C(text: "Drake with Future", role: .primary, unresolved: false)], resolveIn([track(1, "Drake with Future")], 1))
    }

    func testIndependentSegmentsSplitForEverySeparator() {
        for sep in [" & ", " / ", "; ", ", ", " x "] {
            let lib = [track(1, "Drake\(sep)Future"), track(2, "Drake"), track(3, "Future")]
            XCTAssertEqual(["Drake", "Future"], resolveIn(lib, 1).map(\.text), sep)
        }
        let sb = [track(1, "$uicideboy$ x SHAKEWELL"), track(2, "$uicideboy$"), track(3, "SHAKEWELL")]
        XCTAssertEqual(["$uicideboy$", "SHAKEWELL"], resolveIn(sb, 1).map(\.text))
    }

    func testFeatMarkersSplitPrimaryFromFeatured() {
        for raw in ["Drake feat. Future", "Drake ft. Future", "Drake featuring Future", "Drake (with Future)"] {
            XCTAssertEqual(
                [C(text: "Drake", role: .primary, unresolved: false), C(text: "Future", role: .featured, unresolved: false)],
                resolveIn([track(1, raw)], 1), raw
            )
        }
    }

    func testFeaturedBlockNeedsEvidenceToo() {
        let lonely = [track(1, "Drake feat. Future & Young Thug")]
        XCTAssertEqual(["Drake", "Future & Young Thug"], resolveIn(lonely, 1).map(\.text))
        let known = lonely + [track(2, "Future"), track(3, "Young Thug")]
        XCTAssertEqual(["Drake", "Future", "Young Thug"], resolveIn(known, 1).map(\.text))
    }

    func testTitleMarkerRoleOnOwnTrackOnly() {
        let lib = [track(1, "Drake, 21 Savage", title: "B's On The Table (feat. 21 Savage)"), track(2, "Drake/21 Savage", title: "Rich Flex")]
        XCTAssertEqual([C(text: "Drake", role: .primary, unresolved: false), C(text: "21 Savage", role: .featured, unresolved: false)], resolveIn(lib, 1))
        XCTAssertEqual([C(text: "Drake", role: .primary, unresolved: false), C(text: "21 Savage", role: .primary, unresolved: false)], resolveIn(lib, 2))
    }

    func testWithoutWarning() {
        let ww = [
            track(1, "21 Savage/Offset/Metro Boomin", title: "Darth Vader"),
            track(2, "Offset/Metro Boomin", title: "Ric Flair Drip (with Metro Boomin)"),
            track(3, "21 Savage/Metro Boomin", title: "Run Up the Racks"),
            track(4, "21 Savage", title: "3AM on Glenwood"),
        ]
        XCTAssertEqual(["21 Savage", "Offset", "Metro Boomin"], resolveIn(ww, 1).map(\.text))
        let withoutMarker = ww.map { t -> RawTrack in
            var copy = t
            if t.songId == 2 { copy.title = "Nightmare" }
            return copy
        }
        XCTAssertEqual(
            [C(text: "21 Savage", role: .primary, unresolved: false), C(text: "Offset/Metro Boomin", role: .primary, unresolved: true)],
            resolveIn(withoutMarker, 1)
        )
    }

    func testMarkerBlockWithPunctuationKeptWhole() {
        let lib = [track(1, "Kali Uchis/Tyler/ The Creator", title: "Song (feat. Tyler, The Creator)")]
        XCTAssertEqual(
            [C(text: "Kali Uchis", role: .primary, unresolved: false), C(text: "Tyler/ The Creator", role: .featured, unresolved: true)],
            resolveIn(lib, 1)
        )
    }

    func testBlankAndUnknownBecomeUnknownArtist() {
        for raw in ["", " / ", " & ", "Unknown Artist", "unknown artist"] {
            XCTAssertEqual([C(text: unknownArtist, role: .primary, unresolved: false)], resolveIn([track(1, raw)], 1), raw)
        }
    }

    func testPositionsSequentialAndDuplicatesRemoved() {
        let lib = [track(1, "A/B feat. A"), track(2, "A"), track(3, "B")]
        let credits = CreditResolver(evidence: EvidenceIndex.build(lib)).resolve(lib[0])
        XCTAssertEqual(["A", "B"], credits.map(\.text))
        XCTAssertEqual([0, 1], credits.map(\.position))
    }
}

final class ArtistIdentityTests: XCTestCase {
    func testIdentityHashKeepsAndroidIds() {
        XCTAssertEqual(1_616_113_631_558_986_022, IdentityHash.of("drake"))
        XCTAssertEqual(6_800_762_372_324_799_937, IdentityHash.of("21 savage"))
        XCTAssertEqual(-484_836_757_766_393_360, IdentityHash.of("$uicideboy$"))
        XCTAssertEqual(6_684_406_489_965_805_378, IdentityHash.of("kanye west"))
    }

    func testExactNamesShareIdentity() {
        let identity = ArtistIdentityResolver(aliases: [:])
        XCTAssertEqual(identity.idOf(CreditText.canonicalKey("Drake")), identity.idOf(CreditText.canonicalKey("ＤＲＡＫＥ ")))
        XCTAssertNotEqual(identity.idOf("yameii"), identity.idOf("yameii online"))
        XCTAssertNotEqual(identity.idOf("future"), identity.idOf("future islands"))
    }

    func testAliasMapsOneKey() {
        let identity = ArtistIdentityResolver(aliases: ["tyler/ the creator": "tyler, the creator"])
        XCTAssertEqual(identity.idOf("tyler, the creator"), identity.idOf("tyler/ the creator"))
        XCTAssertEqual("tyler, the creator", identity.canonicalKey("tyler/ the creator"))
    }

    func testDisplayNameMostFrequentThenAlphabetical() {
        XCTAssertEqual("Drake", chooseDisplayName(["Drake": 5, "DRAKE": 1]))
        XCTAssertEqual("AAA", chooseDisplayName(["aaa": 2, "AAA": 2]))
    }

    func testPrimaryArtistExtractor() {
        XCTAssertEqual("The Weeknd", PrimaryArtistExtractor.extractPrimaryArtist("The Weeknd feat. Daft Punk"))
        XCTAssertEqual("Drake", PrimaryArtistExtractor.extractPrimaryArtist("Drake & Future"))
        XCTAssertNil(PrimaryArtistExtractor.extractPrimaryArtist("Unknown Artist"))
        XCTAssertNil(PrimaryArtistExtractor.extractPrimaryArtist(nil))
        XCTAssertNil(PrimaryArtistExtractor.extractPrimaryArtist("   "))
        XCTAssertEqual("Michael Jackson", PrimaryArtistExtractor.extractPrimaryArtist("Michael Jackson"))
    }
}
