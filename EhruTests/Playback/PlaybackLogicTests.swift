import XCTest
@testable import Ehru

func testSong(_ id: Int64, durationMs: Int64 = 1_000) -> Song {
    Song(id: id, title: "t\(id)", artist: "a", album: "b", durationMs: durationMs, path: "\(id).mp3")
}

final class ListeningTrackerTests: XCTestCase {
    private var clock: Int64 = 0
    private var counted: [Int64] = []
    private var listened: [String] = []
    private lazy var tracker = ListeningTracker(
        elapsedRealtime: { [unowned self] in self.clock },
        onPlayCounted: { [unowned self] in self.counted.append($0) },
        onListened: { [unowned self] id, ms in self.listened.append("\(id):\(ms)") }
    )
    private let length: Int64 = 200_000
    private let pollMs: Int64 = 250

    private func startSong(_ id: Int64) {
        tracker.onItemChanged(id, durationMs: length, isPlaying: false)
        tracker.onPlayingChanged(true, durationMs: length)
    }

    private func listen(_ ms: Int64) {
        let end = clock + ms
        while clock < end {
            clock = min(clock + pollMs, end)
            tracker.onProgress(durationMs: length)
        }
    }

    private func pause() { tracker.onPlayingChanged(false, durationMs: length) }
    private func resume() { tracker.onPlayingChanged(true, durationMs: length) }

    func testCountsOnlyAtHalf() {
        startSong(1)
        listen(99_000)
        XCTAssertEqual([], counted)
        listen(1_000)
        XCTAssertEqual([1], counted)
    }

    func testListeningToTheEndCountsOnce() {
        startSong(1)
        listen(length)
        pause()
        XCTAssertEqual([1], counted)
    }

    func testSkippedEarlyDoesNotCount() {
        startSong(1)
        listen(60_000)
        tracker.onItemChanged(2, durationMs: length, isPlaying: true)
        listen(100_000)
        XCTAssertEqual([2], counted)
    }

    func testPauseAndResumeDoNotRestart() {
        startSong(1)
        listen(40_000)
        pause()
        clock += 600_000
        resume()
        listen(40_000)
        pause()
        resume()
        XCTAssertEqual([], counted)
        listen(20_000)
        XCTAssertEqual([1], counted)
        pause()
        resume()
        listen(100_000)
        XCTAssertEqual([1], counted)
    }

    func testRepeatOneCountsEachHalfHeardLoop() {
        startSong(1)
        listen(length)
        tracker.onItemChanged(1, durationMs: length, isPlaying: true)
        listen(length)
        tracker.onItemChanged(1, durationMs: length, isPlaying: true)
        listen(20_000)
        tracker.onItemChanged(2, durationMs: length, isPlaying: true)
        XCTAssertEqual([1, 1], counted)
    }

    func testSkippingWhilePausedCountsNothing() {
        startSong(1)
        pause()
        tracker.onItemChanged(2, durationMs: length, isPlaying: false)
        tracker.onItemChanged(3, durationMs: length, isPlaying: false)
        resume()
        listen(100_000)
        XCTAssertEqual([3], counted)
    }

    func testPlayingAgainAfterTheEndIsANewListen() {
        startSong(1)
        listen(length)
        pause()
        tracker.onEnded()
        resume()
        listen(99_000)
        XCTAssertEqual([1], counted)
        listen(1_000)
        XCTAssertEqual([1, 1], counted)
    }

    func testThresholdCheckedWhenPlaybackStops() {
        startSong(1)
        clock += 100_000
        tracker.onItemChanged(2, durationMs: length, isPlaying: true)
        XCTAssertEqual([1], counted)
    }

    func testUnknownLengthCountsOnceKnown() {
        tracker.onItemChanged(1, durationMs: 0, isPlaying: false)
        tracker.onPlayingChanged(true, durationMs: 0)
        clock += 150_000
        tracker.onProgress(durationMs: 0)
        XCTAssertEqual([], counted)
        tracker.onProgress(durationMs: length)
        XCTAssertEqual([1], counted)
    }

