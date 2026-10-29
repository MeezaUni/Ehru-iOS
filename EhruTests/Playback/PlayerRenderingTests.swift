import SwiftUI
import UIKit
import XCTest
@testable import Ehru

/// Render the production containers, rather than accepting a mathematically correct frame
/// while its pixels are clipped, covered by a sibling, or collapsed to a tiny ideal size.
final class PlayerRenderingTests: XCTestCase {
    @MainActor
    func testCachedArtworkIsVisibleOnTheFirstFrameWithoutWaitingForATask() async throws {
        let url = TagFixtures.write(TagFixtures.mp3(v4: true), name: "first-frame-cover.mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var edit = TagWriteRequest()
        edit.artwork = try XCTUnwrap(image.pngData())
        try TagWriter.write(edit, to: url)
        ArtworkLoader.shared.forget(path: url.path)
        _ = await ArtworkLoader.shared.image(for: url, maxPixels: 600)
        // ImageRenderer does not run .task: this must use the existing 600px cache immediately,
        // even though the full player requests 1200px artwork.
        let rendered = try pixels(SongArtworkView(url: url, maxPixels: 1200), size: CGSize(width: 100, height: 100))
        assertColor(rendered, at: CGPoint(x: 50, y: 50), dominant: 0)
    }

    @MainActor
    func testCarouselActuallyPaintsBothPreviewsAndTheNearestCover() throws {
        let entries = (0..<4).map { QueueEntry(song: testSong(Int64($0 + 1))) }
        var scene = CarouselScene()
        scene.select(CarouselSelection(previous: entries[0], current: entries[1], next: entries[2]))
        let colors = [entries[0].id: Color.red, entries[1].id: .green, entries[2].id: .blue, entries[3].id: .red]
        func strip(_ focus: CGFloat, front: Int) -> some View {
            CarouselStrip(items: scene.items, focus: focus, frontOrdinal: front, stack: 0,
                          viewport: CGSize(width: 390, height: 450), cardSize: CGSize(width: 280, height: 380),
                          hideLeft: false, reduceMotion: false, meter: CarouselPresentationMeter()) { item in
                Rectangle().fill(colors[item.entry.id] ?? .white).frame(width: 280, height: 380)
            }
            .background(Color.black)
        }
        let resting = try pixels(strip(0, front: 0), size: CGSize(width: 390, height: 450))
        assertColor(resting, at: CGPoint(x: 5, y: 225), dominant: 0)
        assertColor(resting, at: CGPoint(x: 195, y: 225), dominant: 1)
        assertColor(resting, at: CGPoint(x: 385, y: 225), dominant: 2)
        let forward = try pixels(strip(0.75, front: 1), size: CGSize(width: 390, height: 450))
        assertColor(forward, at: CGPoint(x: 195, y: 225), dominant: 2)
        let reverse = try pixels(strip(0.25, front: 0), size: CGSize(width: 390, height: 450))
        assertColor(reverse, at: CGPoint(x: 195, y: 225), dominant: 1)
        scene.select(CarouselSelection(previous: entries[1], current: entries[2], next: entries[3]))
        scene.settle()
        let afterSkip = try pixels(strip(1, front: 1), size: CGSize(width: 390, height: 450))
        assertColor(afterSkip, at: CGPoint(x: 5, y: 225), dominant: 1)
        assertColor(afterSkip, at: CGPoint(x: 195, y: 225), dominant: 2)
        assertColor(afterSkip, at: CGPoint(x: 385, y: 225), dominant: 0)
    }

    @MainActor
    func testCoverPixelsEscapeTheScrollViewportAndLandOnTheMiniPlayer() throws {
        let source = CGRect(x: 55, y: 100, width: 280, height: 280)
        let mini = CGRect(x: 20, y: 745, width: 44, height: 44)
        for progress in [CGFloat(1), 0.5, 0] {
            let content = ZStack(alignment: .topLeading) {
                Color.black
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        Color.gray.frame(width: 280, height: 380).offset(x: 55, y: 100)
                        Color.blue.frame(width: 350, height: 90).offset(x: 20, y: 450)
                    }.frame(width: 390, height: 600)
                }
                .frame(width: 390, height: 600)
                .clipped()
            }
            .frame(width: 390, height: 844)
            .overlay {
                PlayerArtworkOverlay(progress: progress, frames: PlayerArtworkFrames(expanded: source, mini: mini)) {
                    Color.red
                }
            }
            let rendered = try pixels(content, size: CGSize(width: 390, height: 844))
            let center = CGPoint(x: mini.midX + (source.midX - mini.midX) * progress,
                                 y: mini.midY + (source.midY - mini.midY) * progress)
            assertColor(rendered, at: center, dominant: 0)
            assertColor(rendered, at: CGPoint(x: 350, y: 495), dominant: 2)
        }
    }

    @MainActor
    func testAuditionCursorPaintsOneStraightLineThroughBothWaveforms() throws {
        for fraction in [0.2, 0.5, 0.8] {
            let content = TransitionPlayheadStroke(fraction: fraction).background(Color.black)
            let rendered = try pixels(content, size: CGSize(width: 300, height: 280))
            for y in [15, 70, 140, 210, 265] {
                assertColor(rendered, at: CGPoint(x: fraction * 300, y: Double(y)), dominant: 1)
            }
            let otherX = fraction == 0.5 ? 20 : 150
            let outside = rendered.color(x: otherX, y: 140)
            XCTAssertLessThan(outside.max() ?? 1, 0.05)
        }
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        func color(x: Int, y: Int) -> [Double] {
            let start = (y * width + x) * 4
            return (0..<3).map { Double(bytes[start + $0]) / 255 }
        }
    }

    @MainActor
    private func pixels<Content: View>(_ content: Content, size: CGSize) throws -> Pixels {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(bytes: bytes, width: width)
    }

    private func assertColor(_ image: Pixels, at point: CGPoint, dominant: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        let rgb = image.color(x: Int(point.x.rounded()), y: Int(point.y.rounded()))
        XCTAssertGreaterThan(rgb[dominant], 0.25, "Missing cover/cursor at \(point): \(rgb)", file: file, line: line)
        for component in 0..<3 where component != dominant {
            XCTAssertGreaterThan(rgb[dominant], rgb[component] * 1.4, "Incorrect stacking at \(point): \(rgb)", file: file, line: line)
        }
    }
}
