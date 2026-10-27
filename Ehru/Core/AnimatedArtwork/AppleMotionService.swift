import Foundation
import AVFoundation

struct AppleMotionMatch: Equatable, Sendable {
    let catalogId: Int64
    let title: String
    let artist: String
    let storefront: String
    let master: URL
    var portraitMaster: URL? = nil
}

/// Mirrors empee3's Apple web-catalog lookup. The web player's public token is session-only;
/// no Apple ID, user library, subscription credentials or audio are accessed.
actor AppleMotionService {
    private let client: HTTPClient
    private var token: String?
    private var retryAt = Date.distantPast
    init(client: HTTPClient = URLSessionHTTPClient()) { self.client = client }

    struct Search: Decodable {
        let results: [AlbumResult]
    }
    struct AlbumResult: Decodable {
        let collectionId: Int64
        let collectionName: String
        let artistName: String
        let collectionExplicitness: String?
    }
    private struct Catalog: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable {
                struct Video: Decodable {
                    struct Detail: Decodable { let video: String? }
                    let motionDetailSquare: Detail?
                    let motionSquareVideo1x1: Detail?
                    let motionDetailTall: Detail?
                    let motionTallVideo3x4: Detail?
                }
                let editorialVideo: Video?
            }
            let attributes: Attributes
        }
        let data: [Item]
    }

    static func albumKey(_ title: String) -> String {
        let editions = Regex16(#"(?i)\s*[\(\[](?:deluxe|expanded|anniversary|remastered)[^\)\]]*[\)\]]"#)
        return foldForMatch(editions.replacing(in: title, with: ""))
    }

    static func candidates(_ results: [AlbumResult], album: String, artist: String) -> [AlbumResult] {
        results.filter {
            albumKey($0.collectionName) == albumKey(album)
                && LyricsMatcher.strictTagsIn($0.collectionName) == LyricsMatcher.strictTagsIn(album)
                && MetadataScorer.textSimilarity($0.artistName, artist) >= 0.85
        }.sorted { ($0.collectionExplicitness == "explicit" ? 0 : 1, $0.collectionId) < ($1.collectionExplicitness == "explicit" ? 0 : 1, $1.collectionId) }
    }

    func find(album: String, artist: String, country: String) async throws -> AppleMotionMatch? {
        guard Date() >= retryAt else { throw MotionArtworkError("Apple asked to wait before trying again.") }
        let countries = [country.lowercased(), "us", "in", "gb"].filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }.distinct(by: { $0 })
        var matches: [AlbumResult] = []
        for country in countries.prefix(2) {
            let url = requestURL("https://itunes.apple.com/search", [("term", "\(artist) \(album)"), ("entity", "album"), ("limit", "25"), ("country", country)])
            let data = try await get(url)
            matches += Self.candidates(try JSONDecoder().decode(Search.self, from: data).results, album: album, artist: artist)
        }
        matches = matches.distinct(by: \.collectionId)
        guard !matches.isEmpty else { return nil }
        for country in countries {
            for match in matches.prefix(3) {
                try Task.checkCancellation()
                let url = requestURL("https://amp-api.music.apple.com/v1/catalog/\(country)/albums/\(match.collectionId)", [("extend", "editorialVideo"), ("platform", "web")])
                var data: Data?
                for attempt in 0..<2 {
                    let bearer = try await webToken()
                    let (body, response) = try await client.get(url, headers: ["Authorization": "Bearer \(bearer)", "Origin": "https://music.apple.com"])
                    if response.statusCode == 404 { break }
                    if [401, 403].contains(response.statusCode) {
                        token = nil
                        if attempt == 0 { continue }
                    }
                    try check(response)
                    data = body
                    break
                }
                guard let data else { continue }
                let video = try JSONDecoder().decode(Catalog.self, from: data).data.first?.attributes.editorialVideo
                if let raw = video?.motionDetailSquare?.video ?? video?.motionSquareVideo1x1?.video ?? video?.motionDetailTall?.video ?? video?.motionTallVideo3x4?.video {
                    let portrait = video?.motionDetailTall?.video ?? video?.motionTallVideo3x4?.video
                    return AppleMotionMatch(catalogId: match.collectionId, title: match.collectionName, artist: match.artistName,
                                            storefront: country, master: try MotionPlaylist.trustedURL(raw),
                                            portraitMaster: try portrait.map { try MotionPlaylist.trustedURL($0) })
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        return nil
    }

    private func check(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 {
            let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
            retryAt = Date().addingTimeInterval(min(max(seconds, 1), 1800))
            throw MotionArtworkError("Apple is limiting requests. Try again later.")
        }
        guard (200..<300).contains(response.statusCode) else { throw MotionArtworkError("Apple lookup failed (HTTP \(response.statusCode)).") }
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await client.get(url, headers: [:])
        try check(response)
        guard data.count <= 8 * 1024 * 1024 else { throw MotionArtworkError("The Apple response was too large.") }
        return data
    }

    private func webToken() async throws -> String {
        if let token { return token }
        let base = URL(string: "https://music.apple.com/us/browse")!
        let page = String(decoding: try await get(base), as: UTF8.self)
        let paths = Regex16(#"/assets/[^"\s<>]+\.js"#).matches(in: page).map { $0.group(0, in: page) }
            .distinct(by: { $0 }).filter { $0.contains("index") || $0.contains("web-client") || $0.contains("apple-music") }
        for path in paths.prefix(8) {
            let script = String(decoding: try await get(MotionPlaylist.trustedURL(path, relativeTo: base)), as: UTF8.self)
            if let match = Regex16(#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#).firstMatch(in: script) {
                let found = match.group(0, in: script)
                token = found
                return found
            }
        }
        throw MotionArtworkError("Apple's web player changed; its motion artwork lookup is unavailable.")
    }

    func download(_ match: AppleMotionMatch, to destination: URL) async throws {
        let master = String(decoding: try await get(match.master), as: UTF8.self)
        let variants = try MotionPlaylist.variants(master, base: match.master)
        let mediaURL = MotionPlaylist.displayVariant(variants)?.url ?? match.master
        let media = mediaURL == match.master ? master : String(decoding: try await get(mediaURL), as: UTF8.self)
        let parts = try MotionPlaylist.parts(media, base: mediaURL)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw MotionArtworkError("Could not create the motion-cover file.") }
        let output = try FileHandle(forWritingTo: temp)
        do {
            var total: Int64 = 0
            for part in parts {
                try Task.checkCancellation()
                var request = URLRequest(url: part.url, timeoutInterval: 45)
                if let offset = part.offset, let length = part.length { request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range") }
                let (local, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: local) }
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == (part.length == nil ? 200 : 206),
                      let final = response.url else { throw MotionArtworkError("The motion-cover download failed.") }
                _ = try MotionPlaylist.trustedURL(final.absoluteString)
                let size = (try local.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size > 0, Int64(size) <= 64 * 1024 * 1024 - total,
                      part.length == nil || Int64(size) == part.length else { throw MotionArtworkError("The motion cover is incomplete or exceeds 64 MB.") }
                total += Int64(size)
                let input = try FileHandle(forReadingFrom: local)
                do {
                    defer { try? input.close() }
                    while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty { try output.write(contentsOf: chunk) }
                }
            }
            try output.close()
        } catch { try? output.close(); throw error }
        try MotionTimeline.startAtZero(temp)
        let asset = AVURLAsset(url: temp)
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw MotionArtworkError("The downloaded motion cover cannot be played on this device.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 120 else { throw MotionArtworkError("This is not a short motion-cover clip.") }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
