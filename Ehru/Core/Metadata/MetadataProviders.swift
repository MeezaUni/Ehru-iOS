import Foundation

/// Why a provider request failed, in terms the batch and the screen can act on. A network failure
/// is never "no results".
struct ProviderError: Error, Equatable {
    var status: ProviderStatus
    var message: String
    /// For rate limiting: what the provider asked us to wait (Retry-After), if it said.
    var retryAfterMs: Int64?
    /// Worth retrying the same request after a pause (connection or provider load, never the request itself).
    var retryable = false
    /// The provider won't serve this whole session (credentials rejected, not offered in this country).
    var sessionWide = false
}

/// Sorts any error from a provider request.
func classifyProviderFailure(_ error: Error) -> ProviderError {
    if let error = error as? ProviderError { return error }
    if let error = error as? URLError {
        switch error.code {
        case .timedOut:
            return ProviderError(status: .timedOut, message: "Request timed out", retryable: true)
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return ProviderError(status: .networkError, message: "Connection failed: \(error.localizedDescription)", retryable: true)
        default:
            return ProviderError(status: .failed, message: error.localizedDescription)
        }
    }
    if error is DecodingError { return ProviderError(status: .failed, message: "The provider's answer couldn't be read") }
    return ProviderError(status: .failed, message: error.localizedDescription)
}

/// Retry-After as seconds ("120") or an HTTP date; nil when unreadable.
func parseRetryAfterMs(_ value: String, now: Date = Date()) -> Int64? {
    if let seconds = Int64(value.trimmed) { return max(seconds * 1000, 0) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value.trimmed) else { return nil }
    return max(Int64(date.timeIntervalSince(now) * 1000), 0)
}

/// Bounded retries for transient provider failures: exponential backoff with jitter, a provider's
/// Retry-After respected when it is short; anything else fails at once.
struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var baseDelayMs: Int64 = 1_000
    var maxDelayMs: Int64 = 8_000
    var maxRetryAfterMs: Int64 = 30_000
    var jitter = 0.25

    func run<T>(_ block: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await block()
            } catch {
                let failure = classifyProviderFailure(error)
                guard let wait = delayBeforeRetry(attempt, failure) else { throw failure }
                try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                attempt += 1
            }
        }
    }

    /// The wait before attempt [attempt] + 1, or nil when [failure] must not be retried.
    func delayBeforeRetry(_ attempt: Int, _ failure: ProviderError, random: Double = Double.random(in: -1...1)) -> Int64? {
        guard failure.retryable, attempt < maxAttempts else { return nil }
        if let asked = failure.retryAfterMs { return asked <= maxRetryAfterMs ? asked : nil }
        let exponential = min(maxDelayMs, baseDelayMs << Int64(attempt - 1))
        let spread = Double(exponential) * jitter
        return (exponential + Int64(spread * random)).clamped(0, maxDelayMs)
    }
}

/// The user agent MusicBrainz asks every client to send.
let metadataUserAgent = "empee3/1.0.0 (https://github.com/lochanpthakke/empee3)"

/// GETs [url] and decodes the JSON answer, turning HTTP failures into [ProviderError]s.
func fetchJSON<T: Decodable>(_ type: T.Type, _ url: URL, client: HTTPClient, headers: [String: String] = [:]) async throws -> T {
    let (data, response) = try await client.get(url, headers: ["User-Agent": metadataUserAgent, "Accept": "application/json"].merging(headers) { $1 })
    try checkStatus(response)
    return try JSONDecoder().decode(T.self, from: data)
}

func checkStatus(_ response: HTTPURLResponse) throws {
    let code = response.statusCode
    guard !(200..<300).contains(code) else { return }
    let retryAfter = (response.value(forHTTPHeaderField: "Retry-After")).flatMap { parseRetryAfterMs($0) }
    switch code {
    case 429, 503: throw ProviderError(status: .rateLimited, message: "Rate limited (HTTP \(code))", retryAfterMs: retryAfter, retryable: true)
    case 401, 403: throw ProviderError(status: .authFailed, message: "Access refused (HTTP \(code))", sessionWide: true)
    case 500...: throw ProviderError(status: .failed, message: "Server error (HTTP \(code))", retryable: true)
    default: throw ProviderError(status: .failed, message: "HTTP \(code)")
    }
}

/// [base] with query items, "+" encoded too (servers read a bare "+" as a space).
func requestURL(_ base: String, _ items: [(String, String)]) -> URL {
    var components = URLComponents(string: base)!
    components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return components.url!
}

