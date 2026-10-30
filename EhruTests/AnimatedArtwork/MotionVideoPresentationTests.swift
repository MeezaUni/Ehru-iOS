import AVFoundation
import UIKit
import XCTest
@testable import Ehru

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
    func testCurrentVideoFrameFreezesIntoAnImageAndRestoresWithoutASecondPlayer() async throws {
        let surface = MotionVideoSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                          nil, &optionalBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 255, CVPixelBufferGetBytesPerRow(buffer) * 64)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        surface.setReady(true)
        surface.freeze(buffer)
        let image = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        for _ in 0..<100 {
            if image.image != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(surface.isFrozen)
        XCTAssertNotNil(image.image)
        XCTAssertEqual(surface.videoLayer.opacity, 0)
        surface.unfreeze()
        XCTAssertFalse(surface.isFrozen)
        XCTAssertNil(image.image)
        XCTAssertEqual(surface.videoLayer.opacity, 1)
        // A result completing after cancellation must not put a snapshot back over live video.
        surface.freeze(buffer)
        surface.unfreeze()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(image.image)
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

    private func movie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
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
        let deadline = Date().addingTimeInterval(5)
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard input.isReadyForMoreMediaData else { throw MotionArtworkError("Test movie writer timed out") }
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}
