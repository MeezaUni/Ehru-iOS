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
    @ObservationIgnored private var libraryObserver: NSObjectProtocol?
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedArtists = Set<String>()

    init(library: LibraryStore, service: MetadataService, search: ArtworkSearch = ArtworkSearch()) {
        self.library = library
        self.service = service
        self.search = search
    }

    /// Match missing photos on launch and whenever an import or scan adds artists.
    func startAutomaticMatching() {
        guard libraryObserver == nil else { return }
        libraryObserver = NotificationCenter.default.addObserver(forName: SQLiteDatabase.didChange,
            object: library.database.db, queue: .main) { [weak self] note in
                guard SQLiteDatabase.affects(note, tables: ["artists"]) else { return }
                MainActor.assumeIsolated { self?.scheduleAutomaticMatching() }
            }
        scheduleAutomaticMatching()
    }

    func stopAutomaticMatching() {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        libraryObserver = nil
        automaticTask?.cancel()
        automaticTask = nil
    }

    private func scheduleAutomaticMatching() {
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            guard let self else { return }
            defer { self.automaticTask = nil }
            // Read current rows even when this notification precedes LibraryStore's reload.
            while !Task.isCancelled {
                let pending = ((try? self.library.database.allArtists()) ?? []).filter {
                      $0.artworkPath == nil && !$0.isUnresolved && isUsableTag($0.name) &&
                          !self.attemptedArtists.contains($0.artistKey)
                }
                guard !pending.isEmpty else { break }
                for artist in pending {
                    guard !Task.isCancelled else { break }
                    self.attemptedArtists.insert(artist.artistKey)
                    _ = await self.matchPhotoIfMissing(artist)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    static var artistArtFolder: URL { folder("artist-art") }
    static var playlistArtFolder: URL { folder("playlist-art") }

    private static func folder(_ name: String) -> URL {
        let url = LibraryPaths.supportFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Finds missing album covers and all artists, including photos the listener may replace.
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
        artists = library.artists.filter { !$0.isUnresolved && isUsableTag($0.name) }
        for artist in artists where artistStatus[artist.id] == nil {
            artistStatus[artist.id] = artist.artworkPath == nil ? .missing : .done
        }
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
    @discardableResult
    func applyCover(_ candidate: ArtworkCandidate, to album: Album) async -> Bool {
        albumStatus[album.id] = .writing
        do {
            let image = try await service.downloadArtwork(candidate.url)
            try await embed(image, in: album)
            albumStatus[album.id] = .done
            albums.removeAll { $0.id == album.id }
            return true
        } catch {
            albumStatus[album.id] = .failed(error.localizedDescription)
            return false
        }
    }

    /// Embeds image bytes the user picked into every song of [album].
    @discardableResult
    func applyCover(_ image: Data, to album: Album) async -> Bool {
        albumStatus[album.id] = .writing
        do {
            try await embed(image, in: album)
            albumStatus[album.id] = .done
            albums.removeAll { $0.id == album.id }
            return true
        } catch {
            albumStatus[album.id] = .failed(error.localizedDescription)
            return false
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
    @discardableResult
    func applyPhoto(_ candidate: ArtworkCandidate, to artist: Artist) async -> Bool {
        artistStatus[artist.id] = .writing
        do {
            let image = try await service.downloadArtwork(candidate.url)
            try storePhoto(image, for: artist, source: "CUSTOM")
            artistStatus[artist.id] = .done
            return true
        } catch {
            artistStatus[artist.id] = .failed(error.localizedDescription)
            return false
        }
    }

    /// Stores image bytes as [artist]'s photo (relative path, JPEG, scaled like embedded artwork).
    func storePhoto(_ image: Data, for artist: Artist, source: String, deezerId: Int64? = nil) throws {
        let oldPath = try library.database.artistArtworkRow(key: artist.artistKey)?.path ?? artist.artworkPath
        let name = "artist-art/\(UUID().uuidString).jpg"
        let url = LibraryPaths.supportFolder.appendingPathComponent(name)
        _ = Self.artistArtFolder
        try ArtworkEncoder.prepare(image).write(to: url, options: .atomic)
        try library.database.setArtistArtwork(key: artist.artistKey, path: name, source: source, providerArtistId: deezerId)
        if let old = oldPath, !old.hasPrefix("/") { try? FileManager.default.removeItem(atPath: LibraryPaths.resolveImage(old)) }
        if let index = artists.firstIndex(where: { $0.id == artist.id }), let updated = try library.database.artist(id: artist.id) {
            artists[index] = updated
        }
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
        for artist in artists where library.artist(artist.id)?.artworkPath == nil {
            guard !Task.isCancelled else { break }
            if await matchPhotoIfMissing(artist) { matched += 1 }
            // Deezer allows about 50 requests per 5 seconds.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        message = "Matched \(matched) artist\(matched == 1 ? "" : "s"). The rest need a photo picked by hand."
        isAutoMatching = false
    }

    private func matchPhotoIfMissing(_ artist: Artist) async -> Bool {
        guard artistStatus[artist.id] != .searching, artistStatus[artist.id] != .writing,
              let existing = try? library.database.artist(id: artist.id), existing.artworkPath == nil else { return false }
        artistStatus[artist.id] = .searching
        do {
            let profiles = try await search.deezerArtists(artist.name)
            try Task.checkCancellation()
            switch ArtworkSearch.selectDeezerArtist(artist.name, profiles) {
            case .selected(let id, let picture):
                let image = try await service.downloadArtwork(picture)
                try Task.checkCancellation()
                // An image picked by hand while the request was running always wins.
                guard let current = try library.database.artist(id: artist.id),
                      current.artistKey == artist.artistKey else {
                    artistStatus[artist.id] = .missing
                    return false
                }
                guard current.artworkPath == nil else {
                    artistStatus[artist.id] = .done
                    return false
                }
                try storePhoto(image, for: current, source: "DEEZER", deezerId: id)
                artistStatus[artist.id] = .done
                return true
            case .rejected(let reason): artistStatus[artist.id] = .failed("Not matched automatically: \(reason)")
            }
        } catch is CancellationError {
            if artistStatus[artist.id] == .searching { artistStatus[artist.id] = .missing }
        } catch {
            if artistStatus[artist.id] == .searching { artistStatus[artist.id] = .failed(classifyProviderFailure(error).message) }
        }
        return false
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
