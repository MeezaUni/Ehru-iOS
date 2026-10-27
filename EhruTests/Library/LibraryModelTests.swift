import XCTest
@testable import Ehru

final class AlbumGrouperTests: XCTestCase {
    private let identity = ArtistIdentityResolver(aliases: [:])

    private func input(_ id: Int64, _ album: String = "Her Loss", aa: String? = nil, folder: String = "/Music/Her Loss",
                       track: Int? = nil, compilation: Bool = false) -> AlbumInput {
        AlbumInput(songId: id, album: album, rawAlbumArtist: aa, folder: folder, trackNumber: track ?? Int(id),
                   discNumber: 1, isCompilation: compilation)
    }

    func testNoAlbumArtistGroupsByTitle() {
        let groups = AlbumGrouper.group((1...16).map { input(Int64($0)) }, identity: identity)
        XCTAssertEqual(1, groups.count)
        XCTAssertEqual(16, groups[0].songIds.count)
    }

    func testSameTitleInTwoFoldersMerges() {
        let groups = AlbumGrouper.group([
            input(1, "Ganapathi Geethamala", folder: "/Download"),
            input(2, "Ganapathi Geethamala", folder: "/Download/Seal/Audio"),
        ], identity: identity)
        XCTAssertEqual(1, groups.count)
    }

    func testSameAlbumArtistAcrossFolders() {
        let groups = AlbumGrouper.group([input(1, aa: "Drake", folder: "/a"), input(2, aa: "Drake", folder: "/b")], identity: identity)
        XCTAssertEqual(1, groups.count)
        XCTAssertEqual("aa:drake", groups[0].groupingKey)
    }

    func testMissingAlbumArtistInherits() {
        let groups = AlbumGrouper.group([input(1, aa: "Drake"), input(2), input(3)], identity: identity)
        XCTAssertEqual(1, groups.count)
        XCTAssertFalse(groups[0].albumArtistInconsistent)
        XCTAssertEqual("drake", groups[0].albumArtistKey)
    }

    func testDifferingAlbumArtistsWithoutCollisionsMergeFlagged() {
        let groups = AlbumGrouper.group([input(1, aa: "Drake"), input(2, aa: "Drake"), input(3, aa: "Drake & 21 Savage")], identity: identity)
        XCTAssertEqual(1, groups.count)
        XCTAssertTrue(groups[0].albumArtistInconsistent)
        XCTAssertEqual("drake", groups[0].albumArtistKey)
    }

    func testCollidingTrackNumbersSplit() {
        let groups = AlbumGrouper.group([
            input(1, "Greatest Hits", aa: "Queen", folder: "/m", track: 1),
            input(2, "Greatest Hits", aa: "ABBA", folder: "/m", track: 1),
            input(3, "Greatest Hits", aa: nil, folder: "/m", track: 2),
        ], identity: identity)
        XCTAssertEqual(2, groups.count)
    }

    func testBlankTitlesGroupPerFolder() {
        let groups = AlbumGrouper.group([input(1, "", folder: "/a"), input(2, " ", folder: "/a"), input(3, "", folder: "/b")], identity: identity)
        XCTAssertEqual([2, 1], groups.map(\.songIds.count).sorted(by: >))
        XCTAssertTrue(groups.allSatisfy { $0.title == unknownAlbum })
    }

    func testUntitledTracksWithAlbumArtistStillGroupPerFolder() {
        let groups = AlbumGrouper.group([
            input(1, "", aa: "Drake", folder: "/Download"),
            input(2, "Unknown Album", aa: "Drake", folder: "/WhatsApp Documents"),
            input(3, "", aa: "Drake", folder: "/Music/x"),
        ], identity: identity)
        XCTAssertEqual(3, groups.count)
        XCTAssertTrue(groups.allSatisfy { $0.title == unknownAlbum && $0.groupingKey.hasPrefix("dir:") })
    }

    func testCompilationFlagCarried() {
        XCTAssertTrue(AlbumGrouper.group([input(1, compilation: true), input(2)], identity: identity)[0].isCompilationTagged)
    }