    func testListeningTimeIsTimeSpentPlaying() {
        startSong(1)
        clock = 30_000
        pause()
        clock = 90_000
        resume()
        clock = 100_000
        tracker.onItemChanged(2, durationMs: length, isPlaying: true)
        clock = 160_000
        tracker.checkpoint()
        clock = 170_000
        pause()
        XCTAssertEqual(["1:30000", "1:10000", "2:60000", "2:10000"], listened)
    }

    func testEmptyQueueCountsNothing() {
        tracker.onItemChanged(nil, durationMs: 0, isPlaying: false)
        tracker.onPlayingChanged(true, durationMs: 0)
        listen(length)
        XCTAssertEqual([], counted)
        XCTAssertEqual([], listened)
    }
}

final class AbLoopControllerTests: XCTestCase {
    private final class FakePlayer: LoopPlayer {
        var currentSongId: Int64? = 1
        var currentIndex = 0
        var positionMs: Int64 = 0
        var durationMs: Int64 = 300_000
        var seeks: [Int64] = []

        func seekTo(_ positionMs: Int64) {
            seeks.append(positionMs)
            self.positionMs = positionMs
        }
    }

    private final class Scheduled {
        let index: Int
        let positionMs: Int64
        let onReached: () -> Void
        var cancelled = false

        init(index: Int, positionMs: Int64, onReached: @escaping () -> Void) {
            self.index = index
            self.positionMs = positionMs
            self.onReached = onReached
        }
    }

    private let player = FakePlayer()
    private var schedules: [Scheduled] = []
    private var published: [AbLoopState?] = []
    private lazy var loop = AbLoopController(
        scheduler: { [unowned self] index, position, onReached in
            let scheduled = Scheduled(index: index, positionMs: position, onReached: onReached)
            self.schedules.append(scheduled)
            return Cancellable { scheduled.cancelled = true }
        },
        player: player,
        onStateChanged: { [unowned self] in self.published.append($0) }
    )

    private func reach(_ positionMs: Int64) {
        player.positionMs = positionMs
        schedules.filter { !$0.cancelled && $0.positionMs == positionMs && $0.index == player.currentIndex }.forEach { $0.onReached() }
    }

    private func markers(_ a: Int64, _ b: Int64) {
        player.positionMs = a
        XCTAssertEqual(.ok, loop.setStart())
        player.positionMs = b
        XCTAssertEqual(.ok, loop.setEnd())
        player.positionMs = (a + b) / 2
    }

    func testReachingBReturnsToAEveryPass() {
        markers(10_000, 20_000)
        XCTAssertEqual(.ok, loop.setEnabled(true))
        reach(20_000)
        XCTAssertEqual([10_000], player.seeks)
        reach(20_000)
        XCTAssertEqual([10_000, 10_000], player.seeks)
        XCTAssertEqual(AbLoopState(songId: 1, startMs: 10_000, endMs: 20_000, enabled: true), loop.state)
        XCTAssertEqual(loop.state, published.last!)
    }

    func testBadMarkersRejected() {
        player.positionMs = 20_000
        loop.setEnd()
        XCTAssertEqual(.aNotBeforeB, loop.setStart())
        player.positionMs = 25_000
        XCTAssertEqual(.aNotBeforeB, loop.setStart())
        player.positionMs = 19_500
        XCTAssertEqual(.aNotBeforeB, loop.setStart())
        XCTAssertNil(loop.state?.startMs)
        XCTAssertEqual(.notReady, loop.setEnabled(true))
        XCTAssertTrue(schedules.isEmpty)
    }

    func testBKeptOffTheEnd() {
        player.positionMs = 300_000
        loop.setEnd()
        XCTAssertEqual(300_000 - AbLoopController.endGuardMs, loop.state?.endMs)
        player.currentSongId = nil
        XCTAssertEqual(.noTrack, loop.setStart())
    }

