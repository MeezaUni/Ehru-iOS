import XCTest
import os
@testable import Ehru

/// Embeds by keyword: axis 0 "dark", 1 "party", 2 "soul". Enough to check the hybrid logic.
private struct KeywordEmbedder: TextEmbedder {
    let modelId = "keywords"
    let dimension = 3
    let weakBest: Float = 0.30

    func embed(_ text: String, role: EmbeddingRole) -> [Float] {
        let t = text.lowercased()
        let dark: Float = t.contains("dark") || t.contains("cloud rap") || t.contains("memphis") ? 1 : 0.1
        let party: Float = t.contains("party") || t.contains("trap") ? 1 : 0.1
        let soul: Float = t.contains("soul") || t.contains("r&b") || t.contains("mellow") ? 1 : 0.1
        return [dark, party, soul]
    }
}

private struct MapVectors: SongVectors {
    let map: [Int64: [Float]]

    func rank(limit: Int, score: (Int64, [Float]) -> Float?) -> [VybeMatch] {
        let matches = map.compactMap { id, v in score(id, v).map { VybeMatch(songId: id, score: $0) } }
        return Array(matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.songId < $1.songId }.prefix(limit))
    }

    func vectorOf(_ songId: Int64) -> [Float]? { map[songId] }
}

final class VybeStartupTests: XCTestCase {
    func testSmartMixLookupDoesNotLoadAnEmbeddingModelWithoutASavedIndex() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = VybeEngine(database: try LibraryDatabase.inMemory(), indexURL: missing, makeEmbedder: {
            calls.withLock { $0 += 1 }
            return KeywordEmbedder()
        }, publish: { _, _ in })
        let result = await engine.tasteNeighbours([1: 1], limit: 5)
        XCTAssertNil(result)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testSavedIndexIdentityDoesNotRecreateTheModelForEachMixRebuild() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = VybeIndexFile(url: url, modelId: "keywords", dimension: 3)
        try index.append([IndexedSong(songId: 1, textHash: 1, vector: [1, 0, 0])])
        let engine = VybeEngine(database: try LibraryDatabase.inMemory(), indexURL: url, makeEmbedder: {
            calls.withLock { $0 += 1 }
            return KeywordEmbedder()
        }, publish: { _, _ in })
        _ = await engine.tasteNeighbours([1: 1], limit: 5)
        _ = await engine.tasteNeighbours([1: 1], limit: 5)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testIncompatibleSavedIndexDoesNotRepeatedlyLoadTheModel() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = VybeIndexFile(url: url, modelId: "older-model", dimension: 3)
        try index.append([IndexedSong(songId: 1, textHash: 1, vector: [1, 0, 0])])
        let engine = VybeEngine(database: try LibraryDatabase.inMemory(), indexURL: url, makeEmbedder: {
            calls.withLock { $0 += 1 }
            return KeywordEmbedder()
        }, publish: { _, _ in })
        let first = await engine.tasteNeighbours([1: 1], limit: 5)
        let second = await engine.tasteNeighbours([1: 1], limit: 5)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }
}

final class VybeDiscoveryTests: XCTestCase {
    private let songs = [
        SongText(songId: 1, title: "Nightmare", artist: "$uicideboy$", album: "THY KINGDOM COME", genre: "cloud rap; memphis rap", bpm: 140),
        SongText(songId: 2, title: "Runaway", artist: "Kanye West/Pusha T", album: "MBDTF", genre: "hip hop", bpm: 87),
        SongText(songId: 3, title: "OPPOSITE", artist: "Don Toliver", album: "OCTANE", genre: "alternative r&b; hip hop; trap", bpm: 128),
        SongText(songId: 4, title: "Mystery", artist: "Unknown Band", album: "Demos"),
        SongText(songId: 5, title: "Pink + White", artist: "Frank Ocean", album: "Blonde", genre: "alternative r&b; soul", bpm: 80),
    ]

