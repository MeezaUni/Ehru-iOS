import Foundation

/// The library database: the same tables as the Android app's Room database (version 14), plus a
/// few columns the iOS scanner fills itself (file size and audio format). Queries are kept as close
/// to the Android DAOs as possible.
final class LibraryDatabase: @unchecked Sendable {
    let db: SQLiteDatabase

    static let schemaVersion = 1

    init(db: SQLiteDatabase) throws {
        self.db = db
        try migrate()
    }

    /// The app's database file.
    static func open() throws -> LibraryDatabase {
        let url = LibraryPaths.supportFolder.appendingPathComponent("library.sqlite")
        return try LibraryDatabase(db: SQLiteDatabase(path: url.path))
    }

    static func inMemory() throws -> LibraryDatabase {
        try LibraryDatabase(db: .inMemory())
    }

    private func migrate() throws {
        if db.userVersion < 1 {
            try db.executeScript(Self.schemaV1)
            db.userVersion = 1
        }
    }

    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS songs (
        id INTEGER PRIMARY KEY NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL,
        artist_id INTEGER NOT NULL, album_id INTEGER NOT NULL, duration_ms INTEGER NOT NULL, uri TEXT NOT NULL,
        file_path TEXT NOT NULL, track_number INTEGER NOT NULL, year INTEGER NOT NULL, date_modified INTEGER NOT NULL,
        artwork_uri TEXT, is_enriched INTEGER NOT NULL DEFAULT 0, lyrics TEXT, disc_number INTEGER NOT NULL DEFAULT 1,
        composer TEXT, genre TEXT, is_favorite INTEGER NOT NULL DEFAULT 0, bpm INTEGER,
        file_size INTEGER NOT NULL DEFAULT 0, codec TEXT, sample_rate INTEGER NOT NULL DEFAULT 0,
        bitrate INTEGER NOT NULL DEFAULT 0, channels INTEGER NOT NULL DEFAULT 2,
        raw_artist TEXT NOT NULL DEFAULT '', raw_album_artist TEXT, raw_album TEXT NOT NULL DEFAULT '',
        is_compilation INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS index_songs_album_id ON songs(album_id);
    CREATE TABLE IF NOT EXISTS albums (
        id INTEGER PRIMARY KEY NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL, artist_id INTEGER NOT NULL,
        song_count INTEGER NOT NULL, year INTEGER NOT NULL, artwork_uri TEXT, is_compilation INTEGER NOT NULL DEFAULT 0,
        album_artist_inconsistent INTEGER NOT NULL DEFAULT 0, grouping_key TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS artists (
        id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL, song_count INTEGER NOT NULL, album_count INTEGER NOT NULL,
        artwork_uri TEXT, artist_key TEXT NOT NULL DEFAULT '', is_unresolved INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, name TEXT NOT NULL, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, artwork_uri TEXT
    );
    CREATE TABLE IF NOT EXISTS playlist_song_cross_ref (
        playlist_id INTEGER NOT NULL, song_id INTEGER NOT NULL, position INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, position)
    );
    CREATE INDEX IF NOT EXISTS index_playlist_song_cross_ref_song_id ON playlist_song_cross_ref(song_id);
    CREATE TABLE IF NOT EXISTS song_artist_cross_ref (
        song_id INTEGER NOT NULL, artist_id INTEGER NOT NULL, role TEXT NOT NULL, position INTEGER NOT NULL,
        credit_text TEXT NOT NULL DEFAULT '', is_unresolved INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (song_id, artist_id, role)
    );
    CREATE INDEX IF NOT EXISTS index_song_artist_cross_ref_artist_id ON song_artist_cross_ref(artist_id);
    CREATE TABLE IF NOT EXISTS album_artist_cross_ref (
        album_id INTEGER NOT NULL, artist_id INTEGER NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (album_id, artist_id)
    );
    CREATE INDEX IF NOT EXISTS index_album_artist_cross_ref_artist_id ON album_artist_cross_ref(artist_id);
    CREATE TABLE IF NOT EXISTS artist_artwork (
        artist_key TEXT PRIMARY KEY NOT NULL, artwork_uri TEXT NOT NULL, updated_at INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'AUTO', provider_artist_id INTEGER, matcher_version INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS artist_alias (
        alias_key TEXT PRIMARY KEY NOT NULL, canonical_key TEXT NOT NULL, source TEXT NOT NULL, created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS unverified_credit_segment (
        song_id INTEGER NOT NULL, artist_id INTEGER NOT NULL, segment_key TEXT NOT NULL, segment_index INTEGER NOT NULL,
        PRIMARY KEY (song_id, artist_id, segment_index)
    );
    CREATE INDEX IF NOT EXISTS index_unverified_credit_segment_segment_key ON unverified_credit_segment(segment_key);
    CREATE TABLE IF NOT EXISTS recently_played (
        kind TEXT NOT NULL, item_id INTEGER NOT NULL, played_at INTEGER NOT NULL, PRIMARY KEY (kind, item_id)
    );
    CREATE TABLE IF NOT EXISTS listening_stats (
        month_key TEXT NOT NULL, song_id INTEGER NOT NULL, play_count INTEGER NOT NULL, listened_ms INTEGER NOT NULL,
        last_played_at INTEGER NOT NULL, PRIMARY KEY (month_key, song_id)
    );
    CREATE INDEX IF NOT EXISTS index_listening_stats_song_id ON listening_stats(song_id);
    CREATE TABLE IF NOT EXISTS listening_days (day TEXT PRIMARY KEY NOT NULL, play_count INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS track_bookmarks (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, song_id INTEGER NOT NULL, position_ms INTEGER NOT NULL,
        label TEXT NOT NULL, created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS index_track_bookmarks_song_id ON track_bookmarks(song_id);
    CREATE TABLE IF NOT EXISTS waveform_cache (
        song_id INTEGER PRIMARY KEY NOT NULL, source_uri TEXT NOT NULL, file_size INTEGER NOT NULL,
        date_modified INTEGER NOT NULL, format_version INTEGER NOT NULL, levels BLOB NOT NULL, created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS learned_watermarks (
        token TEXT PRIMARY KEY NOT NULL, frequency_count INTEGER NOT NULL, date_discovered INTEGER NOT NULL,
        is_active INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS animated_artwork (
        album_id INTEGER PRIMARY KEY NOT NULL, normalized_artist TEXT NOT NULL, normalized_album TEXT NOT NULL,
        catalog_album_id TEXT, storefront TEXT, square_file_name TEXT, tall_file_name TEXT, has_square INTEGER,
        has_tall INTEGER, status TEXT NOT NULL, updated_at_epoch_ms INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS index_animated_artwork_key ON animated_artwork(normalized_artist, normalized_album);
    CREATE TABLE IF NOT EXISTS metadata_processing (
        file_path TEXT PRIMARY KEY NOT NULL, file_size INTEGER NOT NULL, date_modified INTEGER NOT NULL,
        processing_version INTEGER NOT NULL, status TEXT NOT NULL, last_processed_timestamp INTEGER NOT NULL,
        confidence_score REAL NOT NULL, matched_source TEXT, failure_reason TEXT
    );
    """

    // MARK: Row mapping

    static func song(_ r: Row) -> Song {
        Song(
            id: r.int64("id"), title: r.string("title"), artist: r.string("artist"), album: r.string("album"),
            artistId: r.int64("artist_id"), albumId: r.int64("album_id"), durationMs: r.int64("duration_ms"),
            path: r.string("file_path"), trackNumber: r.int("track_number"), discNumber: r.int("disc_number"),
            year: r.int("year"), dateModified: r.int64("date_modified"), isFavorite: r.bool("is_favorite"),
            genre: r.optionalString("genre"), bpm: r.optionalInt("bpm"), composer: r.optionalString("composer"),
            fileSize: r.int64("file_size"), codec: r.optionalString("codec"), sampleRate: r.int("sample_rate"),
            bitrate: r.int("bitrate"), channels: r.int("channels")
        )
    }

    static func album(_ r: Row) -> Album {
        Album(id: r.int64("id"), title: r.string("title"), artist: r.string("artist"), artistId: r.int64("artist_id"),
              songCount: r.int("song_count"), year: r.int("year"), isCompilation: r.bool("is_compilation"))
    }

    static func artist(_ r: Row) -> Artist {
        Artist(id: r.int64("id"), name: r.string("name"), songCount: r.int("song_count"), albumCount: r.int("album_count"),
               artworkPath: r.optionalString("artwork_uri"), artistKey: r.string("artist_key"), isUnresolved: r.bool("is_unresolved"))
    }

    static func playlist(_ r: Row) -> Playlist {
        Playlist(id: r.int64("id"), name: r.string("name"), songCount: r.int("songCount"), artworkPath: r.optionalString("artworkUri"))
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Songs (SongDao)

extension LibraryDatabase {
    func allSongs() throws -> [Song] {
        try db.query("SELECT * FROM songs ORDER BY title COLLATE NOCASE ASC", [], Self.song)
    }

    func song(id: Int64) throws -> Song? {
        try db.query("SELECT * FROM songs WHERE id = ? LIMIT 1", [id], Self.song).first
    }

    /// The songs with these ids, in the order of [ids]; missing ones are left out.
    func songs(ids: [Int64]) throws -> [Song] {
        var byId: [Int64: Song] = [:]
        for chunk in Array(Set(ids)).chunked(into: 500) {
            for song in try db.query("SELECT * FROM songs WHERE id IN (\(placeholders(chunk.count)))", chunk, Self.song) {
                byId[song.id] = song
            }
        }
        return ids.compactMap { byId[$0] }
    }

    func favoriteSongs() throws -> [Song] {
        try db.query("SELECT * FROM songs WHERE is_favorite = 1 ORDER BY title COLLATE NOCASE ASC", [], Self.song)
    }

    func setFavorite(songId: Int64, _ isFavorite: Bool) throws {
        try db.execute("UPDATE songs SET is_favorite = ? WHERE id = ?", [isFavorite, songId])
    }

    func toggleFavorite(songId: Int64) throws {
        try db.execute("UPDATE songs SET is_favorite = 1 - is_favorite WHERE id = ?", [songId])
    }

    func songsOfAlbum(_ albumId: Int64) throws -> [Song] {
        try db.query(
            "SELECT * FROM songs WHERE album_id = ? ORDER BY disc_number ASC, track_number ASC, title COLLATE NOCASE ASC",
            [albumId], Self.song
        )
    }

    func songsOfArtist(_ artistId: Int64, role: CreditRole? = nil) throws -> [Song] {
        let roleFilter = role.map { " AND ref.role = '\($0.rawValue)'" } ?? ""
        return try db.query("""
            SELECT DISTINCT s.* FROM songs s
            INNER JOIN song_artist_cross_ref ref ON s.id = ref.song_id
            WHERE ref.artist_id = ?\(roleFilter)
            ORDER BY s.disc_number ASC, s.track_number ASC, s.title COLLATE NOCASE ASC
            """, [artistId], Self.song)
    }

    /// Songs whose unresolved credit contains this artist's exact standalone name (presentation only).
    func unverifiedSongs(artistKey: String) throws -> [Song] {
        try db.query("""
            SELECT DISTINCT s.* FROM songs s
            INNER JOIN unverified_credit_segment u ON u.song_id = s.id
            WHERE u.segment_key = ?
            ORDER BY s.title COLLATE NOCASE ASC
            """, [artistKey], Self.song)
    }

    func recentlyAddedSongs(limit: Int) throws -> [Song] {
        try db.query("SELECT * FROM songs ORDER BY date_modified DESC, id DESC LIMIT ?", [limit], Self.song)
    }

    func lyrics(songId: Int64) throws -> String? {
        try db.query("SELECT lyrics FROM songs WHERE id = ?", [songId]) { $0.optionalString("lyrics") }.first ?? nil
    }

    func updateSongTags(songId: Int64, title: String, artist: String, album: String) throws {
        try db.execute("UPDATE songs SET title = ?, artist = ?, album = ? WHERE id = ?", [title, artist, album, songId])
    }

    func updateBpm(songId: Int64, bpm: Int?) throws {
        try db.execute("UPDATE songs SET bpm = ? WHERE id = ?", [bpm, songId])
    }

    func updateFilePath(songId: Int64, path: String) throws {
        try db.execute("UPDATE songs SET file_path = ?, uri = ? WHERE id = ?", [path, path, songId])
    }

    /// Every song's facts for the smart mixes, by id.
    func trackFacts() throws -> [TrackFacts] {
        try db.query("""
            SELECT id, title, artist, artist_id, album, album_id, genre, bpm, year, duration_ms, is_favorite, date_modified
            FROM songs ORDER BY id
            """) { r in
            TrackFacts(
                songId: r.int64("id"), title: r.string("title"), artistId: r.int64("artist_id"), artist: r.string("artist"),
                albumId: r.int64("album_id"), album: r.string("album"), genre: r.optionalString("genre"), bpm: r.optionalInt("bpm"),
                durationMs: r.int64("duration_ms"), isFavorite: r.bool("is_favorite"), addedAt: r.int64("date_modified"),
                year: r.optionalInt("year")
            )
        }
    }

    /// Lyrics characters read for discovery: an excerpt is all VYBE uses.
    static let lyricsExcerptChars = 600

    func songTags() throws -> [SongTags] {
        try db.query("""
            SELECT id, title, artist, album, genre, year, bpm, substr(lyrics, 1, \(Self.lyricsExcerptChars)) AS lyricsExcerpt
            FROM songs ORDER BY id
            """) { r in
            SongTags(songId: r.int64("id"), title: r.string("title"), artist: r.string("artist"), album: r.string("album"),
                     genre: r.optionalString("genre"), year: r.int("year"), bpm: r.optionalInt("bpm"),
                     lyricsExcerpt: r.optionalString("lyricsExcerpt"))
        }
    }
}

// MARK: - Albums and artists

extension LibraryDatabase {
    func allAlbums() throws -> [Album] {
        try db.query("SELECT * FROM albums ORDER BY title COLLATE NOCASE ASC", [], Self.album)
    }

    func album(id: Int64) throws -> Album? {
        try db.query("SELECT * FROM albums WHERE id = ? LIMIT 1", [id], Self.album).first
    }

    /// Albums listed under this artist (album artist, or a core artist of a collaborative album).
    func albumsOfArtist(_ artistId: Int64) throws -> [Album] {
        try db.query("""
            SELECT a.* FROM albums a
            INNER JOIN album_artist_cross_ref l ON l.album_id = a.id
            WHERE l.artist_id = ?
            ORDER BY a.year DESC, a.title ASC
            """, [artistId], Self.album)
    }

    func allArtists() throws -> [Artist] {
        try db.query("SELECT * FROM artists ORDER BY name COLLATE NOCASE ASC", [], Self.artist)
    }

    func artist(id: Int64) throws -> Artist? {
        try db.query("SELECT * FROM artists WHERE id = ? LIMIT 1", [id], Self.artist).first
    }

    func aliases() throws -> [String: String] {
        Dictionary(try db.query("SELECT * FROM artist_alias") { ($0.string("alias_key"), $0.string("canonical_key")) },
                   uniquingKeysWith: { first, _ in first })
    }

    func artistArtworkByKey() throws -> [String: String] {
        Dictionary(try db.query("SELECT * FROM artist_artwork") { ($0.string("artist_key"), $0.string("artwork_uri")) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Stores an artist's artwork (custom or automatic) and copies it onto the artist row.
    func setArtistArtwork(key: String, path: String, source: String, providerArtistId: Int64? = nil, matcherVersion: Int = 0) throws {
        try db.transaction {
            try db.execute("""
                INSERT OR REPLACE INTO artist_artwork (artist_key, artwork_uri, updated_at, source, provider_artist_id, matcher_version)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [key, path, Self.now(), source, providerArtistId, matcherVersion])
            try db.execute("""
                UPDATE artists SET artwork_uri = (SELECT w.artwork_uri FROM artist_artwork w WHERE w.artist_key = artists.artist_key)
                WHERE artist_key = ?
                """, [key])
        }
    }

    func artistArtworkRow(key: String) throws -> (path: String, source: String, updatedAt: Int64, matcherVersion: Int)? {
        try db.query("SELECT * FROM artist_artwork WHERE artist_key = ? LIMIT 1", [key]) {
            ($0.string("artwork_uri"), $0.string("source"), $0.int64("updated_at"), $0.int("matcher_version"))
        }.first
    }

    /// Removes a custom image's row only; automatic rows are never deleted.
    func deleteCustomArtistArtwork(key: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM artist_artwork WHERE artist_key = ? AND source = 'CUSTOM'", [key])
            try db.execute("""
                UPDATE artists SET artwork_uri = (SELECT w.artwork_uri FROM artist_artwork w WHERE w.artist_key = artists.artist_key)
                WHERE artist_key = ?
                """, [key])
        }
    }
}

// MARK: - Playlists (PlaylistDao)

extension LibraryDatabase {
    /// Counts only songs that still exist in the library.
    func playlists() throws -> [Playlist] {
        try db.query("""
            SELECT p.id AS id, p.name AS name, p.artwork_uri AS artworkUri, COUNT(s.id) AS songCount
            FROM playlists p
            LEFT JOIN playlist_song_cross_ref ref ON ref.playlist_id = p.id
            LEFT JOIN songs s ON s.id = ref.song_id
            GROUP BY p.id
            ORDER BY p.name COLLATE NOCASE ASC
            """, [], Self.playlist)
    }

    func playlistEntries(_ playlistId: Int64) throws -> [PlaylistEntry] {
        try db.query("""
            SELECT s.*, ref.position AS entry_position FROM songs s
            INNER JOIN playlist_song_cross_ref ref ON s.id = ref.song_id
            WHERE ref.playlist_id = ?
            ORDER BY ref.position ASC
            """, [playlistId]) { PlaylistEntry(song: Self.song($0), position: $0.int("entry_position")) }
    }

    @discardableResult
    func createPlaylist(name: String, songIds: [Int64] = []) throws -> Int64 {
        try db.transaction {
            let now = Self.now()
            try db.execute("INSERT INTO playlists (name, created_at, updated_at) VALUES (?, ?, ?)", [name, now, now])
            let id = db.lastInsertRowId
            for (position, songId) in songIds.enumerated() {
                try db.execute("INSERT INTO playlist_song_cross_ref (playlist_id, song_id, position) VALUES (?, ?, ?)",
                               [id, songId, position])
            }
            return id
        }
    }

    func renamePlaylist(_ playlistId: Int64, name: String) throws {
        try db.execute("UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?", [name, Self.now(), playlistId])
    }

    func deletePlaylist(_ playlistId: Int64) throws {
        try db.transaction {
            try db.execute("DELETE FROM playlist_song_cross_ref WHERE playlist_id = ?", [playlistId])
            try db.execute("DELETE FROM playlists WHERE id = ?", [playlistId])
            try db.execute("DELETE FROM recently_played WHERE kind = 'PLAYLIST' AND item_id = ?", [playlistId])
        }
    }

    func playlistArtwork(_ playlistId: Int64) throws -> String? {
        try db.query("SELECT artwork_uri FROM playlists WHERE id = ?", [playlistId]) { $0.optionalString("artwork_uri") }.first ?? nil
    }

    func setPlaylistArtwork(_ playlistId: Int64, path: String?) throws {
        try db.execute("UPDATE playlists SET artwork_uri = ?, updated_at = ? WHERE id = ?", [path, Self.now(), playlistId])
    }

    /// Appends [songId]; a song already in the playlist is left where it is. False if it was already there.
    @discardableResult
    func appendSong(_ songId: Int64, toPlaylist playlistId: Int64) throws -> Bool {
        try db.transaction {
            let exists = try db.query("SELECT EXISTS(SELECT 1 FROM playlist_song_cross_ref WHERE playlist_id = ? AND song_id = ?) AS e",
                                      [playlistId, songId]) { $0.bool("e") }.first ?? false
            if exists { return false }
            let maxPosition = try db.query("SELECT COALESCE(MAX(position), -1) AS m FROM playlist_song_cross_ref WHERE playlist_id = ?",
                                           [playlistId]) { $0.int("m") }.first ?? -1
            try db.execute("INSERT INTO playlist_song_cross_ref (playlist_id, song_id, position) VALUES (?, ?, ?)",
                           [playlistId, songId, maxPosition + 1])
            try db.execute("UPDATE playlists SET updated_at = ? WHERE id = ?", [Self.now(), playlistId])
            return true
        }
    }

    func removeSong(_ songId: Int64, fromPlaylist playlistId: Int64) throws {
        try db.execute("DELETE FROM playlist_song_cross_ref WHERE playlist_id = ? AND song_id = ?", [playlistId, songId])
        try db.execute("UPDATE playlists SET updated_at = ? WHERE id = ?", [Self.now(), playlistId])
    }
}

// MARK: - Recently played (RecentlyPlayedDao)

extension LibraryDatabase {
    func recordAlbumOfSongPlayed(_ songId: Int64) throws {
        try db.execute("""
            INSERT OR REPLACE INTO recently_played (kind, item_id, played_at)
            SELECT 'ALBUM', album_id, ? FROM songs WHERE id = ?
            """, [Self.now(), songId])
    }

    func markPlaylistPlayed(_ playlistId: Int64) throws {
        try db.execute("INSERT OR REPLACE INTO recently_played (kind, item_id, played_at) VALUES ('PLAYLIST', ?, ?)",
                       [playlistId, Self.now()])
    }

    func recentAlbums(limit: Int) throws -> [Album] {
        try db.query("""
            SELECT a.* FROM albums a
            INNER JOIN recently_played r ON r.kind = 'ALBUM' AND r.item_id = a.id
            ORDER BY r.played_at DESC
            LIMIT ?
            """, [limit], Self.album)
    }

    func recentPlaylists(limit: Int) throws -> [Playlist] {
        try db.query("""
            SELECT p.id AS id, p.name AS name, p.artwork_uri AS artworkUri, COUNT(s.id) AS songCount
            FROM recently_played r
            INNER JOIN playlists p ON r.kind = 'PLAYLIST' AND r.item_id = p.id
            LEFT JOIN playlist_song_cross_ref ref ON ref.playlist_id = p.id
            LEFT JOIN songs s ON s.id = ref.song_id
            GROUP BY p.id
            ORDER BY MAX(r.played_at) DESC
            LIMIT ?
            """, [limit], Self.playlist)
    }
}

// MARK: - Bookmarks and waveform cache

extension LibraryDatabase {
    static let maxBookmarkLabelLength = 60

    func bookmarks(songId: Int64) throws -> [TrackBookmark] {
        try db.query("SELECT * FROM track_bookmarks WHERE song_id = ? ORDER BY position_ms ASC, id ASC", [songId]) {
            TrackBookmark(id: $0.int64("id"), songId: $0.int64("song_id"), positionMs: $0.int64("position_ms"),
                          label: $0.string("label"), createdAt: $0.int64("created_at"))
        }
    }

    @discardableResult
    func addBookmark(songId: Int64, positionMs: Int64, label: String = "") throws -> Int64 {
        try db.execute("INSERT INTO track_bookmarks (song_id, position_ms, label, created_at) VALUES (?, ?, ?, ?)",
                       [songId, max(positionMs, 0), String(label.trimmed.prefix(Self.maxBookmarkLabelLength)), Self.now()])
        return db.lastInsertRowId
    }

    func renameBookmark(id: Int64, label: String) throws {
        try db.execute("UPDATE track_bookmarks SET label = ? WHERE id = ?", [String(label.trimmed.prefix(Self.maxBookmarkLabelLength)), id])
    }

    func deleteBookmark(id: Int64) throws {
        try db.execute("DELETE FROM track_bookmarks WHERE id = ?", [id])
    }

    func cachedWaveform(songId: Int64) throws -> (sourceUri: String, fileSize: Int64, dateModified: Int64, formatVersion: Int, levels: Data)? {
        try db.query("SELECT * FROM waveform_cache WHERE song_id = ? LIMIT 1", [songId]) {
            ($0.string("source_uri"), $0.int64("file_size"), $0.int64("date_modified"), $0.int("format_version"), $0.data("levels"))
        }.first
    }

    func storeWaveform(songId: Int64, sourceUri: String, fileSize: Int64, dateModified: Int64, formatVersion: Int, levels: Data) throws {
        try db.execute("""
            INSERT OR REPLACE INTO waveform_cache (song_id, source_uri, file_size, date_modified, format_version, levels, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [songId, sourceUri, fileSize, dateModified, formatVersion, levels, Self.now()])
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
