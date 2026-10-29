import SwiftUI
import XCTest
@testable import Ehru

final class CarouselSceneTests: XCTestCase {
    func testAdjacentChangesKeepSharedPageCoordinatesAndIdentityWithoutARebase() throws {
        let a = QueueEntry(song: testSong(1)), b = QueueEntry(song: testSong(2))
        let c = QueueEntry(song: testSong(3)), d = QueueEntry(song: testSong(4))
        var scene = CarouselScene()
        scene.select(CarouselSelection(previous: nil, current: a, next: b))
        scene.settle()
        let aKey = try XCTUnwrap(scene.items.first { $0.entry.id == a.id }).id
        let bKey = try XCTUnwrap(scene.items.first { $0.entry.id == b.id }).id
        XCTAssertTrue(scene.select(CarouselSelection(previous: a, current: b, next: c)))
        XCTAssertEqual(scene.center, 1)
        XCTAssertEqual(scene.items.first { $0.entry.id == a.id }?.id, aKey)
        XCTAssertEqual(scene.items.first { $0.entry.id == b.id }?.id, bKey)
        XCTAssertEqual(scene.items.first { $0.entry.id == b.id }?.ordinal, 1)
        // Interrupt the settlement with another next or a reversal: coordinates stay stable.
        XCTAssertTrue(scene.select(CarouselSelection(previous: b, current: c, next: d)))
        XCTAssertEqual(scene.center, 2)
        XCTAssertTrue(scene.items.contains { $0.entry.id == a.id })
        XCTAssertTrue(scene.select(CarouselSelection(previous: a, current: b, next: c)))
        XCTAssertEqual(scene.center, 1)
        XCTAssertEqual(scene.items.first { $0.entry.id == b.id }?.id, bKey)
        scene.settle()
        XCTAssertEqual(scene.items.map(\.entry.id), [a.id, b.id, c.id])
    }

    func testRepeatNeighboursAndUnrelatedJumpsHaveUniqueOccurrences() {
        let a = QueueEntry(song: testSong(1)), b = QueueEntry(song: testSong(2)), c = QueueEntry(song: testSong(3))
        var scene = CarouselScene()
        scene.select(CarouselSelection(previous: b, current: a, next: b))
        XCTAssertEqual(Set(scene.items.map(\.id)).count, 3)
        scene.select(CarouselSelection(previous: a, current: b, next: a))
        scene.settle()
        XCTAssertEqual(Set(scene.items.map(\.id)).count, 3)
        XCTAssertFalse(scene.select(CarouselSelection(previous: nil, current: c, next: nil)))
        XCTAssertEqual(scene.center, 0)
        XCTAssertEqual(scene.items.map(\.entry.id), [c.id])
        scene.select(CarouselSelection(previous: nil, current: nil, next: nil))
        scene.settle()
        XCTAssertTrue(scene.items.isEmpty)
    }

    func testRepeatedInterruptedSwipesKeepAtMostSevenNearbyCards() {
        let entries = (0..<100).map { QueueEntry(song: testSong(Int64($0))) }
        var scene = CarouselScene()
        for index in entries.indices {
            scene.select(CarouselSelection(previous: index > 0 ? entries[index - 1] : nil,
                                           current: entries[index], next: index + 1 < entries.count ? entries[index + 1] : nil))
            XCTAssertLessThanOrEqual(scene.items.count, 7)
            XCTAssertEqual(Set(scene.items.map(\.ordinal)).count, scene.items.count)
            XCTAssertTrue(scene.items.contains { $0.id == scene.currentKey })
        }
        scene.settle()
        XCTAssertEqual(scene.items.count, 2)
    }

    func testSingleEntryRepeatBouncesAndDuplicateSongsWithDifferentEntriesStillSwipe() {
        let entry = QueueEntry(song: testSong(1))
        let single = CarouselSelection(previous: entry, current: entry, next: entry)
        XCTAssertFalse(single.canMove(1))
        XCTAssertFalse(single.canMove(-1))
        let duplicate = QueueEntry(song: entry.song)
        let pair = CarouselSelection(previous: duplicate, current: entry, next: duplicate)
        XCTAssertTrue(pair.canMove(1))
        XCTAssertTrue(pair.canMove(-1))
        XCTAssertFalse(pair.canMove(0))
    }