    private var discovery: VybeDiscovery {
        let embedder = KeywordEmbedder()
        let map = Dictionary(uniqueKeysWithValues: songs.map { ($0.songId, embedder.embed(VybeText.describe($0), role: .document)) })
        return VybeDiscovery(embedder: embedder, vectors: MapVectors(map: map))
    }

    func testAnExactArtistRequestIsAnsweredFromMetadata() throws {
        guard case .named(let kind, _, let ids, let similar) = try discovery.search("songs by Kanye West", songs: songs, limit: 10) else {
            return XCTFail("not named")
        }
        XCTAssertEqual(.artist, kind)
        XCTAssertEqual([2], ids)
        XCTAssertTrue(similar.isEmpty)
        guard case .named(_, _, let likeIds, let likeSimilar) = try discovery.search("songs like Runaway", songs: songs, limit: 2) else {
            return XCTFail("not named")
        }
        XCTAssertEqual([2], likeIds)
        XCTAssertFalse(likeSimilar.contains { $0.songId == 2 }, "the named song isn't its own neighbour")
    }

    func testAMoodIsMatchedSemanticallyAndKeepsSongsWithoutTags() throws {
        guard case .described(_, let hits, _, _) = try discovery.search("dark atmospheric stuff", songs: songs, limit: 10) else {
            return XCTFail("not described")
        }
        XCTAssertEqual(1, hits.first?.songId)
        XCTAssertTrue(hits.contains { $0.songId == 4 })
        XCTAssertEqual(songs.count, hits.count)
    }

    func testAnArtistNamedInsideAMoodWinsAndSaysWhy() throws {
        guard case .described(_, let hits, _, _) = try discovery.search("late-night Frank Ocean vibes", songs: songs, limit: 3) else {
            return XCTFail("not described")
        }
        XCTAssertEqual(5, hits.first?.songId)
        XCTAssertEqual("Artist: Frank Ocean", hits.first?.reasons.first)
    }

    func testALibraryGenreNamedOutrightIsBoosted() {
        let boosts = VybeDiscovery.metadataBoosts("some trap for the gym", songs: songs)
        XCTAssertTrue(boosts[3]!.contains { $0.0 == "Genre: trap" })
        XCTAssertTrue(boosts[1]!.contains { $0.0 == "Tempo: 140 BPM (tag)" })
        XCTAssertNil(boosts[2])
        XCTAssertNil(boosts[4])
    }

    func testAQueryThatDoesntSeparateTheLibraryIsFlaggedWeak() {
        XCTAssertTrue(VybeDiscovery.isWeak([0.51, 0.50, 0.50, 0.49], weakBest: 0.30))
        XCTAssertFalse(VybeDiscovery.isWeak([0.70, 0.50, 0.48, 0.40], weakBest: 0.30))
        XCTAssertTrue(VybeDiscovery.isWeak([0.215, 0.209, 0.15, 0.10], weakBest: 0.30))
    }

    func testSimilarToTheCurrentSongExcludesIt() {
        guard case .similarTo(_, let hits) = discovery.similarToSong(5, limit: 2) else { return XCTFail("not similar") }
        XCTAssertFalse(hits.contains { $0.songId == 5 })
        XCTAssertEqual(2, hits.count)
    }

    func testDescriptionsLeaveTitlesAndAlbumsOutAndSplitGenres() {
        XCTAssertEqual("Artist: Don Toliver. Genres: alternative r&b, hip hop, trap. Tempo: 128 BPM", VybeText.describe(songs[2]))
        XCTAssertFalse(VybeText.describe(songs[0]).contains("Nightmare"))
        XCTAssertEqual("Artist: Unknown Band", VybeText.describe(songs[3]))
    }
}

final class VybeQueryRouterTests: XCTestCase {
    private let library = [
        SongText(songId: 1, title: "EARFQUAKE", artist: "Tyler/ The Creator", album: "IGOR"),
        SongText(songId: 2, title: "NEW MAGIC WAND", artist: "Tyler/ The Creator", album: "IGOR"),
        SongText(songId: 3, title: "911 / Mr. Lonely", artist: "Tyler, The Creator feat. Frank Ocean & Steve Lacy", album: "Flower Boy"),
        SongText(songId: 4, title: "Runaway", artist: "Kanye West feat. Pusha T", album: "My Beautiful Dark Twisted Fantasy"),
        SongText(songId: 5, title: "Rich Flex", artist: "Drake & 21 Savage", album: "Her Loss"),
        SongText(songId: 6, title: "Late", artist: "Kanye West", album: "Late Registration"),
    ]

