import XCTest
@testable import Ehru

final class PlayerDragStateTests: XCTestCase {
    @MainActor
    func testDragTracksTheFingerAndStopsDecorativeMotionUntilSettled() {
        let drag = PlayerDragState()
        drag.travel = 500
        drag.setPresented(true, reduceMotion: true)
        drag.finishEntrance(reduceMotion: true)
        drag.update(80)
        XCTAssertEqual(drag.translation, 80)
        XCTAssertEqual(drag.progress, 0.84, accuracy: 1e-6)
        XCTAssertTrue(drag.isMoving)
        XCTAssertTrue(drag.isCollapsing)
        drag.update(155)
        XCTAssertEqual(drag.translation, 155)
        drag.update(-20)
        XCTAssertEqual(drag.translation, 0)
        drag.restore()
        XCTAssertFalse(drag.isCollapsing)
        XCTAssertEqual(drag.translation, 0)
        XCTAssertEqual(drag.progress, 1)
        // Without an attached view, SwiftUI can complete an animation immediately.
        drag.beginDismissal() // Cancel the settling task; motion stays suspended during removal.
        XCTAssertTrue(drag.isMoving)
        XCTAssertTrue(drag.isCollapsing)
    }

    func testCoverLandsExactlyOnExpandedAndBothMiniPlayerLayouts() {
        let source = CGRect(x: 54, y: 85, width: 282, height: 282)
        for destination in [CGRect(x: 32, y: 660, width: 44, height: 44),
                            CGRect(x: 96, y: 724, width: 44, height: 44)] {
            let open = source.applying(PlayerCoverGeometry.transform(progress: 1, source: source, destination: destination))
            XCTAssertEqual(open, source)
            let closed = source.applying(PlayerCoverGeometry.transform(progress: 0, source: source, destination: destination))
            XCTAssertEqual(closed.minX, destination.minX, accuracy: 1e-6)
            XCTAssertEqual(closed.minY, destination.minY, accuracy: 1e-6)
            XCTAssertEqual(closed.width, destination.width, accuracy: 1e-6)
            XCTAssertEqual(closed.height, destination.height, accuracy: 1e-6)
            let halfway = source.applying(PlayerCoverGeometry.transform(progress: 0.5, source: source, destination: destination))
            XCTAssertEqual(halfway.midX, (source.midX + destination.midX) / 2, accuracy: 1e-6)
            XCTAssertEqual(halfway.midY, (source.midY + destination.midY) / 2, accuracy: 1e-6)
            XCTAssertEqual(halfway.width, (source.width + destination.width) / 2, accuracy: 1e-6)
        }
        XCTAssertEqual(PlayerCoverGeometry.transform(progress: 0.5, source: .zero, destination: source), .identity)
        XCTAssertEqual(PlayerCoverGeometry.chromeOpacity(0), 0)
        XCTAssertEqual(PlayerCoverGeometry.chromeOpacity(1), 1)
    }

    @MainActor
    func testInterruptedPresentationCanReopenAndCancelledPullRestoresTheCover() {
        let drag = PlayerDragState()
        drag.setPresented(true, reduceMotion: true)
        XCTAssertTrue(drag.isPresented)
        XCTAssertEqual(drag.progress, 0)
        drag.finishEntrance(reduceMotion: true)
        XCTAssertEqual(drag.progress, 1)
        drag.update(10_000)
        XCTAssertEqual(drag.progress, 0)
        drag.update(.nan)
        XCTAssertEqual(drag.progress, 0)
        drag.restore(reduceMotion: true)
        XCTAssertEqual(drag.progress, 1)
        drag.setPresented(false, reduceMotion: true)
        XCTAssertEqual(drag.progress, 0)
        drag.setPresented(true, reduceMotion: true)
        XCTAssertTrue(drag.isPresented)
        drag.finishEntrance(reduceMotion: true)
        XCTAssertEqual(drag.progress, 1)
    }

    @MainActor
    func testRepeatedDismissalAndStaleTouchesCannotStrandCoverOverHome() async throws {
        let drag = PlayerDragState()
        drag.setPresented(true, reduceMotion: true)
        drag.finishEntrance(reduceMotion: true)
        drag.update(120)
        drag.beginDismissal(reduceMotion: true)
        XCTAssertFalse(drag.acceptsInput)
        XCTAssertEqual(drag.progress, 0)
        // A late recognizer callback and the router's matching notification must be harmless.
        drag.update(200)
        drag.restore(reduceMotion: true)
        drag.beginDismissal(reduceMotion: true)
        drag.setPresented(false, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(drag.isPresented)
        XCTAssertFalse(drag.isMoving)
        XCTAssertFalse(drag.isReady)
        drag.update(80)
        XCTAssertEqual(drag.progress, 0)
        drag.setPresented(true, reduceMotion: true)
        drag.finishEntrance(reduceMotion: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(drag.acceptsInput)
        XCTAssertTrue(drag.isPresented)
        XCTAssertEqual(drag.progress, 1)
        XCTAssertFalse(drag.isMoving)
    }

    @MainActor
    func testRetouchUsesVisibleCoverProgressAndKeepsOneOriginForTheGesture() {
        let drag = PlayerDragState()
        drag.travel = 500
        drag.setPresented(true, reduceMotion: false)
        drag.finishEntrance()
        drag.meter.record(0.65) // The compositor is partway through the opening animation.
        drag.update(25)
        XCTAssertEqual(drag.progress, 0.60, accuracy: 1e-6)
        drag.meter.record(0.60)
        drag.update(50)
        XCTAssertEqual(drag.progress, 0.55, accuracy: 1e-6)
        drag.beginDismissal(reduceMotion: true)
    }

}
