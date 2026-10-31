import UIKit
import XCTest
@testable import Erhu

final class AutomaticArtistPhotosTests: XCTestCase {
    private actor PhotoHTTP: HTTPClient {
        let image: Data
        let gated: Bool
        private(set) var names: [String] = []
        private(set) var imageRequested = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(image: Data, gated: Bool = false) { self.image = image; self.gated = gated }

        func releaseImage() { released = true; continuation?.resume(); continuation = nil }

        func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
            if url.host == "api.deezer.com" {
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
                names.append(name)
                let body = try JSONSerialization.data(withJSONObject: ["data": [["id": 123, "name": name,
                    "picture_big": "https://images.example/artist/real.jpg", "nb_fan": 1000]]])
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            imageRequested = true
            if gated && !released { await withCheckedContinuation { continuation = $0 } }
            return (image, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        }
    }

    @MainActor
    private func photo() throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData())
    }

    private func insert(_ name: String, id: Int64, into db: LibraryDatabase) throws {
        try db.db.execute("INSERT INTO artists (id, name, song_count, album_count, artist_key) VALUES (?, ?, 1, 0, ?)", [id, name, name.lowercased()])
    }

    @MainActor
    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<150 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Automatic artist matching did not finish")
    }

    @MainActor
    func testMatchesArtistsAddedAfterStartupWithoutOpeningArtworkFetcher() async throws {
        let db = try LibraryDatabase.inMemory()
        let library = LibraryStore(database: db)
        let http = PhotoHTTP(image: try photo())
        let store = ArtworkFetcherStore(library: library, service: MetadataService(client: http), search: ArtworkSearch(client: http))
        store.startAutomaticMatching()
        defer { store.stopAutomaticMatching() }
        try insert("Imported Artist", id: 1, into: db)
        try await waitUntil { try db.artist(id: 1)?.artworkPath != nil }
        let path = try XCTUnwrap(db.artist(id: 1)?.artworkPath)
        defer { try? FileManager.default.removeItem(atPath: LibraryPaths.resolveImage(path)) }
        XCTAssertEqual(try db.artistArtworkRow(key: "imported artist")?.source, "DEEZER")
        // Artwork writes and unrelated rescans must not trigger repeated network requests.
        library.reload()
        try await Task.sleep(for: .milliseconds(300))
        let names = await http.names
        XCTAssertEqual(names, ["Imported Artist"])
    }

    @MainActor
    func testManualImageWinsOverAnAutomaticDownloadAlreadyInProgress() async throws {
        let db = try LibraryDatabase.inMemory()
        try insert("Artist", id: 1, into: db)
        let library = LibraryStore(database: db)
        let http = PhotoHTTP(image: try photo(), gated: true)
        let store = ArtworkFetcherStore(library: library, service: MetadataService(client: http), search: ArtworkSearch(client: http))
        store.startAutomaticMatching()
        defer { store.stopAutomaticMatching() }
        try await waitUntil { await http.imageRequested }
        let artist = try XCTUnwrap(db.artist(id: 1))
        try store.storePhoto(photo(), for: artist, source: "CUSTOM")
        let manual = try XCTUnwrap(db.artist(id: 1)?.artworkPath)
        defer { try? FileManager.default.removeItem(atPath: LibraryPaths.resolveImage(manual)) }
        await http.releaseImage()
        try await waitUntil { store.artistStatus[1] == .done }
        XCTAssertEqual(try db.artist(id: 1)?.artworkPath, manual)
        XCTAssertEqual(try db.artistArtworkRow(key: "artist")?.source, "CUSTOM")
        // Existing photos remain in the manual picker, ready to be replaced.
        await store.scan()
        XCTAssertEqual(store.artists.map(\.id), [1])
    }
}
