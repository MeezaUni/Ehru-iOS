import XCTest
@testable import Ehru

let day: Int64 = 86_400_000
/// 2026-10-15 12:00 UTC.
let now: Int64 = 1_792_065_600_000

func track(_ id: Int64, artist: Int64? = nil, album: Int64? = nil, genre: String? = nil, bpm: Int? = nil,
           favorite: Bool = false, durationMs: Int64 = 200_000, year: Int? = nil) -> TrackFacts {
    let artist = artist ?? id
    return TrackFacts(
        songId: id, title: "Song \(id)", artistId: artist, artist: "Artist \(artist)", albumId: album ?? artist * 100,
        album: "Album \(album ?? artist * 100)", genre: genre, bpm: bpm, durationMs: durationMs, isFavorite: favorite,
        addedAt: id, year: year
    )
}

/// [count] plays of [songId], the latest [daysAgo] days before [now].
func played(_ songId: Int64, _ count: Int, daysAgo: Int) -> MonthlyPlays {
    MonthlyPlays(songId: songId, month: "m\(daysAgo / 30)", plays: count, lastPlayedAt: now - Int64(daysAgo) * day)
}

final class SmartMixEngineTests: XCTestCase {
    /// 80 songs over 8 artists (10 each, two albums per artist), genres by artist.
    private let library: [TrackFacts] = (Int64(1)...80).map { id in
        let artist = (id - 1) / 10 + 1
        let genre: String
        switch artist {
        case 1...4: genre = "Hip-Hop"
        case 5: genre = "Ambient"
        case 6: genre = "R&B"
        case 7: genre = "Techno"
        default: genre = "Indie Pop"
        }
        return track(id, artist: artist, album: artist * 100 + id % 2, genre: genre)
    }

    private func profile(_ plays: MonthlyPlays...) -> ListeningProfile {
        SmartMixEngine.profile(tracks: library, plays: plays, now: now)
    }

    func testRotationFavoursRecentPlaysOverOldHeavyOnes() {
        let p = profile(played(1, 30, daysAgo: 200), played(2, 3, daysAgo: 2), played(3, 6, daysAgo: 40),
                        played(4, 3, daysAgo: 1), played(5, 2, daysAgo: 3), played(6, 2, daysAgo: 5), played(7, 2, daysAgo: 6))
        let rotation = SmartMixEngine.rotation(p)!.songIds
        XCTAssertFalse(rotation.contains(1))
        XCTAssertLessThan(rotation.firstIndex(of: 4)!, rotation.firstIndex(of: 3)!)
        XCTAssertEqual(4, rotation.first)
    }

    func testRecencyWeightingHalvesOverTheHalfLife() {
        let p = profile(played(1, 4, daysAgo: 0), played(2, 4, daysAgo: 21))
        XCTAssertEqual(p.history(1).recent / 2, p.history(2).recent, accuracy: 0.01)
    }

    func testForgottenFavouritesNeedRealPastListeningAndAWhileAway() {
        let p = profile(played(10, 8, daysAgo: 120), played(11, 5, daysAgo: 90), played(12, 4, daysAgo: 70),
                        played(13, 3, daysAgo: 65), played(14, 6, daysAgo: 100), played(15, 1, daysAgo: 200), played(16, 9, daysAgo: 3))
        XCTAssertEqual([10, 14, 11, 12, 13], SmartMixEngine.forgotten(p)!.songIds)
    }

