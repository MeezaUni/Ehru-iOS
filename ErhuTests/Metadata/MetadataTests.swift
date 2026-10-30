@testable import Erhu
import XCTest

private func candidate(_ title: String, _ artist: String, _ album: String = "Album", id: String = "1", durationMs: Int64? = nil,
                       source: String = "") -> MetadataCandidate {
    MetadataCandidate(id: id, title: title, artist: artist, album: album, durationMs: durationMs, sourceName: source)
}

final class MetadataScoringTests: XCTestCase {
    private func score(_ c: MetadataCandidate, _ title: String, _ artist: String?, _ album: String? = nil, _ duration: Int64? = nil) -> Float {
        MetadataScorer.score(c, title: title, artist: artist, album: album, durationMs: duration).confidenceScore
    }

    func testExactMatchIsCertain() {
        XCTAssertEqual(score(candidate("Diwali", "Skrillex", "Soma"), "Diwali", "Skrillex", "Soma"), 1, accuracy: 0.0001)
    }

    func testTheAlbumSeparatesTheIntendedRecording() {
        let wrong = score(candidate("Diwali Riddim", "Lenky", "Invasion Of The Mysteron Killer Sounds Vol. 1"), "Diwali", nil, "Soma")
        let intended = score(candidate("Diwali", "Skrillex", "Soma"), "Diwali", nil, "Soma")
        XCTAssertLessThan(wrong, highConfidenceThreshold)
        XCTAssertGreaterThanOrEqual(intended, highConfidenceThreshold)
    }

    func testShortAndLongTitles() {
        XCTAssertGreaterThan(score(candidate("Diwali", "Skrillex"), "Diwali", "Skrillex"), score(candidate("Diwali Riddim", "Skrillex"), "Diwali", "Skrillex"))
    }