    func testBothNeighbourPreviewsAreVisibleBehindTheCenteredCard() {
        for width in [CGFloat(160), 260, 320, 480] {
            let size = CGSize(width: width, height: width + 100)
            // CardMetrics gives the current card 80% of the available viewport width.
            let viewport = CGRect(x: -width * 0.125, y: 0, width: width * 1.25, height: size.height)
            for reduced in [false, true] {
                let left = bounds(ordinal: -1, focus: 0, size: size, reduced: reduced)
                let right = bounds(ordinal: 1, focus: 0, size: size, reduced: reduced)
                XCTAssertGreaterThan(min(left.maxX, 0) - max(left.minX, viewport.minX), 10)
                XCTAssertGreaterThan(min(right.maxX, viewport.maxX) - max(right.minX, width), 10)
                XCTAssertLessThan(CarouselPose.depth(distance: -1), CarouselPose.depth(distance: 0))
                XCTAssertLessThan(CarouselPose.depth(distance: 1), CarouselPose.depth(distance: 0))
            }
        }
    }

    func testTheNearestCardStaysInFrontThroughForwardAndReverseSlides() {
        for step in -40...40 {
            let focus = CGFloat(step) / 40
            let distances = (-2...2).map { CGFloat($0) - focus }
            let nearest = distances.min { abs($0) < abs($1) }!
            for distance in distances {
                XCTAssertGreaterThanOrEqual(CarouselPose.depth(distance: nearest), CarouselPose.depth(distance: distance))
            }
        }
        var rendered = CarouselCardMotion(distance: -1, stack: 0, size: CGSize(width: 280, height: 380),
                                          hideLeft: false, reduceMotion: false)
        rendered.animatableData = AnimatablePair(-0.2, 0)
        XCTAssertGreaterThan(CarouselPose.depth(distance: rendered.distance), CarouselPose.depth(distance: 0.8))
    }

    func testTwoEntryRepeatHonoursTheRequestedPreviousOccurrence() {
        let a = QueueEntry(song: testSong(1)), b = QueueEntry(song: testSong(2))
        var scene = CarouselScene()
        scene.select(CarouselSelection(previous: b, current: a, next: b))
        let previousKey = scene.items.first { $0.ordinal == -1 }?.id
        XCTAssertTrue(scene.select(CarouselSelection(previous: a, current: b, next: a), preferredDirection: -1))
        XCTAssertEqual(scene.center, -1)
        XCTAssertEqual(scene.currentKey, previousKey)
        XCTAssertTrue(scene.select(CarouselSelection(previous: b, current: a, next: b), preferredDirection: 1))
        XCTAssertEqual(scene.center, 0)
    }

    func testInterruptedGestureCanReadTheActualInterpolatedFocus() {
        let meter = CarouselPresentationMeter()
        let effect = CarouselFocusProbe(focus: 0.42, meter: meter)
        _ = effect.effectValue(size: CGSize(width: 280, height: 380))
        XCTAssertEqual(meter.read(fallback: 1), 0.42, accuracy: 1e-6)
    }

    private func bounds(ordinal: Int, focus: CGFloat, size: CGSize, reduced: Bool) -> CGRect {
        let effect = DepthCard(distance: CGFloat(ordinal) - focus, width: size.width, stack: 0,
                               hideLeft: false, reduceMotion: reduced)
        let m = effect.effectValue(size: size)
        let points = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height),
                      CGPoint(x: size.width, y: size.height)].map { p -> CGPoint in
            let w = m.m13 * p.x + m.m23 * p.y + m.m33
            return CGPoint(x: (m.m11 * p.x + m.m21 * p.y + m.m31) / w,
                           y: (m.m12 * p.x + m.m22 * p.y + m.m32) / w)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
