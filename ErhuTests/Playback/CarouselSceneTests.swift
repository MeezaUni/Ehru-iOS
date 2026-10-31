import SwiftUI
import XCTest
@testable import Erhu

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

    func testRapidSecondSwipeAlreadyHasItsCoverMountedBeforeTheFirstSettles() throws {
        let a = QueueEntry(song: testSong(1)), b = QueueEntry(song: testSong(2))
        let c = QueueEntry(song: testSong(3)), d = QueueEntry(song: testSong(4))
        var scene = CarouselScene()
        scene.select(CarouselSelection(previous: nil, current: a, next: b, nextTwo: c))
        let ahead = try XCTUnwrap(scene.items.first { $0.entry.id == c.id }).id
        scene.select(CarouselSelection(previous: a, current: b, next: c, nextTwo: d))
        scene.select(CarouselSelection(previous: b, current: c, next: d, previousTwo: a))
        XCTAssertEqual(scene.currentKey, ahead)
        XCTAssertEqual(scene.center, 2)
        XCTAssertLessThanOrEqual(scene.items.count, 7)
        scene.settle()
        let behind = try XCTUnwrap(scene.items.first { $0.entry.id == a.id }).id
        scene.select(CarouselSelection(previous: a, current: b, next: c, nextTwo: d), preferredDirection: -1)
        scene.select(CarouselSelection(previous: nil, current: a, next: b, nextTwo: c), preferredDirection: -1)
        XCTAssertEqual(scene.currentKey, behind)
        XCTAssertEqual(scene.center, 0)
    }

    func testSwipeReleaseDefersNewFarArtworkButKeepsTheNextSwipeReady() throws {
        let entries = (1...5).map { QueueEntry(song: testSong(Int64($0))) }
        var scene = CarouselScene()
        scene.select(CarouselSelection(previous: nil, current: entries[0], next: entries[1], nextTwo: entries[2]))
        let ready = try XCTUnwrap(scene.items.first { $0.entry.id == entries[2].id }).id
        scene.select(CarouselSelection(previous: entries[0], current: entries[1], next: entries[2], nextTwo: entries[3]),
                     preferredDirection: 1, deferFarPages: true)
        XCTAssertEqual(scene.items.first { $0.entry.id == entries[2].id }?.id, ready)
        XCTAssertFalse(scene.items.contains { $0.entry.id == entries[3].id })
        scene.settle()
        XCTAssertTrue(scene.items.contains { $0.entry.id == entries[3].id })
        scene.select(CarouselSelection(previous: entries[1], current: entries[2], next: entries[3],
                                       previousTwo: entries[0], nextTwo: entries[4]),
                     preferredDirection: 1, deferFarPages: true)
        XCTAssertEqual(scene.currentKey, ready)
        XCTAssertFalse(scene.items.contains { $0.entry.id == entries[4].id })
        scene.settle()
        XCTAssertTrue(scene.items.contains { $0.entry.id == entries[4].id })
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

    func testDepthPriorityIsGreatestAtTheChosenFrontOrdinal() {
        for step in -40...40 {
            let focus = CGFloat(step) / 40
            let distances = (-2...2).map { CGFloat($0) - focus }
            let nearest = distances.min { abs($0) < abs($1) }!
            for distance in distances {
                XCTAssertGreaterThanOrEqual(CarouselPose.depth(distance: nearest), CarouselPose.depth(distance: distance))
            }
        }

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

    func testLongDragsNeverLeaveAllAvailableCoverPagesOffscreen() {
        for proposed in [CGFloat(-1_000_000), -10, -2, 2, 10, 1_000_000] {
            let focus = CarouselDragLimit.focus(proposed, center: 0, canPrevious: true, canNext: true)
            XCTAssertLessThanOrEqual(abs(focus), 1.12)
        }
        XCTAssertEqual(CarouselDragLimit.focus(0.4, center: 0, canPrevious: true, canNext: true), 0.4)
        XCTAssertLessThan(abs(CarouselDragLimit.focus(-100, center: 0, canPrevious: false, canNext: true)), 0.12)
        XCTAssertEqual(CarouselDragLimit.focus(.nan, center: 5, canPrevious: true, canNext: true), 5)
    }

    func testPresentationMeterRetainsBothPositionAndLayoutWithoutPublishingState() {
        let meter = CarouselPresentationMeter()
        meter.record(0.42, stack: 0.7)
        XCTAssertEqual(meter.sample(fallback: CarouselPresentationSample(focus: 1, stack: 0)),
                       CarouselPresentationSample(focus: 0.42, stack: 0.7))
    }

    func testStackedNeighbourStaysCentredBehindTheCurrentCard() {
        let current = CarouselPose(distance: 0, width: 280, stack: 1, reduceMotion: false)
        let next = CarouselPose(distance: 1, width: 280, stack: 1, reduceMotion: false)
        XCTAssertLessThan(next.scale, current.scale)
        XCTAssertLessThan(next.y, current.y)
        XCTAssertEqual(next.turn, 0)
        XCTAssertEqual(next.x, current.x)
        XCTAssertEqual(next.opacity, 1, "The rear preview must be the actual opaque cover")
        XCTAssertEqual(CarouselPose(distance: -1, width: 280, stack: 1, reduceMotion: false).opacity, 1)
    }

    func testProjectedSpreadCardsHaveAGapThroughoutSwipes() {
        for width in [CGFloat(160), 280, 480] {
            let size = CGSize(width: width, height: width + 100)
            for reduced in [false, true] {
                for step in -40...40 {
                    let focus = CGFloat(step) / 40
                    for ordinal in -2...1 {
                        let left = bounds(ordinal: ordinal, focus: focus, size: size, reduced: reduced)
                        let right = bounds(ordinal: ordinal + 1, focus: focus, size: size, reduced: reduced)
                        XCTAssertGreaterThanOrEqual(right.minX - left.maxX, CarouselPose.gap(width: width) - 0.001,
                                                   "Cards cross at focus \(focus), width \(width)")
                    }
                }
            }
        }
    }

    func testStackedTurnoversFollowAShortMirroredArcFromBehind() {
        for step in -40...40 {
            let focus = CGFloat(step) / 40
            let right = CarouselPose(distance: focus, width: 280, stack: 1, reduceMotion: false)
            let left = CarouselPose(distance: -focus, width: 280, stack: 1, reduceMotion: false)
            XCTAssertEqual(right.x, -left.x, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(right.x), 280 * 0.32 + 1e-6)
            XCTAssertEqual(right.turn, -left.turn, accuracy: 1e-6)
            XCTAssertEqual(right.opacity, 1)
        }
        XCTAssertGreaterThan(CarouselPose(distance: 0.5, width: 280, stack: 1, reduceMotion: false).x, 50)
        XCTAssertLessThan(CarouselPose(distance: -0.5, width: 280, stack: 1, reduceMotion: false).x, -50)
        for distance in [CGFloat(-1), 0, 1] {
            XCTAssertEqual(CarouselPose(distance: distance, width: 280, stack: 1, reduceMotion: false).x, 0)
        }
        XCTAssertEqual(CarouselPose(distance: 0.5, width: 280, stack: 1, reduceMotion: true).x, 0)
    }

    func testSwipeDirectionUsesFingerTravelInsteadOfThePreviousSlidePosition() {
        XCTAssertEqual(CarouselSwipeIntent.direction(translation: -70, predicted: -100, page: 200), 1)
        XCTAssertEqual(CarouselSwipeIntent.direction(translation: 70, predicted: 100, page: 200), -1)
        XCTAssertEqual(CarouselSwipeIntent.direction(translation: 12, predicted: 14, page: 200), 0)
        XCTAssertEqual(CarouselSwipeIntent.direction(translation: -12, predicted: -300, page: 200), 1)
        XCTAssertEqual(CarouselSwipeIntent.direction(translation: .nan, predicted: -300, page: 200), 0)
    }

    func testDepthCardsAreSeparatedBeforeTheirFrontOrderChanges() {
        for width in [CGFloat(160), 280, 480] {
            let size = CGSize(width: width, height: width + 100)
            for direction in [-1, 1] {
                for fraction in [CGFloat(0.48), 0.5, 0.52] {
                    let focus = fraction * CGFloat(direction)
                    let outgoing = bounds(ordinal: 0, focus: focus, size: size, reduced: false, stack: 1)
                    let incoming = bounds(ordinal: direction, focus: focus, size: size, reduced: false, stack: 1)
                    let gap = direction == 1 ? incoming.minX - outgoing.maxX : outgoing.minX - incoming.maxX
                    XCTAssertGreaterThan(gap, width * 0.05, "A depth reorder must happen with daylight between the rotating edges")
                }
            }
        }
    }

    private func bounds(ordinal: Int, focus: CGFloat, size: CGSize, reduced: Bool, stack: CGFloat = 0) -> CGRect {
        let effect = DepthCard(distance: CGFloat(ordinal) - focus, width: size.width, stack: stack,
                               reduceMotion: reduced)
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
