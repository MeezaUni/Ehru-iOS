import XCTest
@testable import Ehru

final class PlaybackSourceTests: XCTestCase {
    func testQueueEntriesUseTheirRealCollectionAndExplicitDiscoverySource() {
        let song = testSong(1)
        let origin = QueueOrigin(collection: .playlist(9), occurrence: TrackOccurrence(song.id, 2))
        XCTAssertEqual(QueueEntry(song: song, origin: origin).source, .playlist(9))
        XCTAssertEqual(QueueEntry(song: song, source: .smartPlaylist("quick_hits")).source, .smartPlaylist("quick_hits"))
        XCTAssertEqual(QueueEntry(song: song).source, .library)
    }

    func testSourcesStayAlignedAcrossDeletedSongsAndDuplicateOccurrences() throws {
        let sources: [PlaybackSource] = [.playlist(9), .album(7), .smartPlaylist("quick_hits"), .favorites]
        let saved = PersistedPlaybackState(queueSongIds: [1, 2, 1, 3], currentIndex: 2,
                                          positionMs: 12_000, queueSources: sources)
        let decoded = try JSONDecoder().decode(PersistedPlaybackState.self, from: JSONEncoder().encode(saved))
        let restored = try XCTUnwrap(buildRestoredQueue(decoded, available: [testSong(1), testSong(3)]))
        XCTAssertEqual(restored.songs.map(\.id), [1, 1, 3])
        XCTAssertEqual(restored.sources, [.playlist(9), .smartPlaylist("quick_hits"), .favorites])
        XCTAssertEqual(restored.startIndex, 1)
        XCTAssertEqual(restored.startPositionMs, 12_000)
    }

    func testOldSavedQueuesStillDecodeAndRecoverAlbumOrPlaylistOrigins() throws {
        let json = #"{"queueSongIds":[1,2],"currentIndex":0,"positionMs":5000,"shuffleModeEnabled":false,"repeatMode":"OFF","queueCollectionKeys":["album:7#s1","playlist:9#s2@4"]}"#
        let saved = try JSONDecoder().decode(PersistedPlaybackState.self, from: Data(json.utf8))
        XCTAssertNil(saved.queueSources)
        let restored = try XCTUnwrap(buildRestoredQueue(saved, available: [testSong(1), testSong(2)]))
        XCTAssertEqual(restored.sources, [.album(7), .playlist(9)])
    }

    @MainActor
    func testOpeningTheSourceClosesPlayerAndRevealsTheCorrectSection() {
        let router = AppRouter()
        router.showsNowPlaying = true
        router.showsDrawer = true
        router.showsSearch = true
        router.reveal(.playlist(9))
        XCTAssertFalse(router.showsNowPlaying)
        XCTAssertFalse(router.showsDrawer)
        XCTAssertFalse(router.showsSearch)
        XCTAssertEqual(router.section, .library)
        XCTAssertEqual(router.paths[.library]?.count, 1)
        router.reveal(.album(7))
        XCTAssertEqual(router.section, .albums)
        XCTAssertEqual(router.paths[.albums]?.count, 1)
        router.reveal(.smartPlaylist("quick_hits"))
        XCTAssertEqual(router.section, .home)
        router.reveal(.vybe)
        XCTAssertEqual(router.section, .vybe)
        XCTAssertEqual(router.paths[.vybe]?.count, 0)
    }
}
