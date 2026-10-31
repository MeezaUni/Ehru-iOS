import XCTest
@testable import Erhu

final class LyricsParserTests: XCTestCase {
    private func synced(_ text: String) -> [LyricLine] {
        guard case .synced(let lines) = LyricsParser.parse(text) else {
            XCTFail("not synced")
            return []
        }
        return lines
    }

    func testLineTimedLrcBecomesSyncedLinesInTimeOrder() {
        let lyrics = LyricsParser.parse("[ar:Someone]\n[ti:Song]\n[00:12.50]Second line\n[00:05.00]First line\n[01:02.3]Third")!
        guard case .synced(let lines) = lyrics else { return XCTFail("not synced") }
        XCTAssertEqual([5_000, 12_500, 62_300], lines.map(\.timeMs))
        XCTAssertEqual(["First line", "Second line", "Third"], lines.map(\.text))
        XCTAssertFalse(lyrics.hasWordTiming)
    }

    func testSeveralStampsOnOneLineRepeatIt() {
        XCTAssertEqual(["Chorus", "Verse", "Chorus"], synced("[00:10.00][00:40.00]Chorus\n[00:20.00]Verse").map(\.text))
    }

    func testOffsetShiftsEveryTimestamp() {
        XCTAssertEqual([9_500], synced("[offset:+500]\n[00:10.00]A").map(\.timeMs))
    }

    func testEnhancedLrcGivesWordTiming() {
        let lyrics = LyricsParser.parse("[00:10.00]<00:10.00>I <00:10.40>love <00:11.00>this")!
        XCTAssertTrue(lyrics.hasWordTiming)
        guard case .synced(let lines) = lyrics, let line = lines.first else { return XCTFail("not synced") }
        XCTAssertEqual("I love this", line.text)
        XCTAssertEqual([10_000, 10_400, 11_000], line.words?.map(\.timeMs))
        XCTAssertEqual(["I ", "love ", "this"], line.words?.map(\.text))
    }

    func testActiveLineAndWordComeFromABinarySearch() {
        let lyrics = LyricsParser.parse("[00:01.00]A\n[00:05.00]<00:05.00>b <00:06.00>c\n[00:09.00]D")!
        XCTAssertEqual(-1, lyrics.lineAt(500))
        XCTAssertEqual(0, lyrics.lineAt(1_000))
        XCTAssertEqual(1, lyrics.lineAt(5_500))
        XCTAssertEqual(2, lyrics.lineAt(60_000))
        XCTAssertEqual(0, lyrics.wordAt(line: 1, 5_500))
        XCTAssertEqual(1, lyrics.wordAt(line: 1, 6_000))
        XCTAssertEqual(-1, lyrics.wordAt(line: 0, 6_000))
    }

    func testTextWithoutTimestampsIsPlain() {
        XCTAssertEqual(.plain(["Just words", "No timing"]), LyricsParser.parse("Just words\nNo timing\n"))
    }

    func testMalformedStampsAreIgnored() {
        XCTAssertEqual(["Good"], synced("[00:99.00]Bad seconds\n[xx:10]Bad\n[00:03.00]Good").map(\.text))
        XCTAssertEqual(.plain(["[ab:cd]x", "plain"]), LyricsParser.parse("[ab:cd]x\nplain"))
    }

    func testBlankLyricsAreNone() {
        XCTAssertNil(LyricsParser.parse(nil))
        XCTAssertNil(LyricsParser.parse("  \n "))
        XCTAssertNil(LyricsParser.parse("[ar:Only tags]\n[ti:Nothing else]"))
    }
}

private let wordSyncedLyricsfile = """
version: '1.0'
metadata:
  title: Test Song
  artist: Someone
  duration_ms: 200000
  instrumental: false
lines:
- text: Hello world
  start_ms: 12000
  end_ms: 14000
  words:
  - text: 'Hello '
    start_ms: 12000
  - text: world
    start_ms: 12650
- text: Second line
  start_ms: 15000
plain: |-
  Hello world
  Second line
"""

private func lrclibRecord(id: Int64 = 1, title: String = "Test Song", artist: String = "Someone", album: String? = "Album",
                    duration: Double = 200, synced: String? = "[00:12.00]Hello world\n[00:15.00]Second line", wordSync: Bool = false,
                    lyricsfile: String? = nil, instrumental: Bool = false) -> LrclibRecord {
    LrclibRecord(id: id, trackName: title, artistName: artist, albumName: album, duration: duration, instrumental: instrumental,
                 plainLyrics: "Hello world\nSecond line", syncedLyrics: synced, hasWordSync: wordSync, lyricsfile: lyricsfile)
}

private let query = LyricsQuery(title: "Test Song", artist: "Someone", album: "Album", durationMs: 200_000)

private func candidate(_ title: String = "Test Song", _ artist: String = "Someone", album: String? = "Album", duration: Double? = 200,
                       id: Int64 = 1, synced: String? = "[00:01.00]x", word: String? = nil) -> LyricsCandidate {
    LyricsCandidate(provider: "LRCLIB", providerId: id, trackName: title, artistName: artist, albumName: album, durationSec: duration,
                    plainLyrics: "x", syncedLyrics: synced, wordSyncedLrc: word)
}