    func testDeepCutsAreLessPlayedSongsByEnjoyedArtists() {
        let loved = profile(played(1, 20, daysAgo: 5), played(2, 15, daysAgo: 10), played(3, 1, daysAgo: 30),
                            played(11, 9, daysAgo: 4), played(12, 8, daysAgo: 4))
        let ids = SmartMixEngine.deepCuts(loved)!.songIds
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.allSatisfy { ![1, 2, 11, 12].contains($0) })
        XCTAssertTrue(ids.allSatisfy { [1, 2].contains(library[Int($0) - 1].artistId) })
        XCTAssertFalse(ids.prefix(2).contains(3))
        let small = SmartMixEngine.profile(tracks: library.filter { $0.songId <= 4 || $0.artistId > 1 },
                                           plays: [played(1, 20, daysAgo: 5)], now: now)
        XCTAssertNil(SmartMixEngine.deepCuts(small))
    }

    func testSparseHistoryOffersNoPersonalMixesAndSaysSo() {
        let sparse = SmartMixEngine.build(profile(played(1, 2, daysAgo: 1), played(2, 1, daysAgo: 1)), taste: nil)
        XCTAssertTrue(sparse.needsMoreListening)
        XCTAssertTrue(sparse.mixes.allSatisfy { !$0.kind.personal })
        let favourites = library.map { t in
            track(t.songId, artist: t.artistId, album: t.albumId, genre: t.genre, favorite: t.songId <= 4)
        }
        let withFavourites = SmartMixEngine.build(SmartMixEngine.profile(tracks: favourites, plays: [], now: now), taste: nil)
        XCTAssertEqual(Set<Int64>([1, 2, 3, 4]), Set(withFavourites.mix(.favourites)!.songIds))
        XCTAssertNotNil(withFavourites.mix(.fresh))
    }

    func testDifferentHistoriesGiveDifferentMixes() {
        let hipHopFan = (Array(1...5) + Array(11...15)).map { played(Int64($0), 5, daysAgo: $0 % 7) }
        let ambientFan = (Array(51...55) + Array(71...75)).map { played(Int64($0), 5, daysAgo: $0 % 7) }
        let a = SmartMixEngine.build(SmartMixEngine.profile(tracks: library, plays: hipHopFan, now: now), taste: nil)
        let b = SmartMixEngine.build(SmartMixEngine.profile(tracks: library, plays: ambientFan, now: now), taste: nil)
        XCTAssertNotEqual(a.mix(.rotation)!.songIds, b.mix(.rotation)!.songIds)
        XCTAssertNotEqual(a.mix(.yourSound)?.songIds, b.mix(.yourSound)?.songIds)
        let aSound = a.mix(.yourSound)!.songIds.prefix(3).map { library[Int($0) - 1].genre }
        XCTAssertTrue(aSound.allSatisfy { $0 == "Hip-Hop" })
    }

    func testVybeTasteShapesYourKindOfSoundAndIsCredited() {
        let history = (Array(1...5) + Array(11...15)).map { played(Int64($0), 5, daysAgo: 1) }
        let p = SmartMixEngine.profile(tracks: library, plays: history, now: now)
        var near: [Int64: Float] = [:]
        for id in Int64(71)...80 { near[id] = 1 - Float(id - 71) * 0.01 }
        let withVybe = SmartMixEngine.build(p, taste: near).mix(.yourSound)!
        XCTAssertEqual(71, withVybe.songIds.first)
        XCTAssertTrue(withVybe.description.contains("VYBE"))
        XCTAssertFalse(SmartMixEngine.build(p, taste: nil).mix(.yourSound)!.description.contains("VYBE"))
    }

    func testEveryMixHasNoDuplicatesAndIsDeterministic() {
        var history: [MonthlyPlays] = []
        for id in Int64(1)...45 {
            let count = Int(id % 6) + 1
            let daysAgo = Int(id * 7 % 150)
            history.append(played(id, count, daysAgo: daysAgo))
        }
        let first = SmartMixEngine.build(SmartMixEngine.profile(tracks: library, plays: history, now: now), taste: nil)
        var generator = SeededGenerator(state: 4)
        let again = SmartMixEngine.build(
            SmartMixEngine.profile(tracks: library.shuffled(using: &generator), plays: history.shuffled(using: &generator), now: now),
            taste: nil
        )
        XCTAssertEqual(first, again)
        XCTAssertFalse(first.mixes.isEmpty)
        for mix in first.mixes { XCTAssertEqual(mix.songIds.count, Set(mix.songIds).count, mix.kind.title) }
    }

    func testTasteSeedsAreTheMostLastingSongs() {
        let seeds = SmartMixEngine.tasteSeeds(profile(played(1, 10, daysAgo: 1), played(2, 10, daysAgo: 300), played(3, 1, daysAgo: 1)))
        XCTAssertEqual([1, 2, 3], seeds.sorted { $0.value > $1.value }.map(\.key))
    }

    func testHashMatchesAndroid() {
        XCTAssertEqual(javaHashCode(""), 0)
        XCTAssertEqual(javaHashCode("a"), 97)
        XCTAssertEqual(javaHashCode("ab"), 97 * 31 + 98)
        XCTAssertEqual(javaHashCode("hello"), 99_162_322)
    }
}

