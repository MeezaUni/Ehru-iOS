import XCTest
@testable import Erhu

final class ArtworkPaletteStateTests: XCTestCase {
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