final class LyricsfileTests: XCTestCase {
    func testApiResponseFieldsAreParsedIncludingWordSync() throws {
        let file = String(data: try JSONEncoder().encode(wordSyncedLyricsfile), encoding: .utf8)!
        let body = """
        {"id":390,"trackName":"Test Song","artistName":"Someone","albumName":"Album","duration":200.0,"instrumental":false,
         "hasWordSync":true,"plainLyrics":"Hello world","syncedLyrics":"[00:12.00]Hello world","lyricsfile":\(file),"name":"Test Song"}
        """
        let parsed = try JSONDecoder().decode(LrclibRecord.self, from: Data(body.utf8))
        XCTAssertTrue(parsed.hasWordSync)
        let candidate = try XCTUnwrap(parsed.toCandidate())
        XCTAssertEqual(.word, candidate.timing)
        XCTAssertEqual("[00:12.000]<00:12.000>Hello <00:12.650>world\n[00:15.000]Second line", candidate.wordSyncedLrc)
    }

    func testSyncedLyricsAloneAreLineTimingNeverWordTiming() {
        let line = lrclibRecord().toCandidate()!
        XCTAssertEqual(.line, line.timing)
        XCTAssertNil(line.wordSyncedLrc)
        XCTAssertNil(lrclibRecord(wordSync: false, lyricsfile: wordSyncedLyricsfile).toCandidate()!.wordSyncedLrc)
        XCTAssertEqual(.plain, lrclibRecord(synced: nil).toCandidate()!.timing)
    }

    func testLinesWithIncompleteWordTimingKeepLineTimingOnly() {
        let partial = """
        lines:
        - text: a b
          start_ms: 1000
          words:
          - text: 'a '
            start_ms: 1000
          - text: b
        - text: c d
          start_ms: 3000
          words:
          - text: 'c '
            start_ms: 3000
          - text: d
            start_ms: 3400
        """
        XCTAssertEqual("[00:01.000]a b\n[00:03.000]<00:03.000>c <00:03.400>d", Lyricsfile.toEnhancedLrc(partial))
        XCTAssertNil(Lyricsfile.toEnhancedLrc("lines:\n- text: only lines\n  start_ms: 5"))
        XCTAssertNil(Lyricsfile.toEnhancedLrc("not: [valid"))
        XCTAssertNil(Lyricsfile.toEnhancedLrc(nil))
        XCTAssertTrue(Lyricsfile.isInstrumental("metadata:\n  instrumental: true\nlines: []"))
    }

    func testBlockScalarsAndQuotes() throws {
        let doc = try MiniYAML.parse("a: |\n  one\n  two\nb: \"x\\ny\"\nc: 'it''s'\nd: 1.5\ne: ~\n") as? [String: Any]
        XCTAssertEqual("one\ntwo\n", doc?["a"] as? String)
        XCTAssertEqual("x\ny", doc?["b"] as? String)
        XCTAssertEqual("it's", doc?["c"] as? String)
        XCTAssertEqual(1.5, doc?["d"] as? Double)
        XCTAssertTrue(doc?["e"] is NSNull)
    }
}

final class LyricsMatcherTests: XCTestCase {
    func testAnExactMatchIsConfidentAndHarmlessDifferencesAreIgnored() {
        XCTAssertTrue(LyricsMatcher.score(query, candidate()).confident)
        XCTAssertTrue(LyricsMatcher.score(query, candidate("Test Song (feat. Guest)", "Someone & Guest")).confident)
        XCTAssertTrue(LyricsMatcher.score(query, candidate("TEST SONG - 2011 Remaster", duration: 201.5)).confident)
        XCTAssertTrue(LyricsMatcher.score(LyricsQuery(title: "Café", artist: "Beyoncé", durationMs: 180_000),
                                          candidate("Cafe", "Beyonce", album: nil, duration: 181)).confident)
        XCTAssertTrue(LyricsMatcher.score(LyricsQuery(title: "Help!", artist: "The Beatles", durationMs: 140_000),
                                          candidate("Help!", "Beatles", album: nil, duration: 139)).confident)
        XCTAssertFalse(LyricsMatcher.score(query, candidate("Test Song", "Someone Else")).confident)
    }

    func testOtherVersionsAndOtherLengthsAreRejected() {
        XCTAssertTrue(LyricsMatcher.score(query, candidate("Test Song (Live)")).rejected)
        XCTAssertTrue(LyricsMatcher.score(query, candidate(album: "Live at Wembley")).rejected)
        XCTAssertTrue(LyricsMatcher.score(query, candidate("Test Song - Remix")).rejected)
        XCTAssertTrue(LyricsMatcher.score(query, candidate("Test Song (Acoustic)")).rejected)
        XCTAssertTrue(LyricsMatcher.score(query, candidate(duration: 230)).rejected)
        let live = LyricsQuery(title: "Test Song (Live)", artist: "Someone", durationMs: 210_000)
        XCTAssertTrue(LyricsMatcher.score(live, candidate("Test Song - Live", album: nil, duration: 210)).confident)
        XCTAssertFalse(LyricsMatcher.score(query, candidate("Test Song (Clean)")).rejected)
    }

    func testWeakMatchesAreNotConfidentButCanBeOffered() {
        XCTAssertFalse(LyricsMatcher.score(query, candidate("Test Song Two", "Someone Else")).confident)
        let noDuration = LyricsQuery(title: "Test Song", artist: "Someone", durationMs: 0)
        XCTAssertTrue(LyricsMatcher.score(noDuration, candidate(duration: nil)).confident)
        XCTAssertFalse(LyricsMatcher.score(noDuration, candidate("Test Songs", duration: nil)).confident)
        XCTAssertFalse(LyricsMatcher.plausible(query, [candidate("Test Song", "Someone Else")]).isEmpty)
        XCTAssertTrue(LyricsMatcher.plausible(query, [candidate("Test Song (Live)")]).isEmpty)
    }

