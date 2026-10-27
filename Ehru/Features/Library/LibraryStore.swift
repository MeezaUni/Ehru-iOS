import Foundation
import Observation

/// The library as the screens see it, reloaded whenever the database changes (Android's
/// LibraryRepository flows). Scans run off the main thread.
@MainActor
@Observable
final class LibraryStore {
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [Playlist] = []
    private(set) var favorites: [Song] = []
    private(set) var recentAlbums: [Album] = []
    private(set) var recentPlaylists: [Playlist] = []
    private(set) var featuredAlbums: [Album] = []
    /// Each album's cover comes from its first song's embedded art.
    private(set) var albumCoverSong: [Int64: Song] = [:]
    private(set) var scanProgress: ScanProgress?
    private(set) var errorMessage: String?
    var isShowingError = false

    let database: LibraryDatabase
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var rescanRequested = false

    var isScanning: Bool { scanProgress != nil }

    /// The Recently Played shelves' length.
    static let recentShelfLimit = 12

    func album(_ id: Int64) -> Album? { albums.first { $0.id == id } }
    func artist(_ id: Int64) -> Artist? { artists.first { $0.id == id } }
    func playlist(_ id: Int64) -> Playlist? { playlists.first { $0.id == id } }

    init(database: LibraryDatabase) {
        self.database = database
        reload()
        observer = NotificationCenter.default.addObserver(forName: SQLiteDatabase.didChange, object: database.db, queue: .main) { [weak self] note in
            guard SQLiteDatabase.affects(note, tables: ["songs", "albums", "artists", "playlists", "playlist_song_cross_ref", "artist_artwork", "recently_played", "listening_stats"]) else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        do {
            songs = try database.allSongs()
            albums = try database.allAlbums()
            artists = try database.allArtists()
            playlists = try database.playlists()
            favorites = try database.favoriteSongs()
            recentAlbums = try database.recentAlbums(limit: Self.recentShelfLimit)
            recentPlaylists = try database.recentPlaylists(limit: Self.recentShelfLimit)
            var covers: [Int64: Song] = [:]
            for song in songs.sorted(by: { ($0.discNumber, $0.trackNumber, $0.id) < ($1.discNumber, $1.trackNumber, $1.id) })
            where covers[song.albumId] == nil {
                covers[song.albumId] = song
            }
            albumCoverSong = covers
            let epochDay = Int64(floor(Date().timeIntervalSince1970 / 86_400))
            let tracks = try database.trackFacts()
            let plays = try database.monthlyPlays()
            featuredAlbums = FeaturedAlbums.select(albums: albums, tracks: tracks, plays: plays, exclude: Set(recentAlbums.map(\.id)),
                                                   epochDay: epochDay)
        } catch {
            report("Couldn't read the library: \(error)")
        }
    }

    /// Rescans the music folder. A request during a scan runs once more after it, so a change is never missed.
    func scan() {
        guard scanProgress == nil else {
            rescanRequested = true
            return
        }
        scanProgress = ScanProgress()
        let scanner = LibraryScanner(database: database)
        let store = self
        Task.detached(priority: .utility) {
            do {
                _ = try scanner.scan { progress in
                    Task { @MainActor in store.updateProgress(progress) }
                }
            } catch {
                let message = "The library scan failed: \(error)"
                await store.report(message)
            }
            await store.scanFinished()
        }
    }

    private func updateProgress(_ progress: ScanProgress) {
        if scanProgress != nil { scanProgress = progress }
    }

    private func scanFinished() {
        scanProgress = nil
        reload()
        if rescanRequested {
            rescanRequested = false
            scan()
        }
    }

    /// Copies files picked in the document picker into the music folder, then rescans.
    func importFiles(_ urls: [URL]) {
        let folder = LibraryPaths.musicFolder
        let store = self
        Task.detached(priority: .userInitiated) {
            var failed: [String] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let destination = uniqueDestination(for: url.lastPathComponent, in: folder)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            let failures = failed
            await MainActor.run {
                if !failures.isEmpty { store.report("Couldn't import: \(failures.joined(separator: ", "))") }
                store.scan()
            }
        }
    }

    func report(_ message: String) {
        errorMessage = message
        isShowingError = true
    }
}

/// `folder/name`, or `folder/name 2.ext`, `3`, … if that name is taken.
func uniqueDestination(for fileName: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var candidate = folder.appendingPathComponent(fileName)
    var counter = 2
    while exists(candidate) {
        candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
        counter += 1
    }
    return candidate
}

/// The home screen's Featured Albums: albums already in the library, chosen locally and
/// deterministically: the most played, then those holding favourites, then a daily rotation of
/// the rest (fuller albums first). Albums on the Recently Played shelf come last, only to fill.
enum FeaturedAlbums {
    static let limit = 5
    /// Below this many songs an album is likely a single; rotation prefers fuller albums.
    private static let minRotationSongs = 3

