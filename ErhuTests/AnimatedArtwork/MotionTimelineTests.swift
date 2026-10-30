import XCTest
@testable import Erhu

final class MotionTimelineTests: XCTestCase {
    private func box(_ name: String, _ body: Data) -> Data { Data.be32(body.count + 8) + Data(name.utf8) + body }
    private func fragment(_ value: UInt64, wide: Bool = true, track: Int = 1) -> Data {
        box("moof", box("traf", box("tfhd", Data.be32(0) + Data.be32(track))
                         + box("tfdt", Data([wide ? 1 : 0, 0, 0, 0]) + (wide ? Data.be64(value) : Data.be32(Int(value))))))
    }
    private func temp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: url)
        return url
    }

    func testNormalizesBothDecodeTimeWidthsWithoutTouchingAudioOrLength() throws {
        for wide in [false, true] {
            let bytes = fragment(240, wide: wide) + box("mdat", Data([1, 2, 3, 4])) + fragment(312, wide: wide)
            let url = try temp(bytes)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertTrue(try MotionTimeline.startAtZero(url))
            XCTAssertEqual(try Data(contentsOf: url), fragment(0, wide: wide) + box("mdat", Data([1, 2, 3, 4])) + fragment(72, wide: wide))
            XCTAssertFalse(try MotionTimeline.startAtZero(url))
        }
    }

    func testMultipleTracksAndMalformedBoxesAreNotPartlyRewritten() throws {
        let bytes = fragment(240) + fragment(300, track: 2)
        let url = try temp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try MotionTimeline.startAtZero(url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let broken = fragment(240) + Data.be32(100) + Data("moof".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try MotionTimeline.startAtZero(url))
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }
}