    func testTrackChangeClearsAndStaleMessagesDoNothing() {
        markers(10_000, 20_000)
        loop.setEnabled(true)
        let first = schedules[0]
        reach(20_000)
        XCTAssertEqual(1, player.seeks.count)
        player.currentSongId = 2
        player.currentIndex = 1
        loop.onEntryChanged(sameEntryRepeated: false)
        XCTAssertNil(loop.state)
        XCTAssertTrue(first.cancelled)
        first.onReached()
        reach(20_000)
        XCTAssertEqual(1, player.seeks.count)
    }

    func testRepeatOfSameEntryKeepsLooping() {
        markers(10_000, 20_000)
        loop.setEnabled(true)
        loop.onEntryChanged(sameEntryRepeated: true)
        reach(20_000)
        XCTAssertEqual([10_000], player.seeks)
    }

    func testDisablingOrClearingStops() {
        markers(10_000, 20_000)
        loop.setEnabled(true)
        loop.setEnabled(false)
        reach(20_000)
        XCTAssertTrue(player.seeks.isEmpty)
        player.positionMs = 15_000
        loop.setEnabled(true)
        loop.clear()
        reach(20_000)
        XCTAssertTrue(player.seeks.isEmpty)
        XCTAssertNil(loop.state)
        XCTAssertNil(published.last!)
    }

    func testEnablingPastBStartsAtA() {
        markers(10_000, 20_000)
        player.positionMs = 25_000
        loop.setEnabled(true)
        XCTAssertEqual([10_000], player.seeks)
        player.positionMs = 30_000
        XCTAssertEqual(.ok, loop.setEnd())
        reach(20_000)
        XCTAssertEqual(1, player.seeks.count)
        reach(30_000)
        XCTAssertEqual([10_000, 10_000], player.seeks)
        XCTAssertEqual(1, schedules.filter { !$0.cancelled }.count)
    }

    func testWithoutSchedulerUnsupported() {
        let unsupported = AbLoopController(scheduler: nil, player: player, onStateChanged: { _ in })
        player.positionMs = 10_000
        unsupported.setStart()
        player.positionMs = 20_000
        unsupported.setEnd()
        XCTAssertEqual(.unsupported, unsupported.setEnabled(true))
        XCTAssertFalse(unsupported.state!.enabled)
    }
}

final class QueueLogicTests: XCTestCase {
    func testShuffleUpcomingKeepsPlayedPart() {
        let queue = [(1, 0), (2, 1), (7, 2), (7, 3), (3, 4), (7, 5), (4, 6)].map { "\($0.0)#\($0.1)" }
        for seed in 0..<20 {
            var generator = SeededGenerator(state: UInt64(seed))
            let upcoming = shuffledUpcoming(queue, currentIndex: 2, using: &generator)!
            XCTAssertEqual(Array(queue[3...]).sorted(), upcoming.sorted())
        }
        XCTAssertNil(shuffledUpcoming([1, 2, 3], currentIndex: 2))
        XCTAssertNil(shuffledUpcoming([1, 2, 3], currentIndex: 1))
        XCTAssertNil(shuffledUpcoming([Int](), currentIndex: -1))
        XCTAssertEqual([1, 2, 3], shuffledUpcoming([1, 2, 3], currentIndex: -1)!.sorted())
    }

    func testUpcomingStart() {
        XCTAssertEqual(3, upcomingStart(queueSize: 5, currentIndex: 2))
        XCTAssertEqual(5, upcomingStart(queueSize: 5, currentIndex: 4))
        XCTAssertEqual(1, upcomingStart(queueSize: 5, currentIndex: -1))
        XCTAssertEqual(5, upcomingStart(queueSize: 5, currentIndex: 9))
        XCTAssertEqual(0, upcomingStart(queueSize: 0, currentIndex: -1))
    }