    func testIdsDeterministicAndOrderIndependent() {
        let inputs = (1...10).map { input(Int64($0), folder: $0 % 2 == 0 ? "/a" : "/b") }
        XCTAssertEqual(AlbumGrouper.group(inputs, identity: identity), AlbumGrouper.group(inputs.reversed(), identity: identity))
    }
}

final class AlbumPresenterTests: XCTestCase {
    private let identity = ArtistIdentityResolver(aliases: [:])
    private let names = ["drake": "Drake", "21 savage": "21 Savage", "kanye west": "Kanye West",
                         "kanye west/jay-z": "Kanye West/JAY-Z", "travis scott": "Travis Scott"]

    private func credit(_ text: String, _ role: CreditRole = .primary, unresolved: Bool = false) -> ResolvedCredit {
        ResolvedCredit(text: text, key: CreditText.canonicalKey(text), role: role, position: 0, isUnresolved: unresolved,
                       segmentKeys: CreditText.segmentsOf(text).map(\.key))
    }

    private func group(_ n: Int64, aa: String? = nil, compilation: Bool = false) -> AlbumGroup {
        AlbumGroup(id: 1, title: "X", groupingKey: "dir:/x", albumArtistKey: aa.map(CreditText.canonicalKey), albumArtistText: aa,
                   songIds: Array(1...n), isCompilationTagged: compilation, albumArtistInconsistent: false)
    }

    private func present(_ g: AlbumGroup, _ credits: [Int64: [ResolvedCredit]], standalone: Set<String> = []) -> AlbumPresentation {
        AlbumPresenter.present(g, creditsBySong: credits, standaloneKeys: standalone, identity: identity) { self.names[$0] ?? $0 }
    }

    func testCoreArtistsOnHalfTheTracks() {
        var credits: [Int64: [ResolvedCredit]] = [:]
        for i in Int64(1)...16 {
            credits[i] = i == 1 ? [credit("21 Savage")]
                : i <= 5 ? [credit("Drake")]
                : [credit("Drake"), credit("21 Savage"), credit("Travis Scott", .featured)]
        }
        let p = present(group(16), credits)
        XCTAssertEqual("Drake & 21 Savage", p.displayArtist)
        XCTAssertEqual(["drake", "21 savage"], p.linkedArtistKeys)
    }

    func testTaggedAlbumArtistWins() {
        XCTAssertEqual("Drake", present(group(2, aa: "Drake"), [1: [credit("21 Savage")]]).displayArtist)
    }

    func testCompilationAndScatteredBecomeVarious() {
        XCTAssertEqual(AlbumPresenter.variousArtists, present(group(2, compilation: true), [1: [credit("Drake")]]).displayArtist)
        var scattered: [Int64: [ResolvedCredit]] = [:]
        for i in Int64(1)...4 { scattered[i] = [credit("Artist \(i)")] }
        let p = present(group(4), scattered)
        XCTAssertEqual(AlbumPresenter.variousArtists, p.displayArtist)
        XCTAssertEqual([], p.linkedArtistKeys)
    }

    func testUnresolvedCountsTowardStandaloneLead() {
        let credits: [Int64: [ResolvedCredit]] = [1: [credit("Kanye West")], 2: [credit("Kanye West/JAY-Z", unresolved: true)]]
        XCTAssertEqual("Kanye West", present(group(2), credits, standalone: ["kanye west"]).displayArtist)
        let tyler: [Int64: [ResolvedCredit]] = [1: [credit("Tyler/ The Creator", unresolved: true)]]
        let unaliased = present(group(1), tyler)
        XCTAssertEqual("Tyler/ The Creator", unaliased.displayArtist)
        XCTAssertEqual([], unaliased.linkedArtistKeys)
        let aliased = AlbumPresenter.present(
            group(1), creditsBySong: tyler, standaloneKeys: [],
            identity: ArtistIdentityResolver(aliases: ManualArtistAliases.aliasKeys, canonicalNames: ManualArtistAliases.artistNames)
        ) { ManualArtistAliases.artistNames[$0] ?? $0 }
        XCTAssertEqual("Tyler, The Creator", aliased.displayArtist)
        XCTAssertEqual(["tyler, the creator"], aliased.linkedArtistKeys)
    }
}

