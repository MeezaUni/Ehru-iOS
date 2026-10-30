import XCTest
@testable import Erhu

final class DatabaseTests: XCTestCase {
    private func insertSong(_ db: LibraryDatabase, _ id: Int64, title: String = "Song", albumId: Int64 = 1) throws {
        try db.db.execute("""
            INSERT INTO songs (id, title, artist, album, artist_id, album_id, duration_ms, uri, file_path, track_number, year, date_modified)
            VALUES (?, ?, 'Artist', 'Album', 0, ?, 180000, ?, ?, 1, 2020, 0)
            """, [id, title, albumId, "\(id).mp3", "\(id).mp3"])
    }

    func testPlaylistsKeepDuplicatesInOrderAndCountOnlyExistingSongs() throws {
        let db = try LibraryDatabase.inMemory()
        for id in Int64(1)...3 { try insertSong(db, id, title: "S\(id)") }
        let id = try db.createPlaylist(name: "Saved queue", songIds: [1, 2, 1, 99])
        XCTAssertEqual([1, 2, 1], try db.playlistEntries(id).map(\.song.id))
        XCTAssertEqual([0, 1, 2], try db.playlistEntries(id).map(\.position))
        XCTAssertEqual(3, try db.playlists().first!.songCount)
        XCTAssertFalse(try db.appendSong(2, toPlaylist: id))
        XCTAssertTrue(try db.appendSong(3, toPlaylist: id))
        XCTAssertEqual(4, try db.playlistEntries(id).last!.position)
        try db.deletePlaylist(id)
        XCTAssertTrue(try db.playlists().isEmpty)
    }

    func testListeningStatsRankAndCountStreaks() throws {
        let db = try LibraryDatabase.inMemory()
        try insertSong(db, 1, title: "A")
        try insertSong(db, 2, title: "B")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }
        try db.recordPlay(songId: 2, at: day(1), calendar: calendar)
        try db.recordPlay(songId: 1, at: day(2), calendar: calendar)
        try db.recordPlay(songId: 1, at: day(3), calendar: calendar)
        try db.recordPlay(songId: 999, at: day(3), calendar: calendar) // unknown: nothing recorded
        try db.addListened(songId: 1, ms: 90_000, at: day(3), calendar: calendar)
        let capsule = try db.capsule(month: "2026-10")
        XCTAssertEqual(3, capsule.totalPlays)
        XCTAssertEqual(90_000, capsule.listenedMs)
        XCTAssertEqual(["A", "B"], capsule.topSongs.map(\.song.title))
        XCTAssertEqual(3, capsule.longestStreakDays)
        XCTAssertEqual(["2026-10"], try db.listeningMonths())
        XCTAssertEqual([1, 2], try db.smartPlaylistSongs(.mostPlayed).map(\.id))
        XCTAssertTrue(try db.smartPlaylistSongs(.neverPlayed).isEmpty)
    }

    func testStreakMayStartBeforeTheMonthButNotAfter() {
        let days = ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-05", "2026-11-01"]
        XCTAssertEqual(4, LibraryDatabase.longestStreakTouching(days: days, month: "2026-10"))
        XCTAssertEqual(3, LibraryDatabase.longestStreakTouching(days: days, month: "2026-09"))
        XCTAssertEqual(0, LibraryDatabase.longestStreakTouching(days: days, month: "2026-08"))
    }

    func testBookmarksAndFavorites() throws {
        let db = try LibraryDatabase.inMemory()
        try insertSong(db, 1)
        try db.addBookmark(songId: 1, positionMs: 30_000, label: "  " + String(repeating: "x", count: 80))
        try db.addBookmark(songId: 1, positionMs: 10_000)
        XCTAssertEqual([10_000, 30_000], try db.bookmarks(songId: 1).map(\.positionMs))
        XCTAssertEqual(60, try db.bookmarks(songId: 1)[1].label.count)
        try db.toggleFavorite(songId: 1)
        XCTAssertTrue(try db.song(id: 1)!.isFavorite)
        XCTAssertEqual([1], try db.smartPlaylistSongs(.favorites).map(\.id))
    }

    func testAlbumTrackOrderUsesDiscThenTrackWithUnknownTracksLast() throws {
        let db = try LibraryDatabase.inMemory()
        for id in Int64(1)...6 { try insertSong(db, id, title: "\(7 - id)") }
        for (id, disc, track) in [(1, 2, 1), (2, 1, 10), (3, 1, 2), (4, 1, 0), (5, 2, 2), (6, 0, 1)] {
            try db.db.execute("UPDATE songs SET disc_number = ?, track_number = ? WHERE id = ?", [disc, track, id])
        }
        XCTAssertEqual(try db.songsOfAlbum(1).map(\.id), [6, 3, 2, 4, 1, 5])
    }
}

final class ScannerTests: XCTestCase {
    func testScanBuildsAlbumsKeepsFavoritesAndDropsDeletedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("IGOR"), withIntermediateDirectories: true)
        try TagFixtures.mp3(v4: true).write(to: folder.appendingPathComponent("IGOR/one.mp3"))
        try TagFixtures.mp3(v4: false).write(to: folder.appendingPathComponent("IGOR/two.mp3"))
        try TagFixtures.flac().write(to: folder.appendingPathComponent("nightmare.flac"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, folder: folder)

        var last = ScanProgress()
        let summary = try scanner.scan { last = $0 }
        XCTAssertTrue(last.isComplete)
        XCTAssertEqual(3, summary.upserted)
        XCTAssertEqual(["IGOR", "Without Warning"], try db.allAlbums().map(\.title))
        XCTAssertEqual("Tyler, The Creator", try db.allAlbums()[0].artist)
        XCTAssertEqual(["Tyler, The Creator"], try db.allArtists().filter { $0.key == "tyler, the creator" }.map(\.name))

        let nightmare = try db.allSongs().first { $0.title == "Nightmare" }!
        try db.setFavorite(songId: nightmare.id, true)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("IGOR/two.mp3"))
        let second = try scanner.scan()
        XCTAssertEqual(1, second.removed)
        XCTAssertEqual(2, try db.allSongs().count)
        XCTAssertTrue(try db.song(id: nightmare.id)!.isFavorite)
        XCTAssertEqual("words", try db.lyrics(songId: nightmare.id))
    }
}

private extension Artist {
    var key: String { artistKey }
}