final class MoodsTests: XCTestCase {
    func testBpmAloneNeverDecidesAMood() {
        XCTAssertFalse(Moods.isHighEnergy(track(1, bpm: 150)))
        XCTAssertFalse(Moods.isChill(track(2, bpm: 72)))
        XCTAssertFalse(Moods.isLateNight(track(3, bpm: 80)))
    }

    func testHalfAndDoubleTimeBpmIsTreatedAsUnknown() {
        XCTAssertNil(Moods.tempo(track(1, bpm: 64)))
        XCTAssertNil(Moods.tempo(track(2, bpm: 190)))
        XCTAssertEqual(120, Moods.tempo(track(3, bpm: 120)))
        XCTAssertTrue(Moods.isHighEnergy(track(4, genre: "Techno", bpm: 64)))
    }

    func testGenresDecideWithTheTempoAsSupport() {
        XCTAssertTrue(Moods.isHighEnergy(track(1, genre: "Drum and Bass")))
        XCTAssertTrue(Moods.isChill(track(2, genre: "Lo-Fi")))
        XCTAssertTrue(Moods.isLateNight(track(3, genre: "R&B")))
        XCTAssertFalse(Moods.isLateNight(track(4, genre: "R&B", bpm: 140)))
        XCTAssertFalse(Moods.isChill(track(5, genre: "Folk", bpm: 150)))
        XCTAssertTrue(Moods.isChill(track(6, genre: "Ambient", bpm: 140)))
        XCTAssertTrue(Moods.isHighEnergy(track(7, genre: "Indie Pop", bpm: 130)))
        XCTAssertFalse(Moods.isHighEnergy(track(8, genre: "Indie Pop", bpm: 100)))
    }

    func testCalmAndEnergeticDoNotOverlap() {
        let softRock = track(1, genre: "Soft Rock")
        XCTAssertFalse(Moods.isHighEnergy(softRock))
        XCTAssertTrue(Moods.isChill(softRock))
        XCTAssertFalse(Moods.isChill(track(2, genre: "Folk Punk")))
    }

    func testSeveralGenresInOneTagAreRead() {
        XCTAssertTrue(Moods.isLateNight(track(1, genre: "Pop; Neo Soul")))
        XCTAssertEqual(["hip-hop", "r&b"], genresOf(track(2, genre: "Hip-Hop / R&B")))
    }
}

final class LibraryMixesTests: XCTestCase {
    private func profile(_ tracks: [TrackFacts], _ plays: [MonthlyPlays] = []) -> ListeningProfile {
        SmartMixEngine.profile(tracks: tracks, plays: plays, now: now)
    }

    private func range(_ r: ClosedRange<Int64>, _ make: (Int64) -> TrackFacts) -> [TrackFacts] { r.map(make) }

    func testSpotlightIsTheMostPlayedArtistWithEnoughSongs() {
        let tracks = range(1...8) { track($0, artist: 1) } + range(11...20) { track($0, artist: 2) }
        let mix = LibraryMixes.spotlight(profile(tracks, [played(3, 4, daysAgo: 2)]))!
        XCTAssertEqual("Spotlight: Artist 1", mix.title)
        XCTAssertEqual(8, mix.songIds.count)
        XCTAssertEqual(3, mix.songIds.first)
    }

    func testSpotlightWithoutHistoryIsTheArtistWithTheMostSongs() {
        let tracks = range(1...8) { track($0, artist: 1) } + range(11...20) { track($0, artist: 2) }
        XCTAssertEqual("Spotlight: Artist 2", LibraryMixes.spotlight(profile(tracks))!.title)
        XCTAssertNil(LibraryMixes.spotlight(profile(range(1...5) { track($0, artist: 1) })))
    }

    func testThrowbacksTrustOnlyRealOldYears() {
        let old = range(1...8) { track($0, year: 2009) }
        let placeholder = range(11...30) { track($0, year: 1970) }
        let missing = range(31...40) { track($0, year: 0) }
        let recent = range(41...50) { track($0, year: 2024) }
        let mix = LibraryMixes.throwbacks(profile(old + placeholder + missing + recent))!
        XCTAssertEqual(Set<Int64>(1...8), Set(mix.songIds))
        XCTAssertNil(LibraryMixes.throwbacks(profile(placeholder + missing + recent)))
    }

