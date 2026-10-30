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
    private lazy var provider = LrclibProvider(http: http, now: { [clock] in clock.now }, minGapMs: 0)

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
    nonisolated let name = "Fake"
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

    func testUncertainResultsAreOfferedNotShownAndNotCached() async {
        await fake.set(search: .success([candidate("Test Song", "Someone Else", id: 5)]))
        guard case .needsChoice(let options) = await repository.lookup(track) else { return XCTFail("expected a choice") }
        var entries = await cache.entries
        XCTAssertTrue(entries.isEmpty)
        _ = await repository.choose(track, options[0])
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