    private func route(_ query: String) -> VybeRoute { VybeQueryRouter.route(query, songs: library) }

    func testMoreFromAnArtistFindsEveryCreditDespiteABrokenSeparator() {
        XCTAssertEqual(.named(kind: .artist, name: "Tyler, the Creator", songIds: [1, 2, 3], wantsSimilar: false),
                       route("more music from Tyler, the Creator"))
    }

    func testSongsLikeAFeaturedArtistFindsTheSongsCreditingThem() {
        XCTAssertEqual(.named(kind: .artist, name: "Frank Ocean", songIds: [3], wantsSimilar: true), route("songs like Frank Ocean"))
    }

    func testAlbumAndTitleQueriesMatchWholeNames() {
        XCTAssertEqual(.named(kind: .album, name: "IGOR", songIds: [1, 2], wantsSimilar: true), route("albums like IGOR"))
        XCTAssertEqual(.named(kind: .title, name: "Runaway", songIds: [4], wantsSimilar: true), route("songs like Runaway"))
    }

    func testANameNotInTheLibraryIsReportedUnknown() {
        XCTAssertEqual(.unknownName(name: "Blonde", query: "songs like Blonde"), route("songs like Blonde"))
    }

    func testMoodQueriesGoToSemanticSearch() {
        XCTAssertEqual(.describe(query: "late night music"), route("late night music"))
        XCTAssertEqual(.describe(query: "dark atmospheric hip-hop"), route("dark atmospheric hip-hop"))
    }

    func testVeryShortNamesAreNotMatchedInsideCredits() {
        guard case .unknownName = route("songs by Ye") else { return XCTFail("matched") }
    }
}