    static func select(albums: [Album], tracks: [TrackFacts], plays: [MonthlyPlays], exclude: Set<Int64>, epochDay: Int64,
                       limit: Int = limit) -> [Album] {
        let inLibrary = albums.filter { $0.songCount > 0 }.distinct(by: \.id)
        let candidates = inLibrary.filter { !exclude.contains($0.id) }
        let albumOfSong = Dictionary(tracks.map { ($0.songId, $0.albumId) }, uniquingKeysWith: { a, _ in a })
        var playsByAlbum: [Int64: Int] = [:]
        for p in plays { if let album = albumOfSong[p.songId] { playsByAlbum[album, default: 0] += p.plays } }
        var favouritesByAlbum: [Int64: Int] = [:]
        for t in tracks where t.isFavorite { favouritesByAlbum[t.albumId, default: 0] += 1 }

        let played = candidates.filter { playsByAlbum[$0.id, default: 0] > 0 }.sorted { a, b in
            let pa = playsByAlbum[a.id, default: 0], pb = playsByAlbum[b.id, default: 0]
            if pa != pb { return pa > pb }
            let fa = favouritesByAlbum[a.id, default: 0], fb = favouritesByAlbum[b.id, default: 0]
            return fa != fb ? fa > fb : a.id < b.id
        }
        let loved = candidates.filter { playsByAlbum[$0.id, default: 0] == 0 && favouritesByAlbum[$0.id, default: 0] > 0 }.sorted { a, b in
            let fa = favouritesByAlbum[a.id, default: 0], fb = favouritesByAlbum[b.id, default: 0]
            return fa != fb ? fa > fb : a.id < b.id
        }
        let chosen = Array((played + loved).prefix(limit))
        let taken = Set(chosen.map(\.id))
        func daily(_ a: Album, _ b: Album) -> Bool {
            let ra = dailyRank(a.id, epochDay), rb = dailyRank(b.id, epochDay)
            return ra != rb ? ra < rb : a.id < b.id
        }
        let rest = candidates.filter { !taken.contains($0.id) }
        let fuller = rest.filter { $0.songCount >= minRotationSongs }.sorted(by: daily)
        let smaller = rest.filter { $0.songCount < minRotationSongs }.sorted(by: daily)
        let recent = inLibrary.filter { exclude.contains($0.id) && !taken.contains($0.id) }.sorted(by: daily)
        return chosen + (fuller + smaller + recent).prefix(max(limit - chosen.count, 0))
    }

    /// A stable pseudo-random rank of [albumId] for [epochDay] (SplitMix64 mixing).
    static func dailyRank(_ albumId: Int64, _ epochDay: Int64) -> Int64 {
        var z = albumId &* Int64(bitPattern: 0x9E37_79B9_7F4A_7C15) &+ epochDay
        z = (z ^ Int64(bitPattern: UInt64(bitPattern: z) >> 30)) &* Int64(bitPattern: 0xBF58_476D_1CE4_E5B9)
        z = (z ^ Int64(bitPattern: UInt64(bitPattern: z) >> 27)) &* Int64(bitPattern: 0x94D0_49BB_1331_11EB)
        return z ^ Int64(bitPattern: UInt64(bitPattern: z) >> 31)
    }
}
