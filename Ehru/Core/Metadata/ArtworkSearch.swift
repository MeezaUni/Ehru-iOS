import Foundation

/// One artwork found online, with where it came from.
struct ArtworkCandidate: Identifiable, Hashable, Sendable {
    let url: String
    let source: String
    var id: String { url }
}

/// How [ArtworkSearch.selectDeezerArtist] decided.
enum DeezerArtistMatch: Equatable {
    case selected(artistId: Int64, pictureUrl: String)
    case rejected(String)
}

/// A Deezer artist profile as the search returns it.
struct DeezerArtist: Decodable, Equatable, Sendable {
    var id: Int64
    var name: String
    var pictureMedium: String?
    var pictureBig: String?
    var pictureXl: String?
    /// Followers on Deezer; used only to tell apart profiles that share one exact name.
    var nbFan: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case id, name
        case pictureMedium = "picture_medium"
        case pictureBig = "picture_big"
        case pictureXl = "picture_xl"
        case nbFan = "nb_fan"
    }

    init(id: Int64, name: String, pictureMedium: String? = nil, pictureBig: String? = nil, pictureXl: String? = nil, nbFan: Int64 = 0) {
        self.id = id
        self.name = name
        self.pictureMedium = pictureMedium
        self.pictureBig = pictureBig
        self.pictureXl = pictureXl
        self.nbFan = nbFan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pictureMedium = try c.decodeIfPresent(String.self, forKey: .pictureMedium)
        pictureBig = try c.decodeIfPresent(String.self, forKey: .pictureBig)
        pictureXl = try c.decodeIfPresent(String.self, forKey: .pictureXl)
        nbFan = try c.decodeIfPresent(Int64.self, forKey: .nbFan) ?? 0
    }
}

/// Album covers and artist photos from iTunes, the Cover Art Archive (MusicBrainz), Deezer and
/// Wikipedia / Wikimedia Commons. Only names are sent; nothing from the library is uploaded.
struct ArtworkSearch: Sendable {
    let client: HTTPClient

    init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    // MARK: Album covers