    func testMissingArtistOrAlbum() {
        XCTAssertEqual(score(candidate("Yellow", "Coldplay", "Parachutes"), "Yellow", nil, "Parachutes"), 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(score(candidate("Yellow", "Coldplay", "Album"), "Yellow", nil, "Parachutes"), highConfidenceThreshold)
        XCTAssertEqual(score(candidate("Yellow", "Coldplay", "Parachutes"), "Yellow", "Coldplay", nil), 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(score(candidate("Yellow", "Coldplay", "Unknown Album"), "Yellow", "Coldplay", "Parachutes"), uncertainThreshold)
        XCTAssertLessThan(score(candidate("Diwali Riddim", "Lenky"), "Diwali", nil, nil), highConfidenceThreshold)
    }

    func testCaseSpellingAndCredits() {
        XCTAssertGreaterThanOrEqual(score(candidate("  YELLOW ", "coldplay"), "yellow", "Coldplay "), highConfidenceThreshold)
        let tyler = candidate("IGOR\u{2019}S THEME", "Tyler, The Creator", "IGOR")
        XCTAssertEqual(score(tyler, "IGOR'S THEME", "Tyler/ The Creator", "Igor"), 1, accuracy: 0.001)
        XCTAssertEqual(score(candidate("Runaway", "Kanye West feat. Pusha T", ""), "Runaway", "Kanye West"), 1, accuracy: 0.001)
        XCTAssertLessThan(score(candidate("Thank You", "Dido", "No Angel"), "Thank You", "Tyler/ The Creator", "IGOR"), 0.85)
    }

    func testUnrelatedDurationAndEmpty() {
        XCTAssertLessThan(score(candidate("Bohemian Rhapsody", "Queen"), "Yellow", "Coldplay"), uncertainThreshold)
        var near = candidate("Yellow", "Coldplay")
        near.durationMs = 266_000
        var off = near
        off.durationMs = 400_000
        XCTAssertLessThan(score(off, "Yellow", "Coldplay", nil, 266_000), score(near, "Yellow", "Coldplay", nil, 266_000))
        XCTAssertLessThan(score(off, "Yellow", "Coldplay", nil, 266_000), highConfidenceThreshold)
        XCTAssertEqual(score(candidate("", ""), "Yellow", "Coldplay"), 0, accuracy: 0.0001)
    }

    func testADifferentVersionNeverPasses() {
        XCTAssertLessThan(score(candidate("Yellow (Live)", "Coldplay", "Parachutes"), "Yellow", "Coldplay", "Parachutes"), uncertainThreshold)
    }

    func testFoldingAndCredits() {
        XCTAssertEqual(foldForMatch("IGOR’S THEME"), "igors theme")
        XCTAssertEqual(foldForMatch("Beyoncé – Halo"), "beyonce halo")
        XCTAssertEqual(stripFeaturing("911 / Mr. Lonely (feat. Frank Ocean & Steve Lacy)"), "911 / Mr. Lonely")
        XCTAssertEqual(creditSimilarity("Tyler/ The Creator/Frank Ocean/ Steve Lacy", "Tyler, The Creator ft. Frank Ocean & Steve Lacy"), 1)
        XCTAssertEqual(artistSearchTerms("Tyler, The Creator ft. Frank Ocean & Steve Lacy"), "tyler the creator frank ocean steve lacy")
        XCTAssertEqual(MetadataScorer.jaroWinkler("martha", "marhta"), 0.9611, accuracy: 0.001)
    }
}

final class FilenameCleanerTests: XCTestCase {
    func testTrackNumberWatermarkAndArtist() {
        let cleaned = FilenameCleaner.clean("03 - Coldplay - Yellow [320kbps] pagalworld.mp3")
        XCTAssertEqual(cleaned.title, "Yellow")
        XCTAssertEqual(cleaned.artistGuess, "Coldplay")
        XCTAssertEqual(FilenameCleaner.clean("My_Song.flac"), CleanedFilename(title: "My Song"))
        XCTAssertEqual(FilenameCleaner.clean("Mr. Lonely (feat. Frank Ocean & Steve Lacy)").title, "Mr. Lonely (feat. Frank Ocean & Steve Lacy)")
    }

    func testTitleCandidates() {
        XCTAssertEqual(TitleCandidates.generate("THANK YOU.mp3"), ["THANK YOU"])
        let feat = TitleCandidates.generate("Runaway (feat. Pusha T).mp3")
        XCTAssertEqual(feat.first, "Runaway (feat. Pusha T)")
        XCTAssertTrue(feat.contains("Runaway"))
        XCTAssertLessThanOrEqual(TitleCandidates.generate("Song - Artist (Remix) (feat. X) [HD].mp3").count, 3)
    }
}

final class TrackMatcherTests: XCTestCase {
    private lazy var musicBrainz: [MetadataCandidate] = {
        let url = Bundle(for: TrackMatcherTests.self).url(forResource: "musicbrainz_gone_gone_thank_you_search", withExtension: "json")!
        let response = try! JSONDecoder().decode(MusicBrainzSearchResponse.self, from: Data(contentsOf: url))
        let today = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 13))!
        return MusicBrainzProvider.candidates(response, targetAlbum: "IGOR", today: today)
    }()

    /// A different, short song whose title is the file name.
    private let decoy = candidate("Thank You", "Dido", "No Angel", id: "dz_1", durationMs: 218_000, source: "Deezer")

    private let thankYouFile = TrackIdentity(title: "GONE, GONE / THANK YOU", artist: "Tyler/ The Creator", album: "IGOR",
                                             durationMs: 375_000, fileTitles: ["THANK YOU"])

    private struct Fixed: MetadataProvider {
        let found: [MetadataCandidate]
        let providerName = "MusicBrainz"
        func searchTrack(title: String, artist: String?, album: String?) async throws -> [MetadataCandidate] { found }
    }