final class LibraryModelBuilderTests: XCTestCase {
    private var fixture: [RawTrack] { LibraryFixture.tracks }
    private lazy var model = LibraryModelBuilder.build(fixture, aliases: [:])

    private func creditsOf(_ title: String) -> [String] {
        let track = fixture.first { $0.title == title }!
        return CreditResolver(evidence: EvidenceIndex.build(fixture)).resolve(track).map { "\($0.text)|\($0.role.rawValue)" }
    }

    func testGoldenAlbums() {
        let albums = model.albums.sorted { $0.title.lowercased() < $1.title.lowercased() }
            .map { "\($0.title)|\($0.songIds.count)|\($0.displayArtist)" }
        XCTAssertEqual([
            "Flower Boy|14|Tyler, The Creator",
            "Her Loss|16|Drake & 21 Savage",
            "ICEMAN|18|Drake",
            "IGOR|12|Tyler, The Creator",
            "Late Registration|21|Kanye West",
            "My Beautiful Dark Twisted Fantasy|13|Kanye West",
            "Without Warning|10|Metro Boomin, 21 Savage & Offset",
        ], albums)
    }

    func testGoldenCredits() {
        XCTAssertEqual(["Drake|PRIMARY", "21 Savage|PRIMARY"], creditsOf("Rich Flex"))
        XCTAssertEqual(["Drake|PRIMARY", "21 Savage|FEATURED"], creditsOf("B's On The Table (feat. 21 Savage)"))
        XCTAssertEqual(["21 Savage|PRIMARY", "Offset|PRIMARY", "Metro Boomin|PRIMARY"], creditsOf("Darth Vader"))
        XCTAssertEqual(["Offset|PRIMARY", "Metro Boomin|PRIMARY"], creditsOf("Nightmare"))
        XCTAssertEqual(["21 Savage|PRIMARY", "Offset|PRIMARY", "Metro Boomin|PRIMARY", "Travis Scott|FEATURED"],
                       creditsOf("Ghostface Killers (feat. Travis Scott)"))
        XCTAssertEqual(["Tyler/ The Creator|PRIMARY"], creditsOf("Glitter"))
        XCTAssertEqual(["Tyler/ The Creator|PRIMARY", "Kali Uchis|FEATURED"], creditsOf("See You Again (feat. Kali Uchis)"))
        XCTAssertEqual(["Tyler/ The Creator|PRIMARY", "Rex Orange County/Anna of the North|FEATURED"],
                       creditsOf("Boredom (feat. Rex Orange County & Anna of the North)"))
        XCTAssertEqual(["Tyler/ The Creator/Alexander Brettin/Jaden|PRIMARY"], creditsOf("Pothole (feat. Jaden Smith)"))
        XCTAssertEqual(["Kanye West/JAY-Z|PRIMARY", "Rick Ross/Nicki Minaj/Bon Iver|PRIMARY"], creditsOf("Monster"))
    }

    func testAlbumGroupingIgnoresTrackArtists() {
        let a = model.albums.map { "\($0.id)|\($0.songIds)" }
        let b = LibraryModelBuilder.build(fixture.map { var t = $0; t.rawArtist = "X"; return t }, aliases: [:]).albums.map { "\($0.id)|\($0.songIds)" }
        XCTAssertEqual(a, b)
    }

    func testModelIndependentOfInputOrder() {
        for seed in 0..<20 {
            var generator = SeededGenerator(state: UInt64(seed))
            XCTAssertEqual(model, LibraryModelBuilder.build(fixture.shuffled(using: &generator), aliases: [:]))
        }
    }

    func testAddingTracksNeverRemovesSplit() {
        let ww = fixture.filter { $0.album == "Without Warning" }
        let wwIds = Set(ww.map(\.songId))
        func splits(_ m: LibraryModel) -> Set<String> {
            Set(m.credits.filter { wwIds.contains($0.songId) }.map { "\($0.songId)|\($0.creditText)" })
        }
        let small = splits(LibraryModelBuilder.build(ww, aliases: [:]))
        let large = splits(model)
        for split in small where !split.contains("/") {
            XCTAssertTrue(large.contains(split), split)
        }
    }

