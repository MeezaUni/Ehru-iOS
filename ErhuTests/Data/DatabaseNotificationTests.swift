import XCTest
@testable import Erhu

final class DatabaseNotificationTests: XCTestCase {
    @MainActor
    func testWaveformWritesDoNotInvalidateLibraryAndDiscoveryInputs() async throws {
        let db = try LibraryDatabase.inMemory()
        // Drain the schema notification before observing individual writes.
        let ready = expectation(forNotification: SQLiteDatabase.didChange, object: db.db)
        await fulfillment(of: [ready], timeout: 2)
        let changed = expectation(forNotification: SQLiteDatabase.didChange, object: db.db) { note in
            XCTAssertTrue(SQLiteDatabase.affects(note, tables: ["waveform_cache"]))
            XCTAssertFalse(SQLiteDatabase.affects(note, tables: ["songs", "listening_stats"]))
            return true
        }
        try db.storeWaveform(songId: 1, sourceUri: "one.mp3", fileSize: 10, dateModified: 0,
                             formatVersion: 1, levels: Data([0, 1]))
        await fulfillment(of: [changed], timeout: 2)
    }

    @MainActor
    func testCoalescedWritesPreserveAllAffectedTables() async throws {
        let db = try LibraryDatabase.inMemory()
        let ready = expectation(forNotification: SQLiteDatabase.didChange, object: db.db)
        await fulfillment(of: [ready], timeout: 2)
        let changed = expectation(forNotification: SQLiteDatabase.didChange, object: db.db) { note in
            XCTAssertTrue(SQLiteDatabase.affects(note, tables: ["playlists"]))
            XCTAssertTrue(SQLiteDatabase.affects(note, tables: ["track_bookmarks"]))
            XCTAssertFalse(SQLiteDatabase.affects(note, tables: ["songs"]))
            return true
        }
        _ = try db.createPlaylist(name: "Test")
        _ = try db.addBookmark(songId: 1, positionMs: 10)
        await fulfillment(of: [changed], timeout: 2)
    }
}