    private func run(_ identity: TrackIdentity, found: [MetadataCandidate]? = nil, queries: inout [TrackQuery]) async -> MatchResult {
        let provider = Fixed(found: found ?? musicBrainz + [decoy])
        var sent: [TrackQuery] = []
        let result = await TrackMatcher.match(identity) { query in
            sent.append(query)
            let (candidates, outcome) = await MetadataService.searchOne(provider, selection: MetadataSources.all, availability: .available,
                                                                         title: query.title, artist: query.artist, album: identity.album,
                                                                         durationMs: identity.durationMs, retry: RetryPolicy())
            return SearchResponse(candidates: candidates.sorted { $0.confidenceScore > $1.confidenceScore }, outcomes: [outcome])
        }
        queries = sent
        return result
    }

    private func run(_ identity: TrackIdentity, found: [MetadataCandidate]? = nil) async -> MatchResult {
        var ignored: [TrackQuery] = []
        return await run(identity, found: found, queries: &ignored)
    }

    func testTheMusicBrainzFixtureMapsReleasesAndDates() {
        XCTAssertEqual(musicBrainz.count, 3)
        let album = musicBrainz.first { $0.durationMs == 375_000 }!
        XCTAssertEqual(album.album, "IGOR")
        XCTAssertEqual(album.versionNote, "explicit")
        XCTAssertEqual(album.releaseDate, "2019-08-23")
        XCTAssertEqual(album.coverArtUrl, "https://coverartarchive.org/release-group/0f1b9e07-b38b-4bba-9794-55e0924d7177/front-500")
        let live = musicBrainz.first { $0.durationMs == 279_000 }!
        XCTAssertNil(live.releaseDate)
        XCTAssertNotNil(live.releaseDateIssue)
        XCTAssertEqual(musicBrainz.last?.durationMs, 279_000) // a live-only recording ranks last
    }

    func testTheFileNameTitleIsOneSideOfTheAlbumTitle() {
        let scored = musicBrainz.map { MetadataScorer.score($0, title: "THANK YOU", artist: "Tyler/ The Creator", album: "IGOR", durationMs: 375_000) }
        XCTAssertGreaterThanOrEqual(scored.first { $0.durationMs == 375_000 }!.confidenceScore, highConfidenceThreshold)
        XCTAssertLessThan(scored.first { $0.durationMs == 272_000 }!.confidenceScore, highConfidenceThreshold)
    }

    func testTheAlbumVersionIsFoundFromTheEmbeddedTitle() async {
        var queries: [TrackQuery] = []
        let result = await run(thankYouFile, queries: &queries)
        guard case .confident(let match) = result.decision else { return XCTFail("\(result.decision)") }
        XCTAssertEqual(match.durationMs, 375_000)
        XCTAssertEqual(match.album, "IGOR")
        XCTAssertEqual(match.releaseDate, "2019-08-23")
        XCTAssertEqual(queries, [TrackQuery(title: "GONE, GONE / THANK YOU", artist: "Tyler/ The Creator", source: .tag)])
    }

    func testDurationSeparatesRecordingsAndTheDecoyIsNeverAccepted() async {
        let ranked = await run(thankYouFile).candidates
        let album = ranked.first { $0.durationMs == 375_000 }!
        let short = ranked.first { $0.durationMs == 272_000 }!
        XCTAssertGreaterThan(album.confidenceScore, short.confidenceScore)
        XCTAssertGreaterThan(short.confidenceScore, 0.5)
        XCTAssertLessThan(short.confidenceScore, highConfidenceThreshold)
        XCTAssertLessThan(ranked.first { $0.id == "dz_1" }!.confidenceScore, highConfidenceThreshold)
        var noTitle = thankYouFile
        noTitle.title = nil
        let decoyOnly = await run(noTitle, found: [decoy])
        if case .confident = decoyOnly.decision { XCTFail("the decoy was accepted") }
        let fromFileName = await run(noTitle, found: musicBrainz)
        guard case .confident(let match) = fromFileName.decision else { return XCTFail("\(fromFileName.decision)") }
        XCTAssertEqual(match.durationMs, 375_000)
    }

