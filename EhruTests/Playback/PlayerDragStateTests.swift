import XCTest
@testable import Ehru

final class PlayerDragStateTests: XCTestCase {
    @MainActor
    func testDragTracksTheFingerAndStopsDecorativeMotionUntilSettled() {
        let drag = PlayerDragState()
        drag.update(80)
        XCTAssertEqual(drag.translation, 80)
        XCTAssertTrue(drag.isMoving)
        drag.update(155)
        XCTAssertEqual(drag.translation, 155)
        drag.update(-20)
        XCTAssertEqual(drag.translation, 0)
        drag.restore()
        XCTAssertEqual(drag.translation, 0)
        XCTAssertTrue(drag.isMoving)
        drag.beginDismissal() // Cancel the settling task; motion stays suspended during removal.
        XCTAssertTrue(drag.isMoving)
    }
}