/// One source of track metadata.
protocol MetadataProvider: Sendable {
    var providerName: String { get }
    /// Candidates for a track; failures throw (they are reported as such, never as "no results").
    func searchTrack(title: String, artist: String?, album: String?) async throws -> [MetadataCandidate]
}

// MARK: - iTunes

struct ITunesProvider: MetadataProvider {
    let client: HTTPClient
    let providerName = "iTunes"

    struct Response: Decodable {
        var results: [Result] = []
    }

    struct Result: Decodable {
        var trackId: Int64?
        var collectionId: Int64?
        var trackName: String?
        var artistName: String?
        var collectionName: String?
        var trackTimeMillis: Int64?
        var artworkUrl100: String?
        var artworkUrl60: String?
        var releaseDate: String?
    }

    func searchTrack(title: String, artist: String?, album: String?) async throws -> [MetadataCandidate] {
        let term = [artist.flatMap { $0.isBlank || $0 == "Unknown Artist" ? nil : $0 }, title.isBlank ? nil : title]
            .compactMap { $0 }.joined(separator: " ").trimmed
        guard !term.isEmpty else { return [] }
        let response = try await fetchJSON(Response.self, requestURL("https://itunes.apple.com/search", [("term", term), ("entity", "song"), ("limit", "10")]), client: client)
        return Self.candidates(response)
    }

    static func candidates(_ response: Response, today: Date = Date()) -> [MetadataCandidate] {
        response.results.compactMap { result in
            guard let name = result.trackName, !name.isBlank else { return nil }
            let date = result.releaseDate.flatMap { ReleaseDate.parse(String($0.prefix(10)), today: today) }
            let id = result.trackId ?? result.collectionId ?? Int64(javaHashCode(name))
            return MetadataCandidate(
                id: "itunes_\(id)", title: name, artist: result.artistName ?? "", album: result.collectionName ?? "",
                year: date?.year ?? 0, durationMs: result.trackTimeMillis,
                coverArtUrl: (result.artworkUrl100 ?? result.artworkUrl60).map(upgradeArtwork), sourceName: "iTunes",
                releaseDate: date?.tagValue
            )
        }
    }

    /// The 1000 px version of an iTunes artwork URL.
    static func upgradeArtwork(_ url: String) -> String {
        url.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
            .replacingOccurrences(of: "60x60bb", with: "1000x1000bb")
            .replacingOccurrences(of: "100x100", with: "1000x1000")
    }
}

// MARK: - MusicBrainz

struct MusicBrainzSearchResponse: Decodable {
    var recordings: [Recording] = []

    struct Recording: Decodable {
        var id: String
        var title: String
        var length: Int64?
        var disambiguation: String?
        var artistCredit: [Credit] = []
        var releases: [Release] = []

        enum CodingKeys: String, CodingKey {
            case id, title, length, disambiguation, releases
            case artistCredit = "artist-credit"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            length = try c.decodeIfPresent(Int64.self, forKey: .length)
            disambiguation = try c.decodeIfPresent(String.self, forKey: .disambiguation)
            artistCredit = try c.decodeIfPresent([Credit].self, forKey: .artistCredit) ?? []
            releases = try c.decodeIfPresent([Release].self, forKey: .releases) ?? []
        }

        init(id: String, title: String, length: Int64? = nil, disambiguation: String? = nil, artistCredit: [Credit] = [], releases: [Release] = []) {
            self.id = id
            self.title = title
            self.length = length
            self.disambiguation = disambiguation
            self.artistCredit = artistCredit
            self.releases = releases
        }
    }

    struct Credit: Decodable {
        var name: String
        var joinPhrase: String?

        enum CodingKeys: String, CodingKey {
            case name
            case joinPhrase = "joinphrase"
        }
    }

    struct Release: Decodable {
        var id: String
        var title: String
        var date: String?
        /// "Official", "Promotion", "Bootleg", "Pseudo-Release"; absent when unknown.
        var status: String?
        var releaseGroup: ReleaseGroup?

        enum CodingKeys: String, CodingKey {
            case id, title, date, status
            case releaseGroup = "release-group"
        }
    }

    struct ReleaseGroup: Decodable {
        var id: String
        var primaryType: String?
        /// e.g. "Compilation", "Live", "Mixtape/Street", "Remix".
        var secondaryTypes: [String] = []