    func testARejectedMatchSaysWhy() async {
        var identity = thankYouFile
        identity.title = nil
        identity.durationMs = 200_000
        let result = await run(identity, found: musicBrainz)
        let reason: String
        switch result.decision {
        case .lowConfidence(_, let why): reason = why
        case .noMatch(let why): reason = why ?? ""
        default: return XCTFail("\(result.decision)")
        }
        XCTAssertTrue(reason.contains("GONE, GONE / THANK YOU") && reason.contains("vs file 3:20") && reason.contains("%"), reason)
    }

    func testEquallyGoodMatchesThatWouldWriteDifferentTagsAreAmbiguous() async {
        let a = candidate("Runaway", "Kanye West", "My Beautiful Dark Twisted Fantasy", id: "a", durationMs: 548_000, source: "MusicBrainz")
        var b = a
        b.id = "b"
        b.album = "Runaway (Single)"
        let identity = TrackIdentity(title: "Runaway", artist: "Kanye West", album: nil, durationMs: 548_000)
        let ambiguous = await run(identity, found: [a, b])
        guard case .ambiguous = ambiguous.decision else { return XCTFail("\(ambiguous.decision)") }
        var same = a
        same.id = "c"
        same.artist = "Kanye West feat. Pusha T"
        let confident = await run(identity, found: [a, same])
        guard case .confident = confident.decision else { return XCTFail("\(confident.decision)") }
    }

    func testQueriesComeFromTagsFirstThenTheFileNameWithoutDuplicates() {
        var identity = thankYouFile
        identity.fileTitles = ["THANK YOU", "gone gone thank you"]
        XCTAssertEqual(TrackMatcher.planQueries(identity), [
            TrackQuery(title: "GONE, GONE / THANK YOU", artist: "Tyler/ The Creator", source: .tag),
            TrackQuery(title: "GONE, GONE / THANK YOU", artist: nil, source: .tag, album: "IGOR"),
            TrackQuery(title: "THANK YOU", artist: "Tyler/ The Creator", source: .fileName),
            TrackQuery(title: "THANK YOU", artist: nil, source: .fileName, album: "IGOR"),
            TrackQuery(title: "GONE, GONE / THANK YOU", artist: nil, source: .tag),
        ])
    }

    func testUnusableIdentityText() {
        XCTAssertNil(usableIdentityText("Unknown Artist"))
        XCTAssertNil(usableIdentityText("runaway_spotidownloader.com"))
        XCTAssertNil(usableIdentityText("IGORâ€™S THEME"))
        XCTAssertEqual(usableIdentityText(" IGOR’S THEME "), "IGOR’S THEME")
    }

    func testMusicBrainzQueries() {
        XCTAssertEqual(MusicBrainzProvider.recordingQuery(title: "THANK YOU", artist: "Tyler/ The Creator", album: "IGOR"),
                       "recording:\"THANK YOU\" AND artist:(tyler the creator)")
        XCTAssertEqual(MusicBrainzProvider.recordingQuery(title: "Say \"Hi\"", artist: nil, album: "IGOR"),
                       "recording:\"Say \\\"Hi\\\"\" AND release:\"IGOR\"")
        XCTAssertEqual(DeezerProvider.query(title: "Earfquake", artist: "Tyler/ The Creator", album: "IGOR"), "album:\"IGOR\" track:\"Earfquake\"")
        XCTAssertEqual(DeezerProvider.query(title: "Earfquake", artist: "Tyler, The Creator", album: nil), "artist:\"Tyler, The Creator\" track:\"Earfquake\"")
    }
}

final class ProviderTests: XCTestCase {
    private struct FakeHTTP: HTTPClient {
        let status: Int
        let body: String
        var headers: [String: String] = [:]

