import Foundation

/// Fetches a URL (URLSession in the app, a fake in tests).
protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    var session: URLSession = .shared
    var cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    var timeout: TimeInterval = 20

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// A record as LRCLIB returns it.
struct LrclibRecord: Decodable, Equatable {
    var id: Int64?
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental = false
    var plainLyrics: String?
    /// Line-timed LRC only; word timing is never in here.
    var syncedLyrics: String?
    /// True when [lyricsfile] carries word-level timing.
    var hasWordSync = false
    /// LRCLIB's Lyricsfile (YAML): lines with start/end times and, with [hasWordSync], timed words.
    var lyricsfile: String?

    init(id: Int64? = nil, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil, duration: Double? = nil,
         instrumental: Bool = false, plainLyrics: String? = nil, syncedLyrics: String? = nil, hasWordSync: Bool = false,
         lyricsfile: String? = nil) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
        self.hasWordSync = hasWordSync
        self.lyricsfile = lyricsfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        trackName = try c.decodeIfPresent(String.self, forKey: .trackName)
        artistName = try c.decodeIfPresent(String.self, forKey: .artistName)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        instrumental = try c.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
        plainLyrics = try c.decodeIfPresent(String.self, forKey: .plainLyrics)
        syncedLyrics = try c.decodeIfPresent(String.self, forKey: .syncedLyrics)
        hasWordSync = try c.decodeIfPresent(Bool.self, forKey: .hasWordSync) ?? false
        lyricsfile = try c.decodeIfPresent(String.self, forKey: .lyricsfile)
    }

    private enum CodingKeys: String, CodingKey {
        case id, trackName, artistName, albumName, duration, instrumental, plainLyrics, syncedLyrics, hasWordSync, lyricsfile
    }

    /// A candidate; nil without an id or a title. Word timing only when the record has it.
    func toCandidate() -> LyricsCandidate? {
        guard let id, let title = trackName, !title.isBlank else { return nil }
        return LyricsCandidate(
            provider: LrclibProvider.providerName, providerId: id, trackName: title, artistName: artistName ?? "", albumName: albumName,
            durationSec: duration, instrumental: instrumental || Lyricsfile.isInstrumental(lyricsfile),
            plainLyrics: plainLyrics?.nonBlank, syncedLyrics: syncedLyrics?.nonBlank,
            wordSyncedLrc: hasWordSync ? Lyricsfile.toEnhancedLrc(lyricsfile) : nil
        )
    }
}