    func testQuickHitsAndLongListensFollowTheSongsLength() {
        let short = range(1...9) { track($0, durationMs: 140_000) }
        let long = range(11...19) { track($0, durationMs: 360_000) }
        let p = profile(short + long + range(21...30) { track($0) })
        XCTAssertEqual(Set<Int64>(1...9), Set(LibraryMixes.quickHits(p)!.songIds))
        XCTAssertEqual(Set<Int64>(11...19), Set(LibraryMixes.longListens(p)!.songIds))
    }

    func testYetToHearNeedsRealHistoryAndHoldsOnlyUnplayedSongs() {
        let tracks = range(1...20) { track($0) }
        XCTAssertNil(LibraryMixes.yetToHear(profile(tracks)))
        let mix = LibraryMixes.yetToHear(profile(tracks, (Int64(1)...5).map { played($0, 3, daysAgo: 3) }))!
        XCTAssertTrue(mix.songIds.allSatisfy { $0 > 5 })
        XCTAssertGreaterThanOrEqual(mix.songIds.count, 8)
    }

    func testEveryLibraryMixIsOfferedOnlyWithEnoughSongs() {
        XCTAssertEqual([], LibraryMixes.build(profile(range(1...4) { track($0, artist: 1) })))
    }
}

final class RadioEngineTests: XCTestCase {
    /// 60 songs over 6 artists (10 each, two albums per artist); artists 1-3 Hip-Hop, 4-5 Ambient, 6 untagged.
    private let library: [TrackFacts] = (Int64(1)...60).map { id in
        let artist = (id - 1) / 10 + 1
        let genre: String? = artist <= 3 ? "Hip-Hop" : artist <= 5 ? "Ambient" : nil
        return track(id, artist: artist, album: artist * 100 + id % 2, genre: genre)
    }

    /// 120 songs by 20 artists (three per album).
    private let wide: [TrackFacts] = (Int64(1)...120).map { id in
        let artist = (id - 1) / 6 + 1
        return track(id, artist: artist, album: artist * 100 + id % 2, genre: artist <= 10 ? "Hip-Hop" : "Jazz")
    }

    private func profile(_ tracks: [TrackFacts]? = nil, plays: [MonthlyPlays] = [], hidden: Set<Int64> = []) -> ListeningProfile {
        SmartMixEngine.profile(tracks: tracks ?? library, plays: plays, now: now, hidden: hidden)
    }

    private func radio(_ seed: RadioSeed, _ profile: ListeningProfile? = nil, similarity: [Int64: Float]? = nil,
                       exclude: Set<Int64> = []) -> RadioPlan {
        RadioEngine.build(profile ?? self.profile(), seed: seed, similarity: similarity, exclude: exclude)!
    }

    private func artistOf(_ id: Int64) -> Int64 { (id - 1) / 10 + 1 }

    private func noRepeats(_ artists: [Int64]) -> Bool { zip(artists, artists.dropFirst()).allSatisfy { $0 != $1 } }

    func testASongRadioStartsWithTheSeedAndNeverRepeatsIt() {
        let plan = radio(.song(1))
        XCTAssertEqual(1, plan.startSongId)
        XCTAssertFalse(plan.songIds.contains(1))
        XCTAssertEqual(plan.songIds.count, Set(plan.songIds).count)
        XCTAssertEqual(RadioEngine.length, plan.songIds.count)
    }

    func testWithoutVybeSharedGenresLead() {
        let plan = radio(.song(1))
        XCTAssertTrue(plan.songIds.prefix(6).allSatisfy { (1...3).contains(artistOf($0)) })
        XCTAssertTrue(plan.basedOn.contains(.genre))
        XCTAssertFalse(plan.basedOn.contains(.sound))
    }

    func testVybeSimilarityOutranksGenreAlone() {
        var similarity: [Int64: Float] = [:]
        for t in library { similarity[t.songId] = artistOf(t.songId) == 4 ? 0.9 : 0.1 }
        let plan = radio(.song(1), similarity: similarity)
        XCTAssertEqual(4, plan.songIds.map(artistOf).first { $0 != 1 })
        XCTAssertTrue(plan.basedOn.contains(.sound))
    }

