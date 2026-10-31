import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Erhu

final class ArtworkPaletteStateTests: XCTestCase {
    private func writePhoto(_ url: URL, red: CGFloat, green: CGFloat, blue: CGFloat) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testArtistPhotoUsesImageDecodingAndItsOwnPaletteCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePhoto(url, red: 0, green: 0.7, blue: 0)
        let cache = LyricsPaletteCache.shared
        let embedded = await cache.palette(for: url)
        XCTAssertEqual(embedded, .fallback, "An image is not an audio file with embedded tags")
        let photo = await cache.palette(for: .image(url))
        XCTAssertEqual(hslOf(photo.surface).h, 120, accuracy: 2)
        XCTAssertEqual(cache.cachedPalette(for: .image(url)), photo)
        XCTAssertEqual(cache.cachedPalette(for: url), .fallback)
        XCTAssertEqual(ArtworkPaletteState().palette(for: .image(url)), photo)
        XCTAssertEqual(ArtworkPaletteState().palette(for: .image(nil)), .fallback)
    }

    func testReplacingAnArtistPhotoAtTheSamePathRefreshesItsColours() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePhoto(url, red: 0.8, green: 0, blue: 0)
        let first = await LyricsPaletteCache.shared.palette(for: .image(url))
        var state = ArtworkPaletteState()
        state.set(first, for: .image(url), revision: ArtworkLoader.shared.revision(for: url.path))
        try writePhoto(url, red: 0, green: 0, blue: 0.8)
        ArtworkLoader.shared.forget(path: url.path)
        XCTAssertNil(LyricsPaletteCache.shared.cachedPalette(for: .image(url)))
        XCTAssertEqual(state.palette(for: .image(url)), .fallback)
        let second = await LyricsPaletteCache.shared.palette(for: .image(url))
        XCTAssertEqual(hslOf(first.surface).h, 0, accuracy: 2)
        XCTAssertEqual(hslOf(second.surface).h, 240, accuracy: 2)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(state.palette(for: .image(url)), second)
    }

    func testNewSongNeverInheritsThePreviousSongsPalette() {
        let first = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3")
        let next = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3")
        let red = LyricsPalette.from(hue: 0, saturation: 0.8, artworkLightness: 0.3)
        var state = ArtworkPaletteState()
        state.set(red, for: first, revision: ArtworkLoader.shared.revision(for: first.path))
        XCTAssertEqual(state.palette(for: first), red)
        XCTAssertEqual(state.palette(for: next), .fallback)
        XCTAssertEqual(state.palette(for: nil), .fallback)
        XCTAssertLessThan(hslOf(LyricsPalette.fallback.surface).s, 0.01, "Loading should not introduce a red/purple hue")
    }

    func testWarmPaletteIsImmediatelyAvailableToRecreatedViewsAndInvalidatedOnEdit() async {
        let url = TagFixtures.write(TagFixtures.mp3(v4: true), name: "palette-cache.mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LyricsPaletteCache.shared
        let sampled = await cache.palette(for: url)
        XCTAssertEqual(cache.cachedPalette(for: url), sampled)
        // New SwiftUI state can resolve synchronously before its .task executes.
        XCTAssertEqual(ArtworkPaletteState().palette(for: url), sampled)
        ArtworkLoader.shared.forget(path: url.path)
        XCTAssertNil(cache.cachedPalette(for: url))
    }

    func testEditingArtworkInvalidatesAViewsOlderAsyncResult() {
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3")
        var state = ArtworkPaletteState()
        let old = LyricsPalette.from(hue: 345, saturation: 0.8, artworkLightness: 0.3)
        state.set(old, for: url, revision: ArtworkLoader.shared.revision(for: url.path))
        ArtworkLoader.shared.forget(path: url.path)
        XCTAssertEqual(state.palette(for: url), .fallback)
    }
}