    func testCreditsDependOnlyOnRawRows() {
        let evidence = EvidenceIndex.build(fixture)
        let identity = ArtistIdentityResolver(aliases: ManualArtistAliases.aliasKeys, canonicalNames: ManualArtistAliases.artistNames)
        for track in fixture {
            let direct = CreditResolver(evidence: evidence).resolve(track).filter(identity.hasIdentity).map(\.text)
            let stored = model.credits.filter { $0.songId == track.songId }.sorted { $0.position < $1.position }.map(\.creditText)
            XCTAssertEqual(direct, stored, track.title)
        }
    }

    func testUnverifiedSegmentsLinkStandaloneArtists() {
        let kanye = IdentityHash.of("kanye west")
        let monster = LibraryFixture.songId("Monster")
        XCTAssertTrue(model.unverifiedSegments.contains { $0.songId == monster && $0.segmentKey == "kanye west" })
        XCTAssertFalse(model.artists.contains { $0.id == kanye && $0.isUnresolved })
    }

    func testTenThousandTracksBuildQuickly() {
        let big = (0..<10_000).map { i in
            rawTrack(Int64(i), "t\(i)", "Artist \(i % 2000)/Guest \(i % 7)", nil, "Album \(i % 800)", i % 20, 1, "/m/\(i % 800)")
        }
        let start = Date()
        _ = LibraryModelBuilder.build(big, aliases: [:])
        // Android allows 2 s on a JVM; this runs unoptimised in a simulator, so the bound is looser.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}

final class AcceptanceCriteriaTests: XCTestCase {
    private lazy var model = LibraryModelBuilder.build(LibraryFixture.tracks, aliases: [:])

    private func albumsTitled(_ title: String) -> [AlbumRow] { model.albums.filter { $0.title == title } }
    private func albumTitled(_ title: String) -> AlbumRow { albumsTitled(title)[0] }

    func testHerLossIsOneAlbum() {
        XCTAssertEqual(1, albumsTitled("Her Loss").count)
        XCTAssertEqual(16, albumTitled("Her Loss").songIds.count)
    }

    func testWithoutWarningAllThreeResolved() {
        let album = albumTitled("Without Warning")
        let credits = model.credits.filter { album.songIds.contains($0.songId) }
        XCTAssertFalse(credits.contains { $0.isUnresolved })
        for key in ["21 savage", "offset", "metro boomin"] {
            let artist = model.artists.first { $0.key == key }!
            XCTAssertFalse(artist.isUnresolved)
            XCTAssertTrue(credits.contains { $0.artistId == artist.id })
        }
    }

    func testTylerIsOneArtist() {
        XCTAssertEqual(["Tyler, The Creator"], model.artists.filter { $0.key == "tyler, the creator" }.map(\.name))
        XCTAssertFalse(model.artists.contains { ["the creator", "tyler", "tyler/ the creator"].contains($0.key) })
        let tyler = IdentityHash.of("tyler, the creator")
        for title in ["Flower Boy", "IGOR"] {
            let album = albumTitled(title)
            XCTAssertTrue(model.albumArtists.contains { $0.albumId == album.id && $0.artistId == tyler }, title)
            XCTAssertEqual("Tyler, The Creator", album.displayArtist)
        }
        XCTAssertTrue(model.credits.filter { $0.songId == LibraryFixture.songId("Glitter") }.allSatisfy { $0.artistId == tyler })
    }

    func testNothingNowhereStaysOneCredit() {
        let extra = rawTrack(9_000_001, "Song", "nothing/nowhere.", nil, "Album", 1, 1, "/m/nn")
        let tracks = LibraryFixture.tracks + [extra]
        XCTAssertEqual(["nothing/nowhere."], CreditResolver(evidence: EvidenceIndex.build(tracks)).resolve(extra).map(\.text))
        let withNn = LibraryModelBuilder.build(tracks, aliases: [:])
        XCTAssertFalse(withNn.artists.contains { ["nothing", "nowhere.", "nothing/nowhere."].contains($0.key) })
    }

    func testYameiiFollowsExplicitEvidence() {
        let tracks = [rawTrack(1, "a", "Yameii", nil, "A", 1, 1, "/y"), rawTrack(2, "b", "Yameii Online", nil, "B", 1, 1, "/y2")]
        let separate = LibraryModelBuilder.build(tracks, aliases: [:])
        XCTAssertNotEqual(separate.artists.first { $0.key == "yameii" }!.id, separate.artists.first { $0.key == "yameii online" }!.id)
        let merged = LibraryModelBuilder.build(tracks, aliases: ["yameii online": "yameii"])
        XCTAssertEqual(1, merged.artists.count)
        XCTAssertEqual(2, merged.artists[0].songCount)
    }

    func testMbdtfLinkedToKanye() {
        let album = albumTitled("My Beautiful Dark Twisted Fantasy")
        XCTAssertEqual("Kanye West", album.displayArtist)
        XCTAssertTrue(model.albumArtists.contains { $0.albumId == album.id && $0.artistId == IdentityHash.of("kanye west") })
        XCTAssertEqual(6_684_406_489_965_805_378, model.artists.first { $0.key == "kanye west" }!.id)
    }

    func testUnresolvedKanyeCollaborationsCreateNoArtist() {
        for name in ["Kanye West/JAY-Z", "Kanye West/Adam Levine", "Kanye West/Bon Iver", "Kanye West/Brandy", "Kanye West/Kid Cudi/Raekwon"] {
            XCTAssertFalse(model.artists.contains { $0.name == name }, name)
        }
        for title in ["Monster", "So Appalled", "Gorgeous"] {
            XCTAssertTrue(model.unverifiedSegments.contains { $0.songId == LibraryFixture.songId(title) && $0.segmentKey == "kanye west" }, title)
        }
    }

    func testUnresolvedFeaturedCreditsCreateNoArtist() {
        let tracks = [
            rawTrack(1, "911 / Mr. Lonely", "Tyler/ The Creator/Frank Ocean/Steve Lacy", nil, "Flower Boy", 1, 1, "/fb"),
            rawTrack(2, "Song", "Drake feat. Future, Molly Santana", nil, "X", 1, 1, "/x"),
            rawTrack(3, "Solo", "Drake", nil, "X", 2, 1, "/x"),
        ]
        let m = LibraryModelBuilder.build(tracks, aliases: [:])
        for key in ["frank ocean/steve lacy", "future, molly santana"] {
            XCTAssertFalse(m.artists.contains { $0.key == key }, key)
        }
        XCTAssertFalse(m.credits.contains { $0.creditText == "Future, Molly Santana" })
    }

    func testFullBuildHasNoUnresolvedArtistRows() {
        XCTAssertFalse(model.artists.contains { $0.isUnresolved })
        let credited = Set(model.credits.map(\.artistId)).union(model.albumArtists.map(\.artistId))
        XCTAssertEqual(Set(model.artists.map(\.id)), credited)
        XCTAssertFalse(model.artists.contains { $0.key.contains("/") })
        XCTAssertEqual(model.artists.count, Set(model.artists.map(\.key)).count)
    }

    func testOnlyUnresolvedCreditsMeansNoPrimaryArtist() {
        XCTAssertEqual(noArtistId, model.songs[LibraryFixture.songId("Monster")]!.primaryArtistId)
        XCTAssertFalse(model.credits.contains { $0.songId == LibraryFixture.songId("Monster") })
    }

    func testCompoundTaggedAlbumArtistCreatesNoArtist() {
        let tracks = [
            rawTrack(1, "a", "Drake", "Drake & 21 Savage", "Her Loss", 1, 1, "/hl"),
            rawTrack(2, "b", "21 Savage", "Drake & 21 Savage", "Her Loss", 2, 1, "/hl"),
        ]
        let m = LibraryModelBuilder.build(tracks, aliases: [:])
        XCTAssertFalse(m.artists.contains { $0.key == "drake & 21 savage" })
        XCTAssertEqual("Drake & 21 Savage", m.albums[0].displayArtist)
    }
}
