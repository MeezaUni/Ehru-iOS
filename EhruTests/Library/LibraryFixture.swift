import XCTest
@testable import Ehru

/// The real-library fixture shared with the Android tests: 104 rows from public albums.
enum LibraryFixture {
    static let tracks: [RawTrack] = {
        let url = Bundle(for: BundleToken.self).url(forResource: "library_fixture", withExtension: "tsv")!
        let lines = try! String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        return lines.dropFirst().map { line in
            let c = line.components(separatedBy: "\t")
            let track = Int(c[5]) ?? 0
            return RawTrack(
                songId: Int64(c[0])!, title: c[1], rawArtist: c[2], rawAlbumArtist: c[3].isBlank ? nil : c[3],
                album: c[4], trackNumber: track % 1000, discNumber: track / 1000, folder: c[6], isCompilation: c[7] == "1"
            )
        }
    }()

    static func songId(_ title: String) -> Int64 { tracks.first { $0.title == title }!.songId }

    private final class BundleToken {}
}

func rawTrack(_ id: Int64, _ title: String, _ artist: String, _ albumArtist: String?, _ album: String,
              _ track: Int, _ disc: Int, _ folder: String, _ compilation: Bool = false) -> RawTrack {
    RawTrack(songId: id, title: title, rawArtist: artist, rawAlbumArtist: albumArtist, album: album,
             trackNumber: track, discNumber: disc, folder: folder, isCompilation: compilation)
}