final class VybeIndexTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var file: URL { folder.appending(path: "vybe.idx") }

    private func index(model: String = "gemma", dimension: Int = 3) -> VybeIndexFile {
        VybeIndexFile(url: file, modelId: model, dimension: dimension)
    }

    private func song(_ id: Int64, _ hash: Int64, _ v: Float...) -> IndexedSong { IndexedSong(songId: id, textHash: hash, vector: v) }

    private func cosine(_ query: [Float]) -> (Int64, [Float]) -> Float? { { _, v in cosineSimilarity(query, v) } }

    func testRecordsAreAppendedAndTheLastOneOfASongWins() throws {
        let index = self.index()
        try index.append([song(1, 10, 1, 0, 0), song(2, 20, 0, 1, 0)])
        try index.append([song(1, 11, 0, 0, 1)])
        XCTAssertEqual([1: 11, 2: 20], index.entries())
        XCTAssertEqual([0, 0, 1], index.vectorOf(1))
        XCTAssertEqual(3, index.recordCount())
    }

    func testRankingUsesOnlyLiveCurrentVectorsBestFirst() throws {
        let index = self.index()
        try index.append([song(1, 10, 1, 0, 0), song(2, 20, 0.9, 0.1, 0), song(3, 30, 0, 1, 0)])
        try index.append([song(1, 11, 0, 0, 1)])
        let live: [Int64: Int64] = [1: 11, 2: 20]
        XCTAssertEqual([2, 1], index.rank(live: live, limit: 5, score: cosine([1, 0, 0])).map(\.songId))
        XCTAssertEqual([2], index.rank(live: [1: 12, 2: 20], limit: 5, score: cosine([1, 0, 0])).map(\.songId))
        XCTAssertEqual(1, index.rank(live: live, limit: 1, score: cosine([1, 0, 0])).count)
    }

    func testCompactionKeepsOnlyLiveRecords() throws {
        let index = self.index()
        try index.append([song(1, 10, 1, 0, 0), song(2, 20, 0, 1, 0)])
        try index.append([song(1, 11, 0, 0, 1)])
        try index.compact(keep: [1: 11])
        XCTAssertEqual(1, index.recordCount())
        XCTAssertEqual([1: 11], index.entries())
        XCTAssertEqual([0, 0, 1], index.vectorOf(1))
    }

    func testAnotherModelsFileIsIgnoredAndReplaced() throws {
        try index(model: "other").append([song(1, 10, 1, 0, 0)])
        let index = self.index(model: "gemma")
        XCTAssertTrue(index.entries().isEmpty)
        try index.append([song(2, 20, 0, 1, 0)])
        XCTAssertEqual([2: 20], index.entries())
        XCTAssertTrue(self.index(dimension: 4).entries().isEmpty)
    }

    func testARecordCutShortByAnInterruptedWriteIsIgnored() throws {
        let index = self.index()
        try index.append([song(1, 10, 1, 0, 0), song(2, 20, 0, 1, 0)])
        let bytes = try Data(contentsOf: file)
        try bytes.prefix(bytes.count - 5).write(to: file)
        XCTAssertEqual([1: 10], index.entries())
        XCTAssertNil(index.vectorOf(2))
    }

    func testTheFormatMatchesAndroid() throws {
        try index(model: "m").append([song(1, 2, 1.5, 0, -1)])
        let bytes = [UInt8](try Data(contentsOf: file))
        // "VYBEIDX1", version 1, dimension 3, writeUTF("m"), then id, hash and floats, big-endian.
        XCTAssertEqual(Array("VYBEIDX1".utf8) + [0, 0, 0, 1, 0, 0, 0, 3, 0, 1, 0x6D], Array(bytes.prefix(19)))
        XCTAssertEqual([0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2], Array(bytes[19..<35]))
        XCTAssertEqual([0x3F, 0xC0, 0, 0], Array(bytes[35..<39]))
        XCTAssertEqual(47, bytes.count)
    }

    func testTextHashFollowsTheText() {
        XCTAssertEqual(textHash("Genres: trap"), textHash("Genres: trap"))
        XCTAssertNotEqual(textHash("Genres: trap"), textHash("Genres: trap metal"))
    }

    // MARK: Taste

    private let live: [Int64: Int64] = Dictionary(uniqueKeysWithValues: (Int64(1)...6).map { ($0, $0 * 10) })

    private func taste(_ id: Int64, _ v: Float...) -> IndexedSong { IndexedSong(songId: id, textHash: id * 10, vector: v) }

    func testTheStoredDimensionIsReadOnlyForTheSameModel() throws {
        XCTAssertNil(VybeIndexFile.storedDimension(file, modelId: "gemma"))
        try index().append([taste(1, 1, 0, 0)])
        XCTAssertEqual(3, VybeIndexFile.storedDimension(file, modelId: "gemma"))
        XCTAssertNil(VybeIndexFile.storedDimension(file, modelId: "another-model"))
    }

    func testNeighboursFollowTheWeightedTasteSeedsLeftOut() throws {
        let index = self.index()
        try index.append([taste(1, 1, 0, 0), taste(2, 0, 1, 0), taste(3, 0.95, 0.05, 0), taste(4, 0.05, 0.95, 0), taste(5, 0, 0, 1)])
        XCTAssertEqual([3, 4, 5], tasteNeighbours(index, live: live, seeds: [1: 5, 2: 1], limit: 3).map(\.songId))
        XCTAssertEqual(4, tasteNeighbours(index, live: live, seeds: [1: 1, 2: 5], limit: 3).first?.songId)
    }

    func testNoUsableSeedsNoNeighbours() throws {
        let index = self.index()
        try index.append([taste(1, 1, 0, 0), taste(2, 0, 1, 0)])
        XCTAssertTrue(tasteNeighbours(index, live: live, seeds: [:], limit: 5).isEmpty)
        XCTAssertTrue(tasteNeighbours(index, live: live, seeds: [9: 1], limit: 5).isEmpty)
        XCTAssertTrue(tasteNeighbours(index, live: live, seeds: [1: 0], limit: 5).isEmpty)
    }

    func testVectorsOfReadsOnlyCurrentRecords() throws {
        let index = self.index()
        try index.append([taste(1, 1, 0, 0), taste(2, 0, 1, 0)])
        try index.append([IndexedSong(songId: 1, textHash: 11, vector: [0, 0, 1])])
        let found = index.vectorsOf(live: [1: 11, 2: 20], wanted: [1, 2])
        XCTAssertEqual([0, 0, 1], found[1])
        XCTAssertEqual([0, 1, 0], found[2])
    }
}

