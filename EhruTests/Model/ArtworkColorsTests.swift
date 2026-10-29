@testable import Ehru
import SwiftUI
import XCTest

final class ArtworkColorsTests: XCTestCase {
    private func image(_ fill: (Int) -> UInt32) -> [UInt32] {
        (0..<(64 * 64)).map(fill)
    }

    func testARedCoverGivesARedAccentOnADarkRedBackground() {
        let colors = DominantColorExtractor.colors(pixels: image { _ in 0xFFE0_2030 })
        let palette = DominantColorExtractor.palette(colors)
        let bg = DominantColorExtractor.rgbToHsl(Int(colors.primary >> 16 & 0xFF), Int(colors.primary >> 8 & 0xFF), Int(colors.primary & 0xFF))
        XCTAssertLessThan(abs(bg.h - 355), 10)
        XCTAssertNotEqual(palette, .dark)
    }

    func testADarkCoverPicksASmallVividClusterAsAccent() {
        // Mostly near-black blue, with a few bright orange pixels.
        let colors = DominantColorExtractor.colors(pixels: image { $0 % 40 == 0 ? 0xFFF0_8020 : 0xFF10_1830 })
        let accent = DominantColorExtractor.rgbToHsl(Int(colors.accent >> 16 & 0xFF), Int(colors.accent >> 8 & 0xFF), Int(colors.accent & 0xFF))
        XCTAssertLessThan(abs(accent.h - 27), 10, "the orange, not the blue")
    }

    func testAGreyCoverFallsBackToNeutralSurfaces() {
        let palette = DominantColorExtractor.palette(DominantColorExtractor.colors(pixels: image { _ in 0xFF80_8080 }))
        XCTAssertEqual(palette.background, Color(argb: 0xFF0F_1014))
    }

    func testHslRoundTrips() {
        for argb: UInt32 in [0xFFFF_0000, 0xFF00_FF00, 0xFF33_66CC, 0xFF80_8080] {
            let hsl = DominantColorExtractor.rgbToHsl(Int(argb >> 16 & 0xFF), Int(argb >> 8 & 0xFF), Int(argb & 0xFF))
            XCTAssertEqual(DominantColorExtractor.hslToArgb(hsl.h, hsl.s, hsl.l), argb)
        }
    }

    func testArtworkThemeUsesTheSamePaletteAsThePlayerCard() {
        for hue: Float in [0, 30, 120, 210, 290] {
            let sampled = LyricsPalette.from(hue: hue, saturation: 0.6, artworkLightness: 0.3)
            let card = LyricsColors(sampled)
            let page = AppPalette.artwork(sampled)
            XCTAssertEqual(page.surface, card.surface)
            XCTAssertEqual(page.primary, card.accent)
            XCTAssertEqual(page.onSurface, card.content)
            XCTAssertEqual(page.onSurfaceVariant, card.secondary)
            XCTAssertEqual(page.background, card.cardGradient.last ?? card.surface)
        }
    }

    func testIncompleteTracksAreFoundForFixTags() {
        func song(_ id: Int64, _ title: String, _ artist: String, _ album: String, trackNumber: Int = 1) -> Song {
            Song(id: id, title: title, artist: artist, album: album, durationMs: 1, path: "\(id).mp3", trackNumber: trackNumber)
        }
        let songs = [
            song(1, "Fine", "Artist", "Album"),
            song(2, "Track 01", "", "Album"),
            song(3, "Song", "Artist", ""),
            song(4, "Song (www.site.com)", "Artist", "Album"),
            song(5, "song.mp3", "Unknown Artist", "Album"),
            song(6, "Fine", "Artist", "Album", trackNumber: 0),
        ]
        XCTAssertEqual(FixTagsStore.incomplete(songs).map(\.id), [2, 3, 4, 5, 6])
    }
}