    func testUndoingRemovalsRestoresTheQueue() {
        let original = ["a", "b#1", "c", "b#2", "d"]
        var queue = original
        var removals = QueueRemovals<String>()
        for index in [3, 1, 2] { removals.push(index: index, item: queue.remove(at: index)) }
        XCTAssertEqual(["a", "c"], queue)
        while let removal = removals.pop() { queue.insert(removal.item, at: removal.index.clamped(0, queue.count)) }
        XCTAssertEqual(original, queue)
        var small = QueueRemovals<Int>(capacity: 2)
        small.push(index: 0, item: 1)
        small.push(index: 0, item: 2)
        small.push(index: 0, item: 3)
        XCTAssertEqual(2, small.count)
        XCTAssertEqual(3, small.pop()?.item)
    }

    func testPlayOrder() {
        XCTAssertEqual(1, PlayOrder.next(after: 0, count: 3, repeatMode: .off, userSkip: true))
        XCTAssertNil(PlayOrder.next(after: 2, count: 3, repeatMode: .off, userSkip: false))
        XCTAssertEqual(0, PlayOrder.next(after: 2, count: 3, repeatMode: .all, userSkip: false))
        XCTAssertEqual(2, PlayOrder.next(after: 2, count: 3, repeatMode: .one, userSkip: false))
        XCTAssertNil(PlayOrder.next(after: 2, count: 3, repeatMode: .one, userSkip: true))
        XCTAssertEqual(2, PlayOrder.previous(before: 0, count: 3, repeatMode: .all))
        XCTAssertNil(PlayOrder.previous(before: 0, count: 3, repeatMode: .one))
    }

    private func state(_ ids: [Int64], _ index: Int, position: Int64 = 42_000) -> PersistedPlaybackState {
        PersistedPlaybackState(queueSongIds: ids, currentIndex: index, positionMs: position)
    }

    func testRestoredQueue() {
        XCTAssertNil(buildRestoredQueue(state([], 0), available: [testSong(1)]))
        XCTAssertNil(buildRestoredQueue(state([1, 2], 0), available: []))
        let ordered = buildRestoredQueue(state([3, 1, 2], 1), available: [testSong(1), testSong(2), testSong(3)])!
        XCTAssertEqual([3, 1, 2], ordered.songs.map(\.id))
        XCTAssertEqual(1, ordered.startIndex)
        XCTAssertEqual(42_000, ordered.startPositionMs)
        let shifted = buildRestoredQueue(state([1, 2, 3, 4], 2), available: [testSong(1), testSong(3), testSong(4)])!
        XCTAssertEqual(1, shifted.startIndex)
        XCTAssertEqual(42_000, shifted.startPositionMs)
        let currentGone = buildRestoredQueue(state([1, 2, 3], 1), available: [testSong(1), testSong(3)])!
        XCTAssertEqual(1, currentGone.startIndex)
        XCTAssertEqual(0, currentGone.startPositionMs)
        XCTAssertEqual(0, buildRestoredQueue(state([1, 2, 3], 2), available: [testSong(1), testSong(2)])!.startIndex)
        XCTAssertEqual(2, buildRestoredQueue(state([5, 6, 5], 2), available: [testSong(5), testSong(6)])!.startIndex)
        XCTAssertEqual(0, buildRestoredQueue(state([1, 2], 9), available: [testSong(1), testSong(2)])!.startIndex)
        XCTAssertEqual(0, buildRestoredQueue(state([1], 0, position: -5), available: [testSong(1)])!.startPositionMs)

        let album = CollectionRef.album(9)
        var saved = state([1, 2, 3, 4], 0)
        saved.queueCollectionKeys = [album.key, album.key, "", "playlist:4#s4@7"]
        let restored = buildRestoredQueue(saved, available: [testSong(1), testSong(3), testSong(4)])!
        XCTAssertEqual([QueueOrigin(collection: album, occurrence: TrackOccurrence(1)), nil,
                        QueueOrigin(collection: .playlist(4), occurrence: TrackOccurrence(4, 7))], restored.origins)
    }

