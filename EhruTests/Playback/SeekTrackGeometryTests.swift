import CoreGraphics
import XCTest
@testable import Ehru

final class SeekTrackGeometryTests: XCTestCase {
    func testEndpointsReserveTheWholeThumbAndGlow() {
        let track = SeekTrackGeometry(width: 320)
        XCTAssertEqual(track.x(at: 0), 12)
        XCTAssertEqual(track.x(at: 1), 308)
        XCTAssertEqual(track.fraction(at: 0), 0)
        XCTAssertEqual(track.fraction(at: 320), 1)
    }

    func testTouchAndDrawingAgreeAcrossTheTrack() {
        for width: CGFloat in [0, 16, 24, 100, 320, 600] {
            let track = SeekTrackGeometry(width: width)
            XCTAssertGreaterThanOrEqual(track.start, 0)
            XCTAssertGreaterThanOrEqual(track.length, 0)
            for fraction: Float in [0, 0.1, 0.5, 0.9, 1] where track.length > 0 {
                XCTAssertEqual(track.fraction(at: track.x(at: fraction)), fraction, accuracy: 0.00001)
            }
        }
        XCTAssertEqual(SeekTrackGeometry(width: 0).fraction(at: 10), 0)
    }
}