    func testRankingPrefersWordTimingThenLineTimingThenPlain() {
        let plain = candidate(id: 1, synced: nil)
        let line = candidate(id: 2)
        let word = candidate(id: 3, word: "[00:01.000]<00:01.000>x")
        XCTAssertEqual(3, LyricsMatcher.best(query, [plain, line, word])?.providerId)
        XCTAssertEqual(2, LyricsMatcher.best(query, [plain, line])?.providerId)
        XCTAssertNil(LyricsMatcher.best(query, [candidate("Other")]))
    }
}

/// A scripted HTTP server.
private final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var calls = 0
    var respond: (URL) throws -> (Int, [String: String], Data) = { _ in (404, [:], Data()) }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        let (status, fields, body) = try respond(url)
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!)
    }
}

private final class Clock: @unchecked Sendable {
    var now: Int64 = 1_000_000
}

final class LrclibProviderTests: XCTestCase {
    private let http = FakeHTTP()
    private let clock = Clock()
    private lazy var provider = LrclibProvider(http: http, now: { [clock] in clock.now }, minGapMs: 0, retryDelayMs: 0)

    private func json(_ record: LrclibRecord) -> Data {
        let dict: [String: Any] = ["id": record.id!, "trackName": record.trackName!, "artistName": record.artistName!,
                                   "albumName": record.albumName!, "duration": record.duration!, "instrumental": false,
                                   "plainLyrics": record.plainLyrics!, "syncedLyrics": record.syncedLyrics!]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    func test404IsNotFoundAndSuccessIsACandidate() async {
        http.respond = { _ in (404, [:], Data()) }
        if case .notFound = await provider.exact(query) {} else { XCTFail("expected not found") }
        let body = json(lrclibRecord())
        http.respond = { _ in (200, [:], body) }
        guard case .success(let found) = await provider.exact(query) else { return XCTFail("expected success") }
        XCTAssertEqual(1, found.providerId)
    }

    func test429BlocksEveryRequestUntilRetryAfterHasPassed() async {
        http.respond = { _ in (429, ["Retry-After": "30"], Data()) }
        guard case .rateLimited(let at) = await provider.exact(query) else { return XCTFail("expected rate limit") }
        XCTAssertEqual(clock.now + 30_000, at)
        let before = http.calls
        if case .rateLimited = await provider.search(query, freeText: nil) {} else { XCTFail("expected rate limit") }
        XCTAssertEqual(before, http.calls)
        clock.now += 31_000
        let body = json(lrclibRecord())
        http.respond = { _ in (200, [:], body) }
        if case .success = await provider.exact(query) {} else { XCTFail("expected success") }
        XCTAssertEqual(60_000, provider.retryAfterMs(nil))
        XCTAssertEqual(5_000, provider.retryAfterMs("5"))
    }

    func testNoConnectionIsOfflineOtherFailuresAreFailures() async {
        http.respond = { _ in throw URLError(.notConnectedToInternet) }
        if case .offline = await provider.exact(query) {} else { XCTFail("expected offline") }
        http.respond = { _ in (500, [:], Data()) }
        if case .failed = await provider.exact(query) {} else { XCTFail("expected failure") }
    }

    func testHealthyExactArtistAliasStillSuppliesSyncWhenTheSearchEndpointIsDown() async throws {
        let q = LyricsQuery(title: "Black Skinhead", artist: "Ye", album: "Yeezus", durationMs: 188_000)
        let object: [String: Any] = ["id": 51, "trackName": "Black Skinhead", "artistName": "Kanye West",
                                   "albumName": "Yeezus", "duration": 188, "syncedLyrics": "[00:01.000]Test words"]
        let record = try JSONSerialization.data(withJSONObject: object)
        var exactArtists: [String] = []
        http.respond = { url in
            if url.path == "/api/search" { return (502, [:], Data()) }
            let artist = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "artist_name" }?.value ?? ""
            exactArtists.append(artist)
            return artist == "Ye" ? (404, [:], Data()) : (200, [:], record)
        }
        let repository = OnlineLyricsRepository(providers: [provider], cache: MemoryCache())
        guard case .found(let found, _, _, _) = await repository.lookup(LyricsTrack(songId: 8, query: q)) else { return XCTFail("A search outage must not discard real synchronization from exact lookup") }
        XCTAssertEqual(exactArtists, ["Ye", "Kanye West"])
        XCTAssertEqual(found.timing, .line)
    }

    func testKnownArtistAliasIsQueriedOnlyAfterHealthyEmptyAutomaticSearch() async throws {
        let q = LyricsQuery(title: "Black Skinhead", artist: "Ye", album: "Yeezus", durationMs: 188_000)
        let object: [String: Any] = ["id": 50, "trackName": "Black Skinhead", "artistName": "Kanye West",
                                   "albumName": "Yeezus", "duration": 188, "syncedLyrics": "[00:01.000]Test words"]
        let results = try JSONSerialization.data(withJSONObject: [object])
        var artists: [String] = []
        http.respond = { url in
            let artist = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "artist_name" }?.value ?? ""
            artists.append(artist)
            return (200, [:], artist == "Ye" ? Data("[]".utf8) : results)
        }
        guard case .success(let found) = await provider.search(q, freeText: nil) else { return XCTFail("Expected alias lookup") }
        XCTAssertEqual(artists, ["Ye", "Kanye West"])
        XCTAssertEqual(found.first?.timing, .line)
        XCTAssertNotNil(LyricsMatcher.best(q, found, minimumTiming: .line))
        XCTAssertEqual(q.artist, "Ye", "Lookup aliases never retag the file")
    }

    func testGatewayRetryRecoversButPersistentFailuresAreBounded() async {
        let body = json(lrclibRecord())
        http.respond = { [http] _ in http.calls == 1 ? (502, [:], Data()) : (200, [:], body) }
        guard case .success = await provider.exact(query) else { return XCTFail("Transient gateway should recover") }
        XCTAssertEqual(http.calls, 2)
        http.respond = { _ in (502, [:], Data()) }
        guard case .failed(let reason) = await provider.search(query, freeText: "song") else { return XCTFail("Persistent gateway should surface") }
        XCTAssertEqual(reason, "HTTP 502")
        XCTAssertEqual(http.calls, 4, "Only one retry per request, not an outage loop")
    }

    func testGatewayWithExplicitRetryAfterIsNotImmediatelyRepeated() async {
        http.respond = { _ in (503, ["Retry-After": "60"], Data()) }
        guard case .rateLimited(let at) = await provider.exact(query) else { return XCTFail("Expected service backoff") }
        XCTAssertEqual(at, clock.now + 60_000)
        _ = await provider.search(query, freeText: nil)
        XCTAssertEqual(http.calls, 1)
    }

    func testOnlyTrackMetadataIsSent() async {
        var sent: URL?
        http.respond = { url in
            sent = url
            return (404, [:], Data())
        }
        _ = await provider.exact(query)
        let items = URLComponents(url: sent!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Set(["track_name", "artist_name", "album_name", "duration"]), Set(items.map(\.name)))
        XCTAssertEqual("200", items.first { $0.name == "duration" }?.value)
    }
}

