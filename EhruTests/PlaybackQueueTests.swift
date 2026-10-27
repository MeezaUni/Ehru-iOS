import XCTest
@testable import Ehru

final class PlaybackQueueTests: XCTestCase {
    private func makeQueue(_ items: [Int], at index: Int, repeatMode: RepeatMode = .off) -> PlaybackQueue<Int> {
        var queue = PlaybackQueue<Int>()
        queue.load(items, startingAt: index)
        queue.repeatMode = repeatMode
        return queue
    }

    func testLoadStartsAtIndex() {
        XCTAssertEqual(makeQueue([1, 2, 3], at: 1).current, 2)
    }

    func testLoadOutOfRangeHasNothingCurrent() {
        XCTAssertNil(makeQueue([1, 2, 3], at: 5).current)
        XCTAssertNil(makeQueue([], at: 0).current)
    }

    func testSkipForwardStopsAtEndWithoutRepeat() {
        var queue = makeQueue([1, 2], at: 0)
        XCTAssertEqual(queue.skipForward(), 2)
        XCTAssertNil(queue.skipForward())
        XCTAssertEqual(queue.current, 2)
    }

    func testRepeatAllWrapsBothWays() {
        var queue = makeQueue([1, 2, 3], at: 2, repeatMode: .all)
        XCTAssertEqual(queue.skipForward(), 1)
        XCTAssertEqual(queue.skipBackward(), 3)
    }

    func testSkipBackwardStaysOnFirstWithoutRepeat() {
        var queue = makeQueue([1, 2, 3], at: 0)
        XCTAssertEqual(queue.skipBackward(), 1)
    }

    func testRepeatOneReplaysOnCompletionButSkipMovesOn() {
        var queue = makeQueue([1, 2, 3], at: 0, repeatMode: .one)
        XCTAssertEqual(queue.advanceAfterCompletion(), 1)
        XCTAssertEqual(queue.skipForward(), 2)
    }

    func testCompletionAtEndStopsWithoutRepeat() {
        var queue = makeQueue([1, 2], at: 1)
        XCTAssertNil(queue.advanceAfterCompletion())
    }

    func testShuffleKeepsCurrentFirstAndAllItems() {
        var queue = makeQueue(Array(1...20), at: 7)
        var generator = SeededGenerator(state: 42)
        queue.setShuffled(true, using: &generator)
        XCTAssertTrue(queue.isShuffled)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.current, 8)
        XCTAssertEqual(queue.items.sorted(), Array(1...20))
    }

    func testUnshuffleRestoresOrderAndKeepsCurrentSong() {
        var queue = makeQueue(Array(1...20), at: 0)
        var generator = SeededGenerator(state: 7)
        queue.setShuffled(true, using: &generator)
        _ = queue.skipForward()
        let playing = queue.current
        queue.setShuffled(false, using: &generator)
        XCTAssertEqual(queue.items, Array(1...20))
        XCTAssertEqual(queue.current, playing)
    }

    func testRepeatModeCycles() {
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }
}
