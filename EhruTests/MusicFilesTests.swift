import XCTest
@testable import Ehru

final class MusicFilesTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/music")

    func testKeepsNameWhenFree() {
        let url = MusicFiles.uniqueDestination(for: "Song.mp3", in: folder) { _ in false }
        XCTAssertEqual(url.lastPathComponent, "Song.mp3")
    }

    func testNumbersTakenNames() {
        let taken: Set<String> = ["Song.mp3", "Song 2.mp3"]
        let url = MusicFiles.uniqueDestination(for: "Song.mp3", in: folder) { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(url.lastPathComponent, "Song 3.mp3")
    }

    func testNumbersNamesWithoutExtension() {
        let url = MusicFiles.uniqueDestination(for: "Song", in: folder) { $0.lastPathComponent == "Song" }
        XCTAssertEqual(url.lastPathComponent, "Song 2")
    }

    func testDurationFormatting() {
        XCTAssertEqual(TimeInterval(0).formattedDuration, "0:00")
        XCTAssertEqual(TimeInterval(187.9).formattedDuration, "3:07")
        XCTAssertEqual(TimeInterval(3729).formattedDuration, "1:02:09")
        XCTAssertEqual(TimeInterval.nan.formattedDuration, "0:00")
    }

    func testSubtitleSkipsMissingParts() {
        let url = URL(fileURLWithPath: "/music/a.mp3")
        XCTAssertEqual(Song(url: url, title: "A", artist: "X", album: "Y", duration: 0).subtitle, "X — Y")
        XCTAssertEqual(Song(url: url, title: "A", artist: "", album: "Y", duration: 0).subtitle, "Y")
        XCTAssertEqual(Song(url: url, title: "A", artist: "", album: "", duration: 0).subtitle, "Unknown artist")
    }
}