/// An in-memory cache and a scripted provider, for the repository.
private actor MemoryCache: OnlineLyricsCache {
    var entries: [Int64: CachedLyrics] = [:]
    func get(_ songId: Int64) -> CachedLyrics? { entries[songId] }
    func put(_ entry: CachedLyrics) { entries[entry.songId] = entry }
    func remove(_ songId: Int64) { entries[songId] = nil }
    func clear() { entries = [:] }
}

private actor FakeProvider: OnlineLyricsProvider {
    nonisolated let name: String
    nonisolated let supportsSyncedLyrics: Bool
    init(name: String = "Fake", supportsSyncedLyrics: Bool = true) {
        self.name = name
        self.supportsSyncedLyrics = supportsSyncedLyrics
    }
    var exactCalls = 0
    var searchCalls = 0
    var exactResult: ProviderResponse<LyricsCandidate> = .notFound
    var searchResult: ProviderResponse<[LyricsCandidate]> = .success([])

    func set(exact: ProviderResponse<LyricsCandidate>? = nil, search: ProviderResponse<[LyricsCandidate]>? = nil) {
        if let exact { exactResult = exact }
        if let search { searchResult = search }
    }

    func exact(_ query: LyricsQuery) async -> ProviderResponse<LyricsCandidate> {
        exactCalls += 1
        return exactResult
    }

    func search(_ query: LyricsQuery, freeText: String?) async -> ProviderResponse<[LyricsCandidate]> {
        searchCalls += 1
        return searchResult
    }
}

final class OnlineLyricsRepositoryTests: XCTestCase {
    private let fake = FakeProvider()
    private let cache = MemoryCache()
    private let clock = Clock()
    private lazy var repository = OnlineLyricsRepository(providers: [fake], cache: cache, now: { [clock] in clock.now })
    private let track = LyricsTrack(songId: 7, query: query)

    func testAConfidentResultIsCachedAndTheNextLookupIsACacheHit() async {
        await fake.set(exact: .success(candidate(word: "[00:01.000]<00:01.000>x")))
        guard case .found(_, let fromCache, _, _) = await repository.lookup(track) else { return XCTFail("not found") }
        XCTAssertFalse(fromCache)
        let searches = await fake.searchCalls
        XCTAssertEqual(0, searches)
        guard case .found(_, let second, _, _) = await repository.lookup(track) else { return XCTFail("not found") }
        XCTAssertTrue(second)
        var exacts = await fake.exactCalls
        XCTAssertEqual(1, exacts)
        var renamed = track
        renamed.query.title = "Renamed"
        let stale = await repository.cached(renamed)
        XCTAssertNil(stale)
        _ = await repository.lookup(track, refresh: true)
        exacts = await fake.exactCalls
        XCTAssertEqual(2, exacts)
    }

    func testLineTimedExactResultStillSearchesForWordTimingAndPrefersIt() async {
        await fake.set(exact: .success(candidate(id: 1)), search: .success([candidate(id: 2, word: "[00:01.000]<00:01.000>x")]))
        guard case .found(let found, _, _, _) = await repository.lookup(track) else { return XCTFail("not found") }
        XCTAssertEqual(2, found.providerId)
    }

    func testUncertainResultsStayInManualSearchWithoutAnAutomaticChoosePrompt() async {
        await fake.set(search: .success([candidate("Test Song", "Someone Else", id: 5)]))
        guard case .notFound = await repository.lookup(track) else { return XCTFail("An unverified artist must not force a chooser or select another recording") }
        var entries = await cache.entries
        XCTAssertTrue(entries.isEmpty)
        guard case .success(let options) = await repository.search(track, freeText: "Test Song") else { return XCTFail("Manual alternatives must remain available") }
        XCTAssertEqual(options.candidates.count, 1)
        _ = await repository.choose(track, options.candidates[0])
        entries = await cache.entries
        XCTAssertEqual(true, entries[7]?.userChosen)
    }

