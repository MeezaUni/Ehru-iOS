import Foundation
import Observation

/// Where an album or artist is in the Artwork Fetcher.
enum ArtworkStatus: Equatable {
    case missing
    case searching
    case found(Int)
    case notFound
    case writing
    case done
    case failed(String)

    var label: String {
        switch self {
        case .missing: "No artwork"
        case .searching: "Searching…"
        case .found(let count): "\(count) found"
        case .notFound: "Nothing found"
        case .writing: "Saving…"
        case .done: "Saved"
        case .failed(let reason): reason
        }
    }
}

/// The Artwork Fetcher: finds albums without a cover and artists without a photo, searches covers
/// and photos online, and saves the one picked: an album cover is embedded into every song of the
/// album; an artist photo is stored by the app. Automatic artist photos only take a Deezer profile
/// that is safely the artist (see [ArtworkSearch.selectDeezerArtist]).
@MainActor
@Observable
final class ArtworkFetcherStore {
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var albumStatus: [Int64: ArtworkStatus] = [:]
    private(set) var artistStatus: [Int64: ArtworkStatus] = [:]
    private(set) var isScanning = false
    private(set) var isAutoMatching = false
    private(set) var message: String?

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored let search: ArtworkSearch
    @ObservationIgnored private let service: MetadataService

    init(library: LibraryStore, service: MetadataService, search: ArtworkSearch = ArtworkSearch()) {
        self.library = library
        self.service = service
        self.search = search
    }

    static var artistArtFolder: URL { folder("artist-art") }
    static var playlistArtFolder: URL { folder("playlist-art") }

    private static func folder(_ name: String) -> URL {
        let url = LibraryPaths.supportFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Finds the albums whose songs carry no cover and the artists without a photo.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let covers = library.albumCoverSong
        let candidates = library.albums
        let missing = await Task.detached(priority: .utility) {
            candidates.filter { album in covers[album.id].map { !TagReader.read($0.url).hasArtwork } ?? false }
        }.value
        albums = missing
        for album in missing where albumStatus[album.id] == nil { albumStatus[album.id] = .missing }
        artists = library.artists.filter { $0.artworkPath == nil && !$0.isUnresolved && isUsableTag($0.name) }
        for artist in artists where artistStatus[artist.id] == nil { artistStatus[artist.id] = .missing }
        isScanning = false
    }

    func albumCovers(_ album: Album) async -> [ArtworkCandidate] {
        albumStatus[album.id] = .searching
        let found = await search.albumCovers(album: album.title, artist: album.artist)
        albumStatus[album.id] = found.isEmpty ? .notFound : .found(found.count)
        return found
    }

    func artistPhotos(_ artist: Artist) async -> [ArtworkCandidate] {
        artistStatus[artist.id] = .searching
        let found = await search.artistPhotos(artist.name)
        artistStatus[artist.id] = found.isEmpty ? .notFound : .found(found.count)
        return found
    }

    /// Downloads [candidate] and embeds it into every song of [album] (each write verified).
    func applyCover(_ candidate: ArtworkCandidate, to album: Album) async {
        albumStatus[album.id] = .writing
        do {
            let image = try await service.downloadArtwork(candidate.url)
            try await embed(image, in: album)
            albumStatus[album.id] = .done
            albums.removeAll { $0.id == album.id }
        } catch {
            albumStatus[album.id] = .failed(error.localizedDescription)
        }
    }

    /// Embeds image bytes the user picked into every song of [album].
    func applyCover(_ image: Data, to album: Album) async {
        albumStatus[album.id] = .writing
        do {
            try await embed(image, in: album)
            albumStatus[album.id] = .done
            albums.removeAll { $0.id == album.id }
        } catch {
            albumStatus[album.id] = .failed(error.localizedDescription)
        }
    }

