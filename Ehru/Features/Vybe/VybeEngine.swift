import Foundation

/// Where VYBE stands.
enum VybeStatus: Equatable, Sendable {
    case loadingModel
    /// Songs are being described and embedded on the device; search works on the [done] ones.
    case indexing(done: Int, total: Int)
    case ready(songs: Int)
    case failed(String)
}

/// Model load and per-embedding timings measured on this device, for the screen's details line.
struct VybeTimings: Equatable, Sendable {
    var modelLoadMs: Int?
    var averageEmbedMs: Int?
    var lastQueryMs: Int?
}

/// VYBE on the device: loads the embedder, keeps a vector index of the library's song
/// descriptions up to date, and answers queries.
///
/// - Everything model- and index-related runs on this actor, in order: the index has one writer.
/// - Indexing embeds only songs whose description changed (or is new), each distinct description
///   once, appending as it goes: an interrupted run resumes where it stopped. Searches run between
///   embeddings. Library changes re-trigger it (debounced by the caller).
/// - Nothing leaves the device: no network is used anywhere here.
actor VybeEngine {
    static let appendBatch = 8
    static let compactRatio = 2
    static let compactSlack = 64

    private let database: LibraryDatabase
    private let indexURL: URL
    private let makeEmbedder: @Sendable () throws -> any TextEmbedder
    private let publish: @Sendable (VybeStatus, VybeTimings) -> Void

    private var embedder: (any TextEmbedder)?
    private var index: VybeIndexFile?
    private var library: [SongText] = []
    private var indexing: Task<Void, Never>?
    private var status: VybeStatus = .loadingModel
    private var timings = VybeTimings()
    private var tasteCache: (key: TasteKey, result: [Int64: Float])?
    private var tasteModelId: String?

    init(database: LibraryDatabase, indexURL: URL = LibraryPaths.supportFolder.appending(path: "vybe/index.bin"),
         makeEmbedder: @escaping @Sendable () throws -> any TextEmbedder = { try SentenceEmbedder() },
         publish: @escaping @Sendable (VybeStatus, VybeTimings) -> Void) {
        self.database = database
        self.indexURL = indexURL
        self.makeEmbedder = makeEmbedder
        self.publish = publish
    }

    /// Loads the model (once) and brings the index up to date with the library.
    func refresh() {
        guard loadModel() else { return }
        let songs: [SongText]
        do {
            songs = try database.songTags().map(VybeText.fromTags)
        } catch {
            update(.failed("The library couldn't be read: \(error.localizedDescription)"))
            return
        }
        if songs == library {
            switch status {
            case .ready, .indexing: return
            default: break
            }
        }
        indexing?.cancel()
        indexing = Task { await self.reindex(songs) }
    }

    /// Answers [query] from the indexed songs; nil when VYBE isn't ready.
    func search(_ query: String, limit: Int) throws -> VybeAnswer? {
        let start = Date()
        guard let discovery = discovery() else { return nil }
        let answer = try discovery.search(query, songs: library, limit: limit)
        timings.lastQueryMs = Int(Date().timeIntervalSince(start) * 1000)
        publish(status, timings)
        return answer
    }

    /// Songs nearest to [songId] by description (e.g. the current track).
    func similarTo(_ songId: Int64, limit: Int) -> VybeAnswer? {
        discovery()?.similarToSong(songId, limit: limit)
    }

    /// Indexed songs nearest to a listening taste, for the smart mixes: [seeds] (song id -> weight)
    /// averaged into one point and every other song scored against it. Never starts indexing.
    /// A saved index's model identity is checked once; no model is requested without an index.
    func tasteNeighbours(_ seeds: [Int64: Float], limit: Int) -> [Int64: Float]? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let modelId = embedder?.modelId ?? tasteModelId ?? (try? makeEmbedder().modelId)
        guard let modelId, let dimension = VybeIndexFile.storedDimension(indexURL, modelId: modelId) else { return nil }
        tasteModelId = modelId
        let songs = library.isEmpty ? ((try? database.songTags().map(VybeText.fromTags)) ?? []) : library
        let live = Dictionary(songs.map { ($0.songId, Self.documentHash($0)) }, uniquingKeysWith: { a, _ in a })
        let attributes = try? FileManager.default.attributesOfItem(atPath: indexURL.path)
        let key = TasteKey(seeds: seeds, limit: limit, indexSize: attributes?[.size] as? Int ?? 0,
                           indexModified: attributes?[.modificationDate] as? Date, library: live)
        if let cached = tasteCache, cached.key == key { return cached.result }
        let file = index ?? VybeIndexFile(url: indexURL, modelId: modelId, dimension: dimension)
        let stored = file.entries()
        let current = live.filter { stored[$0.key] == $0.value }
        let result = Dictionary(Ehru.tasteNeighbours(file, live: current, seeds: seeds, limit: limit).map { ($0.songId, $0.score) },
                                uniquingKeysWith: { a, _ in a })
        tasteCache = (key, result)
        return result
    }

    private struct TasteKey: Equatable {
        let seeds: [Int64: Float]
        let limit: Int
        let indexSize: Int
        let indexModified: Date?
        let library: [Int64: Int64]
    }

    static func documentHash(_ song: SongText) -> Int64 { textHash(VybeText.describe(song)) }

    private func discovery() -> VybeDiscovery? {
        if embedder == nil, !loadModel() { return nil }
        if library.isEmpty, indexing == nil { refresh() }
        guard let embedder, let index else { return nil }
        return VybeDiscovery(embedder: embedder, vectors: IndexVectors(file: index, live: currentEntries(index)))
    }

    /// The index entries whose text is still the song's current description.
    private func currentEntries(_ file: VybeIndexFile) -> [Int64: Int64] {
        let stored = file.entries()
        var live: [Int64: Int64] = [:]
        for song in library {
            let hash = Self.documentHash(song)
            if stored[song.songId] == hash { live[song.songId] = hash }
        }
        return live
    }

    private func loadModel() -> Bool {
        if embedder != nil { return true }
        update(.loadingModel)
        let start = Date()
        do {
            let model = try makeEmbedder()
            embedder = model
            tasteModelId = model.modelId
            index = VybeIndexFile(url: indexURL, modelId: model.modelId, dimension: model.dimension)
            timings.modelLoadMs = Int(Date().timeIntervalSince(start) * 1000)
            publish(status, timings)
            return true
        } catch {
            update(.failed("The model couldn't be loaded: \(error.localizedDescription)"))
            return false
        }
    }

    private func reindex(_ songs: [SongText]) async {
        library = songs
        guard let model = embedder, let file = index else { return }
        let stored = file.entries()
        var wanted: [Int64: Int64] = [:]
        for song in songs { wanted[song.songId] = Self.documentHash(song) }
        let missing = songs.filter { stored[$0.songId] != wanted[$0.songId] }
        var done = songs.count - missing.count
        update(missing.isEmpty ? .ready(songs: songs.count) : .indexing(done: done, total: songs.count))
        // Songs with the same description (an album's tracks often are) share one embedding.
        let byText = missing.orderedGrouped(by: { VybeText.describe($0) })
        var batch: [IndexedSong] = []
        var embedded = 0
        var embedSeconds = 0.0
        do {
            for (text, group) in byText {
                try Task.checkCancellation()
                let start = Date()
                let vector = try model.embed(text, role: .document)
                embedSeconds += Date().timeIntervalSince(start)
                embedded += 1
                for song in group { batch.append(IndexedSong(songId: song.songId, textHash: wanted[song.songId]!, vector: vector)) }
                done += group.count
                if batch.count >= Self.appendBatch {
                    try file.append(batch)
                    batch.removeAll()
                }
                timings.averageEmbedMs = Int(embedSeconds * 1000) / embedded
                update(.indexing(done: done, total: songs.count))
                // Let a waiting search run between embeddings.
                await Task.yield()
            }
            try file.append(batch)
            if file.recordCount() > wanted.count * Self.compactRatio + Self.compactSlack { try file.compact(keep: wanted) }
            update(.ready(songs: songs.count))
        } catch is CancellationError {
            try? file.append(batch)
        } catch {
            try? file.append(batch)
            update(.failed("Indexing stopped: \(error.localizedDescription)"))
        }
    }

    private func update(_ status: VybeStatus) {
        self.status = status
        publish(status, timings)
    }

    /// The song vectors of [file] limited to the songs whose description is current.
    private struct IndexVectors: SongVectors {
        let file: VybeIndexFile
        let live: [Int64: Int64]

        func rank(limit: Int, score: (Int64, [Float]) -> Float?) -> [VybeMatch] { file.rank(live: live, limit: limit, score: score) }
        func vectorOf(_ songId: Int64) -> [Float]? { live[songId] != nil ? file.vectorOf(songId) : nil }
    }
}
