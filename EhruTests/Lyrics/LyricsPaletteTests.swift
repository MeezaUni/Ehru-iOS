@testable import Ehru
import XCTest

/// The lyrics surface's colours from artwork: in the artwork's hue, and always readable.
final class LyricsPaletteTests: XCTestCase {
    private func artwork(_ colors: UInt32...) -> [UInt32] {
        (0..<(32 * 32)).map { colors[$0 % colors.count] }
    }

    /// Hue in degrees, or -1 for a grey.
    private func hueOf(_ argb: UInt32) -> Float {
        let hsl = hslOf(argb)
        return hsl.s == 0 ? -1 : hsl.h
    }

    private func hueDistance(_ a: Float, _ b: Float) -> Float {
        min(abs(a - b), 360 - abs(a - b))
    }

    /// Text must read on the surface and on every stop of the opaque gradients.
    private func assertReadable(_ palette: LyricsPalette, file: StaticString = #filePath, line: UInt = #line) {
        for stop in palette.gradient + palette.cardGradient + [palette.surface] {
            XCTAssertGreaterThanOrEqual(contrast(palette.content, stop), 4.5, "content", file: file, line: line)
            XCTAssertGreaterThanOrEqual(contrast(palette.secondary, stop), 3.0, "secondary", file: file, line: line)
            XCTAssertGreaterThanOrEqual(contrast(palette.accent, stop), 4.5, "accent", file: file, line: line)
        }
    }

    func testTheGradientHasTonalDepthNotOneFlatColour() {
        let palette = LyricsPalette.fromPixels(artwork(0xFFFF_8C1A, 0xFFE0_601E))
        let top = palette.gradient[0], middle = palette.gradient[1], bottom = palette.gradient[2]
        XCTAssertEqual(middle, palette.surface)
        XCTAssertGreaterThan(relativeLuminance(top), relativeLuminance(middle))
        XCTAssertLessThan(relativeLuminance(bottom), relativeLuminance(middle))
        // The deeper stop turns away from the dominant hue (not the same colour darker).
        XCTAssertGreaterThan(hueDistance(hueOf(bottom), hueOf(middle)), 10)
    }

    func testTwoColourArtworkCardGradientEndsInTheSecondColour() {
        let palette = LyricsPalette.fromPixels(artwork(0xFFE0_202A, 0xFFE0_202A, 0xFF1E_50D8))
        XCTAssertLessThan(hueDistance(hueOf(palette.cardGradient[0]), 0), 20)
        XCTAssertLessThan(hueDistance(hueOf(palette.cardGradient[2]), 225), 20)
        assertReadable(palette)
    }

    func testSingleColourArtworkCardGradientStaysNearItsHue() {
        let palette = LyricsPalette.fromPixels(artwork(0xFFE0_202A))
        for stop in palette.cardGradient { XCTAssertLessThan(hueDistance(hueOf(stop), 0), 40) }
        XCTAssertEqual(Set(palette.cardGradient).count, 3)
    }

    func testMonochromeArtworkGivesAGreyGradient() {
        let palette = LyricsPalette.fromPixels(artwork(0xFF22_2222, 0xFF99_9999))
        for stop in palette.gradient { XCTAssertEqual(hueOf(stop), -1) }
        assertReadable(palette)
    }

    func testWarmOrangeArtworkGivesAWarmDarkSurface() {
        let palette = LyricsPalette.fromPixels(artwork(0xFFFF_8C1A, 0xFFE0_601E, 0xFF3A_6B2F))
        XCTAssertLessThan(hueDistance(hueOf(palette.surface), 28), 25)
        XCTAssertLessThan(relativeLuminance(palette.surface), 0.08)
        assertReadable(palette)
    }

    func testBlueAndPinkAndGreenArtworkKeepTheirHue() {
        let cases: [(UInt32, Float)] = [(0xFF1E_5BD6, 220), (0xFFE8_5D9A, 333), (0xFF2E_8B57, 146)]
        for (color, hue) in cases {
            let palette = LyricsPalette.fromPixels(artwork(color))
            XCTAssertLessThan(hueDistance(hueOf(palette.surface), hue), 20, "hue for \(hue)")
            assertReadable(palette)
        }
    }

    func testCompetingColoursDoNotCancelOutIntoGrey() {
        // Lavender background, pink and warm skin tones (a mostly pastel cover): the strongest colour wins.
        let palette = LyricsPalette.fromPixels(artwork(0xFFC9_B3E0, 0xFFC9_B3E0, 0xFFC9_B3E0, 0xFFE0_7AA0, 0xFFC9_8A6B, 0xFF2A_1A22))
        XCTAssertGreaterThanOrEqual(hueOf(palette.surface), 0, "surface should carry colour")
        XCTAssertLessThan(hueDistance(hueOf(palette.surface), 270), 40)
        assertReadable(palette)
    }

    func testBlackAndWhiteArtworkGivesANeutralSurface() {
        let palette = LyricsPalette.fromPixels(artwork(0xFF11_1111, 0xFF77_7777, 0xFFDD_DDDD))
        XCTAssertEqual(hueOf(palette.surface), -1)
        assertReadable(palette)
    }

    func testGenuinelyLightArtworkGetsDarkText() {
        let palette = LyricsPalette.fromPixels(artwork(0xFFFF_FFFF, 0xFFF2_F2F0, 0xFFE6_E6E6))
        XCTAssertGreaterThan(relativeLuminance(palette.surface), 0.5)
        XCTAssertLessThan(relativeLuminance(palette.content), 0.1)
        assertReadable(palette)
    }

    func testEveryHueAndLightnessStaysReadable() {
        for hue in stride(from: 0, to: 360, by: 15) {
            for lightness: Float in [0.15, 0.5, 0.85] {
                assertReadable(LyricsPalette.fromPixels(artwork(hslToArgb(Float(hue), 0.8, lightness))))
            }
        }
    }

    func testMissingOrTransparentArtworkUsesTheFallback() {
        XCTAssertEqual(LyricsPalette.fromPixels([UInt32](repeating: 0, count: 16)), LyricsPalette.fallback)
        assertReadable(LyricsPalette.fallback)
    }

    func testTheSameArtworkAlwaysGivesTheSamePalette() {
        let pixels = artwork(0xFF8E_44AD, 0xFF1A_BC9C)
        XCTAssertEqual(LyricsPalette.fromPixels(pixels), LyricsPalette.fromPixels(pixels))
    }

    func testHslRoundTrips() {
        for argb: UInt32 in [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF] {
            let hsl = hslOf(argb)
            XCTAssertEqual(hslToArgb(hsl.h, hsl.s, hsl.l), argb)
        }
    }
}