    func testPicksAreSpreadOverArtistsAndAlbums() {
        let plan = radio(.song(1), profile(wide))
        XCTAssertEqual(RadioEngine.length, plan.songIds.count)
        let artists = plan.songIds.map { ($0 - 1) / 6 + 1 }
        XCTAssertTrue(noRepeats(artists))
        XCTAssertTrue(Dictionary(grouping: artists, by: { $0 }).values.allSatisfy { $0.count <= 3 })
        let albums = plan.songIds.map { id in wide.first { $0.songId == id }!.albumId }
        XCTAssertTrue(Dictionary(grouping: albums, by: { $0 }).values.allSatisfy { $0.count <= 2 })
    }

    func testALibraryOfFewArtistsStillFillsTheRadio() {
        let plan = radio(.song(1))
        XCTAssertEqual(RadioEngine.length, plan.songIds.count)
        XCTAssertTrue(noRepeats(plan.songIds.map(artistOf)))
    }

    func testAnArtistRadioIsMostlyThatArtist() {
        let plan = radio(.artist(2), profile(plays: [played(17, 9, daysAgo: 3), played(12, 2, daysAgo: 3)]))
        XCTAssertEqual(17, plan.startSongId)
        let own = plan.songIds.filter { artistOf($0) == 2 }.count
        XCTAssertTrue((4...RadioEngine.length / 3).contains(own), "\(own)")
        XCTAssertTrue(plan.basedOn.contains(.sameArtist))
    }

    func testAnAlbumRadioReachesBeyondTheAlbum() {
        let plan = radio(.album(101))
        let albumSongs = Set(library.filter { $0.albumId == 101 }.map(\.songId))
        XCTAssertTrue(albumSongs.contains(plan.startSongId))
        XCTAssertLessThanOrEqual(plan.songIds.filter(albumSongs.contains).count, 2)
    }

    func testHiddenSongsAreNeverPicked() {
        let hidden = Set(Int64(2)...10)
        XCTAssertTrue(radio(.song(1), profile(hidden: hidden)).songIds.allSatisfy { !hidden.contains($0) })
    }

    func testRefreshingAvoidsEarlierPicks() {
        let first = radio(.song(1))
        let second = radio(.song(1), exclude: Set(first.songIds))
        XCTAssertTrue(second.songIds.allSatisfy { !first.songIds.contains($0) })
        XCTAssertFalse(second.songIds.isEmpty)
    }

    func testRefreshingASmallLibraryFallsBackToEarlierPicks() {
        let p = profile(Array(library.prefix(8)))
        let first = radio(.song(1), p)
        XCTAssertEqual(Set(first.songIds), Set(radio(.song(1), p, exclude: Set(first.songIds)).songIds))
    }

    func testATinyLibraryStillGivesARadio() {
        XCTAssertEqual([2, 3], radio(.song(1), profile(Array(library.prefix(3)))).songIds.sorted())
    }

    func testSongsWithoutMetadataStillPlayButNoSignalIsInvented() {
        let plan = radio(.song(1), profile((Int64(1)...6).map { track($0) }))
        XCTAssertEqual(5, plan.songIds.count)
        XCTAssertTrue(plan.basedOn.isEmpty)
    }

    func testOutOfRangeBpmIsNotTrustedAsTempo() {
        let tracks = [track(1, bpm: 140), track(2, bpm: 280), track(3, bpm: 138), track(4, bpm: 35)]
        let plan = radio(.song(1), profile(tracks))
        XCTAssertEqual(3, plan.songIds.first)
        XCTAssertEqual([.tempo], plan.basedOn)
        XCTAssertTrue(plan.songIds.contains(2) && plan.songIds.contains(4))
    }

    func testFamiliarSongsOutrankUnheardOnes() {
        let tracks = (Int64(1)...4).map { track($0, genre: "Jazz") }
        let plan = radio(.song(1), profile(tracks, plays: [played(3, 5, daysAgo: 10)]))
        XCTAssertEqual(3, plan.songIds.first)
        XCTAssertTrue(plan.basedOn.contains(.listening))
    }

    func testTheSameInputsGiveTheSameRadio() {
        XCTAssertEqual(radio(.song(5)), radio(.song(5)))
    }

    func testAnUnknownSeedGivesNoRadio() {
        XCTAssertNil(RadioEngine.build(profile(), seed: .song(999), similarity: nil))
        XCTAssertNil(RadioEngine.build(profile(), seed: .artist(999), similarity: nil))
    }
}