/// LRCLIB (https://lrclib.net/docs). One request at a time, a short gap between them, and after a
/// 429 no request at all until its Retry-After has passed. Only the track's title, artist, album and
/// duration are sent. Word timing is taken only from the Lyricsfile when LRCLIB says it has it.
actor LrclibProvider: OnlineLyricsProvider {
    static let providerName = "LRCLIB"
    nonisolated let name = LrclibProvider.providerName
    private static let base = URL(string: "https://lrclib.net/")!
    static let defaultRetryMs: Int64 = 60_000

    private let http: HTTPClient
    private let now: @Sendable () -> Int64
    private let minGapMs: Int64
    private let retryDelayMs: Int64
    private var lastRequestMs: Int64 = 0
    private var blockedUntilMs: Int64 = 0
    private var tail: Task<Void, Never>?

    init(http: HTTPClient = URLSessionHTTPClient(cachePolicy: .reloadIgnoringLocalCacheData), now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         minGapMs: Int64 = 400, retryDelayMs: Int64 = 750) {
        self.http = http
        self.now = now
        self.minGapMs = minGapMs
        self.retryDelayMs = max(retryDelayMs, 0)
    }

    func exact(_ query: LyricsQuery) async -> ProviderResponse<LyricsCandidate> {
        var items = [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist)]
        if let album = query.album, !album.isBlank { items.append(URLQueryItem(name: "album_name", value: album)) }
        if query.durationMs > 0 { items.append(URLQueryItem(name: "duration", value: String(Int((Double(query.durationMs) / 1000).rounded())))) }
        let response: ProviderResponse<LrclibRecord> = await call(path: "api/get", items: items)
        switch response {
        case .success(let record): return record.toCandidate().map { .success($0) } ?? .notFound
        case .notFound: return .notFound
        case .rateLimited(let at): return .rateLimited(retryAtMs: at)
        case .offline: return .offline
        case .failed(let reason): return .failed(reason)
        }
    }

    func search(_ query: LyricsQuery, freeText: String?) async -> ProviderResponse<[LyricsCandidate]> {
        let items = freeText.map { [URLQueryItem(name: "q", value: $0)] }
            ?? [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist)]
        let response: ProviderResponse<[LrclibRecord]> = await call(path: "api/search", items: items)
        switch response {
        case .success(let records): return .success(records.compactMap { $0.toCandidate() })
        case .notFound: return .notFound
        case .rateLimited(let at): return .rateLimited(retryAtMs: at)
        case .offline: return .offline
        case .failed(let reason): return .failed(reason)
        }
    }

    /// Requests run one after another, never overlapping.
    private func call<T: Decodable & Sendable>(path: String, items: [URLQueryItem]) async -> ProviderResponse<T> {
        let previous = tail
        let work = Task { () -> ProviderResponse<T> in
            await previous?.value
            guard !Task.isCancelled else { return .failed("cancelled") }
            return await self.perform(path: path, items: items)
        }
        tail = Task { _ = await work.value }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func perform<T: Decodable & Sendable>(path: String, items: [URLQueryItem]) async -> ProviderResponse<T> {
        var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return .failed("cancelled") }
            let start = now()
            if start < blockedUntilMs { return .rateLimited(retryAtMs: blockedUntilMs) }
            let wait = lastRequestMs + minGapMs - start
            do {
                if wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
                try Task.checkCancellation()
                lastRequestMs = now()
                let (data, response) = try await http.get(components.url!, headers: LyricsHTTP.headers)
                switch response.statusCode {
                case 429:
                    blockedUntilMs = now() + retryAfterMs(response.value(forHTTPHeaderField: "Retry-After"))
                    return .rateLimited(retryAtMs: blockedUntilMs)
                case 404:
                    return .notFound
                case 200..<300:
                    do { return .success(try JSONDecoder().decode(T.self, from: data)) }
                    catch { return .failed("malformed response") }
                case 502, 503, 504:
                    // One bounded retry for transient gateways. Do not hammer an outage or
                    // ignore an explicit server wait, and never reuse a cached gateway page.
                    if let retry = response.value(forHTTPHeaderField: "Retry-After") {
                        blockedUntilMs = now() + retryAfterMs(retry)
                        return .rateLimited(retryAtMs: blockedUntilMs)
                    }
                    if attempt == 0 {
                        try await Task.sleep(for: .milliseconds(retryDelayMs))
                        continue
                    }
                    return .failed("HTTP \(response.statusCode)")
                default:
                    return .failed("HTTP \(response.statusCode)")
                }
            } catch {
                return LyricsHTTP.failure(error)
            }
        }
        return .failed("service unavailable")
    }

    /// Retry-After in seconds or as an HTTP date; a minute when missing or unreadable.
    nonisolated func retryAfterMs(_ header: String?, nowMs: Int64? = nil) -> Int64 {
        LyricsHTTP.retryAfterMs(header, nowMs: nowMs ?? now())
    }
}

/// Shared transport policy for lyrics services; files and other HTTP consumers keep their own
/// cache policy. Only track metadata is sent, and no unavailable service becomes a cached miss.
enum LyricsHTTP {
    static let headers = [
        "User-Agent": "Erhu/1.0.0 (https://github.com/MeezaUni/Erhu-iOS)",
        "Accept": "application/json", "Cache-Control": "no-cache",
    ]

    static func failure<T: Sendable>(_ error: Error) -> ProviderResponse<T> {
        if error is CancellationError { return .failed("cancelled") }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed: return .offline
            case .timedOut: return .failed("timed out")
            case .cancelled: return .failed("cancelled")
            default: return .failed(error.code.rawValue.description)
            }
        }
        return .failed(String(describing: type(of: error)))
    }

    static func retryAfterMs(_ header: String?, nowMs: Int64) -> Int64 {
        let maximum: Int64 = 3_600_000
        let value = header?.trimmed ?? ""
        if let seconds = Int64(value) {
            return Int64(min(max(Double(seconds) * 1000, 0), Double(maximum)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return LrclibProvider.defaultRetryMs }
        return Int64(min(max(date.timeIntervalSince1970 * 1000 - Double(nowMs), 0), Double(maximum)))
    }
}