        enum CodingKeys: String, CodingKey {
            case id
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            primaryType = try c.decodeIfPresent(String.self, forKey: .primaryType)
            secondaryTypes = try c.decodeIfPresent([String].self, forKey: .secondaryTypes) ?? []
        }

        init(id: String, primaryType: String? = nil, secondaryTypes: [String] = []) {
            self.id = id
            self.primaryType = primaryType
            self.secondaryTypes = secondaryTypes
        }
    }
}

struct MusicBrainzGenre: Decodable, Equatable {
    var name: String
    var count = 0
}

/// MusicBrainz recording search, with its one-request-per-second limit kept for the whole app.
actor MusicBrainzProvider: MetadataProvider {
    nonisolated let providerName = "MusicBrainz"
    private let client: HTTPClient
    private var lastRequest: Date = .distantPast
    private var genresByReleaseGroup: [String: [MusicBrainzGenre]] = [:]
    private static let minInterval: TimeInterval = 1.1

    init(client: HTTPClient) {
        self.client = client
    }

    func searchTrack(title: String, artist: String?, album: String?) async throws -> [MetadataCandidate] {
        let query = Self.recordingQuery(title: title, artist: artist, album: album)
        let response = try await throttled {
            try await fetchJSON(MusicBrainzSearchResponse.self, requestURL("https://musicbrainz.org/ws/2/recording", [("query", query), ("fmt", "json")]), client: self.client)
        }
        return Self.candidates(response, targetAlbum: album)
    }

    /// Curated genres (with vote counts) of a release group; cached for the session. Throws on failure.
    func releaseGroupGenres(_ id: String) async throws -> [MusicBrainzGenre] {
        if let cached = genresByReleaseGroup[id] { return cached }
        struct Response: Decodable { var genres: [MusicBrainzGenre]? }
        let response = try await throttled {
            try await fetchJSON(Response.self, requestURL("https://musicbrainz.org/ws/2/release-group/\(id)", [("inc", "genres"), ("fmt", "json")]), client: self.client)
        }
        let genres = response.genres ?? []
        genresByReleaseGroup[id] = genres
        return genres
    }

    /// Runs [request] at least [minInterval] after the previous one (MusicBrainz answers faster
    /// callers with 503). The slot is taken before waiting, so concurrent callers queue up.
    private func throttled<T>(_ request: @Sendable () async throws -> T) async throws -> T {
        let start = max(Date(), lastRequest.addingTimeInterval(Self.minInterval))
        lastRequest = start
        let wait = start.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return try await request()
    }

    /// The Lucene query for a recording: the title as an escaped phrase, plus the artist credit as
    /// words, or the album as a phrase when there is no artist.
    static func recordingQuery(title: String, artist: String?, album: String?) -> String {
        let terms = artistSearchTerms(artist.flatMap { $0.lowercased() == "unknown artist" ? nil : $0 })
        let release = album?.trimmed.nonBlank.flatMap { $0.lowercased() == "unknown album" ? nil : $0 }
        let recording = "recording:\"\(escapePhrase(title.trimmed))\""
        if let terms { return "\(recording) AND artist:(\(terms))" }
        if let release { return "\(recording) AND release:\"\(escapePhrase(release))\"" }
        return recording
    }

    /// Front cover of a release group from the Cover Art Archive; 404 when it has none.
    static func coverArtArchiveUrl(_ releaseGroupId: String) -> String {
        "https://coverartarchive.org/release-group/\(releaseGroupId)/front-500"
    }

    /// Maps a recording search. Each candidate takes its album, year and artwork from the release
    /// that best fits; recordings whose best release is official and plain come first.
    static func candidates(_ response: MusicBrainzSearchResponse, targetAlbum: String?, today: Date = Date()) -> [MetadataCandidate] {
        let paired = response.recordings.map { ($0, bestRelease($0.releases, targetAlbum: targetAlbum)) }
        let plainFirst = paired.enumerated().sorted { a, b in
            let rankA = a.element.1.map(isPlainOfficial) == true ? 0 : 1
            let rankB = b.element.1.map(isPlainOfficial) == true ? 0 : 1
            return rankA != rankB ? rankA < rankB : a.offset < b.offset
        }.map(\.element)
        return plainFirst.map { recording, release in
            let (date, issue) = releaseDate(recording, chosen: release, targetAlbum: targetAlbum, today: today)
            var candidate = toCandidate(recording, release)
            candidate.year = date?.year ?? 0
            candidate.releaseDate = date?.tagValue
            candidate.releaseDateIssue = issue
            return candidate
        }
    }

    /// The original release date of [chosen]'s album for this recording, or the reason there is none.
    static func releaseDate(_ recording: MusicBrainzSearchResponse.Recording, chosen: MusicBrainzSearchResponse.Release?,
                            targetAlbum: String?, today: Date) -> (ReleaseDate?, String?) {
        guard let chosen else { return (nil, "MusicBrainz lists no release for this recording") }
        guard chosen.status?.lowercased() == "official" else {
            return (nil, "MusicBrainz lists this recording only on unofficial releases (\(chosen.status ?? "status unknown"))")
        }
        let secondary = chosen.releaseGroup?.secondaryTypes ?? []
        let isTaggedAlbum = targetAlbum.map { chosen.title.trimmed.lowercased() == $0.trimmed.lowercased() } ?? false
        if !secondary.isEmpty && !isTaggedAlbum {
            return (nil, "MusicBrainz lists this recording only on \(secondary.joined(separator: "/").lowercased()) releases")
        }
        let groupId = chosen.releaseGroup?.id
        let raw = recording.releases
            .filter { $0.status?.lowercased() == "official" }
            .filter { groupId == nil ? $0.id == chosen.id : $0.releaseGroup?.id == groupId }
            .compactMap { $0.date?.trimmed.nonBlank }
        guard let first = raw.first else { return (nil, "MusicBrainz has no release date for \"\(chosen.title)\"") }
        guard let earliest = ReleaseDate.earliest(raw.compactMap { ReleaseDate.parse($0, today: today) }) else {
            return (nil, "MusicBrainz's release date isn't a valid date (\"\(first)\")")
        }
        return (earliest, nil)
    }

    static func bestRelease(_ releases: [MusicBrainzSearchResponse.Release], targetAlbum: String?) -> MusicBrainzSearchResponse.Release? {
        let wanted = targetAlbum?.trimmed.lowercased().nonBlank.flatMap { $0 == "unknown album" ? nil : $0 }
        func key(_ release: MusicBrainzSearchResponse.Release) -> [String] {
            [
                wanted != nil && release.title.trimmed.lowercased() == wanted ? "0" : "1",
                String(statusRank(release.status)),
                (release.releaseGroup?.secondaryTypes ?? []).isEmpty ? "0" : "1",
                String(primaryTypeRank(release.releaseGroup?.primaryType)),
                release.date?.nonBlank ?? "9999",
            ]
        }
        // The first of equally ranked releases wins (as Kotlin's minWith).
        var best: MusicBrainzSearchResponse.Release?
        var bestKey: [String] = []
        for release in releases {
            let k = key(release)
            if best == nil || k.lexicographicallyPrecedes(bestKey) {
                best = release
                bestKey = k
            }
        }
        return best
    }

    private static func isPlainOfficial(_ release: MusicBrainzSearchResponse.Release) -> Bool {
        release.status?.lowercased() == "official" && (release.releaseGroup?.secondaryTypes ?? []).isEmpty
    }

    private static func statusRank(_ status: String?) -> Int {
        switch status?.lowercased() {
        case "official": 0
        case nil: 1
        case "promotion": 2
        default: 3
        }
    }

    private static func primaryTypeRank(_ type: String?) -> Int {
        switch type?.lowercased() {
        case "album": 0
        case "ep": 1
        case "single": 2
        default: 3
        }
    }

    private static func toCandidate(_ recording: MusicBrainzSearchResponse.Recording, _ release: MusicBrainzSearchResponse.Release?) -> MetadataCandidate {
        let credits = recording.artistCredit
        let artist = credits.contains { !($0.joinPhrase ?? "").isEmpty }
            ? credits.map { $0.name + ($0.joinPhrase ?? "") }.joined().trimmed
            : credits.map(\.name).joined(separator: ", ").trimmed
        let groupId = release?.releaseGroup?.id
        return MetadataCandidate(
            id: "mb_\(recording.id)", title: recording.title, artist: artist, album: release?.title ?? "",
            durationMs: recording.length, coverArtUrl: groupId.map(coverArtArchiveUrl), sourceName: "MusicBrainz",
            releaseGroupId: groupId, versionNote: recording.disambiguation?.trimmed.nonBlank
        )
    }
}