        func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: self.headers)!)
        }
    }

    func testITunesMapping() async throws {
        let body = """
        {"results":[{"trackId":42,"trackName":"Yellow","artistName":"Coldplay","collectionName":"Parachutes","trackTimeMillis":266000,
        "artworkUrl100":"https://x/100x100bb.jpg","releaseDate":"2000-06-26T07:00:00Z"},{"trackName":""}]}
        """
        let found = try await ITunesProvider(client: FakeHTTP(status: 200, body: body)).searchTrack(title: "Yellow", artist: "Coldplay", album: nil)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].id, "itunes_42")
        XCTAssertEqual(found[0].releaseDate, "2000-06-26")
        XCTAssertEqual(found[0].coverArtUrl, "https://x/1000x1000bb.jpg")
    }

    func testDeezerWithheldResultsAreNotNoResults() async {
        let provider = DeezerProvider(client: FakeHTTP(status: 200, body: #"{"data":[],"total":12}"#))
        do {
            _ = try await provider.searchTrack(title: "Yellow", artist: "Coldplay", album: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(classifyProviderFailure(error).status, .unavailable)
        }
    }

    func testHttpFailuresKeepTheirCategory() async {
        let limited = FakeHTTP(status: 429, body: "", headers: ["Retry-After": "3"])
        let outcome = await MetadataService.searchOne(ITunesProvider(client: limited), selection: MetadataSources.all, availability: .available,
                                                      title: "Yellow", artist: nil, album: nil, durationMs: nil, retry: RetryPolicy(maxAttempts: 1))
        XCTAssertEqual(outcome.1.status, .rateLimited)
        let denied = await MetadataService.searchOne(ITunesProvider(client: FakeHTTP(status: 403, body: "")), selection: MetadataSources.all,
                                                     availability: .available, title: "Yellow", artist: nil, album: nil, durationMs: nil,
                                                     retry: RetryPolicy())
        XCTAssertEqual(denied.1.status, .authFailed)
        let skipped = await MetadataService.searchOne(ITunesProvider(client: limited), selection: MetadataSources.deezer, availability: .available,
                                                      title: "Yellow", artist: nil, album: nil, durationMs: nil, retry: RetryPolicy())
        XCTAssertEqual(skipped.1.status, .skipped)
        XCTAssertEqual(classifyProviderFailure(URLError(.notConnectedToInternet)).status, .networkError)
        XCTAssertEqual(classifyProviderFailure(URLError(.timedOut)).status, .timedOut)
    }

    func testRetryPolicy() {
        let policy = RetryPolicy()
        let transient = ProviderError(status: .networkError, message: "", retryable: true)
        XCTAssertEqual(policy.delayBeforeRetry(1, transient, random: 0), 1_000)
        XCTAssertEqual(policy.delayBeforeRetry(2, transient, random: 0), 2_000)
        XCTAssertNil(policy.delayBeforeRetry(3, transient, random: 0))
        XCTAssertNil(policy.delayBeforeRetry(1, ProviderError(status: .failed, message: "")))
        XCTAssertEqual(policy.delayBeforeRetry(1, ProviderError(status: .rateLimited, message: "", retryAfterMs: 5_000, retryable: true)), 5_000)
        XCTAssertNil(policy.delayBeforeRetry(1, ProviderError(status: .rateLimited, message: "", retryAfterMs: 60_000, retryable: true)))
        XCTAssertEqual(parseRetryAfterMs("120"), 120_000)
    }

    func testGenresFromMusicBrainzKeepTiesAndDropDownvoted() {
        let lookup = MetadataService.genre(fromMusicBrainz: [
            MusicBrainzGenre(name: "hip hop", count: 3), MusicBrainzGenre(name: "neo soul", count: 1),
            MusicBrainzGenre(name: "pop", count: 0), MusicBrainzGenre(name: "rap", count: 3),
        ])
        XCTAssertEqual(lookup, .found(["hip hop", "rap", "neo soul"], source: "MusicBrainz release group"))
        XCTAssertEqual(MetadataService.genre(fromMusicBrainz: []), .notFound("MusicBrainz has no genre for this album"))
    }

    func testFixTagsNetworkVerdicts() {
        let down = ProviderOutcome(providerName: "iTunes", status: .networkError, errorMessage: "offline")
        let answered = ProviderOutcome(providerName: "Deezer", status: .noResults)
        XCTAssertEqual(FixTagsStore.networkVerdict([down]), .unreachable("iTunes: offline"))
        XCTAssertEqual(FixTagsStore.networkVerdict([down, answered]), .partly("iTunes: offline"))
        XCTAssertNil(FixTagsStore.networkVerdict([answered]))
        XCTAssertNil(FixTagsStore.providerFailureSummary([answered]))
        XCTAssertNotNil(FixTagsStore.providerFailureSummary([ProviderOutcome(providerName: "iTunes", status: .failed)]))
    }
}

final class ReleaseDateTests: XCTestCase {
    private let today = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 13))!

    func testParse() {
        XCTAssertEqual(ReleaseDate.parse("2010-11-19", today: today)?.tagValue, "2010-11-19")
        XCTAssertEqual(ReleaseDate.parse("2010-11", today: today)?.tagValue, "2010-11")
        XCTAssertEqual(ReleaseDate.parse(" 2010 ", today: today)?.tagValue, "2010")
        XCTAssertNil(ReleaseDate.parse("2010-02-30", today: today))
        XCTAssertNil(ReleaseDate.parse("2010-13", today: today))
        XCTAssertNil(ReleaseDate.parse("1899", today: today))
        XCTAssertNil(ReleaseDate.parse("2030", today: today))
        XCTAssertNil(ReleaseDate.parse("2010/11/19", today: today))
    }

    func testEarliestKeepsThePrecision() {
        let dates = ["2010-11", "2010-11-19", "2011-01-02"].compactMap { ReleaseDate.parse($0, today: today) }
        XCTAssertEqual(ReleaseDate.earliest(dates)?.tagValue, "2010-11-19")
    }

    func testYearTags() {
        XCTAssertTrue(isUsableYearTag("2019-05"))
        XCTAssertFalse(isUsableYearTag("1970"))
        XCTAssertFalse(isUsableYearTag(""))
        XCTAssertFalse(isUsableYearTag(nil))
    }

    func testEqualMatchesDisagreeingOnTheYearGiveNone() {
        var a = candidate("Song", "A", id: "a")
        a.confidenceScore = 0.95
        a.releaseDate = "2010"
        var b = a
        b.id = "b"
        b.releaseDate = "2015"
        XCTAssertEqual(releaseDateFor(a, candidates: [a, b], today: today, confidentScore: 0.85),
                       .rejected("Equally good matches disagree on the year (2010, 2015)"))
        b.confidenceScore = 0.9
        XCTAssertEqual(releaseDateFor(a, candidates: [a, b], today: today, confidentScore: 0.85), .found(ReleaseDate.parse("2010", today: today)!))
    }
}

