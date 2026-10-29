import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Ehru

final class ArtworkRefreshTests: XCTestCase {
    private func png(width: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testLockScreenCanUseAnAlreadyCachedCoverSizeWithoutAnotherRead() async throws {
        let url = TagFixtures.write(TagFixtures.mp3(v4: true), name: "cached-fallback.mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        var edit = TagWriteRequest()
        edit.artwork = try png(width: 16)
        try TagWriter.write(edit, to: url)
        let loader = ArtworkLoader.shared
        loader.forget(path: url.path)
        let loaded = await loader.image(for: url, maxPixels: 1200)
        XCTAssertNotNil(loaded)
        XCTAssertNil(loader.cachedImage(for: url, maxPixels: 600))
        XCTAssertTrue(loader.cachedImage(for: url, maxPixels: 600, fallbackSizes: [1200, 300]) === loaded)
        loader.forget(path: url.path)
        XCTAssertNil(loader.cachedImage(for: url, maxPixels: 600, fallbackSizes: [1200, 300]))
    }

    func testReplacingArtAtTheSameURLInvalidatesPositiveAndMissingCaches() async throws {
        let url = TagFixtures.write(TagFixtures.mp3(v4: true), name: "artwork-refresh.mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = ArtworkLoader.shared
        var edit = TagWriteRequest()
        edit.artwork = try png(width: 8)
        try TagWriter.write(edit, to: url)
        loader.forget(path: url.path)
        let first = await loader.image(for: url, maxPixels: 64)
        XCTAssertEqual(first?.size.width, 8)
        XCTAssertNotNil(loader.cachedImage(for: url, maxPixels: 64))

        edit.artwork = try png(width: 16)
        try TagWriter.write(edit, to: url)
        loader.forget(path: url.path)
        XCTAssertNil(loader.cachedImage(for: url, maxPixels: 64))
        let replaced = await loader.image(for: url, maxPixels: 64)
        XCTAssertEqual(replaced?.size.width, 16)

        edit = TagWriteRequest()
        edit.clearArtwork = true
        try TagWriter.write(edit, to: url)
        loader.forget(path: url.path)
        let missing = await loader.image(for: url, maxPixels: 64)
        XCTAssertNil(missing)
        edit = TagWriteRequest()
        edit.artwork = try png(width: 8)
        try TagWriter.write(edit, to: url)
        loader.forget(path: url.path)
        let restored = await loader.image(for: url, maxPixels: 64)
        XCTAssertNotNil(restored)
    }
}
