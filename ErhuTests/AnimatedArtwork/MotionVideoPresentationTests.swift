import AVFoundation
import UIKit
import SwiftUI
import Observation
import XCTest
@testable import Erhu

final class MotionVideoPresentationTests: XCTestCase {
    @MainActor
    func testUnusedVideoSessionsDoNotConstructNativePlayersOrLayers() {
        for _ in 0..<20 {
            let session = MotionVideoSession()
            session.pause()
            session.stop()
            XCTAssertFalse(session.hasResidentPlayer)
            XCTAssertFalse(session.hasResidentSurface)
        }
    }

    @MainActor
    func testVideoBoundsDoNotLagBehindContainerWithAnImplicitResizeAnimation() {
        let surface = MotionVideoSurface(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        surface.layoutIfNeeded()
        CATransaction.begin()
        CATransaction.setAnimationDuration(1)
        surface.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        CATransaction.commit()
        XCTAssertEqual(surface.videoLayer.frame, surface.bounds)
        XCTAssertFalse(surface.videoLayer.animationKeys()?.contains("bounds") ?? false)
        XCTAssertFalse(surface.videoLayer.animationKeys()?.contains("position") ?? false)
    }

    @MainActor
    func testTemporaryReadinessChangesKeepThePresentedVideoLayerVisible() {
        let surface = MotionVideoSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        surface.setReady(true)
        surface.freeze()
        surface.setReady(false)
        XCTAssertTrue(surface.isFrozen)
        XCTAssertEqual(surface.videoLayer.opacity, 1, "An occluded cover must hold its decoded frame, not expose the poster")
        XCTAssertTrue(surface.subviews.isEmpty, "Dragging must not allocate a bitmap snapshot view")
        surface.unfreeze()
        XCTAssertEqual(surface.videoLayer.opacity, 1)
        surface.reset()
        XCTAssertEqual(surface.videoLayer.opacity, 0, "A new asset must still start with its loading fallback")
    }

    @MainActor
    func testOcclusionPausesTheMountedMovieAndPowerModeAloneUsesStaticFallback() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let session = MotionVideoSession()
        let visibility = CoverVisibility()
        let controller = UIHostingController(rootView: CoverProbe(url: url, session: session, visibility: visibility)
            // MovingArtwork is a production modifier with its own required environment,
            // even when this fixture supplies a video and disables still-image motion.
            .environment(AnimatedArtworkStore()).environment(AppSettings()).ignoresSafeArea())
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            session.stop(); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for _ in 0..<250 {
            if session.hasResidentSurface && session.surface.videoLayer.isReadyForDisplay { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.surface.videoLayer.isReadyForDisplay)
        let item = try XCTUnwrap(session.player.currentItem)
        let surface = session.surface
        let host = try XCTUnwrap(surface.superview)
        visibility.visible = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(surface.superview === host, "Opening the player must pause the album layer without dismantling it")
        XCTAssertTrue(session.player.currentItem === item)
        XCTAssertEqual(session.player.rate, 0)
        let paused = session.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.player.currentTime().seconds, paused, accuracy: 1.0 / 30)
        visibility.moving = true
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(surface.isFrozen)
        XCTAssertTrue(surface.superview === host)
        XCTAssertEqual(surface.videoLayer.opacity, 1)
        visibility.moving = false
        visibility.visible = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(surface.superview === host)
        XCTAssertEqual(session.player.rate, 1)
        visibility.lowPower = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(surface.superview, "Low Power Mode may use the static fallback")
        XCTAssertEqual(session.player.rate, 0)
        visibility.lowPower = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.surface === surface)
        XCTAssertNotNil(surface.superview)
        XCTAssertTrue(session.player.currentItem === item)
    }

    @MainActor @Observable
    final class CoverVisibility {
        var visible = true
        var moving = false
        var lowPower = false
    }

    private struct CoverProbe: View {
        let url: URL
        let session: MotionVideoSession
        let visibility: CoverVisibility
        var body: some View {
            MotionCoverView(song: nil, videoURL: url, playing: true, videoSession: session, tracksScrollVisibility: false)
                .environment(\.motionCoverVisible, visibility.visible)
                .environment(\.playerInMotion, visibility.moving)
                .environment(\.scenePhase, .active)
                .environment(\.visualWorkBudget, VisualWorkBudget(lowPower: visibility.lowPower, thermalState: .nominal))
                .frame(width: 100, height: 100)
        }
    }

    @MainActor
    func testPausedNeighbourActuallyDecodesAFirstFrameBeforeItStartsMoving() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let scene = try XCTUnwrap(previous?.windowScene ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let session = MotionVideoSession()
        defer {
            session.stop(); window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let host = MotionVideoHost(frame: controller.view.bounds)
        controller.view.addSubview(host)
        session.prepare(url: url)
        session.attach(host, url: url, playing: false, frozen: false)
        for _ in 0..<250 {
            if session.surface.videoLayer.isReadyForDisplay || session.player.status == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(session.player.status, .readyToPlay)
        XCTAssertTrue(session.surface.videoLayer.isReadyForDisplay, "A queued movie must have a real decoded frame ready before a swipe")
        XCTAssertEqual(session.player.rate, 0)
        let item = session.player.currentItem
        let layer = session.surface.videoLayer
        session.attach(host, url: url, playing: true, frozen: false)
        XCTAssertTrue(session.player.currentItem === item)
        XCTAssertTrue(session.surface.videoLayer === layer)
        XCTAssertFalse(session.surface.isFrozen)
    }

    @MainActor
    func testSameAlbumRebindKeepsItsItemAndOldSurfaceTeardownCannotStopTheNewOne() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = MotionVideoSession()
        defer { session.stop() }
        let first = MotionVideoHost(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        session.attach(first, url: url, playing: false, frozen: false)
        for _ in 0..<100 {
            if session.player.currentItem != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try XCTUnwrap(session.player.currentItem)
        let originalLayer = session.surface.videoLayer
        let next = MotionVideoHost(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        session.attach(next, url: url, playing: false, frozen: true)
        XCTAssertTrue(session.player.currentItem === item)
        XCTAssertTrue(session.surface.videoLayer === originalLayer)
        XCTAssertTrue(session.surface.videoLayer.player === session.player)
        XCTAssertTrue(session.surface.superview === next)
        XCTAssertTrue(first.subviews.isEmpty)
        XCTAssertEqual(session.surface.bounds, next.bounds)
        XCTAssertTrue(session.surface.isFrozen)
        session.detach(first)
        XCTAssertTrue(session.surface.superview === next)
        XCTAssertTrue(session.player.currentItem === item)
        session.attach(first, url: url, playing: false, frozen: false)
        session.detach(next)
        XCTAssertTrue(session.surface.superview === first)
        XCTAssertTrue(session.surface.videoLayer === originalLayer)
        XCTAssertTrue(session.player.currentItem === item)
        XCTAssertFalse(session.surface.isFrozen)
        session.stop()
        XCTAssertNil(session.player.currentItem)
        XCTAssertNil(session.surface.videoLayer.player)
        XCTAssertNil(session.surface.superview)
    }

    @MainActor
    func testNeighbourKeepsItsOwnPreparedMovieThroughTurnoverAndOldCardTeardown() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = CarouselVideoDeck()
        defer { deck.stop() }
        let requests = (-1...1).map { CarouselVideoDeck.Request(key: "\($0)", url: url) }
        deck.configure(requests, current: "0")
        let outgoing = try XCTUnwrap(deck.currentSession)
        let incoming = try XCTUnwrap(deck.slots["1"]?.session)
        let reusable = try XCTUnwrap(deck.slots["-1"]?.session)
        XCTAssertFalse(outgoing === incoming, "Cards on the same album must not steal one shared layer")
        let first = MotionVideoHost(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = MotionVideoHost(frame: first.frame)
        outgoing.attach(first, url: url, playing: true, frozen: false)
        incoming.attach(second, url: url, playing: false, frozen: false)
        // AVPlayerLooper inserts its copied item asynchronously, even for a local file.
        for _ in 0..<250 {
            if incoming.player.currentItem != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(incoming.player.currentItem)
        let surface = incoming.surface
        XCTAssertTrue(surface.superview === second)
        XCTAssertFalse(surface.isFrozen)
        // The approaching card starts before the centre, without replacing its paused layer.
        incoming.attach(second, url: url, playing: true, frozen: false)
        deck.configure([requests[1], requests[2], .init(key: "2", url: url)], current: "1", prepareNeighbours: false)
        XCTAssertTrue(deck.currentSession === incoming)
        XCTAssertTrue(incoming.player.currentItem === prepared)
        XCTAssertTrue(incoming.surface === surface)
        XCTAssertTrue(outgoing.surface.superview === first)
        outgoing.detach(first)
        XCTAssertTrue(surface.superview === second)
        XCTAssertNil(deck.slots["2"], "Do not construct a far neighbour during an active turnover")
        XCTAssertEqual(deck.residentCount, 3)
        deck.configure([requests[1], requests[2], .init(key: "2", url: url)], current: "1")
        XCTAssertEqual(deck.slots.count, 3)
        XCTAssertTrue(deck.slots["2"]?.session === reusable, "Same-album swipes must recycle the already prepared neighbour")
        XCTAssertEqual(deck.residentCount, 3)
        deck.retainCurrent()
        XCTAssertEqual(deck.slots.count, 1)
        XCTAssertEqual(deck.residentCount, 1)
        XCTAssertTrue(deck.currentSession === incoming)
        XCTAssertEqual(incoming.player.rate, 0)
        deck.configure([.init(key: "reopened-at-zero", url: url)], current: "reopened-at-zero")
        XCTAssertTrue(deck.currentSession === incoming, "Reopening must preserve the ready movie despite new carousel coordinates")
        XCTAssertTrue(incoming.player.currentItem === prepared)
        XCTAssertTrue(incoming.surface === surface)
    }

    @MainActor
    func testApproachingVideoStartsBeforeCentreAndThePoolStaysBounded() {
        XCTAssertTrue(CarouselVideoDeck.shouldAnimate(distance: 0, current: true))
        XCTAssertFalse(CarouselVideoDeck.shouldAnimate(distance: 1, current: false))
        XCTAssertTrue(CarouselVideoDeck.shouldAnimate(distance: 0.7, current: false))
        XCTAssertTrue(CarouselVideoDeck.shouldAnimate(distance: -0.7, current: false))
        XCTAssertFalse(CarouselVideoDeck.shouldAnimate(distance: 1.5, current: false))
        let deck = CarouselVideoDeck()
        // Empty construction is cheap; media is only allocated for downloaded cover requests.
        XCTAssertTrue(deck.slots.isEmpty)
        XCTAssertNil(deck.currentSession)
    }

    @MainActor
    func testMiniPlayerHandsTheSameMovieToAnOpeningCarouselEvenWithRepeatNeighbours() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = CarouselVideoDeck()
        defer { deck.stop() }
        deck.configure([.init(key: "old#1", url: url)], current: "old#1")
        let original = try XCTUnwrap(deck.currentSession)
        let player = original.player
        deck.prepareMini(url: url, entryID: UUID())
        XCTAssertTrue(deck.currentSession === original)
        // The old coordinate is also a repeat neighbour. The mini's layer must become current,
        // with a separate neighbour filled later, rather than moving to the back card.
        deck.configure([.init(key: "new#0", url: url), .init(key: "old#1", url: url)], current: "new#0",
                       prepareNeighbours: false, allowNewSessions: false)
        XCTAssertTrue(deck.currentSession === original)
        XCTAssertTrue(deck.currentSession?.player === player)
        XCTAssertNil(deck.slots["old#1"])
        deck.configure([.init(key: "new#0", url: url), .init(key: "old#1", url: url)], current: "new#0")
        XCTAssertFalse(deck.slots["old#1"]?.session === original)
        XCTAssertLessThanOrEqual(deck.residentCount, 3)
        deck.retainCurrent(pause: false)
        XCTAssertTrue(deck.currentSession === original)
    }

    @MainActor
    func testColdDecoderConstructionCanWaitUntilAfterTheGesture() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = CarouselVideoDeck()
        defer { deck.stop() }
        let requests = [CarouselVideoDeck.Request(key: "current", url: url)]
        deck.configure(requests, current: "current", allowNewSessions: false)
        XCTAssertTrue(deck.slots.isEmpty)
        XCTAssertNil(deck.currentSession)
        deck.configure(requests, current: "current")
        let prepared = try XCTUnwrap(deck.currentSession)
        XCTAssertTrue(prepared.hasResidentPlayer)
        deck.configure(requests, current: "current", allowNewSessions: false)
        XCTAssertTrue(deck.currentSession === prepared)
    }

    @MainActor
    func testVideoPosterUsesRealPixelsAndIsSharedWithoutRepeatedExtraction() async throws {
        let url = try await movie()
        let poster = MotionCoverPosterCache.posterURL(for: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: poster)
        }
        let cache = MotionCoverPosterCache()
        async let first = cache.image(for: url)
        async let second = cache.image(for: url)
        let (a, b) = await (first, second)
        let image = try XCTUnwrap(a)
        XCTAssertTrue(image === b, "Simultaneous mini/carousel requests must share one extraction")
        XCTAssertTrue(cache.cached(url) === image)
        XCTAssertEqual(image.cgImage?.width, 64)
        XCTAssertEqual(image.cgImage?.height, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: poster.path))
        let restoredImage = await MotionCoverPosterCache().image(for: url)
        let restored = try XCTUnwrap(restoredImage)
        XCTAssertEqual(restored.cgImage?.width, 64)
        // The fixture contains white video frames: the poster must contain those real pixels.
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[0], 240)
        XCTAssertGreaterThan(pixel[1], 240)
        XCTAssertGreaterThan(pixel[2], 240)
        cache.forget(url)
        XCTAssertNil(cache.cached(url))
    }

    @MainActor
    func testPosterHandlesAClipWhoseFirstPictureStartsAfterZero() async throws {
        let url = try await movie(firstFrameTime: CMTime(value: 3, timescale: 30))
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: MotionCoverPosterCache.posterURL(for: url))
        }
        let image = await MotionCoverPosterCache().image(for: url)
        XCTAssertNotNil(image, "A leading composition offset must not replace the video poster with embedded artwork")
        XCTAssertEqual(image?.cgImage?.width, 64)
    }

    private func movie(firstFrameTime: CMTime = .zero) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        defer {
            if writer.status != .completed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 255, CVPixelBufferGetBytesPerRow(buffer) * 64)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // Keep identity assertions away from the looper's intentional end-of-file item swap.
        for frame in 0..<60 {
            // Bound a stalled encoder, rather than the total time for all 60 frames on a
            // shared simulator runner. Every successful append starts a fresh progress budget.
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard input.isReadyForMoreMediaData else {
                throw writer.error ?? MotionArtworkError("Test movie writer stalled at frame \(frame) (status \(writer.status.rawValue))")
            }
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTimeAdd(firstFrameTime, CMTime(value: Int64(frame), timescale: 30))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}