final class VybeBasicsTests: XCTestCase {
    func testCosineSimilarity() {
        XCTAssertEqual(1, cosineSimilarity([1, 2, 3], [2, 4, 6])!, accuracy: 1e-6)
        XCTAssertEqual(-1, cosineSimilarity([1, 0], [-3, 0])!, accuracy: 1e-6)
        XCTAssertEqual(0, cosineSimilarity([1, 0], [0, 5])!, accuracy: 1e-6)
        XCTAssertNil(cosineSimilarity([], []))
        XCTAssertNil(cosineSimilarity([1, 2], [1, 2, 3]))
        XCTAssertNil(cosineSimilarity([0, 0], [1, 2]))
        XCTAssertNil(cosineSimilarity([.nan, 1], [1, 1]))
        XCTAssertNil(cosineSimilarity([.infinity, 1], [1, 1]))
    }

    func testRankingIsBestFirstLimitedAndSkipsInvalidVectors() {
        let songs = [EmbeddedSong(songId: 1, vector: [0, 1]), EmbeddedSong(songId: 2, vector: [1, 0.1]), EmbeddedSong(songId: 3, vector: [1, 1]),
                     EmbeddedSong(songId: 4, vector: [1, 0, 0]), EmbeddedSong(songId: 5, vector: [0, 0])]
        XCTAssertEqual([2, 3, 1], VybeRanker.rank([1, 0], songs: songs, limit: 10).map(\.songId))
        XCTAssertEqual([2], VybeRanker.rank([1, 0], songs: songs, limit: 1).map(\.songId))
        let equal = [EmbeddedSong(songId: 9, vector: [2, 2]), EmbeddedSong(songId: 3, vector: [1, 1]), EmbeddedSong(songId: 5, vector: [4, 4])]
        XCTAssertEqual([3, 5, 9], VybeRanker.rank([1, 1], songs: equal, limit: 3).map(\.songId))
        XCTAssertEqual([3, 5, 9], VybeRanker.rank([1, 1], songs: equal.reversed(), limit: 3).map(\.songId))
        XCTAssertTrue(VybeRanker.rank([1], songs: [], limit: 5).isEmpty)
        XCTAssertTrue(VybeRanker.rank([1], songs: [EmbeddedSong(songId: 1, vector: [1])], limit: 0).isEmpty)
    }

    func testDescriptionUsesTheKnownFieldsOnly() {
        let song = SongText(songId: 1, title: "Lost In The World", artist: "Kanye West", album: "My Beautiful Dark Twisted Fantasy",
                            genre: "Hip-Hop", year: 2010)
        XCTAssertEqual("Title: Lost In The World. Artist: Kanye West. Genre: Hip-Hop. Year: 2010", SongDescriber.describe(song))
        XCTAssertEqual("Title: Track 01", SongDescriber.describe(SongText(songId: 2, title: "Track 01", artist: "<unknown>", album: " ")))
    }

    func testSeveralGenresAreSeparateGenres() {
        let song = SongText(songId: 3, title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                            genre: "Electronic; Synth-pop; Alternative")
        XCTAssertEqual(["Electronic", "Synth-pop", "Alternative"], song.genres)
        XCTAssertEqual("Title: Midnight City. Artist: M83. Genres: Electronic, Synth-pop, Alternative", SongDescriber.describe(song))
        XCTAssertEqual(["Hip-Hop"], SongText(songId: 4, title: "T", artist: "A", album: "B", genre: " Hip-Hop ").genres)
        XCTAssertEqual([], SongText(songId: 5, title: "T", artist: "A", album: "B", genre: "Unknown").genres)
        XCTAssertEqual("Title: T. Artist: A", SongDescriber.describe(SongText(songId: 5, title: "T", artist: "A", album: "B", genre: " ; unknown")))
    }

