import SwiftUI
import UIKit
import XCTest
@testable import Ehru

final class CarouselMotionTests: XCTestCase {
    @MainActor
    func testAStackedDragUnfoldsUnderTheFingerInsteadOfJumpingToSpread() {
        let motion = CarouselMotion()
        motion.snap(center: 0, stacked: true)
        motion.drag(translation: -10, page: 200, center: 0, canPrevious: true, canNext: true)
        XCTAssertEqual(motion.focus, 0.05, accuracy: 1e-6)
        XCTAssertEqual(motion.stack, 0.9, accuracy: 1e-6)
        motion.drag(translation: -50, page: 200, center: 0, canPrevious: true, canNext: true)
        XCTAssertEqual(motion.focus, 0.25, accuracy: 1e-6)
        XCTAssertEqual(motion.stack, 0.5, accuracy: 1e-6)
        motion.cancel()
        XCTAssertFalse(motion.moving)
    }

    @MainActor
    func testAnInterruptedDragStartsFromBothRenderedPositionAndRenderedStack() {
        let motion = CarouselMotion()
        motion.snap(center: 1, stacked: true)
        motion.meter.record(0.7, stack: 0.6)
        motion.drag(translation: -10, page: 200, center: 1, canPrevious: true, canNext: true)
        XCTAssertEqual(motion.focus, 0.75, accuracy: 1e-6)
        XCTAssertEqual(motion.stack, 0.5, accuracy: 1e-6)
        motion.drag(translation: -20, page: 200, center: 1, canPrevious: true, canNext: true)
        XCTAssertEqual(motion.focus, 0.8, accuracy: 1e-6)
        XCTAssertEqual(motion.stack, 0.4, accuracy: 1e-6)
    }

    @MainActor
    func testCleanupDeadlineDoesNotDependOnAVisibleSwiftUIRenderer() async throws {
        let motion = CarouselMotion()
        var completed = 0
        motion.settle(center: 1, stacked: true, reduceMotion: false) { completed += 1 }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(motion.moving)
        XCTAssertEqual(completed, 1)
        let drag = PlayerDragState()
        drag.setPresented(true, reduceMotion: false)
        drag.finishEntrance()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(drag.isMoving)
        drag.setPresented(false, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(80))
        drag.setPresented(true, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(drag.isPresented)
        XCTAssertEqual(drag.progress, 1)
        XCTAssertFalse(drag.isMoving)
    }

    @MainActor
    func testHostedSlidesAndModeChangesHaveIntermediateFramesAndFinishPromptly() async throws {
        let motion = CarouselMotion()
        try await hosted(MotionProbe(motion: motion)) {
            var completed = 0
            motion.settle(center: 1, stacked: false, reduceMotion: false) { completed += 1 }
            try await Task.sleep(for: .milliseconds(80))
            let middle = motion.meter.sample(fallback: CarouselPresentationSample(focus: motion.focus, stack: motion.stack))
            XCTAssertGreaterThan(middle.focus, 0)
            XCTAssertLessThan(middle.focus, 1)
            XCTAssertTrue(motion.moving)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(motion.moving)
            XCTAssertEqual(completed, 1)
            motion.settle(center: 1, stacked: true, reduceMotion: false)
            try await Task.sleep(for: .milliseconds(80))
            let layout = motion.meter.sample(fallback: CarouselPresentationSample(focus: motion.focus, stack: motion.stack))
            XCTAssertGreaterThan(layout.stack, 0)
            XCTAssertLessThan(layout.stack, 1)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(motion.moving)
            XCTAssertEqual(motion.stack, 1)
        }
    }

    @MainActor
    func testInterruptingAnAnimationCannotRunItsObsoleteCompletion() async throws {
        let motion = CarouselMotion()
        try await hosted(MotionProbe(motion: motion)) {
            var obsolete = 0
            motion.settle(center: 1, stacked: false, reduceMotion: false) { obsolete += 1 }
            try await Task.sleep(for: .milliseconds(80))
            motion.drag(translation: -20, page: 200, center: 1, canPrevious: true, canNext: true)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(obsolete, 0)
            XCTAssertTrue(motion.moving)
            motion.settle(center: 2, stacked: true, reduceMotion: false)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertFalse(motion.moving)
            XCTAssertEqual(motion.focus, 2)
            XCTAssertEqual(motion.stack, 1)
        }
    }

    @MainActor
    func testOpeningReleasesTheCoverAndControlsWithoutWaitingForASpringTail() async throws {
        let drag = PlayerDragState()
        drag.setPresented(true, reduceMotion: false)
        let frames = PlayerArtworkFrames(expanded: CGRect(x: 55, y: 80, width: 280, height: 280),
                                         mini: CGRect(x: 20, y: 390, width: 44, height: 44))
        try await hosted(EntranceProbe(drag: drag, frames: frames)) {
            drag.finishEntrance()
            XCTAssertTrue(drag.isReady)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertFalse(drag.isMoving)
            XCTAssertEqual(drag.progress, 1)
        }
    }

    private struct EntranceProbe: View {
        let drag: PlayerDragState
        let frames: PlayerArtworkFrames
        var body: some View { PlayerArtworkOverlay(progress: drag.progress, frames: frames) { Color.blue } }
    }

    private struct MotionProbe: View {
        let motion: CarouselMotion
        let items = (-1...3).map { CarouselScene.Item(ordinal: $0, entry: QueueEntry(song: testSong(Int64($0 + 2)))) }
        var body: some View {
            CarouselStrip(items: items, focus: motion.focus, frontOrdinal: motion.frontOrdinal, stack: motion.stack,
                          viewport: CGSize(width: 390, height: 450), cardSize: CGSize(width: 280, height: 350),
                          hideLeft: true, reduceMotion: false, meter: motion.meter) { _ in
                Color.blue.frame(width: 280, height: 350)
            }
        }
    }

    @MainActor
    private func hosted<Content: View>(_ content: Content, operation: @MainActor () async throws -> Void) async throws {
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                   "Animated tests require a live simulator window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 450)
        let controller = UIHostingController(rootView: content.ignoresSafeArea())
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try await operation()
    }
}