final class FieldFixPlanTests: XCTestCase {
    private let match: MetadataCandidate = {
        var m = candidate("GONE, GONE / THANK YOU", "Tyler, The Creator", "IGOR", id: "mb_1", source: "MusicBrainz")
        m.releaseDate = "2019-05-17"
        return m
    }()

    private func plan(_ selected: Set<MetadataField>, _ local: LocalTrackTags, genre: String? = "Hip Hop; Neo Soul",
                      bpm: FoundBpm? = nil) -> FieldFixPlan {
        let selection = FieldSelection(selected)
        return FieldFixPlanner.plan(fields: selection.fields, fillOnly: selection.fillOnly, local: local, match: match, genre: genre,
                                    artwork: nil, releaseDate: ReleaseDate.parse(match.releaseDate), bpm: bpm)
    }

    func testAllFieldsFillsOnlyWhatIsMissing() {
        let local = LocalTrackTags(title: "THANK YOU", artist: "Tyler/ The Creator", album: "Unknown Album", genre: "Rap", year: nil)
        let result = plan(MetadataField.fillOnlyTags, local)
        XCTAssertEqual(result.request?.title, "GONE, GONE / THANK YOU")
        XCTAssertNil(result.request?.artist) // a valid artist is kept
        XCTAssertEqual(result.request?.album, "IGOR") // a placeholder is replaced
        XCTAssertEqual(result.request?.releaseDate, "2019-05-17")
        XCTAssertNil(result.request?.genre) // kept
        XCTAssertTrue(result.notes.contains("Kept the existing genre \"Rap\""))
    }

