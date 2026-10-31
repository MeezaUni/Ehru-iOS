import Foundation

/// A track to find lyrics for, by its library id.
struct LyricsTrack: Equatable, Sendable {
    let songId: Int64
    var query: LyricsQuery
}

extension Song {
    var lyricsTrack: LyricsTrack {
        LyricsTrack(songId: id, query: LyricsQuery(title: title, artist: artist, album: album.isBlank ? nil : album, durationMs: durationMs))
    }
}

/// The outcome of a lookup.
enum OnlineLyricsResult: Equatable, Sendable {
    case found(LyricsCandidate, fromCache: Bool, userChosen: Bool, fetchedAtMs: Int64)
    case notFound
    case instrumental
    /// Results that might match but none confidently: the user chooses (nothing is shown silently).
    case needsChoice([LyricsCandidate])
    case offline
    case rateLimited(retryAtMs: Int64)
    case failed(String)
}

enum CachedStatus: String, Codable, Sendable {
    case found = "FOUND"
    case notFound = "NOT_FOUND"
    case instrumental = "INSTRUMENTAL"
}

/// A fetched result for one track, kept so lyrics work offline and are not fetched again.
/// [fingerprint] is the metadata it was matched for: if the tags change, it no longer applies.
struct CachedLyrics: Codable, Equatable, Sendable {
    static let currentSchema = 1
    var schema = CachedLyrics.currentSchema
    let songId: Int64
    let fingerprint: String
    let status: CachedStatus
    var candidate: LyricsCandidate?
    let fetchedAtMs: Int64
    var userChosen = false
}

/// Storage of fetched lyrics.
protocol OnlineLyricsCache: Sendable {
    func get(_ songId: Int64) async -> CachedLyrics?
    func put(_ entry: CachedLyrics) async
    func remove(_ songId: Int64) async
}

/// The metadata a match depends on: a re-tagged file is looked up again.
func lyricsFingerprint(_ query: LyricsQuery) -> String {
    [query.title, query.artist, query.album ?? "", String(query.durationMs / 1000)].map { $0.trimmed.lowercased() }.joined(separator: "|")
}

/// One small JSON file per song in the app's own storage.
actor FileOnlineLyricsCache: OnlineLyricsCache {
    private let folder: URL

    init(folder: URL = LibraryPaths.supportFolder.appending(path: "online-lyrics")) { self.folder = folder }

    private func file(_ songId: Int64) -> URL { folder.appending(path: "\(songId).json") }

    func get(_ songId: Int64) -> CachedLyrics? {
        guard let data = try? Data(contentsOf: file(songId)), let entry = try? JSONDecoder().decode(CachedLyrics.self, from: data),
              entry.schema == CachedLyrics.currentSchema else { return nil }
        return entry
    }

    func put(_ entry: CachedLyrics) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file(entry.songId), options: .atomic) }
    }

    func remove(_ songId: Int64) { try? FileManager.default.removeItem(at: file(songId)) }
}