    /// Covers for an album from every source, best sources first, each image once.
    func albumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        async let iTunes = iTunesAlbumCovers(album: album, artist: artist)
        async let archive = coverArtArchive(album: album, artist: artist)
        async let deezer = deezerAlbumCovers(album: album, artist: artist)
        let all = await iTunes + archive + deezer
        var seen = Set<String>()
        return all.filter { seen.insert($0.url).inserted }
    }

    private func iTunesAlbumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Result: Decodable { var artworkUrl100: String?; var artworkUrl60: String? }
            var results: [Result] = []
        }
        let usableArtist = artist.flatMap { isUsableTag($0) ? $0 : nil }
        let term = [usableArtist, album].compactMap { $0 }.joined(separator: " ")
        guard !term.isBlank else { return [] }
        let response = try? await fetchJSON(Response.self, requestURL("https://itunes.apple.com/search", [("term", term), ("entity", "album"), ("limit", "10")]), client: client)
        return (response?.results ?? []).compactMap { ($0.artworkUrl100 ?? $0.artworkUrl60).map { ArtworkCandidate(url: ITunesProvider.upgradeArtwork($0), source: "iTunes") } }
    }

    private func coverArtArchive(album: String, artist: String?) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Group: Decodable { var id: String }
            var groups: [Group] = []
            enum CodingKeys: String, CodingKey { case groups = "release-groups" }
        }
        var query = "release:\"\(escapePhrase(album.trimmed))\""
        if let terms = artistSearchTerms(artist.flatMap { isUsableTag($0) ? $0 : nil }) { query += " AND artist:(\(terms))" }
        let response = try? await fetchJSON(Response.self, requestURL("https://musicbrainz.org/ws/2/release-group", [("query", query), ("fmt", "json"), ("limit", "5")]), client: client)
        return (response?.groups ?? []).map { ArtworkCandidate(url: MusicBrainzProvider.coverArtArchiveUrl($0.id), source: "Cover Art Archive") }
    }

    private func deezerAlbumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        struct Response: Decodable {
            struct Album: Decodable {
                var coverXl: String?
                var coverBig: String?
                enum CodingKeys: String, CodingKey { case coverXl = "cover_xl", coverBig = "cover_big" }
            }
            var data: [Album]?
        }
        let usableArtist = artist.flatMap { isUsableTag($0) ? $0 : nil }
        let query = usableArtist.map { "artist:\"\($0)\" album:\"\(album)\"" } ?? album
        let response = try? await fetchJSON(Response.self, requestURL("https://api.deezer.com/search/album", [("q", query)]), client: client)
        return (response?.data ?? []).compactMap { ($0.coverXl ?? $0.coverBig).map { ArtworkCandidate(url: $0, source: "Deezer") } }
    }

    // MARK: Artist photos

    /// Photos of an artist: Deezer profiles with exactly this name (most followed first, real photos
    /// only), then Wikipedia / Wikimedia Commons through the artist's MusicBrainz links.
    func artistPhotos(_ name: String) async -> [ArtworkCandidate] {
        guard isUsableTag(name) else { return [] }
        async let deezer = deezerArtistPhotos(name)
        async let wiki = wikimediaPhotos(name)
        let all = await deezer + wiki
        var seen = Set<String>()
        return all.filter { seen.insert($0.url).inserted }
    }

    func deezerArtists(_ name: String) async throws -> [DeezerArtist] {
        struct Response: Decodable {
            var data: [DeezerArtist]?
            var error: DeezerProvider.DeezerError?
        }
        // The plain name, not artist:"…": Deezer ranks the field query so that the exact artist is often missing.
        let response = try await fetchJSON(Response.self, requestURL("https://api.deezer.com/search/artist", [("q", name.trimmed), ("limit", "100")]), client: client)
        if let error = response.error { throw ProviderError(status: .failed, message: "Deezer: \(error.message ?? "artist search failed")") }
        guard let data = response.data else { throw ProviderError(status: .failed, message: "Deezer gave no results field") }
        return data
    }

    private func deezerArtistPhotos(_ name: String) async -> [ArtworkCandidate] {
        guard let artists = try? await deezerArtists(name) else { return [] }
        let key = Self.normalizeArtistName(name)
        let exact = artists.filter { Self.normalizeArtistName($0.name) == key }.sorted { $0.nbFan > $1.nbFan }
        return (exact.isEmpty ? artists : exact).compactMap(Self.realPicture).map { ArtworkCandidate(url: $0, source: "Deezer") }
    }

    /// Wikipedia page images and Wikidata (P18) portraits of the artist's MusicBrainz entries.
    private func wikimediaPhotos(_ name: String) async -> [ArtworkCandidate] {
        struct ArtistSearch: Decodable {
            struct Artist: Decodable { var id: String; var name: String; var score: Int? }
            var artists: [Artist] = []
        }
        struct Relations: Decodable {
            struct Relation: Decodable {
                struct Target: Decodable { var resource: String }
                var type: String
                var url: Target?
            }
            var relations: [Relation]?
        }
        var urls: [String] = []
        let query = "artist:\"\(escapePhrase(name.trimmed))\" OR alias:\"\(escapePhrase(name.trimmed))\""
        if let search = try? await fetchJSON(ArtistSearch.self, requestURL("https://musicbrainz.org/ws/2/artist", [("query", query), ("fmt", "json"), ("limit", "5")]), client: client) {
            let exact = search.artists.filter { ($0.score ?? 0) >= 80 && Self.normalizeArtistName($0.name) == Self.normalizeArtistName(name) }
            for artist in exact.prefix(2) {
                // MusicBrainz allows about one request a second.
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard let relations = try? await fetchJSON(Relations.self, requestURL("https://musicbrainz.org/ws/2/artist/\(artist.id)", [("inc", "url-rels"), ("fmt", "json")]), client: client)
                else { continue }
                for relation in relations.relations ?? [] {
                    guard let resource = relation.url?.resource else { continue }
                    let last = resource.components(separatedBy: "/").last ?? ""
                    if relation.type.lowercased() == "wikidata", last.uppercased().hasPrefix("Q") {
                        urls += await wikidataPortraits(last)
                    } else if relation.type.lowercased() == "wikipedia", !last.isEmpty {
                        urls += await wikipediaPageImages(titles: last.removingPercentEncoding ?? last)
                    }
                }
            }
        }
        urls += await wikipediaPageImages(titles: name.trimmed)
        return urls.map { ArtworkCandidate(url: $0, source: "Wikimedia") }
    }

    private func wikidataPortraits(_ qid: String) async -> [String] {
        guard let url = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json"),
              let answer = try? await client.get(url, headers: ["User-Agent": metadataUserAgent]), (200..<300).contains(answer.1.statusCode),
              let object = try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any],
              let entity = (object["entities"] as? [String: Any])?[qid] as? [String: Any],
              let claims = (entity["claims"] as? [String: Any])?["P18"] as? [[String: Any]]
        else { return [] }
        let preferred = claims.sorted { ($0["rank"] as? String == "preferred" ? 1 : 0) > ($1["rank"] as? String == "preferred" ? 1 : 0) }
        return preferred.compactMap { claim in
            guard let file = ((claim["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] as? String else { return nil }
            let encoded = file.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
            return "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=1000"
        }
    }

    private func wikipediaPageImages(titles: String) async -> [String] {
        struct Response: Decodable {
            struct Query: Decodable {
                struct Page: Decodable {
                    struct Thumbnail: Decodable { var source: String }
                    var thumbnail: Thumbnail?
                }
                var pages: [String: Page]?
            }
            var query: Query?
        }
        let url = requestURL("https://en.wikipedia.org/w/api.php", [("action", "query"), ("prop", "pageimages"), ("format", "json"),
                                                                   ("pithumbsize", "1000"), ("redirects", "1"), ("titles", titles)])
        guard let response = try? await fetchJSON(Response.self, url, client: client) else { return [] }
        return (response.query?.pages ?? [:]).values.compactMap { $0.thumbnail?.source }.map(Self.normalizeImageUrl)
    }

    static func normalizeImageUrl(_ url: String) -> String {
        let trimmed = url.trimmed
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") { return "https://" + trimmed.dropFirst(7) }
        return trimmed
    }

    // MARK: Automatic artist photos

    /// The top same-name profile needs this many times the fans of the next one.
    static let dominanceFactor: Int64 = 10

    /// Picks the Deezer profile that is safely [artistName], or rejects all of them: only profiles
    /// with exactly this name count; of several, the top one needs ten times the fans of the next;
    /// and it must have a real photo (never a fallback to a smaller duplicate). A wrong photo is
    /// worse than none.
    static func selectDeezerArtist(_ artistName: String, _ candidates: [DeezerArtist]) -> DeezerArtistMatch {
        let key = normalizeArtistName(artistName)
        let exact = candidates.filter { normalizeArtistName($0.name) == key }.enumerated()
            .sorted { $0.element.nbFan != $1.element.nbFan ? $0.element.nbFan > $1.element.nbFan : $0.offset < $1.offset }.map(\.element)
        guard let top = exact.first else { return .rejected("no exact-name profile") }
        if exact.count > 1, top.nbFan < dominanceFactor * max(exact[1].nbFan, 1) {
            return .rejected("ambiguous: \(exact.count) exact-name profiles, \(top.nbFan) vs \(exact[1].nbFan) fans")
        }
        guard let picture = realPicture(top) else { return .rejected("profile \(top.id) has no photo") }
        return .selected(artistId: top.id, pictureUrl: picture)
    }

    /// Harmless spelling differences only: NFKC, case, curly quotes, whitespace. "$ & , ." are kept,
    /// so "A$AP Rocky" and "Tyler, The Creator" stay distinct.
    static func normalizeArtistName(_ name: String) -> String {
        let quotes: [Character: Character] = ["\u{2018}": "'", "\u{2019}": "'", "\u{201B}": "'", "\u{02BC}": "'", "\u{2032}": "'",
                                              "\u{201C}": "\"", "\u{201D}": "\"", "\u{201F}": "\"", "\u{2033}": "\""]
        let straight = String(name.precomposedStringWithCompatibilityMapping.map { quotes[$0] ?? $0 })
        // Upper then lower case folds more than lowercasing alone (e.g. "ß" and "SS").
        return Regex16("\\s+").replacing(in: straight.uppercased().lowercased().trimmed, with: " ")
    }

    /// Deezer returns ".../images/artist//..." (no image hash) for a profile without a photo.
    static func realPicture(_ artist: DeezerArtist) -> String? {
        guard let url = [artist.pictureBig, artist.pictureXl, artist.pictureMedium].compactMap({ $0 }).first(where: { !$0.isBlank }),
              !url.contains("/artist//") else { return nil }
        return url
    }
}