    func testNotFoundIsRememberedForAWhileFailuresAndOfflineAreNot() async {
        let first = await repository.lookup(track)
        XCTAssertEqual(.notFound, first)
        _ = await repository.lookup(track)
        var exacts = await fake.exactCalls
        XCTAssertEqual(1, exacts)
        clock.now += OnlineLyricsRepository.notFoundTtlMs + 1
        _ = await repository.lookup(track)
        exacts = await fake.exactCalls
        XCTAssertEqual(2, exacts)

        await cache.clear()
        await fake.set(exact: .offline)
        let offline = await repository.lookup(track)
        XCTAssertEqual(.offline, offline)
        var entries = await cache.entries
        XCTAssertTrue(entries.isEmpty)
        await fake.set(exact: .rateLimited(retryAtMs: clock.now + 5_000))
        if case .rateLimited = await repository.lookup(track) {} else { XCTFail("expected rate limit") }
        entries = await cache.entries
        XCTAssertTrue(entries.isEmpty)
    }

    func testInstrumentalIsReportedAndCached() async {
        var instrumental = candidate()
        instrumental.instrumental = true
        instrumental.plainLyrics = nil
        instrumental.syncedLyrics = nil
        await fake.set(exact: .success(instrumental))
        let first = await repository.lookup(track)
        let second = await repository.lookup(track)
        XCTAssertEqual(.instrumental, first)
        XCTAssertEqual(.instrumental, second)
        let exacts = await fake.exactCalls
        XCTAssertEqual(1, exacts)
    }
}

final class LyricsFallbackTests: XCTestCase {
    func testOutageHoldsAutomaticPlainTextButManualSearchShowsOptionsWithAnOutageNotice() async {
        let primary = FakeProvider(name: "LRCLIB")
        let backup = FakeProvider(name: "lyrics.ovh", supportsSyncedLyrics: false)
        let cache = MemoryCache()
        await primary.set(exact: .failed("HTTP 502"), search: .failed("HTTP 502"))
        var plain = candidate(synced: nil)
        plain.provider = "lyrics.ovh"
        await backup.set(search: .success([plain]))
        let repository = OnlineLyricsRepository(providers: [primary, backup], cache: cache)
        let track = LyricsTrack(songId: 9, query: query)
        guard case .failed = await repository.lookup(track) else { return XCTFail("An outage cannot prove synchronization is missing") }
        let autoPlainCalls = await backup.searchCalls
        XCTAssertEqual(autoPlainCalls, 0)
        let cached = await cache.get(track.songId)
        XCTAssertNil(cached)
        let exacts = await primary.exactCalls
        guard case .success(let manual) = await repository.search(track, freeText: "edited query") else { return XCTFail("Manual alternatives must remain available") }
        XCTAssertEqual(manual.candidates, [plain])
        XCTAssertTrue(manual.syncedServiceNotice?.contains("LRCLIB") == true)
        let unchanged = await primary.exactCalls
        XCTAssertEqual(exacts, unchanged)
    }

    func testUnavailableSourceIsNotCachedAsMissingEvenWhenBackupHasNoMatch() async {
        let primary = FakeProvider()
        let backup = FakeProvider()
        let cache = MemoryCache()
        await primary.set(exact: .failed("HTTP 502"), search: .success([]))
        let repository = OnlineLyricsRepository(providers: [primary, backup], cache: cache)
        let track = LyricsTrack(songId: 9, query: query)
        guard case .failed = await repository.lookup(track) else { return XCTFail("An incomplete lookup is not a seven-day miss") }
        let stored = await cache.get(track.songId)
        XCTAssertNil(stored)
        await primary.set(exact: .success(candidate()), search: .success([]))
        guard case .found = await repository.lookup(track) else { return XCTFail("Retry must reach the recovered source") }
    }

    func testHealthyPrimaryDoesNotContactBackupAndRetainsRealWordTiming() async {
        let primary = FakeProvider()
        let backup = FakeProvider()
        await primary.set(exact: .success(candidate(word: "[00:01.000]<00:01.000>test")))
        let repository = OnlineLyricsRepository(providers: [primary, backup], cache: MemoryCache())
        guard case .found(let found, _, _, _) = await repository.lookup(LyricsTrack(songId: 9, query: query)) else { return XCTFail("Expected primary") }
        XCTAssertEqual(found.timing, .word)
        let exacts = await backup.exactCalls
        let searches = await backup.searchCalls
        XCTAssertEqual(exacts + searches, 0)
    }

    func testMetadataWithoutTextCannotSuppressAWorkingFallback() async {
        let primary = FakeProvider()
        let backup = FakeProvider()
        var empty = candidate(synced: nil)
        empty.plainLyrics = nil
        await primary.set(exact: .success(empty), search: .success([empty]))
        await backup.set(search: .success([candidate(id: 8, synced: nil)]))
        let repository = OnlineLyricsRepository(providers: [primary, backup], cache: MemoryCache())
        guard case .found(let found, _, _, _) = await repository.lookup(LyricsTrack(songId: 9, query: query)) else { return XCTFail("Expected actual text") }
        XCTAssertEqual(found.providerId, 8)
        XCTAssertNotNil(found.bestText)
        guard case .success(let manual) = await repository.search(LyricsTrack(songId: 9, query: query), freeText: "song") else { return XCTFail("Manual search also needs usable text") }
        XCTAssertEqual(manual.candidates.first?.providerId, 8)
    }

    func testManualEmptyPrimaryCanFindBackupAndAllFailuresStayFailures() async {
        let primary = FakeProvider()
        let backup = FakeProvider()
        await backup.set(search: .success([candidate(id: 2)]))
        let repository = OnlineLyricsRepository(providers: [primary, backup], cache: MemoryCache())
        let track = LyricsTrack(songId: 9, query: query)
        guard case .success(let found) = await repository.search(track, freeText: "song") else { return XCTFail("Expected fallback search") }
        XCTAssertEqual(found.candidates.first?.providerId, 2)
        await primary.set(search: .failed("HTTP 502"))
        await backup.set(search: .failed("HTTP 503"))
        guard case .failed = await repository.search(track, freeText: "song") else { return XCTFail("Do not report an outage as no results") }
    }

