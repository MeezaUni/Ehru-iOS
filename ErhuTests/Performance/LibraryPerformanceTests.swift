import XCTest
@testable import Erhu

/// CI records wall time and CPU time in the xcresult. Compare runs on the same runner/Xcode;
/// simulator timings cannot measure physical-device energy consumption or temperature.
final class LibraryPerformanceTests: XCTestCase {
    func testBuildTenThousandTrackLibrary() {
        let tracks = (0..<10_000).map { i in
            RawTrack(songId: Int64(i + 1), title: "Track \(i)", rawArtist: "Artist \(i / 100)",
                     rawAlbumArtist: "Artist \(i / 100)", album: "Album \(i / 10)", trackNumber: i % 10 + 1,
                     discNumber: 1, folder: "Music/\(i / 10)", isCompilation: false)
        }
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            let model = LibraryModelBuilder.build(tracks, aliases: [:])
            XCTAssertEqual(model.songs.count, tracks.count)
            XCTAssertEqual(model.albums.count, 1_000)
        }
    }
}
