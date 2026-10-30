import AVFoundation
import Foundation

struct ScanProgress: Equatable, Sendable {
    var scanned = 0
    var total = 0
    var currentTitle: String?
    var isComplete = false
}

struct WriteSummary: Equatable, Sendable {
    let upserted: Int
    let removed: Int
    let albums: Int
}

/// One audio file found in the music folder.
struct FoundFile: Equatable {
    let url: URL
    let path: String
    let size: Int64
    let modified: Int64
}

/// A song as the scanner wants to store it, with the raw tags album grouping and credits need.
struct ScannedSong: Equatable {
    var song: Song
    var raw: RawTrack
    var lyrics: String?
}

/// Builds the library from the files in the music folder (Android's MediaStoreScanner + tag
/// enrichment + LibraryWriter). Unchanged files (same path, size and modification time) are not
/// read again; everything else is read from its own tags. One scan is one transaction: a failed
/// scan leaves the previous library intact.
final class LibraryScanner: @unchecked Sendable {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "mp4", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf"]

    private let database: LibraryDatabase
    private let folder: URL

    init(database: LibraryDatabase, folder: URL = LibraryPaths.musicFolder) {
        self.database = database
        self.folder = folder
    }

    static func songId(forPath path: String) -> Int64 {
        IdentityHash.of("file:\(path)")
    }