    private func embed(_ image: Data, in album: Album) async throws {
        let songs = try library.database.songsOfAlbum(album.id)
        guard !songs.isEmpty else { throw ProviderError(status: .failed, message: "The album has no songs") }
        let prepared = ArtworkEncoder.prepare(image)
        var failures: [String] = []
        for song in songs {
            var request = TagWriteRequest()
            request.artwork = prepared
            let url = song.url
            do {
                try await Task.detached(priority: .utility) { try TagWriter.write(request, to: url) }.value
            } catch {
                failures.append("\(song.title): \(error.localizedDescription)")
            }
            ArtworkLoader.shared.forget(path: url.path)
        }
        library.scan()
        if failures.count == songs.count { throw ProviderError(status: .failed, message: failures.first ?? "Nothing was saved") }
        if !failures.isEmpty { message = "Saved to \(songs.count - failures.count) of \(songs.count) songs. \(failures.joined(separator: "; "))" }
    }

    /// Downloads [candidate] and stores it as [artist]'s photo.
    func applyPhoto(_ candidate: ArtworkCandidate, to artist: Artist) async {
        artistStatus[artist.id] = .writing
        do {
            let image = try await service.downloadArtwork(candidate.url)
            try storePhoto(image, for: artist, source: "CUSTOM")
            artistStatus[artist.id] = .done
            artists.removeAll { $0.id == artist.id }
        } catch {
            artistStatus[artist.id] = .failed(error.localizedDescription)
        }
    }

    /// Stores image bytes as [artist]'s photo (relative path, JPEG, scaled like embedded artwork).
    func storePhoto(_ image: Data, for artist: Artist, source: String, deezerId: Int64? = nil) throws {
        let name = "artist-art/\(UUID().uuidString).jpg"
        let url = LibraryPaths.supportFolder.appendingPathComponent(name)
        _ = Self.artistArtFolder
        try ArtworkEncoder.prepare(image).write(to: url, options: .atomic)
        try library.database.setArtistArtwork(key: artist.artistKey, path: name, source: source, providerArtistId: deezerId)
        if let old = artist.artworkPath, !old.hasPrefix("/") { try? FileManager.default.removeItem(atPath: LibraryPaths.resolveImage(old)) }
    }

    func removePhoto(_ artist: Artist) {
        try? library.database.deleteCustomArtistArtwork(key: artist.artistKey)
    }

    /// Gives each listed artist the photo of its Deezer profile when one is safely that artist;
    /// doubtful names are left without a photo.
    func autoMatchArtists() async {
        guard !isAutoMatching else { return }
        isAutoMatching = true
        var matched = 0
        for artist in artists {
            artistStatus[artist.id] = .searching
            do {
                let profiles = try await search.deezerArtists(artist.name)
                switch ArtworkSearch.selectDeezerArtist(artist.name, profiles) {
                case .selected(let id, let picture):
                    let image = try await service.downloadArtwork(picture)
                    try storePhoto(image, for: artist, source: "DEEZER", deezerId: id)
                    artistStatus[artist.id] = .done
                    matched += 1
                case .rejected(let reason):
                    artistStatus[artist.id] = .failed("Not matched automatically: \(reason)")
                }
            } catch {
                artistStatus[artist.id] = .failed(classifyProviderFailure(error).message)
            }
            // Deezer allows about 50 requests per 5 seconds.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        artists.removeAll { artistStatus[$0.id] == .done }
        message = "Matched \(matched) artist\(matched == 1 ? "" : "s"). The rest need a photo picked by hand."
        isAutoMatching = false
    }

    /// Stores image bytes as a playlist's cover.
    func setPlaylistCover(_ image: Data, playlist: Playlist) throws {
        let name = "playlist-art/\(UUID().uuidString).jpg"
        _ = Self.playlistArtFolder
        try ArtworkEncoder.prepare(image).write(to: LibraryPaths.supportFolder.appendingPathComponent(name), options: .atomic)
        try library.database.setPlaylistArtwork(playlist.id, path: name)
        if let old = playlist.artworkPath, !old.hasPrefix("/") { try? FileManager.default.removeItem(atPath: LibraryPaths.resolveImage(old)) }
    }

    func removePlaylistCover(_ playlist: Playlist) {
        try? library.database.setPlaylistArtwork(playlist.id, path: nil)
        if let old = playlist.artworkPath, !old.hasPrefix("/") { try? FileManager.default.removeItem(atPath: LibraryPaths.resolveImage(old)) }
    }

    func clearMessage() { message = nil }
}