    func testBrowserSearchEncodesEditedTextAsAQueryRatherThanAURL() throws {
        let input = "AC/DC & someone? #Title"
        let url = try XCTUnwrap(LyricsWebSearch.url(for: input))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(components.queryItems?.first?.value, input + " lyrics")
        XCTAssertNil(components.fragment)
        XCTAssertNil(LyricsWebSearch.url(for: "  "))
    }
}

final class LyricsOvhProviderTests: XCTestCase {
    private let http = FakeHTTP()
    private let clock = Clock()
    private lazy var provider = LyricsOvhProvider(http: http, now: { [clock] in clock.now })

    private func suggestions(title: String = "Test Song", artist: String = "Someone") -> Data {
        try! JSONSerialization.data(withJSONObject: ["data": [
            ["id": 123, "title": title, "duration": 200, "artist": ["name": artist], "album": ["title": "Album"]],
        ]])
    }

    func testCatalogMetadataAndReturnedPlainTextAreRealAndNeverArtificiallySynced() async throws {
        let page = suggestions()
        let lyrics = try JSONSerialization.data(withJSONObject: ["lyrics": "First line\nSecond line"])
        var urls: [URL] = []
        http.respond = { url in
            urls.append(url)
            return (200, [:], url.path.hasPrefix("/suggest/") ? page : lyrics)
        }
        guard case .success(let found) = await provider.search(query, freeText: nil), let result = found.first else { return XCTFail("Expected real text") }
        XCTAssertEqual(result.providerId, 123)
        XCTAssertEqual(result.trackName, "Test Song")
        XCTAssertEqual(result.provider, "lyrics.ovh")
        XCTAssertEqual(result.durationSec, 200)
        XCTAssertEqual(result.plainLyrics, "First line\nSecond line")
        XCTAssertEqual(result.timing, .plain)
        XCTAssertNil(result.syncedLyrics)
        XCTAssertNil(result.wordSyncedLrc)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.last?.path, "/v1/Someone/Test Song")
    }

    func testDifferentVersionIsNotAutomaticallyFetchedButEditedManualSearchIsHonoured() async {
        let page = suggestions(title: "Test Song (Live)")
        var requested: [URL] = []
        http.respond = { url in requested.append(url); return (200, [:], page) }
        guard case .success(let found) = await provider.search(query, freeText: nil) else { return XCTFail("Expected empty filtered suggestions") }
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(requested.count, 1, "A different recording must not fetch lyrics automatically")
        _ = await provider.search(query, freeText: "edited artist/title")
        XCTAssertEqual(requested[1].lastPathComponent, "edited artist/title")
    }

    func testReservedCharactersRemainOneArtistOrTitleComponent() async throws {
        let page = suggestions(title: "Question? #1", artist: "AC/DC")
        var urls: [URL] = []
        http.respond = { url in
            urls.append(url)
            return (200, [:], url.path.hasPrefix("/suggest/") ? page : Data("{\"lyrics\":\"text\"}".utf8))
        }
        _ = await provider.search(query, freeText: "AC/DC Question? #1")
        let url = try XCTUnwrap(urls.last)
        XCTAssertEqual(url.host, "api.lyrics.ovh")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertTrue(parts.percentEncodedPath.contains("AC%2FDC"))
        XCTAssertNil(parts.query)
        XCTAssertNil(parts.fragment)
    }

    func testRateLimitBlocksFurtherRequestsAndMissingTextIsNotAResult() async {
        http.respond = { _ in (429, ["Retry-After": "30"], Data()) }
        guard case .rateLimited(let at) = await provider.search(query, freeText: nil) else { return XCTFail("Expected rate limit") }
        XCTAssertEqual(at, clock.now + 30_000)
        _ = await provider.search(query, freeText: nil)
        XCTAssertEqual(http.calls, 1)
        clock.now += 31_000
        let page = suggestions()
        http.respond = { url in (200, [:], url.path.hasPrefix("/suggest/") ? page : Data("{\"lyrics\":\"   \"}".utf8)) }
        guard case .success(let found) = await provider.search(query, freeText: nil) else { return XCTFail("Expected no usable text") }
        XCTAssertTrue(found.isEmpty)
    }
}


/// Deliberately ignores cancellation so a genuinely late network response reaches the store.
private actor DelayedLyricsSearch: OnlineLyricsProvider {
    nonisolated let name = "Delayed"
    private var old: CheckedContinuation<ProviderResponse<[LyricsCandidate]>, Never>?
    private(set) var oldStarted = false
    private(set) var oldReturned = false

    func exact(_ query: LyricsQuery) async -> ProviderResponse<LyricsCandidate> { .notFound }
    func search(_ query: LyricsQuery, freeText: String?) async -> ProviderResponse<[LyricsCandidate]> {
        if freeText == "old" {
            let result: ProviderResponse<[LyricsCandidate]> = await withCheckedContinuation {
                old = $0
                oldStarted = true
            }
            oldReturned = true
            return result
        }
        return .success(freeText == "new" ? [candidate(id: 99)] : [])
    }
    func resetOld() { oldStarted = false; oldReturned = false }
    func finishOld() {
        old?.resume(returning: .failed("HTTP 502"))
        old = nil
    }
}

