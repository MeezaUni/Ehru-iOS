import AVFoundation
import MediaPlayer
import XCTest
@testable import Erhu

final class LockScreenMotionArtworkTests: XCTestCase {
    func testOnlyRecognizedAspectRatiosUseSupportedSystemKeys() {
        XCTAssertEqual(LockScreenMotionAspect(size: CGSize(width: 600, height: 600)), .square)
        XCTAssertEqual(LockScreenMotionAspect(size: CGSize(width: 450, height: 600)), .portrait)
        XCTAssertNil(LockScreenMotionAspect(size: CGSize(width: 1920, height: 1080)))
        XCTAssertNil(LockScreenMotionAspect(size: .zero))
        if #available(iOS 26.0, *) {
            let square = MPNowPlayingInfoProperty1x1AnimatedArtwork
            let portrait = MPNowPlayingInfoProperty3x4AnimatedArtwork
            XCTAssertEqual(LockScreenMotionAspect.square.key(supported: [square]), square)
            XCTAssertNil(LockScreenMotionAspect.portrait.key(supported: [square]))
            XCTAssertNil(LockScreenMotionAspect.square.key(supported: []))
            XCTAssertEqual(LockScreenMotionAspect.portrait.key(supported: [portrait]), portrait)
        }
    }

    func testExistingSavedCoverIndexStillDecodesWithoutPortraitField() throws {
        let data = Data(#"{"albumId":1,"album":"Album","artist":"Artist","catalogId":42,"storefront":"us","fileName":"old.mp4"}"#.utf8)
        let cover = try JSONDecoder().decode(SavedMotionCover.self, from: data)
        XCTAssertEqual(cover.fileName, "old.mp4")
        XCTAssertNil(cover.portraitFileName)
    }

    private func movie(width: Int = 64, height: Int = 64) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &optionalBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 255, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = Date().addingTimeInterval(5)
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard input.isReadyForMoreMediaData else { throw writer.error ?? MotionArtworkError("Test video writer timed out") }
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    func testPreviewComesFromVideoAndFileRemainsValidAfterDownloadRemoval() async throws {
        let source = try await movie()
        defer { try? FileManager.default.removeItem(at: source) }
        var asset: LockScreenMotionAsset? = try await LockScreenMotionAsset.prepare(source: source)
        XCTAssertEqual(asset?.aspect, .square)
        XCTAssertEqual(asset?.preview.width, asset?.preview.height)
        let leased = try XCTUnwrap(asset?.url)
        let id = try XCTUnwrap(asset?.artworkID)
        XCTAssertTrue(id.contains(source.lastPathComponent))
        XCTAssertNotEqual(leased, source)
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leased.path))
        let playable = try await AVURLAsset(url: leased).load(.isPlayable)
        XCTAssertTrue(playable)
        asset = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: leased.path))
    }

    func testHighResolutionPreviewIsNotReducedTo600Pixels() async throws {
        let source = try await movie(width: 1280, height: 1280)
        defer { try? FileManager.default.removeItem(at: source) }
        let asset = try await LockScreenMotionAsset.prepare(source: source)
        XCTAssertEqual(asset.aspect, .square)
        XCTAssertGreaterThanOrEqual(asset.preview.width, 1080)
        XCTAssertLessThanOrEqual(asset.preview.width, 1200)
        XCTAssertEqual(asset.preview.width, asset.preview.height)
    }

    func testAnimatedDescriptorRetainsItsVideoAndUnsupportedKeysHaveNoEntry() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Animated Now Playing artwork requires iOS 26") }
        let source = try await movie()
        defer { try? FileManager.default.removeItem(at: source) }
        var asset: LockScreenMotionAsset? = try await LockScreenMotionAsset.prepare(source: source)
        let leased = try XCTUnwrap(asset?.url)
        XCTAssertTrue(try XCTUnwrap(asset).info(supported: []).isEmpty)
        try autoreleasepool {
            var info = try XCTUnwrap(asset).info(supported: [MPNowPlayingInfoProperty1x1AnimatedArtwork])
            XCTAssertTrue(info[MPNowPlayingInfoProperty1x1AnimatedArtwork] is MPMediaItemAnimatedArtwork)
            asset = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: leased.path), "System request handlers retain the asset")
            info.removeAll()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leased.path))
    }

    func testMissingAndRemoteVideosNeverBecomeLockScreenArtwork() async {
        for url in [URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"), URL(string: "https://example.com/clip.mp4")!] {
            do {
                _ = try await LockScreenMotionAsset.prepare(source: url)
                XCTFail("Expected a local, readable video")
            } catch { /* Existing static Now Playing artwork remains the fallback. */ }
        }
    }

    @MainActor
    func testBadPortraitDoesNotDiscardSquareAndUnchangedInputDoesNotReprepare() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Animated Now Playing artwork requires iOS 26") }
        let source = try await movie()
        defer { try? FileManager.default.removeItem(at: source) }
        let missing = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        let manager = LockScreenMotionArtwork(supportedKeys: {
            [MPNowPlayingInfoProperty1x1AnimatedArtwork, MPNowPlayingInfoProperty3x4AnimatedArtwork]
        })
        let ready = expectation(description: "Square survives portrait failure")
        manager.update(sources: [source, missing]) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(manager.status, .ready)
        let artwork = try XCTUnwrap(manager.info[MPNowPlayingInfoProperty1x1AnimatedArtwork] as? MPMediaItemAnimatedArtwork)
        XCTAssertNil(manager.info[MPNowPlayingInfoProperty3x4AnimatedArtwork])
        manager.update(sources: [source, missing]) { XCTFail("Unchanged artwork must not be decoded again") }
        XCTAssertTrue(manager.info[MPNowPlayingInfoProperty1x1AnimatedArtwork] as? MPMediaItemAnimatedArtwork === artwork)
    }

    @MainActor
    func testBothShapesArePublishedAndClearedWhenCoverIsRemoved() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Animated Now Playing artwork requires iOS 26") }
        let square = try await movie()
        let portrait = try await movie(width: 48, height: 64)
        defer {
            try? FileManager.default.removeItem(at: square)
            try? FileManager.default.removeItem(at: portrait)
        }
        let manager = LockScreenMotionArtwork(supportedKeys: {
            [MPNowPlayingInfoProperty1x1AnimatedArtwork, MPNowPlayingInfoProperty3x4AnimatedArtwork]
        })
        let ready = expectation(description: "Both shapes prepared")
        manager.update(sources: [square, portrait]) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(manager.status, .ready)
        XCTAssertEqual(Set(manager.info.keys), Set([MPNowPlayingInfoProperty1x1AnimatedArtwork, MPNowPlayingInfoProperty3x4AnimatedArtwork]))
        manager.update(sources: [], onReady: {})
        XCTAssertTrue(manager.info.isEmpty)
        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(manager.videoRequested)
    }

    @MainActor
    func testSameFileIsRetriedWhenSystemCapabilitiesChange() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Animated Now Playing artwork requires iOS 26") }
        let source = try await movie()
        defer { try? FileManager.default.removeItem(at: source) }
        var supported: [String] = []
        let manager = LockScreenMotionArtwork(supportedKeys: { supported })
        manager.update(sources: [source], onReady: {})
        guard case .unavailable = manager.status else { return XCTFail("Expected unsupported status") }
        supported = [MPNowPlayingInfoProperty1x1AnimatedArtwork]
        let ready = expectation(description: "Capability change retries same file")
        manager.update(sources: [source]) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(manager.status, .ready)
        XCTAssertFalse(manager.info.isEmpty)
    }

    @MainActor
    func testPreparationFailureIsVisibleAndCanBeRetriedWithoutChangingURL() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Animated Now Playing artwork requires iOS 26") }
        let source = try await movie()
        let original = try Data(contentsOf: source)
        try FileManager.default.removeItem(at: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let manager = LockScreenMotionArtwork(supportedKeys: { [MPNowPlayingInfoProperty1x1AnimatedArtwork] })
        let failed = expectation(description: "Preparation failure reported")
        manager.update(sources: [source]) { failed.fulfill() }
        await fulfillment(of: [failed], timeout: 10)
        guard case .unavailable(let message) = manager.status else { return XCTFail("Expected an explanation") }
        XCTAssertTrue(message.contains("Could not prepare"))
        XCTAssertTrue(manager.info.isEmpty)

        try original.write(to: source)
        manager.retry()
        let ready = expectation(description: "Same URL works after retry")
        manager.update(sources: [source]) { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(manager.status, .ready)
    }
    @MainActor
    func testReturningToAnAlbumReusesItsPreparedAnimationImmediately() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Animated Now Playing artwork requires iOS 26") }
        let a = try await movie(), b = try await movie()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let manager = LockScreenMotionArtwork(supportedKeys: { [MPNowPlayingInfoProperty1x1AnimatedArtwork] })
        let first = expectation(description: "First album prepared")
        manager.update(sources: [a]) { first.fulfill() }
        await fulfillment(of: [first], timeout: 10)
        let second = expectation(description: "Second album prepared")
        manager.update(sources: [b]) { second.fulfill() }
        await fulfillment(of: [second], timeout: 10)
        manager.update(sources: [a], onReady: {})
        XCTAssertEqual(manager.status, .ready, "Returning to a cached album must not enter a blank preparation phase")
        XCTAssertFalse(manager.info.isEmpty)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: a.path)
        let replaced = expectation(description: "Changed download prepared again")
        manager.update(sources: [a]) { replaced.fulfill() }
        XCTAssertEqual(manager.status, .preparing)
        await fulfillment(of: [replaced], timeout: 10)
        XCTAssertEqual(manager.status, .ready)
    }

}
