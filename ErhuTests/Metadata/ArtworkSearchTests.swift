@testable import Erhu
import XCTest

/// Candidate lists are the real Deezer `search/artist` results the Android tests were written from.
final class DeezerArtistMatchTests: XCTestCase {
    private static let blank = "https://cdn-images.dzcdn.net/images/artist//500x500-000000-80-0-0.jpg"

    private func dto(_ id: Int64, _ name: String, _ fans: Int64, photo: Bool = true) -> DeezerArtist {
        DeezerArtist(id: id, name: name, pictureBig: photo ? "https://cdn-images.dzcdn.net/images/artist/h\(id)/500x500-000000-80-0-0.jpg" : Self.blank, nbFan: fans)
    }

    private func selected(_ name: String, _ candidates: [DeezerArtist]) -> Int64? {
        if case .selected(let id, _) = ArtworkSearch.selectDeezerArtist(name, candidates) { return id }
        return nil
    }

    private func rejected(_ name: String, _ candidates: [DeezerArtist]) -> Bool {
        if case .rejected = ArtworkSearch.selectDeezerArtist(name, candidates) { return true }
        return false
    }

    private func normalize(_ name: String) -> String { ArtworkSearch.normalizeArtistName(name) }

    func testNormalizationFoldsOnlyHarmlessDifferences() {
        XCTAssertEqual(normalize("  Tyler,   The CREATOR "), "tyler, the creator")
        XCTAssertEqual(normalize("Lil' Wayne"), normalize("Lil\u{2019} Wayne"))
        XCTAssertEqual(normalize("\"Weird Al\""), normalize("\u{201C}Weird Al\u{201D}"))
        XCTAssertEqual(normalize("Beyonc\u{00E9}"), normalize("Beyonce\u{0301}"))
        XCTAssertEqual(normalize("A$AP Rocky"), "a$ap rocky")
        XCTAssertNotEqual(normalize("Too $hort"), normalize("Too Short"))
        XCTAssertNotEqual(normalize("Metro Boomin'"), normalize("Metro Boomin"))
        XCTAssertNotEqual(normalize("Tyler, The Creator"), normalize("Tyler The Creator"))
    }

    func testASingleExactCandidateWithAPhotoIsAccepted() {
        XCTAssertEqual(selected("Che Ecru", [dto(12_060_520, "Che Ecru", 4331), dto(125_377, "Cherry Pie", 16322)]), 12_060_520)
        XCTAssertEqual(selected("Kanye West", [dto(230, "Kanye West", 4_550_285), dto(11_198_106, "Kanye West & Nas", 60)]), 230)
    }

    func testTheDominantSameNameProfileWins() {
        let drake = [dto(67_927_442, "Drake", 166), dto(67_926_762, "Drake", 141), dto(246_791, "Drake", 24_098_891),
                     dto(5_215_664, "Drake", 3824), dto(303_396_411, "Drake", 9), dto(2062, "Nick Drake", 103_112)]
        XCTAssertEqual(selected("Drake", drake), 246_791)
        let estelle = [dto(155_713_022, "Estelle", 4), dto(213_297_307, "ESTELLE", 7), dto(16745, "Estelle", 117_766)]
        XCTAssertEqual(selected("Estelle", estelle), 16745)
        XCTAssertEqual(selected("X", [dto(1, "X", 1000), dto(2, "X", 100)]), 1)
        XCTAssertTrue(rejected("X", [dto(1, "X", 999), dto(2, "X", 100)]))
    }

    func testAmbiguousZeroFansAndMissingPhotos() {
        XCTAssertTrue(rejected("Drake", [dto(1, "Drake", 166), dto(2, "Drake", 141)]))
        XCTAssertEqual(selected("$uicideboy$", [dto(10_159_994, "$uicideboy$", 699_601), dto(413_032_511, "$uicideboy$", 0, photo: false)]), 10_159_994)
        XCTAssertEqual(selected("X", [dto(1, "X", 10), dto(2, "X", 0)]), 1)
        XCTAssertTrue(rejected("X", [dto(1, "X", 9), dto(2, "X", 0)]))
        XCTAssertTrue(rejected("X", [dto(1, "X", 50_000, photo: false)]))
        XCTAssertTrue(rejected("X", [DeezerArtist(id: 1, name: "X", nbFan: 5)]))
        XCTAssertTrue(rejected("Metro Boomin", [dto(1, "Metro Boomin", 758_437, photo: false), dto(2, "Metro Boomin", 1)]))
        XCTAssertEqual(selected("Metro Boomin", [dto(4_968_870, "Metro Boomin", 758_437), dto(412_932_831, "Metro Boomin", 1, photo: false)]), 4_968_870)
    }

    func testNoExactNameMeansNotFound() {
        XCTAssertTrue(rejected("Too $hort", [dto(504_125, "Too Short", 151_079), dto(514_404, "Too $hort & Friends", 27)]))
        XCTAssertTrue(rejected("Metro Boomin", [dto(13_590_885, "Metro Boomin'", 15), dto(154_102_992, "Nav Metro Boomin", 647)]))
        XCTAssertTrue(rejected("X", []))
    }

    func testImageUrls() {
        XCTAssertEqual(ArtworkSearch.normalizeImageUrl("//upload.wikimedia.org/a.jpg"), "https://upload.wikimedia.org/a.jpg")
        XCTAssertEqual(ArtworkSearch.normalizeImageUrl("http://x/a.jpg"), "https://x/a.jpg")
        XCTAssertEqual(LibraryPaths.resolveImage("/abs/a.jpg"), "/abs/a.jpg")
        XCTAssertTrue(LibraryPaths.resolveImage("artist-art/a.jpg").hasSuffix("/artist-art/a.jpg"))
    }
}