// MARK: - Deezer

struct DeezerProvider: MetadataProvider {
    let client: HTTPClient
    let providerName = "Deezer"

    struct SearchResponse: Decodable {
        var data: [Track] = []
        /// Matches counted before filtering by country: where Deezer isn't offered, searches answer
        /// a total with no data.
        var total = 0
        var error: DeezerError?

        enum CodingKeys: String, CodingKey { case data, total, error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            data = try c.decodeIfPresent([Track].self, forKey: .data) ?? []
            total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
            error = try c.decodeIfPresent(DeezerError.self, forKey: .error)
        }

        init(data: [Track], total: Int, error: DeezerError? = nil) {
            self.data = data
            self.total = total
            self.error = error
        }
    }

    struct DeezerError: Decodable {
        var message: String?
    }

    struct Track: Decodable {
        var id: Int64
        var title: String
        var titleVersion: String?
        var duration: Int64?
        var bpm: Double?
        var artist: Named?
        var album: Album?

        enum CodingKeys: String, CodingKey {
            case id, title, duration, bpm, artist, album
            case titleVersion = "title_version"
        }
    }

    struct Named: Decodable {
        var name: String
    }

    struct Album: Decodable {
        var id: Int64
        var title: String
        var coverXl: String?
        var coverBig: String?
        var coverMedium: String?