    func testALibraryBpmIsPartOfTheDescription() {
        let song = SongText(songId: 6, title: "EARFQUAKE", artist: "Tyler, The Creator", album: "IGOR", genre: "hip hop", year: 2019, bpm: 80)
        XCTAssertEqual("Title: EARFQUAKE. Artist: Tyler, The Creator. Genre: hip hop. Year: 2019. Tempo: 80 BPM", SongDescriber.describe(song))
        XCTAssertEqual("Title: T", SongDescriber.describe(SongText(songId: 7, title: "T", artist: "", album: "", bpm: 0)))
    }

    func testLyricsBecomeAShortExcerptWithoutTimestamps() {
        let lrc = "[ar:Someone]\n[00:01.00]<00:01.00>Late <00:01.40>night\n[00:05.00]city lights"
        XCTAssertEqual("Late night city lights", SongDescriber.lyricsExcerpt(lrc))
        let excerpt = SongDescriber.lyricsExcerpt(Array(repeating: "word", count: 200).joined(separator: " "))!
        XCTAssertLessThanOrEqual(excerpt.count, SongDescriber.lyricsExcerptChars)
        XCTAssertTrue(excerpt.hasSuffix("word"))
        XCTAssertNil(SongDescriber.lyricsExcerpt("  [00:01.00]  "))
        XCTAssertNil(SongDescriber.lyricsExcerpt(nil))
    }
}

/// Apple's on-device models with real descriptions: checks they rank sensibly and prints the
/// scores, which is how VYBE's "weak result" threshold gets calibrated for them.
final class SentenceEmbedderTests: XCTestCase {
    private let songs = [
        SongText(songId: 1, title: "A", artist: "Night Drive", album: "", genre: "Synthwave; Darkwave", bpm: 92),
        SongText(songId: 2, title: "B", artist: "Gym Crew", album: "", genre: "EDM; Hardstyle", bpm: 150),
        SongText(songId: 3, title: "C", artist: "Quiet Hands", album: "", genre: "Ambient; Piano", bpm: 70),
        SongText(songId: 4, title: "D", artist: "MC Flow", album: "", genre: "Hip-Hop; Trap", bpm: 140),
        SongText(songId: 5, title: "E", artist: "Someone", album: ""),
    ]

    private func calibrate(_ embedder: SentenceEmbedder) throws {
        let vectors = try songs.map { try embedder.embed(VybeText.describe($0), role: .document) }
        for query in ["calm music to sleep", "high energy workout", "hip hop", "sad but beautiful"] {
            let q = try embedder.embed(query, role: .query)
            let scores = vectors.map { cosineSimilarity(q, $0) ?? .nan }
            print("VYBE calibration [\(embedder.modelId), \(embedder.dimension)d] \(query): \(scores.map { String(format: "%.3f", $0) })")
        }
        XCTAssertEqual(embedder.dimension, vectors[0].count)
        let sleep = try embedder.embed("calm music to sleep", role: .query)
        let ranked = VybeRanker.rank(sleep, songs: zip(songs, vectors).map { EmbeddedSong(songId: $0.songId, vector: $1) }, limit: 5)
        XCTAssertEqual(5, ranked.count)
    }

    func testTheSentenceModelRanksByMeaning() throws {
        let embedder = try SentenceEmbedder()
        guard embedder.usesSentenceModel else { throw XCTSkip("No sentence model here; the word model stands in") }
        try calibrate(embedder)
    }

    func testTheWordModelFallbackWorks() throws {
        let embedder: SentenceEmbedder
        do { embedder = try SentenceEmbedder(allowSentence: false) } catch { throw XCTSkip("No word model here: \(error)") }
        XCTAssertFalse(embedder.usesSentenceModel)
        try calibrate(embedder)
    }
}
