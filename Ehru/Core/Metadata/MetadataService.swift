import Foundation

/// Provider names as stored in settings ("ALL", "iTunes", "MusicBrainz", "Deezer").
enum MetadataSources {
    static let all = "ALL"
    static let iTunes = "iTunes"
    static let musicBrainz = "MusicBrainz"
    static let deezer = "Deezer"

    /// The choices offered for Fix Tags.
    static let options: [(key: String, label: String)] = [(all, "All sources"), (iTunes, "iTunes"), (musicBrainz, "MusicBrainz"), (deezer, "Deezer")]

    static func matches(_ provider: String, _ selection: String) -> Bool {
        selection.lowercased() == all.lowercased() || provider.lowercased() == selection.lowercased()
    }
}

/// Outcome of a genre lookup for a matched track.
enum GenreLookup: Equatable {
    /// Every usable genre the source lists, most-voted first where it ranks them.
    case found([String], source: String)
    case notFound(String)
    case failed(String)
}

/// Whether a provider may be asked at all this session.
enum ProviderAvailability: Equatable {
    case available
    /// Its credentials were rejected earlier this session: not called again.
    case rejected(String)
    /// It said earlier this session that it doesn't serve this country: not called again.
    case unavailable(String)
}

/// Searches the metadata providers together, looks up genres and downloads artwork. Providers that
/// can't help for the rest of the session (rejected, not offered here) are remembered, so later
/// tracks get the same truthful status without asking again.
actor MetadataService {
    static let maxArtworkBytes = 10 * 1024 * 1024

    private let client: HTTPClient
    private let iTunes: ITunesProvider
    private let musicBrainz: MusicBrainzProvider
    private let deezer: DeezerProvider
    private let retry: RetryPolicy
    private var unusable: [String: ProviderAvailability] = [:]

    init(client: HTTPClient = URLSessionHTTPClient(), retry: RetryPolicy = RetryPolicy()) {
        self.client = client
        self.retry = retry
        iTunes = ITunesProvider(client: client)
        musicBrainz = MusicBrainzProvider(client: client)
        deezer = DeezerProvider(client: client)
    }

    private var providers: [MetadataProvider] { [iTunes, musicBrainz, deezer] }

    /// Every provider's scored candidates and outcome for one query.
    func search(title: String, artist: String?, album: String?, durationMs: Int64?, selection: String) async -> SearchResponse {
        let list = providers
        let availability = list.map { unusable[$0.providerName] ?? .available }
        let retry = retry
        let results = await withTaskGroup(of: (Int, [MetadataCandidate], ProviderOutcome).self) { group in
            for (index, provider) in list.enumerated() {
                group.addTask {
                    let (candidates, outcome) = await Self.searchOne(provider, selection: selection, availability: availability[index],
                                                                     title: title, artist: artist, album: album, durationMs: durationMs, retry: retry)
                    return (index, candidates, outcome)
                }
            }
            var collected: [(Int, [MetadataCandidate], ProviderOutcome)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        for (_, _, outcome) in results {
            switch outcome.status {
            case .authFailed: unusable[outcome.providerName] = .rejected(outcome.errorMessage ?? "Credentials rejected")
            case .unavailable: unusable[outcome.providerName] = .unavailable(outcome.errorMessage ?? "Not available here")
            default: break
            }
        }
        let candidates = results.flatMap(\.1).enumerated().sorted { a, b in
            a.element.confidenceScore != b.element.confidenceScore ? a.element.confidenceScore > b.element.confidenceScore : a.offset < b.offset
        }.map(\.element)
        return SearchResponse(candidates: candidates, outcomes: results.map(\.2))
    }

    /// One provider's part of a search: skipped when not selected, not asked again after a
    /// session-wide refusal, else run under [retry] with the failure kept in its real category.
    static func searchOne(_ provider: MetadataProvider, selection: String, availability: ProviderAvailability,
                          title: String, artist: String?, album: String?, durationMs: Int64?,
                          retry: RetryPolicy) async -> ([MetadataCandidate], ProviderOutcome) {
        let name = provider.providerName
        guard MetadataSources.matches(name, selection) else {
            return ([], ProviderOutcome(providerName: name, status: .skipped, errorMessage: "Not selected (source: \(selection))"))
        }
        switch availability {
        case .rejected(let reason): return ([], ProviderOutcome(providerName: name, status: .authFailed, errorMessage: "\(reason) (not retried)"))
        case .unavailable(let reason): return ([], ProviderOutcome(providerName: name, status: .unavailable, errorMessage: "\(reason) (not asked again)"))
        case .available: break
        }
        do {
            let found = try await retry.run { try await provider.searchTrack(title: title, artist: artist, album: album) }
            let scored = found.map { MetadataScorer.score($0, title: title, artist: artist, album: album, durationMs: durationMs) }
            let top = scored.map(\.confidenceScore).max() ?? 0
            let status: ProviderStatus = scored.isEmpty ? .noResults : top >= highConfidenceThreshold ? .success : .lowConfidence
            return (scored, ProviderOutcome(providerName: name, candidateCount: scored.count, status: status))
        } catch {
            // Credentials rejected or not offered here: the caller remembers it for the session.
            let failure = classifyProviderFailure(error)
            return ([], ProviderOutcome(providerName: name, status: failure.status, errorMessage: failure.message))
        }
    }

    /// The genre of a confident match: MusicBrainz's curated release-group genres (every usable one,
    /// most-voted first), or the Deezer album's. Album-level, never invented.
    func lookupGenre(_ match: MetadataCandidate) async -> GenreLookup {
        do {
            if let groupId = match.releaseGroupId {
                return Self.genre(fromMusicBrainz: try await musicBrainz.releaseGroupGenres(groupId))
            }
            if let albumId = match.deezerAlbumId {
                let genres = Genres.normalize(try await deezer.albumGenres(albumId).map { Optional($0) })
                return genres.isEmpty ? .notFound("Deezer lists no genre for this album") : .found(genres, source: "Deezer album")
            }
            return .notFound("\(match.sourceName) doesn't provide genres")
        } catch {
            return .failed(classifyProviderFailure(error).message)
        }
    }

    static func genre(fromMusicBrainz genres: [MusicBrainzGenre]) -> GenreLookup {
        // A genre voted down to zero or below is not one MusicBrainz vouches for. Ties keep MusicBrainz's order.
        let ranked = genres.enumerated().filter { $0.element.count > 0 }
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map { Optional($0.element.name) }
        let usable = Genres.normalize(ranked)
        return usable.isEmpty ? .notFound("MusicBrainz has no genre for this album") : .found(usable, source: "MusicBrainz release group")
    }

    /// Downloads an image for embedding; fails rather than returning a non-image.
    func downloadArtwork(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw ProviderError(status: .failed, message: "Not a valid artwork address") }
        let (data, response) = try await client.get(url, headers: ["User-Agent": metadataUserAgent])
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError(status: .failed, message: "Artwork download failed: HTTP \(response.statusCode)")
        }
        if let type = response.value(forHTTPHeaderField: "Content-Type"), !type.lowercased().hasPrefix("image") {
            throw ProviderError(status: .failed, message: "Artwork address is not an image (\(type))")
        }
        guard !data.isEmpty, data.count <= Self.maxArtworkBytes else { throw ProviderError(status: .failed, message: "Artwork has an invalid size") }
        return data
    }
}