    func scan(progress: (ScanProgress) -> Void = { _ in }) throws -> WriteSummary {
        let files = Self.audioFiles(in: folder)
        progress(ScanProgress(scanned: 0, total: files.count))
        let stored = try storedSongs()
        var scanned: [ScannedSong] = []
        scanned.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            let id = Self.songId(forPath: file.path)
            if let existing = stored[id], existing.song.dateModified == file.modified, existing.song.fileSize == file.size,
               existing.song.path == file.path {
                scanned.append(existing)
            } else {
                var fresh = Self.read(file, id: id)
                fresh.song.isFavorite = stored[id]?.song.isFavorite ?? false
                scanned.append(fresh)
            }
            if index % 25 == 0 || index == files.count - 1 {
                progress(ScanProgress(scanned: index + 1, total: files.count, currentTitle: scanned.last?.song.title))
            }
        }
        let model = LibraryModelBuilder.build(scanned.map(\.raw), aliases: try database.aliases())
        let summary = try write(model: model, scanned: scanned, previousIds: Set(stored.keys))
        progress(ScanProgress(scanned: files.count, total: files.count, isComplete: true))
        return summary
    }

    /// Every playable file under [folder] (subfolders included, hidden files skipped), by path.
    static func audioFiles(in folder: URL) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [FoundFile] = []
        for case let url as URL in enumerator where audioExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let path = LibraryPaths.relativePath(of: url, in: folder)
            else { continue }
            found.append(FoundFile(
                url: url, path: path, size: Int64(values.fileSize ?? 0),
                modified: Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
            ))
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Reads one file's tags and audio format.
    static func read(_ file: FoundFile, id: Int64) -> ScannedSong {
        let tags = TagReader.read(file.url)
        let format = AudioFormatInfo.read(file.url, fileSize: file.size)
        let fileTitle = file.url.deletingPathExtension().lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        let rawArtist = tags.artist ?? ""
        let rawAlbum = tags.album ?? ""
        var year = tags.year ?? 0
        if !(1900...2099).contains(year) { year = 0 }
        let song = Song(
            id: id,
            title: tags.title?.nonBlank ?? fileTitle,
            artist: rawArtist.nonBlank ?? unknownArtist,
            album: rawAlbum.nonBlank ?? unknownAlbum,
            durationMs: format.durationMs,
            path: file.path,
            trackNumber: max(tags.trackNumber ?? 0, 0),
            discNumber: max(tags.discNumber ?? 1, 1),
            year: year,
            dateModified: file.modified,
            genre: Genres.join(tags.genres),
            bpm: usableBpm(tags.bpmText),
            composer: tags.composer,
            fileSize: file.size,
            codec: format.codec,
            sampleRate: format.sampleRate,
            bitrate: format.bitrate,
            channels: format.channels
        )
        let raw = RawTrack(
            songId: id, title: song.title, rawArtist: rawArtist, rawAlbumArtist: tags.albumArtist?.nonBlank,
            album: rawAlbum, trackNumber: song.trackNumber, discNumber: tags.discNumber ?? 0, folder: folder,
            isCompilation: tags.isCompilation
        )
        return ScannedSong(song: song, raw: raw, lyrics: tags.lyrics?.nonBlank)
    }

    private func storedSongs() throws -> [Int64: ScannedSong] {
        let rows = try database.db.query("SELECT * FROM songs") { r -> ScannedSong in
            let song = LibraryDatabase.song(r)
            let raw = RawTrack(
                songId: song.id, title: song.title, rawArtist: r.string("raw_artist"),
                rawAlbumArtist: r.optionalString("raw_album_artist"), album: r.string("raw_album"),
                trackNumber: song.trackNumber, discNumber: song.discNumber,
                folder: (song.path as NSString).deletingLastPathComponent, isCompilation: r.bool("is_compilation")
            )
            return ScannedSong(song: song, raw: raw, lyrics: r.optionalString("lyrics"))
        }
        return Dictionary(rows.map { ($0.song.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Writes one scan atomically: derived tables are replaced; favorites, playlists, statistics,
    /// bookmarks, artwork and aliases are kept.
    private func write(model: LibraryModel, scanned: [ScannedSong], previousIds: Set<Int64>) throws -> WriteSummary {
        let db = database.db
        let scannedIds = Set(scanned.map(\.song.id))
        let removed = Array(previousIds.subtracting(scannedIds))
        let artwork = try database.artistArtworkByKey()
        let songById = Dictionary(scanned.map { ($0.song.id, $0) }, uniquingKeysWith: { first, _ in first })
        try db.transaction {
            for chunk in removed.chunked(into: 500) {
                try db.execute("DELETE FROM songs WHERE id IN (\(placeholders(chunk.count)))", chunk)
            }
            for item in scanned {
                try insert(item, assignment: model.songs[item.song.id], into: db)
            }
            for table in ["song_artist_cross_ref", "albums", "artists", "album_artist_cross_ref", "unverified_credit_segment"] {
                try db.execute("DELETE FROM \(table)")
            }
            for credit in model.credits {
                try db.execute("""
                    INSERT OR REPLACE INTO song_artist_cross_ref (song_id, artist_id, role, position, credit_text, is_unresolved)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, [credit.songId, credit.artistId, credit.role.rawValue, credit.position, credit.creditText, credit.isUnresolved])
            }
            for album in model.albums {
                // Year and artwork come from the album's first track.
                let first = album.songIds.compactMap { songById[$0]?.song }
                    .min { ($0.discNumber, $0.trackNumber, $0.id) < ($1.discNumber, $1.trackNumber, $1.id) }
                try db.execute("""
                    INSERT OR REPLACE INTO albums (id, title, artist, artist_id, song_count, year, artwork_uri, is_compilation,
                        album_artist_inconsistent, grouping_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [album.id, album.title, album.displayArtist, album.leadArtistId, album.songIds.count, first?.year ?? 0,
                          first?.path, album.isCompilation, album.albumArtistInconsistent, album.groupingKey])
            }
            for artist in model.artists {
                try db.execute("""
                    INSERT OR REPLACE INTO artists (id, name, song_count, album_count, artwork_uri, artist_key, is_unresolved)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [artist.id, artist.name, artist.songCount, artist.albumCount, artwork[artist.key], artist.key, artist.isUnresolved])
            }
            for row in model.albumArtists {
                try db.execute("INSERT OR REPLACE INTO album_artist_cross_ref (album_id, artist_id, position) VALUES (?, ?, ?)",
                               [row.albumId, row.artistId, row.position])
            }
            for row in model.unverifiedSegments {
                try db.execute("""
                    INSERT OR REPLACE INTO unverified_credit_segment (song_id, artist_id, segment_key, segment_index)
                    VALUES (?, ?, ?, ?)
                    """, [row.songId, row.artistId, row.segmentKey, row.segmentIndex])
            }
        }
        return WriteSummary(upserted: scanned.count, removed: removed.count, albums: model.albums.count)
    }

    private func insert(_ item: ScannedSong, assignment: SongAssignment?, into db: SQLiteDatabase) throws {
        let s = item.song
        let artistId: Int64 = assignment?.primaryArtistId ?? 0
        let albumId: Int64 = assignment?.albumId ?? 0
        var args: [SQLBindable] = [s.id, s.title, s.artist, s.album, artistId, albumId, s.durationMs]
        args += [s.path, s.path, s.trackNumber, s.year, s.dateModified, s.path] as [SQLBindable]
        args += [item.lyrics, s.discNumber, s.composer, s.genre, s.isFavorite, s.bpm] as [SQLBindable]
        args += [s.fileSize, s.codec, s.sampleRate, s.bitrate, s.channels] as [SQLBindable]
        args += [item.raw.rawArtist, item.raw.rawAlbumArtist, item.raw.album, item.raw.isCompilation] as [SQLBindable]
        try db.execute("""
            INSERT OR REPLACE INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path,
                track_number, year, date_modified, artwork_uri, is_enriched, lyrics, disc_number, composer, genre,
                is_favorite, bpm, file_size, codec, sample_rate, bitrate, channels, raw_artist, raw_album_artist,
                raw_album, is_compilation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, args)
    }
}

/// Duration and format of an audio file, from its own headers (AVAudioFile).
struct AudioFormatInfo: Equatable {
    var durationMs: Int64 = 0
    var sampleRate = 0
    var channels = 2
    var bitrate = 0
    var codec: String?

    static func read(_ url: URL, fileSize: Int64) -> AudioFormatInfo {
        var info = AudioFormatInfo()
        info.codec = codecName(url)
        guard let file = try? AVAudioFile(forReading: url) else { return info }
        let rate = file.fileFormat.sampleRate
        info.sampleRate = Int(rate)
        info.channels = Int(file.fileFormat.channelCount)
        if rate > 0 {
            info.durationMs = Int64(Double(file.length) / rate * 1000)
        }
        if info.durationMs > 0 {
            info.bitrate = Int(Double(fileSize) * 8 / (Double(info.durationMs) / 1000))
        }
        return info
    }

    private static func codecName(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "MP3"
        case "flac": return "FLAC"
        case "wav", "wave": return "WAV"
        case "aif", "aiff", "aifc": return "AIFF"
        case "caf": return "CAF"
        default: return "AAC/ALAC"
        }
    }
}

extension LibraryPaths {
    static func relativePath(of url: URL, in folder: URL) -> String? {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base) else { return nil }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