    func testSessionHistory() {
        var clock: Int64 = 1_000
        let history = SessionHistory(now: { clock })
        XCTAssertFalse(history.onItemBecameCurrent(testSong(1), isPlaying: false))
        XCTAssertTrue(history.onPlaybackStarted())
        XCTAssertFalse(history.onPlaybackStarted())
        history.onItemBecameCurrent(testSong(2), isPlaying: false)
        history.onItemBecameCurrent(testSong(3), isPlaying: false)
        history.onPlaybackStarted()
        clock = 2_000
        history.onItemBecameCurrent(testSong(1), isPlaying: true)
        XCTAssertEqual([1, 3, 1], history.entries.map(\.song.id))
        XCTAssertEqual(3, Set(history.entries.map(\.entryId)).count)
        XCTAssertEqual(history.entries.last, history.find(history.entries.last!.entryId))
        let small = SessionHistory(now: { 0 }, capacity: 2)
        for id in Int64(1)...3 { small.onItemBecameCurrent(testSong(id), isPlaying: true) }
        XCTAssertEqual([3, 2], small.entries.map(\.song.id))
    }
}

final class TransitionPlannerTests: XCTestCase {
    private let spec = TransitionSpec(durationMs: 4_000, curve: .linear)

    private func info(spec: TransitionSpec?? = .none, nextIndex: Int = 1, repeatMode: RepeatMode = .off, abLoop: Bool = false,
                      outgoing: Int64 = 200_000, incoming: Int64 = 180_000) -> BoundaryInfo {
        BoundaryInfo(spec: spec ?? self.spec, nextIndex: nextIndex, repeatMode: repeatMode, abLoopEnabled: abLoop,
                     outgoingDurationMs: outgoing, incomingDurationMs: incoming)
    }

    private func reason(_ info: BoundaryInfo) -> NoTransitionReason? { TransitionPlanner.plan(info).reason }

    func testConfiguredBoundaryCrossesAtDurationMinusTransition() {
        XCTAssertEqual(.planned(Planned(nextIndex: 1, startAtMs: 196_000, durationMs: 4_000, spec: spec)), TransitionPlanner.plan(info()))
    }

    func testNormalBoundaryCases() {
        XCTAssertEqual(.notConfigured, reason(info(spec: .some(nil))))
        XCTAssertEqual(.repeatOne, reason(info(repeatMode: .one)))
        XCTAssertEqual(.abLoop, reason(info(abLoop: true)))
        XCTAssertEqual(.noNext, reason(info(nextIndex: -1)))
        XCTAssertEqual(0, TransitionPlanner.plan(info(nextIndex: 0, repeatMode: .all)).planned?.nextIndex)
    }

    func testShortTracks() {
        let shortIncoming = TransitionPlanner.plan(info(incoming: 5_000)).planned!
        XCTAssertEqual(2_500, shortIncoming.durationMs)
        XCTAssertEqual(197_500, shortIncoming.startAtMs)
        let shortOutgoing = TransitionPlanner.plan(info(outgoing: 3_000)).planned!
        XCTAssertEqual(1_500, shortOutgoing.durationMs)
        XCTAssertEqual(1_500, shortOutgoing.startAtMs)
        XCTAssertEqual(.tooShort, reason(info(incoming: 400)))
        XCTAssertEqual(.unknownDuration, reason(info(outgoing: 0)))
    }

    func testCuePoints() {
        var cuedSpec = spec
        cuedSpec.outgoingCutMs = 30_000
        cuedSpec.incomingStartMs = 12_000
        let cued = TransitionPlanner.plan(info(spec: cuedSpec)).planned!
        XCTAssertEqual(166_000, cued.startAtMs)
        XCTAssertEqual(12_000, cued.incomingStartMs)
        XCTAssertEqual(4_000, cued.durationMs)
        var lateSpec = spec
        lateSpec.incomingStartMs = 175_000
        XCTAssertEqual(2_500, TransitionPlanner.plan(info(spec: lateSpec)).planned!.durationMs)
        var beyond = spec
        beyond.incomingStartMs = 200_000
        XCTAssertEqual(.tooShort, reason(info(spec: beyond)))
    }
}