    func testSingleFieldsReplace() {
        let local = LocalTrackTags(title: "THANK YOU", artist: "Someone", album: "Other", genre: "Rap", year: "2018")
        let result = plan([.album, .genre, .year], local)
        XCTAssertNil(result.request?.title)
        XCTAssertEqual(result.request?.album, "IGOR")
        XCTAssertEqual(result.request?.genre, "Hip Hop; Neo Soul")
        XCTAssertEqual(result.request?.releaseDate, "2019-05-17")
    }

    func testCreditsAndSpellingAreKept() {
        let local = LocalTrackTags(title: "gone, gone / thank you", artist: "Tyler, The Creator feat. Kanye West", album: "IGOR")
        let result = plan(MetadataField.fillOnlyTags, local)
        XCTAssertNil(result.request?.title) // same title apart from case
        XCTAssertNil(result.request?.artist) // the credit already names the artist
        XCTAssertEqual(FieldFixPlanner.withLocalFeaturing("Mr. Lonely", local: "Mr. Lonely (feat. Frank Ocean)"), "Mr. Lonely (feat. Frank Ocean)")
    }

    func testAnEstimatedBpmNeverReplacesOne() {
        let estimate = FoundBpm(bpm: 160, source: "on-device estimate", estimated: true)
        let tagged = LocalTrackTags(title: "GONE, GONE / THANK YOU", artist: "Tyler, The Creator", album: "IGOR", bpm: "80")
        XCTAssertNil(plan([.bpm], tagged, bpm: estimate).request)
        let untagged = LocalTrackTags(title: "GONE, GONE / THANK YOU", artist: "Tyler, The Creator", album: "IGOR")
        XCTAssertEqual(plan([.bpm], untagged, bpm: estimate).request?.bpm, 160)
        XCTAssertNil(plan([.bpm], untagged, bpm: FoundBpm(bpm: 999, source: "x", estimated: true)).request)
    }

    func testNothingToWriteIsNil() {
        let local = LocalTrackTags(title: "GONE, GONE / THANK YOU", artist: "Tyler, The Creator", album: "IGOR", genre: "Hip Hop; Neo Soul", year: "2019-05-17")
        XCTAssertNil(plan(MetadataField.fillOnlyTags, local).request)
    }
}

final class TempoTests: XCTestCase {
    private let rate = 11_025

    /// A drum pattern at [bpm]: a kick on every beat, a snare on 2 and 4, hi-hats on every half beat, over quiet noise.
    private func drums(_ bpm: Double, seconds: Int, into: inout [Float], from: Int = 0, seed: UInt64 = 1) {
        var random = SeededGenerator(state: seed)
        func noise() -> Float { Float.random(in: -1...1, using: &random) }
        for i in from..<min(into.count, from + seconds * rate) { into[i] += noise() * 0.01 }
        let beat = 60.0 / bpm
        var t = 0.0
        var n = 0
        func hit(_ at: Int, _ length: Double, _ gain: Float, _ wave: (Double) -> Float) {
            for i in 0..<Int(length * Double(rate)) {
                let index = at + i
                guard index < into.count else { return }
                let s = Double(i) / Double(rate)
                into[index] += gain * wave(s) * Float(exp(-s / (length / 4)))
            }
        }
        while t < Double(seconds) {
            let at = from + Int(t * Double(rate))
            hit(at, 0.15, 0.9) { Float(sin(2 * .pi * 55 * $0)) }
            hit(at, 0.012, 0.4) { _ in noise() }
            if n % 2 == 1 { hit(at, 0.08, 0.5) { _ in noise() } }
            hit(at + Int(beat / 2 * Double(rate)), 0.03, 0.2) { _ in noise() }
            t += beat
            n += 1
        }
    }

    private func drums(_ bpm: Double, seconds: Int) -> [Float] {
        var audio = [Float](repeating: 0, count: seconds * rate)
        drums(bpm, seconds: seconds, into: &audio)
        return audio
    }