final class LyricsSearchStateTests: XCTestCase {
    @MainActor
    func testOlderFailedSearchCannotReplaceNewerResultsOrReopenAClosedSearch() async throws {
        let provider = DelayedLyricsSearch()
        let repository = OnlineLyricsRepository(providers: [provider], cache: MemoryCache())
        let store = LyricsStore(database: try LibraryDatabase.inMemory(), repository: repository)
        store.shown(testSong(7))
        store.search("old")
        for _ in 0..<50 {
            let started = await provider.oldStarted
            if started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await provider.oldStarted
        XCTAssertTrue(started)
        store.search("new")
        for _ in 0..<50 {
            if store.current?.search == .results([candidate(id: 99)]) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.current?.search, .results([candidate(id: 99)]))
        await provider.finishOld()
        for _ in 0..<50 {
            let returned = await provider.oldReturned
            if returned { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(store.current?.search, .results([candidate(id: 99)]), "An old 502 must not overwrite the recovered search")
        await provider.resetOld()
        store.search("old")
        for _ in 0..<50 {
            let started = await provider.oldStarted
            if started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.closeSearch()
        await provider.finishOld()
        for _ in 0..<50 {
            let returned = await provider.oldReturned
            if returned { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(store.current?.search, .idle, "Closing search must suppress its late network error")
    }
}

final class SyncedLyricsPolicyTests: XCTestCase {
    private let track = LyricsTrack(songId: 7, query: query)

    func testHealthySyncedMissAllowsPlainTextButOutageDoesNot() async {
        let primary = FakeProvider(name: "LRCLIB")
        let plainSource = FakeProvider(name: "Plain source", supportsSyncedLyrics: false)
        await plainSource.set(search: .success([candidate(id: 2, synced: nil)]))
        let repository = OnlineLyricsRepository(providers: [primary, plainSource], cache: MemoryCache())
        guard case .found(let plain, _, _, _) = await repository.lookup(track) else { return XCTFail("Healthy empty synced response permits plain text") }
        XCTAssertEqual(plain.timing, .plain)
        await primary.set(exact: .failed("HTTP 502"), search: .failed("HTTP 502"))
        let before = await plainSource.searchCalls
        guard case .failed = await repository.lookup(track, refresh: true) else { return XCTFail("A saved plain result must not mask a sync outage") }
        let after = await plainSource.searchCalls
        XCTAssertEqual(before, after)
    }

    func testPlainExactMatchDoesNotHideFailedSynchronizedSearch() async {
        let primary = FakeProvider(name: "LRCLIB")
        await primary.set(exact: .success(candidate(synced: nil)), search: .failed("HTTP 502"))
        let cache = MemoryCache()
        let repository = OnlineLyricsRepository(providers: [primary], cache: cache)
        guard case .failed(let reason) = await repository.lookup(track) else { return XCTFail("An exact plain hit does not prove synchronized lyrics are missing") }
        XCTAssertTrue(reason.contains("LRCLIB"))
        let stored = await cache.get(track.songId)
        XCTAssertNil(stored)
    }

    func testSyncedSourceAlwaysBeatsAnEarlierPlainHit() async {
        let first = FakeProvider()
        let second = FakeProvider()
        await first.set(exact: .success(candidate(id: 1, synced: nil)), search: .success([]))
        await second.set(exact: .success(candidate(id: 2)))
        let repository = OnlineLyricsRepository(providers: [first, second], cache: MemoryCache())
        guard case .found(let found, _, _, _) = await repository.lookup(track) else { return XCTFail("Expected synchronized result") }
        XCTAssertEqual(found.providerId, 2)
        XCTAssertEqual(found.timing, .line)
    }

    func testLegacyPlainAndMissingCachesAreRecheckedWithoutDiscardingSavedSync() async {
        let primary = FakeProvider(name: "LRCLIB")
        let cache = MemoryCache()
        let repository = OnlineLyricsRepository(providers: [primary], cache: cache)
        await cache.put(CachedLyrics(songId: track.songId, fingerprint: lyricsFingerprint(query), status: .found,
                                    candidate: candidate(synced: nil), fetchedAtMs: 1))
        await primary.set(exact: .success(candidate(id: 2)))
        guard case .found(let upgraded, _, _, _) = await repository.lookup(track) else { return XCTFail("Old plain caches must upgrade") }
        XCTAssertEqual(upgraded.timing, .line)
        await primary.set(exact: .offline)
        guard case .found(let saved, let cached, _, _) = await repository.lookup(track) else { return XCTFail("Saved sync must work offline") }
        XCTAssertTrue(cached)
        XCTAssertEqual(saved.providerId, 2)
        await cache.put(CachedLyrics(songId: track.songId, fingerprint: lyricsFingerprint(query), status: .notFound, fetchedAtMs: Int64(Date().timeIntervalSince1970 * 1000)))
        await primary.set(exact: .success(candidate(id: 3)))
        guard case .found(let recovered, _, _, _) = await repository.lookup(track) else { return XCTFail("A legacy miss did not check synchronized availability") }
        XCTAssertEqual(recovered.providerId, 3)
    }

    func testPlainCachedChoiceIsNotUsedDuringAnOutage() async {
        let primary = FakeProvider(name: "LRCLIB")
        let cache = MemoryCache()
        let repository = OnlineLyricsRepository(providers: [primary], cache: cache)
        _ = await repository.choose(track, candidate(synced: nil))
        await primary.set(exact: .failed("HTTP 502"), search: .failed("HTTP 502"))
        guard case .failed = await repository.lookup(track) else { return XCTFail("Even an old chosen plain result must recheck sync on the next lookup") }
    }

    func testManualOptionsAreSortedSyncedFirstAndKeepTheirActualTiming() async {
        let primary = FakeProvider(name: "LRCLIB")
        await primary.set(search: .success([candidate(id: 1, synced: nil), candidate(id: 2), candidate(id: 3, word: "[00:01.000]<00:01.000>x")]))
        let repository = OnlineLyricsRepository(providers: [primary], cache: MemoryCache())
        guard case .success(let options) = await repository.search(track, freeText: "other versions") else { return XCTFail("Expected manual options") }
        XCTAssertEqual(options.candidates.map(\.timing), [.word, .line, .plain])
        XCTAssertNil(options.syncedServiceNotice)
    }

    func testUntimedFieldsCannotPretendToBeSyncedAndArtistAliasDoesNotBypassVersionChecks() {
        var bad = candidate(synced: "Words without timestamps", word: "Also untimed")
        XCTAssertEqual(bad.timing, .plain)
        XCTAssertNil(LyricsMatcher.best(query, [bad], minimumTiming: .line))
        bad.syncedLyrics = "[00:01.000]A real timed line"
        XCTAssertEqual(bad.timing, .line)
        XCTAssertEqual(bad.bestText, bad.syncedLyrics)
        let ye = LyricsQuery(title: "Black Skinhead", artist: "Ye", album: "Yeezus", durationMs: 188_000)
        let kanye = candidate("Black Skinhead", "Kanye West", album: "Yeezus", duration: 188)
        XCTAssertTrue(LyricsMatcher.score(ye, kanye).confident)
        XCTAssertTrue(LyricsMatcher.score(ye, candidate("Black Skinhead (Live)", "Kanye West", album: "Yeezus", duration: 188)).rejected)
        XCTAssertTrue(LyricsMatcher.score(ye, candidate("Black Skinhead", "Kanye West", album: "Yeezus", duration: 220)).rejected)
    }
}

final class EmbeddedSyncedLyricsPreferenceTests: XCTestCase {
    @MainActor
    private func databaseWithPlainLyrics() throws -> LibraryDatabase {
        let db = try LibraryDatabase.inMemory()
        try db.db.execute("""
            INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path,
                               track_number, year, date_modified, lyrics)
            VALUES (7, 'Test Song', 'Someone', 'Album', 0, 0, 200000, '7.mp3', '7.mp3', 1, 2020, 0, 'Embedded plain words')
            """)
        return db
    }

    @MainActor
    private func waitForLookup(_ store: LyricsStore) async throws {
        for _ in 0..<100 {
            if let state = store.current, state.lookup != .searching { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Lyrics lookup did not settle")
    }

    @MainActor
    func testEmbeddedPlainLyricsDoNotSuppressAvailableSynchronizedLyrics() async throws {
        let primary = FakeProvider(name: "LRCLIB")
        await primary.set(exact: .success(candidate()))
        let cache = MemoryCache()
        var oldMiss = CachedLyrics(songId: 7, fingerprint: lyricsFingerprint(query), status: .notFound,
                                   fetchedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        oldMiss.syncedLookupCompleted = true
        await cache.put(oldMiss)
        let store = LyricsStore(database: try databaseWithPlainLyrics(),
                                repository: OnlineLyricsRepository(providers: [primary], cache: cache))
        let song = Song(id: 7, title: "Test Song", artist: "Someone", album: "Album", durationMs: 200_000, path: "7.mp3")
        store.shown(song)
        XCTAssertNil(store.current?.text, "Do not flash embedded plain text while synchronization is unknown")
        try await waitForLookup(store)
        XCTAssertEqual(store.current?.text, candidate().syncedLyrics)
        XCTAssertEqual(store.current?.timing, .line)
        XCTAssertTrue(store.current?.hasFileLyrics == true)
    }

    @MainActor
    func testEmbeddedPlainLyricsWaitForAHealthyMissingSyncResponse() async throws {
        let primary = FakeProvider(name: "LRCLIB")
        await primary.set(exact: .failed("HTTP 502"), search: .failed("HTTP 502"))
        let store = LyricsStore(database: try databaseWithPlainLyrics(),
                                repository: OnlineLyricsRepository(providers: [primary], cache: MemoryCache()))
        let song = Song(id: 7, title: "Test Song", artist: "Someone", album: "Album", durationMs: 200_000, path: "7.mp3")
        store.shown(song)
        try await waitForLookup(store)
        XCTAssertNil(store.current?.text)
        XCTAssertTrue(store.current?.syncedServiceNotice?.contains("LRCLIB") == true)
        await primary.set(exact: .notFound, search: .success([]))
        store.refresh()
        try await waitForLookup(store)
        XCTAssertEqual(store.current?.text, "Embedded plain words")
        XCTAssertEqual(store.current?.timing, .plain)
        XCTAssertNil(store.current?.syncedServiceNotice)
    }

    @MainActor
    func testRefreshOutageRetainsSavedSynchronizationAndShowsServiceNotice() async throws {
        let primary = FakeProvider(name: "LRCLIB")
        let cache = MemoryCache()
        let repository = OnlineLyricsRepository(providers: [primary], cache: cache)
        let track = LyricsTrack(songId: 7, query: query)
        _ = await repository.choose(track, candidate())
        await primary.set(exact: .failed("HTTP 502"), search: .failed("HTTP 502"))
        let store = LyricsStore(database: try databaseWithPlainLyrics(), repository: repository)
        let song = Song(id: 7, title: "Test Song", artist: "Someone", album: "Album", durationMs: 200_000, path: "7.mp3")
        store.shown(song)
        try await waitForLookup(store)
        store.refresh()
        try await waitForLookup(store)
        XCTAssertEqual(store.current?.text, candidate().syncedLyrics)
        XCTAssertEqual(store.current?.timing, .line)
        XCTAssertTrue(store.current?.syncedServiceNotice?.contains("LRCLIB") == true)
    }
}