/// Finds lyrics online for a track, with a local cache. Order: the cache (a match, an
/// instrumental, or a recent "not found"), then each provider: its exact-match lookup, and a search
/// when that is not already a confident word-timed match. Only a confident match is used
/// automatically, word timing first; otherwise plausible results are offered. Concurrent lookups of
/// the same track share one request; failures are not cached, so a retry can succeed.
actor OnlineLyricsRepository {
    /// How long "no lyrics online" is believed before asking again.
    static let notFoundTtlMs: Int64 = 7 * 24 * 60 * 60 * 1000

    private let providers: [OnlineLyricsProvider]
    private let cache: OnlineLyricsCache
    private let now: @Sendable () -> Int64
    private var inFlight: [Int64: (id: UUID, task: Task<OnlineLyricsResult, Never>)] = [:]

    init(providers: [OnlineLyricsProvider], cache: OnlineLyricsCache,
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.providers = providers
        self.cache = cache
        self.now = now
    }

    /// The cached result for [track] if it still fits its metadata; never touches the network.
    func cached(_ track: LyricsTrack) async -> CachedLyrics? {
        guard let entry = await cache.get(track.songId), entry.fingerprint == lyricsFingerprint(track.query) else { return nil }
        return entry
    }

    /// Lyrics for [track]: from the cache, or looked up online. [refresh] ignores the cache. A caller
    /// that stops waiting (the track changed) does not cancel the shared lookup; its result is cached.
    func lookup(_ track: LyricsTrack, refresh: Bool = false) async -> OnlineLyricsResult {
        if let running = inFlight[track.songId] { return await running.task.value }
        let id = UUID()
        let task = Task { await self.resolve(track, refresh: refresh) }
        inFlight[track.songId] = (id, task)
        let result = await task.value
        if inFlight[track.songId]?.id == id { inFlight[track.songId] = nil }
        return result
    }

    /// Manual search uses the same failover as automatic lookup. An empty or failing primary
    /// must not strand the search sheet while another source can return real results.
    func search(_ track: LyricsTrack, freeText: String?) async -> ProviderResponse<[LyricsCandidate]> {
        var failure: ProviderResponse<[LyricsCandidate]>?
        for provider in providers {
            guard !Task.isCancelled else { return .failed("cancelled") }
            switch await provider.search(track.query, freeText: freeText?.nonBlank) {
            case .success(let candidates):
                let usable = candidates.filter { $0.instrumental || $0.bestText != nil }
                if !usable.isEmpty { return .success(usable) }
            case .notFound: break
            case .offline: if failure == nil { failure = .offline }
            case .rateLimited(let at): if failure == nil { failure = .rateLimited(retryAtMs: at) }
            case .failed(let reason): if failure == nil { failure = .failed("\(provider.name): \(reason)") }
            }
        }
        return failure ?? .success([])
    }

    /// The user picked [candidate] for [track]: it is kept and preferred (also over the file's own lyrics).
    func choose(_ track: LyricsTrack, _ candidate: LyricsCandidate) async -> OnlineLyricsResult {
        let entry = CachedLyrics(songId: track.songId, fingerprint: lyricsFingerprint(track.query),
                                 status: candidate.instrumental ? .instrumental : .found, candidate: candidate, fetchedAtMs: now(), userChosen: true)
        await cache.put(entry)
        return .found(candidate, fromCache: false, userChosen: true, fetchedAtMs: entry.fetchedAtMs)
    }

    /// Forgets what was fetched for [track] (the file's own lyrics, or a new lookup, take over).
    func forget(_ track: LyricsTrack) async { await cache.remove(track.songId) }

    private func resolve(_ track: LyricsTrack, refresh: Bool) async -> OnlineLyricsResult {
        if !refresh, let cached = await fromCache(track) { return cached }
        let query = track.query
        if query.title.isBlank { return .notFound }
        var found: [LyricsCandidate] = []
        var failure: OnlineLyricsResult?
        for provider in providers {
            if let outcome = await ask(provider, query, &found), failure == nil {
                if case .failed(let reason) = outcome { failure = .failed("\(provider.name): \(reason)") }
                else { failure = outcome }
            }
            // A healthy primary keeps its existing word/line preference. Only an unavailable
            // or inconclusive source invokes the next service, including on manual search.
            if let best = LyricsMatcher.best(query, found) { return await store(track, best) }
        }
        let options = LyricsMatcher.plausible(query, found)
        if !options.isEmpty { return .needsChoice(options) }
        // A gateway outage (even when another provider has no result) is not proof that lyrics
        // do not exist. Never turn it into a seven-day NOT_FOUND cache entry.
        if let failure { return failure }
        await cache.put(CachedLyrics(songId: track.songId, fingerprint: lyricsFingerprint(query), status: .notFound, fetchedAtMs: now()))
        return .notFound
    }

    /// Collects a provider's results, retaining failures so another service can recover them.
    private func ask(_ provider: OnlineLyricsProvider, _ query: LyricsQuery, _ found: inout [LyricsCandidate]) async -> OnlineLyricsResult? {
        var exactFailure: OnlineLyricsResult?
        if query.durationMs > 0 && !query.artist.isBlank {
            switch await provider.exact(query) {
            case .success(let candidate): found.append(candidate)
            case .notFound: break
            case .failed(let reason): exactFailure = .failed(reason)
            case let other: return stop(other)
            }
            if let last = found.last, LyricsMatcher.score(query, last).confident, last.timing == .word { return nil }
        }
        switch await provider.search(query, freeText: nil) {
        case .success(let candidates):
            let known = found
            found += candidates.filter { candidate in !known.contains { $0.id == candidate.id } }
        case .notFound:
            break
        case let other:
            if LyricsMatcher.best(query, found) == nil { return stop(other) }
        }
        return LyricsMatcher.best(query, found) == nil ? exactFailure : nil
    }

    private func stop<T>(_ response: ProviderResponse<T>) -> OnlineLyricsResult {
        switch response {
        case .rateLimited(let at): return .rateLimited(retryAtMs: at)
        case .offline: return .offline
        case .failed(let reason): return .failed(reason)
        default: return .notFound
        }
    }

    private func fromCache(_ track: LyricsTrack) async -> OnlineLyricsResult? {
        guard let entry = await cached(track) else { return nil }
        switch entry.status {
        case .instrumental: return .instrumental
        case .found:
            guard let candidate = entry.candidate, candidate.instrumental || candidate.bestText != nil else { return nil }
            return .found(candidate, fromCache: true, userChosen: entry.userChosen, fetchedAtMs: entry.fetchedAtMs)
        case .notFound:
            // "Not found" is remembered for a while, then asked again (lyrics get added over time).
            return now() - entry.fetchedAtMs < Self.notFoundTtlMs ? .notFound : nil
        }
    }

    private func store(_ track: LyricsTrack, _ best: LyricsCandidate) async -> OnlineLyricsResult {
        let entry = CachedLyrics(songId: track.songId, fingerprint: lyricsFingerprint(track.query),
                                 status: best.instrumental ? .instrumental : .found, candidate: best, fetchedAtMs: now())
        await cache.put(entry)
        return best.instrumental ? .instrumental : .found(best, fromCache: false, userChosen: false, fetchedAtMs: entry.fetchedAtMs)
    }
}