        enum CodingKeys: String, CodingKey {
            case id, title
            case coverXl = "cover_xl"
            case coverBig = "cover_big"
            case coverMedium = "cover_medium"
        }
    }

    func searchTrack(title: String, artist: String?, album: String?) async throws -> [MetadataCandidate] {
        let query = Self.query(title: title, artist: artist, album: album)
        return try Self.candidates(try await fetchJSON(SearchResponse.self, requestURL("https://api.deezer.com/search", [("q", query)]), client: client))
    }

    /// Genres of a Deezer album (Deezer has no per-track genre). Throws when the lookup fails.
    func albumGenres(_ albumId: Int64) async throws -> [String] {
        struct Detail: Decodable {
            struct Genres: Decodable { var data: [Named]? }
            var genres: Genres?
            var error: DeezerError?
        }
        let detail = try await fetchJSON(Detail.self, URL(string: "https://api.deezer.com/album/\(albumId)")!, client: client)
        if let error = detail.error { throw ProviderError(status: .failed, message: "Deezer: \(error.message ?? "album lookup failed")") }
        return (detail.genres?.data ?? []).map(\.name.trimmed).filter { !$0.isEmpty }
    }

    /// Maps a track search. An error, or matches counted but none returned (results withheld in this
    /// country), is reported as such, never as "no such track".
    static func candidates(_ response: SearchResponse) throws -> [MetadataCandidate] {
        if let error = response.error { throw ProviderError(status: .failed, message: "Deezer: \(error.message ?? "search failed")") }
        if response.data.isEmpty && response.total > 0 {
            throw ProviderError(status: .unavailable,
                                message: "Deezer found \(response.total) matches but returned none: track search isn't available in this country",
                                sessionWide: true)
        }
        return response.data.map { track in
            MetadataCandidate(
                id: "deezer_\(track.id)", title: track.title, artist: track.artist?.name ?? "", album: track.album?.title ?? "",
                // Search results rarely carry a BPM; only a real value is kept.
                bpm: track.bpm.map { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                durationMs: track.duration.map { $0 * 1000 },
                coverArtUrl: track.album.flatMap { $0.coverXl ?? $0.coverBig ?? $0.coverMedium }, sourceName: "Deezer",
                deezerAlbumId: track.album?.id,
                versionNote: track.titleVersion?.trimmed.nonBlank.flatMap { track.title.lowercased().contains($0.lowercased()) ? nil : $0 }
            )
        }
    }

    /// Deezer's advanced search. A credit flattened with "/" is no artist name Deezer knows, so the
    /// album narrows the search instead.
    static func query(title: String, artist: String?, album: String?) -> String {
        func phrase(_ text: String) -> String { "\"\(text.trimmed.replacingOccurrences(of: "\"", with: ""))\"" }
        let usableArtist = artist.flatMap { $0.isBlank || $0.lowercased() == "unknown artist" || $0.contains("/") ? nil : $0 }
        let usableAlbum = album.flatMap { $0.isBlank || $0.lowercased() == "unknown album" ? nil : $0 }
        if let usableArtist { return "artist:\(phrase(usableArtist)) track:\(phrase(title))" }
        if let usableAlbum { return "album:\(phrase(usableAlbum)) track:\(phrase(title))" }
        return title.trimmed
    }
}
