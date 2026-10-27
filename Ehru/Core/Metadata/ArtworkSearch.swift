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

/// Album covers and artist photos from iTunes, the Cover Art Archive (MusicBrainz), Deezer,
/// Wikipedia / Wikimedia Commons, and, with the listener's own keys, Fanart.tv and Discogs. Only
/// names (and MusicBrainz ids) are sent; nothing from the library is uploaded.
struct ArtworkSearch: Sendable {
    let client: HTTPClient
    /// The listener's own keys (Settings › Online sources); a source without one is skipped.
    let key: @Sendable (APIKeyKind) -> String?

    init(client: HTTPClient = URLSessionHTTPClient(), key: @escaping @Sendable (APIKeyKind) -> String? = { APIKeys.shared.value($0) }) {
        self.client = client
        self.key = key
    }

    // MARK: Album covers

    /// Covers for an album from every source, best sources first, each image once.
    func albumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        async let iTunes = iTunesAlbumCovers(album: album, artist: artist)
        async let groups = releaseGroups(album: album, artist: artist)
        async let deezer = deezerAlbumCovers(album: album, artist: artist)
        async let discogs = discogsAlbumCovers(album: album, artist: artist)
        let groupIds = await groups
        let archive = groupIds.map { ArtworkCandidate(url: MusicBrainzProvider.coverArtArchiveUrl($0), source: "Cover Art Archive") }
        let fanart = await fanartAlbumCovers(groupIds)
        let all = await iTunes + archive + fanart + deezer + discogs
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

    /// MusicBrainz release groups for an album (their covers live in the Cover Art Archive and on Fanart.tv).
    private func releaseGroups(album: String, artist: String?) async -> [String] {
        struct Response: Decodable {
            struct Group: Decodable { var id: String }
            var groups: [Group] = []
            enum CodingKeys: String, CodingKey { case groups = "release-groups" }
        }
        var query = "release:\"\(escapePhrase(album.trimmed))\""
        if let terms = artistSearchTerms(artist.flatMap { isUsableTag($0) ? $0 : nil }) { query += " AND artist:(\(terms))" }
        let response = try? await fetchJSON(Response.self, requestURL("https://musicbrainz.org/ws/2/release-group", [("query", query), ("fmt", "json"), ("limit", "5")]), client: client)
        return (response?.groups ?? []).map(\.id)
    }

    /// Fanart.tv covers of the first release groups that have any.
    private func fanartAlbumCovers(_ groupIds: [String]) async -> [ArtworkCandidate] {
        guard let apiKey = key(.fanartTv) else { return [] }
        var urls: [String] = []
        for id in groupIds.prefix(3) {
            guard let object = await json(requestURL("https://webservice.fanart.tv/v3/music/albums/\(id)", [("api_key", apiKey)])),
                  let albums = object["albums"] as? [String: Any]
            else { continue }
            for case let album as [String: Any] in albums.values {
                urls += Self.fanartUrls(album["albumcover"])
            }
            if !urls.isEmpty { break }
        }
        return urls.map { ArtworkCandidate(url: $0, source: "Fanart.tv") }
    }

    /// Image addresses of a Fanart.tv list, most liked first, over https.
    static func fanartUrls(_ list: Any?) -> [String] {
        func likes(_ image: [String: Any]) -> Int { Int(image["likes"] as? String ?? "") ?? 0 }
        let images = (list as? [[String: Any]]) ?? []
        let ranked = images.enumerated().sorted { a, b in
            likes(a.element) != likes(b.element) ? likes(a.element) > likes(b.element) : a.offset < b.offset
        }
        return ranked.compactMap { ($0.element["url"] as? String)?.replacingOccurrences(of: "http://", with: "https://") }
    }

    private func discogsAlbumCovers(album: String, artist: String?) async -> [ArtworkCandidate] {
        guard let token = key(.discogs) else { return [] }
        var items = [("type", "release"), ("release_title", album), ("per_page", "10")]
        if let artist = artist.flatMap({ isUsableTag($0) ? $0 : nil }) { items.append(("artist", artist)) }
        guard let object = await json(requestURL("https://api.discogs.com/database/search", items), headers: Self.discogsHeaders(token)) else { return [] }
        return Self.discogsImages(object["results"], keys: ["cover_image"]).map { ArtworkCandidate(url: $0, source: "Discogs") }
    }

    static func discogsHeaders(_ token: String) -> [String: String] { ["Authorization": "Discogs token=\(token)"] }

    /// Usable image addresses from Discogs results (its blank "spacer.gif" left out).
    static func discogsImages(_ list: Any?, keys: [String]) -> [String] {
        ((list as? [[String: Any]]) ?? []).compactMap { item in keys.lazy.compactMap { item[$0] as? String }.first }
            .filter { !$0.isBlank && !$0.lowercased().hasSuffix(".gif") }
    }

