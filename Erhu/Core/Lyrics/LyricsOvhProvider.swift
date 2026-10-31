import Foundation

/// Documented public API: https://github.com/NTag/lyrics.ovh#api.
/// Suggestions supply real catalog metadata/IDs; only returned lyric text is used. This source
/// does not supply timestamps, so it never creates line/word timing from a track's duration.
actor LyricsOvhProvider: OnlineLyricsProvider {
    nonisolated let name = "lyrics.ovh"
    nonisolated let supportsSyncedLyrics = false
    private static let base = URL(string: "https://api.lyrics.ovh/")!
    private let http: HTTPClient
    private let now: @Sendable () -> Int64
    private var blockedUntilMs: Int64 = 0

    init(http: HTTPClient = URLSessionHTTPClient(cachePolicy: .reloadIgnoringLocalCacheData, timeout: 10),
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.http = http
        self.now = now
    }

    // The text endpoint has no metadata. Resolve its artist/title through suggestions instead
    // of echoing the requested tags back as if they independently verified a match.
    func exact(_ query: LyricsQuery) async -> ProviderResponse<LyricsCandidate> { .notFound }

    func search(_ query: LyricsQuery, freeText: String?) async -> ProviderResponse<[LyricsCandidate]> {
        let text = freeText?.nonBlank ?? "\(query.title) \(query.artist)".trimmed
        guard !text.isBlank else { return .notFound }
        let page: ProviderResponse<Suggestions> = await get(["suggest", text])
        let records: [Record]
        switch page {
        case .success(let page): records = page.data
        case .notFound: return .notFound
        case .rateLimited(let at): return .rateLimited(retryAtMs: at)
        case .offline: return .offline
        case .failed(let reason): return .failed(reason)
        }
        var seen: Set<Int64> = []
        var candidates = records.compactMap { record -> LyricsCandidate? in
            guard record.id > 0, !record.title.isBlank, !record.artist.name.isBlank,
                  seen.insert(record.id).inserted else { return nil }
            let duration = record.duration.flatMap { $0.isFinite && $0 > 0 && $0 < Double(Int64.max) / 1000 ? $0 : nil }
            return LyricsCandidate(provider: name, providerId: record.id, trackName: record.title,
                                   artistName: record.artist.name, albumName: record.album?.title,
                                   durationSec: duration)
        }
        if freeText?.nonBlank == nil {
            candidates = candidates.filter {
                let score = LyricsMatcher.score(query, $0)
                return !score.rejected && score.score >= LyricsMatcher.plausibleScore
            }.sorted { LyricsMatcher.score(query, $0).score > LyricsMatcher.score(query, $1).score }
        }
        // Bounded requests, in catalog order. Manual search still honours the user's edited
        // query; unrelated automatic suggestions and mismatched recording versions stay out.
        var found: [LyricsCandidate] = []
        var failure: ProviderResponse<[LyricsCandidate]>?
        for var candidate in candidates.prefix(3) {
            guard !Task.isCancelled else { return .failed("cancelled") }
            let text: ProviderResponse<TextResponse> = await get(["v1", candidate.artistName, candidate.trackName])
            switch text {
            case .success(let result):
                if let lyrics = result.lyrics.nonBlank {
                    candidate.plainLyrics = lyrics
                    found.append(candidate)
                    if freeText?.nonBlank == nil, LyricsMatcher.score(query, candidate).confident {
                        return .success(found)
                    }
                }
            case .notFound: break
            case .rateLimited(let at):
                return found.isEmpty ? .rateLimited(retryAtMs: at) : .success(found)
            case .offline: failure = .offline
            case .failed(let reason): failure = .failed(reason)
            }
        }
        return found.isEmpty ? (failure ?? .success([])) : .success(found)
    }

    private struct Suggestions: Decodable, Sendable { let data: [Record] }
    private struct Record: Decodable, Sendable {
        struct Artist: Decodable, Sendable { let name: String }
        struct Album: Decodable, Sendable { let title: String? }
        let id: Int64
        let title: String
        let duration: Double?
        let artist: Artist
        let album: Album?
    }
    private struct TextResponse: Decodable, Sendable { let lyrics: String }

    private func get<T: Decodable & Sendable>(_ components: [String]) async -> ProviderResponse<T> {
        guard !Task.isCancelled else { return .failed("cancelled") }
        guard now() >= blockedUntilMs else { return .rateLimited(retryAtMs: blockedUntilMs) }
        // A slash in an artist/title is one encoded component, never a new route or host.
        let url = components.reduce(Self.base) { $0.appending(component: $1) }
        do {
            let (data, response) = try await http.get(url, headers: LyricsHTTP.headers)
            switch response.statusCode {
            case 200..<300:
                do { return .success(try JSONDecoder().decode(T.self, from: data)) }
                catch { return .failed("malformed response") }
            case 404: return .notFound
            case 429:
                blockedUntilMs = now() + LyricsHTTP.retryAfterMs(response.value(forHTTPHeaderField: "Retry-After"), nowMs: now())
                return .rateLimited(retryAtMs: blockedUntilMs)
            default: return .failed("HTTP \(response.statusCode)")
            }
        } catch { return LyricsHTTP.failure(error) }
    }
}
