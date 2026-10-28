import XCTest
import UIKit
@testable import Ehru

final class GestureIntentTests: XCTestCase {
    func testVerticalScrollingNeverWinsHorizontalGestureRecognition() {
        for translation in [CGSize(width: 0, height: 50), CGSize(width: 8, height: 80),
                            CGSize(width: 15, height: 20), CGSize.zero] {
            XCTAssertFalse(HorizontalGestureIntent.accepts(translation))
        }
        XCTAssertTrue(HorizontalGestureIntent.accepts(CGSize(width: 40, height: 4)))
        XCTAssertTrue(HorizontalGestureIntent.accepts(CGSize(width: -40, height: -4)))
    }

    func testRowSwipesRequireIntentAndEnoughDistanceBeforeCommitting() {
        XCTAssertNil(SongSwipeAction.committed(translation: CGSize(width: 10, height: 0), startedHorizontally: true))
        XCTAssertNil(SongSwipeAction.committed(translation: CGSize(width: 100, height: 200), startedHorizontally: false))
        XCTAssertEqual(SongSwipeAction.committed(translation: CGSize(width: 80, height: 3), startedHorizontally: true), .queue)
        XCTAssertEqual(SongSwipeAction.committed(translation: CGSize(width: -80, height: 3), startedHorizontally: true), .like)
    }

    @MainActor
    func testPanGetsFirstRefusalOnlyAgainstItsOwnAncestorScrollView() {
        var changes = 0
        var commits = 0
        let interaction = PanInteraction(canBegin: { _, movement in HorizontalGestureIntent.accepts(movement) },
                                         change: { _ in changes += 1 }, end: { _ in commits += 1 },
                                         cancel: {}, tap: { _ in commits += 1 })
        let coordinator = PanInteraction.Coordinator(interaction)
        let scroll = UIScrollView()
        let surface = UIView()
        scroll.addSubview(surface)
        let pan = UIPanGestureRecognizer()
        surface.addGestureRecognizer(pan)
        XCTAssertTrue(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: scroll.panGestureRecognizer))
        XCTAssertFalse(coordinator.gestureRecognizer(pan, shouldBeRequiredToFailBy: UIScrollView().panGestureRecognizer))
        coordinator.pan(pan) // Touch-down/possible state must neither preview nor commit.
        coordinator.tap(UITapGestureRecognizer())
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(commits, 0)
    }
}