    /// A GET answered with a JSON object, or nil.
    private func json(_ url: URL, headers: [String: String] = [:]) async -> [String: Any]? {
        guard let answer = try? await client.get(url, headers: ["User-Agent": metadataUserAgent].merging(headers) { $1 }),
              (200..<300).contains(answer.1.statusCode)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: answer.0) as? [String: Any]
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
        async let links = musicBrainzLinks(name)
        let found = await links
        async let wiki = wikimediaPhotos(name, links: found)
        async let fanart = fanartArtistPhotos(found)
        async let discogs = discogsArtistPhotos(name, links: found)
        let all = await deezer + fanart + discogs + wiki
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
    /// What MusicBrainz links to an artist: its id and its URL relations (Wikipedia, Wikidata, Discogs).
    struct ArtistLinks: Sendable {
        let mbid: String
        let relations: [(type: String, resource: String)]
    }

    /// The MusicBrainz entries named exactly [name] (at most two) with their links.
    private func musicBrainzLinks(_ name: String) async -> [ArtistLinks] {
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
        let query = "artist:\"\(escapePhrase(name.trimmed))\" OR alias:\"\(escapePhrase(name.trimmed))\""
        guard let search = try? await fetchJSON(ArtistSearch.self, requestURL("https://musicbrainz.org/ws/2/artist", [("query", query), ("fmt", "json"), ("limit", "5")]), client: client)
        else { return [] }
        let exact = search.artists.filter { ($0.score ?? 0) >= 80 && Self.normalizeArtistName($0.name) == Self.normalizeArtistName(name) }
        var links: [ArtistLinks] = []
        for artist in exact.prefix(2) {
            // MusicBrainz allows about one request a second.
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            let relations = try? await fetchJSON(Relations.self, requestURL("https://musicbrainz.org/ws/2/artist/\(artist.id)", [("inc", "url-rels"), ("fmt", "json")]), client: client)
            let pairs = (relations?.relations ?? []).compactMap { relation in relation.url.map { (type: relation.type.lowercased(), resource: $0.resource) } }
            links.append(ArtistLinks(mbid: artist.id, relations: pairs))
        }
        return links
    }

    /// Wikipedia page images and Wikidata (P18) portraits of the artist's MusicBrainz entries.
    private func wikimediaPhotos(_ name: String, links: [ArtistLinks]) async -> [ArtworkCandidate] {
        var urls: [String] = []
        for relation in links.flatMap(\.relations) {
            let last = relation.resource.components(separatedBy: "/").last ?? ""
            if relation.type == "wikidata", last.uppercased().hasPrefix("Q") {
                urls += await wikidataPortraits(last)
            } else if relation.type == "wikipedia", !last.isEmpty {
                urls += await wikipediaPageImages(titles: last.removingPercentEncoding ?? last)
            }
        }
        urls += await wikipediaPageImages(titles: name.trimmed)
        return urls.map { ArtworkCandidate(url: $0, source: "Wikimedia") }
    }

    /// Fanart.tv artist thumbnails and backgrounds, most liked first, for the first entry that has any.
    private func fanartArtistPhotos(_ links: [ArtistLinks]) async -> [ArtworkCandidate] {
        guard let apiKey = key(.fanartTv) else { return [] }
        for link in links {
            guard let object = await json(requestURL("https://webservice.fanart.tv/v3/music/\(link.mbid)", [("api_key", apiKey)])) else { continue }
            let urls = Self.fanartUrls(object["artistthumb"]) + Self.fanartUrls(object["artistbackground"])
            if !urls.isEmpty { return urls.map { ArtworkCandidate(url: $0, source: "Fanart.tv") } }
        }
        return []
    }

    /// Discogs images of the artist MusicBrainz links to, else of a Discogs artist search.
    private func discogsArtistPhotos(_ name: String, links: [ArtistLinks]) async -> [ArtworkCandidate] {
        guard let token = key(.discogs) else { return [] }
        let headers = Self.discogsHeaders(token)
        let ids = links.flatMap(\.relations).filter { $0.type == "discogs" }.compactMap { Self.discogsArtistId($0.resource) }
        for id in ids {
            guard let detail = await json(URL(string: "https://api.discogs.com/artists/\(id)")!, headers: headers) else { continue }
            let urls = Self.discogsImages(detail["images"], keys: ["uri", "uri150"])
            if !urls.isEmpty { return urls.map { ArtworkCandidate(url: $0, source: "Discogs") } }
        }
        guard let search = await json(requestURL("https://api.discogs.com/database/search", [("type", "artist"), ("q", name.trimmed), ("per_page", "10")]), headers: headers)
        else { return [] }
        return Self.discogsImages(search["results"], keys: ["cover_image", "thumb"]).map { ArtworkCandidate(url: $0, source: "Discogs") }
    }

    /// The artist id in a Discogs address ("https://www.discogs.com/artist/123-Name" → 123).
    static func discogsArtistId(_ address: String) -> Int64? {
        guard let match = Regex16("/artist/(\\d+)").firstMatch(in: address) else { return nil }
        return Int64(match.group(1, in: address))
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