    func testSteadyBeatsGiveTheirTempo() {
        for bpm in [90.0, 120.0, 128.0] {
            guard case .found(let found, _, let sections) = TempoEstimator.estimate(drums(bpm, seconds: 60), sampleRate: rate) else {
                return XCTFail("no tempo for \(bpm)")
            }
            XCTAssertEqual(Double(found), bpm, accuracy: 1, "for \(bpm)")
            XCTAssertEqual(sections, 3)
        }
    }

    func testHatsOnHalfBeatsDoNotDoubleTheTempo() {
        guard case .found(let found, _, _) = TempoEstimator.estimate(drums(100, seconds: 60), sampleRate: rate) else { return XCTFail() }
        XCTAssertEqual(found, 100)
    }

    func testNoiseSilenceAndTooLittleAudioHaveNoTempo() {
        var random = SeededGenerator(state: 7)
        let noise = (0..<(60 * rate)).map { _ in Float.random(in: -0.25...0.25, using: &random) }
        guard case .uncertain = TempoEstimator.estimate(noise, sampleRate: rate) else { return XCTFail() }
        guard case .uncertain = TempoEstimator.estimate([Float](repeating: 0, count: 60 * rate), sampleRate: rate) else { return XCTFail() }
        guard case .uncertain = TempoEstimator.estimate(drums(120, seconds: 5), sampleRate: rate) else { return XCTFail() }
    }

    func testOneChangedSectionIsOutvotedAndAChangingTempoIsNotReported() {
        var outvoted = [Float](repeating: 0, count: 60 * rate)
        drums(120, seconds: 40, into: &outvoted)
        drums(84, seconds: 20, into: &outvoted, from: 40 * rate)
        guard case .found(let bpm, let agreeing, _) = TempoEstimator.estimate(outvoted, sampleRate: rate) else { return XCTFail() }
        XCTAssertEqual(bpm, 120)
        XCTAssertEqual(agreeing, 2)
        var changing = [Float](repeating: 0, count: 60 * rate)
        drums(84, seconds: 20, into: &changing)
        drums(132, seconds: 20, into: &changing, from: 20 * rate)
        drums(109, seconds: 20, into: &changing, from: 40 * rate)
        guard case .uncertain = TempoEstimator.estimate(changing, sampleRate: rate) else { return XCTFail() }
    }

    func testFftMatchesTheDefinition() {
        let size = 16
        var real = (0..<size).map { Float(sin(Double($0) * 0.7) + 0.3) }
        var imaginary = [Float](repeating: 0, count: size)
        let input = real
        RadixTwoFFT(size: size).transform(&real, &imaginary)
        for k in 0..<size {
            var re = 0.0
            var im = 0.0
            for n in 0..<size {
                let angle = -2 * Double.pi * Double(k * n) / Double(size)
                re += Double(input[n]) * cos(angle)
                im += Double(input[n]) * sin(angle)
            }
            XCTAssertEqual(Double(real[k]), re, accuracy: 0.001)
            XCTAssertEqual(Double(imaginary[k]), im, accuracy: 0.001)
        }
    }

    func testAcousticBrainzParsing() {
        let agree: [String: Any] = ["r1": ["0": ["rhythm": ["bpm": 127.8]], "1": ["rhythm": ["bpm": 128.4]], "2": ["rhythm": ["bpm": 128.1]]]]
        XCTAssertEqual(try? BpmFinder.bpm(fromAcousticBrainz: agree, recordingId: "r1").get(), 128)
        let octave: [String: Any] = ["r1": ["0": ["rhythm": ["bpm": 78.0]], "1": ["rhythm": ["bpm": 155.7]]]]
        guard case .failure(let error) = BpmFinder.bpm(fromAcousticBrainz: octave, recordingId: "r1") else { return XCTFail() }
        XCTAssertTrue(error.message.contains("disagree"))
        guard case .failure = BpmFinder.bpm(fromAcousticBrainz: [:], recordingId: "r1") else { return XCTFail() }
    }
}
