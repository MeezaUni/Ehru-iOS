import Foundation

/// A playable track of the library (Android's Song plus what the iOS scanner reads itself).
/// [path] is relative to the music folder, so the library survives the app container moving.
struct Song: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var artist: String
    var album: String
    var artistId: Int64 = 0
    var albumId: Int64 = 0
    var durationMs: Int64
    var path: String
    var trackNumber = 0
    var discNumber = 1
    var year = 0
    var dateModified: Int64 = 0
    var isFavorite = false
    var genre: String?
    var bpm: Int?
    var composer: String?
    var fileSize: Int64 = 0
    var codec: String?
    var sampleRate = 0
    var bitrate = 0
    var channels = 2

    var url: URL { LibraryPaths.musicFolder.appendingPathComponent(path) }

    /// "Artist — Album", skipping whichever is missing.
    var subtitle: String {
        let parts = [artist, album].filter { !$0.isEmpty }
        return parts.isEmpty ? unknownArtist : parts.joined(separator: " — ")
    }

    var isLossless: Bool {
        let lower = path.lowercased()
        return ["flac", "alac", "wav", "aiff", "aif"].contains { codec?.lowercased().contains($0) == true || lower.hasSuffix(".\($0)") }
    }
}

struct Album: Identifiable, Hashable, Sendable {
    let id: Int64
    var title: String
    var artist: String
    var artistId: Int64
    var songCount: Int
    var year: Int
    var isCompilation = false
}

struct Artist: Identifiable, Hashable, Sendable {
    let id: Int64
    var name: String
    var songCount: Int
    var albumCount: Int
    var artworkPath: String?
    /// Canonical identity key (lowercased, normalized name).
    var artistKey = ""
    var isUnresolved = false
}

struct Playlist: Identifiable, Hashable, Sendable {
    let id: Int64
    var name: String
    var songCount: Int
    /// User-chosen cover (a file in app storage); nil shows the default playlist cover.
    var artworkPath: String?
}

/// One entry of a playlist: the song and its position. Positions never change once the entry exists.
struct PlaylistEntry: Hashable, Sendable {
    let song: Song
    let position: Int
}

/// A saved position in one track.
struct TrackBookmark: Identifiable, Hashable, Sendable {
    let id: Int64
    let songId: Int64
    let positionMs: Int64
    /// Short user-given name; blank shows as the timestamp only.
    let label: String
    let createdAt: Int64
}

/// What the recommendations know about a song: identity, grouping and the stored tags.
struct TrackFacts: Equatable, Hashable, Sendable {
    let songId: Int64
    let title: String
    let artistId: Int64
    let artist: String
    let albumId: Int64
    let album: String
    let genre: String?
    /// The file's BPM tag when plausible; may be half- or double-time.
    let bpm: Int?
    let durationMs: Int64
    let isFavorite: Bool
    /// When the file was added or last changed, epoch ms.
    let addedAt: Int64
    /// The year tag as stored: nil, 0 or a placeholder (1970) when the file has no real year.
    var year: Int?
}

/// A song's counted plays in one local calendar month (a play counts once half was heard).
struct MonthlyPlays: Equatable, Hashable, Sendable {
    let songId: Int64
    /// "YYYY-MM".
    let month: String
    let plays: Int
    let lastPlayedAt: Int64
}

/// The text a song carries for discovery (VYBE), as stored.
struct SongTags: Equatable, Sendable {
    let songId: Int64
    let title: String
    let artist: String
    let album: String
    let genre: String?
    let year: Int
    let bpm: Int?
    let lyricsExcerpt: String?
}

struct RankedSong: Hashable, Sendable {
    let song: Song
    let plays: Int
}

struct RankedAlbum: Hashable, Sendable {
    let album: Album
    let plays: Int
}

struct RankedArtist: Hashable, Sendable {
    let artist: Artist
    let plays: Int
}

/// One calendar month of listening: totals and the top songs, albums and artists.
struct SoundCapsule: Equatable, Sendable {
    let month: String
    let totalPlays: Int
    let listenedMs: Int64
    /// Longest run of consecutive listening days that includes a day of [month].
    let longestStreakDays: Int
    let topSongs: [RankedSong]
    let topAlbums: [RankedAlbum]
    let topArtists: [RankedArtist]

    var isEmpty: Bool { totalPlays == 0 }
}

/// A playlist the app builds from the library itself (never stored as a user playlist).
enum SmartPlaylist: String, CaseIterable, Sendable {
    case mostPlayed = "Most Played"
    case recentlyAdded = "Recently Added"
    case recentlyPlayed = "Recently Played"
    case favorites = "Favorites"
    case neverPlayed = "Never Played"

    var title: String { rawValue }
}

/// Where the app keeps its files.
enum LibraryPaths {
    /// The music folder: the app's Documents folder, shown as "empee3" under On My iPhone.
    static var musicFolder: URL { URL.documentsDirectory }

    /// App data that is not music (database, caches, covers), hidden from the Files app.
    static var supportFolder: URL {
        let url = URL.applicationSupportDirectory.appendingPathComponent("Ehru", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cachesFolder: URL {
        let url = URL.cachesDirectory.appendingPathComponent("Ehru", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The path of [url] relative to the music folder, or nil if it lies outside it.
    static func relativePath(of url: URL) -> String? {
        let base = musicFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base) else { return nil }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
