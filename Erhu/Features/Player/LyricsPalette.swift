import SwiftUI
import UIKit

/// Now Playing's lyrics colours, taken from the album artwork: a calm [surface] in the artwork's
/// own hue (muted, so text reads well), a [gradient] around it (a lighter tone, the
/// surface and a deeper tone in the same hue),
/// and text colours chosen for contrast against every stop of it — light text on dark surfaces,
/// dark text on genuinely light ones. ARGB values; a port of Android's LyricsPalette.
struct LyricsPalette: Equatable, Sendable {
    let surface: UInt32
    /// Top to bottom; [surface] in the middle.
    let gradient: [UInt32]
    /// Headings and the active line.
    let content: UInt32
    /// Inactive lines: secondary, still readable (at least 3:1).
    let secondary: UInt32
    /// A restrained accent in the artwork's hue (the timed word), at least 4.5:1.
    let accent: UInt32
    /// The card's diagonal gradient: a lighter tone of the hue, [surface], and a deeper tone in the
    /// artwork's second colour when it has one (otherwise the same hue). [content] reads on every stop.
    let cardGradient: [UInt32]
    /// A light (or, under dark text, deep) tint of the hue for a card's rim.
    let rim: UInt32

    /// No artwork (or still loading): neutral, so another hue never flashes over a real cover.
    static let fallback = from(hue: 210, saturation: 0, artworkLightness: 0.16)

    static let textContrast = 4.5

    /// Below this weighted saturation the artwork reads as black and white: a neutral surface.
    private static let neutralSaturation: Float = 0.08
    /// Above this average lightness (and neutral) the artwork is genuinely light: a light surface.
    private static let lightArtwork: Float = 0.8
    private static let hueBins = 24
    private static let neutralColourfulness = 0.05
    /// The second colour's band starts this many bins (15° each) from the first...
    private static let secondHueMinBins = 3
    /// ...and needs at least this share of the first colour's votes.
    private static let secondHueShare = 0.3
    private static let opaque: UInt32 = 128

    private static let cardUpperSaturation: Float = 0.95
    private static let cardLowerSaturation: Float = 0.8
    private static let cardLighter: Float = 0.08
    private static let cardDeeper: Float = 0.1
    private static let rimSaturationBoost: Float = 0.1
    private static let rimLight: Float = 0.74
    private static let rimDeep: Float = 0.38
    private static let upperSaturation: Float = 0.85
    private static let lowerSaturation: Float = 0.75
    private static let lighter: Float = 0.06
    private static let deeper: Float = 0.09
    private static let maxStop: Float = 0.94
    private static let minStop: Float = 0.07
    private static let half = 0.18
    private static let lightSurface: Float = 0.86
    private static let neutralSurface: Float = 0.16
    private static let neutralLift: Float = 0.08
    private static let darkSurface: Float = 0.2
    private static let darkLift: Float = 0.12
    private static let maxDarkSurface: Float = 0.32
    private static let saturationGain: Float = 1.6
    private static let minSurfaceSaturation: Float = 0.3
    private static let maxSurfaceSaturation: Float = 0.55
    private static let secondaryAlpha: Float = 0.66
    private static let secondaryContrast = 3.0
    private static let lightText: UInt32 = 0xFFF7_F3F2
    private static let darkText: UInt32 = 0xFF17_141A
    private static let stopStep: Float = 0.02
    private static let accentLightStart: Float = 0.74
    private static let accentDarkStart: Float = 0.32
    private static let accentStep: Float = 0.04
    private static let accentSteps = 6
    private static let accentSaturation: Float = 0.7
    private static let blendStep: Float = 0.05

    /// The palette of artwork with these [pixels] (ARGB, a small sample is plenty).
    static func fromPixels(_ pixels: [UInt32]) -> LyricsPalette {
        // The artwork's strongest colour: pixels vote for their hue with their colourfulness
        // (saturation that is visible, i.e. not near black or white); the winning hue band and its
        // neighbours set the hue. Averaging every hue instead lets competing colours cancel out
        // into grey. Lightness is the plain average.
        var votes = [Double](repeating: 0, count: hueBins)
        var xs = [Double](repeating: 0, count: hueBins)
        var ys = [Double](repeating: 0, count: hueBins)
        var colourfulness = 0.0
        var lightness = 0.0
        var counted = 0
        for pixel in pixels where pixel >> 24 >= opaque {
            let hsl = hslOf(pixel)
            let chroma = Double(hsl.s * (1 - abs(hsl.l * 2 - 1)))
            let bin = binOf(hsl.h)
            let angle = Double(hsl.h) * .pi / 180
            votes[bin] += chroma
            xs[bin] += cos(angle) * chroma
            ys[bin] += sin(angle) * chroma
            colourfulness += chroma
            lightness += Double(hsl.l)
            counted += 1
        }
        if counted == 0 { return fallback }
        var best = 0
        for bin in votes.indices where votes[bin] > votes[best] { best = bin }
        let band = [best - 1, best, best + 1].map { ($0 % hueBins + hueBins) % hueBins }
        let x = band.reduce(0.0) { $0 + xs[$1] }
        let y = band.reduce(0.0) { $0 + ys[$1] }
        let bandVotes = band.reduce(0.0) { $0 + votes[$1] }
        let hue = Float(degrees(atan2(y, x)))
        // A second colour: the strongest hue band well away from the first, if it carries real weight.
        var secondBin: Int?
        for bin in votes.indices where binDistance(bin, best) >= secondHueMinBins {
            if secondBin == nil || votes[bin] > votes[secondBin!] { secondBin = bin }
        }
        let second = secondBin.flatMap { bin in
            votes[bin] >= votes[best] * secondHueShare ? Float(degrees(atan2(ys[bin], xs[bin]))) : nil
        }
        // Neutral when the artwork as a whole has hardly any colour; otherwise as colourful as its strongest colour.
        let overall = colourfulness / Double(counted)
        let saturation: Float = overall < neutralColourfulness ? 0 : Float(bandVotes / bandPixels(pixels, band))
        return from(hue: hue, saturation: saturation, artworkLightness: Float(lightness / Double(counted)), secondHue: second)
    }

    private static func degrees(_ radians: Double) -> Double {
        (radians * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func binOf(_ hue: Float) -> Int {
        Int(hue / (360 / Float(hueBins))).clamped(0, hueBins - 1)
    }

    private static func binDistance(_ a: Int, _ b: Int) -> Int {
        min(abs(a - b), hueBins - abs(a - b))
    }

    /// How many opaque pixels fall in the hue [band] (for the band's average colourfulness).
    private static func bandPixels(_ pixels: [UInt32], _ band: [Int]) -> Double {
        let n = pixels.filter { pixel in
            let hsl = hslOf(pixel)
            return pixel >> 24 >= opaque && hsl.s > 0 && band.contains(binOf(hsl.h))
        }.count
        return Double(max(n, 1))
    }

    static func from(hue: Float, saturation: Float, artworkLightness: Float, secondHue: Float? = nil) -> LyricsPalette {
        let neutral = saturation < neutralSaturation
        let surfaceSaturation = neutral ? 0 : (saturation * saturationGain).clamped(minSurfaceSaturation, maxSurfaceSaturation)
        let surfaceLightness: Float
        if neutral && artworkLightness > lightArtwork {
            surfaceLightness = lightSurface
        } else if neutral {
            surfaceLightness = neutralSurface + neutralLift * artworkLightness
        } else {
            surfaceLightness = min(darkSurface + darkLift * artworkLightness, maxDarkSurface)
        }
        let content = readableOn(hslToArgb(hue, surfaceSaturation, surfaceLightness))
        let isLightText = content == lightText
        // Text must read on every part of the gradient: a stop too close to the text steps away from it. No hue is invented to create depth.
        let surface = readableStop(hue, surfaceSaturation, surfaceLightness, content, isLightText)
        let top = readableStop(hue, surfaceSaturation * upperSaturation,
                               min(surfaceLightness + lighter, maxStop), content, isLightText)
        let bottom = readableStop(hue, surfaceSaturation * lowerSaturation,
                                  max(surfaceLightness - deeper, minStop), content, isLightText)
        let gradient = [top, surface, bottom]
        let cardTop = readableStop(hue, surfaceSaturation * cardUpperSaturation,
                                   min(surfaceLightness + cardLighter, maxStop), content, isLightText)
        let cardBottom = readableStop(secondHue ?? hue, surfaceSaturation * cardLowerSaturation,
                                      max(surfaceLightness - cardDeeper, minStop), content, isLightText)
        let cardGradient = [cardTop, surface, cardBottom]
        // Secondary text and the accent read on the lyrics gradient and on the card gradient alike.
        var weakest = gradient[0]
        for stop in gradient + cardGradient where contrast(content, stop) < contrast(content, weakest) { weakest = stop }
        let dark = relativeLuminance(weakest) < half
        let secondary = blendUntil(content, weakest, alpha: secondaryAlpha, minimumContrast: secondaryContrast)
        let accent = neutral ? content : accentOn(weakest, hue: hue, dark: dark)
        let rim = hslToArgb(hue, min(surfaceSaturation + rimSaturationBoost, maxSurfaceSaturation), isLightText ? rimLight : rimDeep)
        return LyricsPalette(surface: surface, gradient: gradient, content: content, secondary: secondary,
                             accent: accent, cardGradient: cardGradient, rim: rim)
    }

    /// Light or dark text, whichever contrasts more with [surface].
    static func readableOn(_ surface: UInt32) -> UInt32 {
        contrast(lightText, surface) >= contrast(darkText, surface) ? lightText : darkText
    }

    /// The colour (h, s, l), darkened under light text / lightened under dark text until [content] reads on it.
    private static func readableStop(_ hue: Float, _ saturation: Float, _ lightness: Float, _ content: UInt32, _ isLightText: Bool) -> UInt32 {
        var l = lightness
        var stop = hslToArgb(hue, saturation, l)
        while contrast(content, stop) < textContrast && (minStop...maxStop).contains(l) {
            l += isLightText ? -stopStep : stopStep
            stop = hslToArgb(hue, saturation, l.clamped(0, 1))
        }
        return stop
    }

    /// A vivid tint of [hue] that still reads at [textContrast] on [surface]; the plain text colour if none does.
    private static func accentOn(_ surface: UInt32, hue: Float, dark: Bool) -> UInt32 {
        var l = dark ? accentLightStart : accentDarkStart
        for _ in 0..<accentSteps {
            let candidate = hslToArgb(hue, accentSaturation, l)
            if contrast(candidate, surface) >= textContrast { return candidate }
            l += dark ? accentStep : -accentStep
        }
        return readableOn(surface)
    }

    /// [color] faded towards [surface] by [alpha], stepped back towards [color] until it reaches [minimumContrast].
    private static func blendUntil(_ color: UInt32, _ surface: UInt32, alpha: Float, minimumContrast: Double) -> UInt32 {
        var a = alpha
        while a < 1 {
            let blended = blend(color, surface, a)
            if contrast(blended, surface) >= minimumContrast { return blended }
            a += blendStep
        }
        return color
    }

    private static func blend(_ top: UInt32, _ bottom: UInt32, _ alpha: Float) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            let value = Float((top >> shift) & 0xFF) * alpha + Float((bottom >> shift) & 0xFF) * (1 - alpha)
            return (UInt32(Int(value)) & 0xFF) << shift
        }
        return 0xFF00_0000 | mix(16) | mix(8) | mix(0)
    }
}

/// Hue (degrees), saturation and lightness (0..1) of an ARGB colour.
func hslOf(_ argb: UInt32) -> (h: Float, s: Float, l: Float) {
    let r = Float((argb >> 16) & 0xFF) / 255
    let g = Float((argb >> 8) & 0xFF) / 255
    let b = Float(argb & 0xFF) / 255
    let hi = max(r, g, b)
    let lo = min(r, g, b)
    let l = (hi + lo) / 2
    if hi == lo { return (0, 0, l) }
    let d = hi - lo
    let s = l > 0.5 ? d / (2 - hi - lo) : d / (hi + lo)
    let sextant: Float
    if hi == r {
        sextant = (g - b) / d + (g < b ? 6 : 0)
    } else if hi == g {
        sextant = (b - r) / d + 2
    } else {
        sextant = (r - g) / d + 4
    }
    return (sextant * 60, s, l)
}

func hslToArgb(_ hue: Float, _ saturation: Float, _ lightness: Float) -> UInt32 {
    let c = (1 - abs(2 * lightness - 1)) * saturation
    let hp = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let rgb: (Float, Float, Float)
    switch hp {
    case ..<1: rgb = (c, x, 0)
    case ..<2: rgb = (x, c, 0)
    case ..<3: rgb = (0, c, x)
    case ..<4: rgb = (0, x, c)
    case ..<5: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    let m = lightness - c / 2
    func byte(_ v: Float) -> UInt32 { UInt32(Double((v + m).clamped(0, 1)) * 255) }
    return 0xFF00_0000 | byte(rgb.0) << 16 | byte(rgb.1) << 8 | byte(rgb.2)
}

/// The lyrics colours for drawing.
struct LyricsColors: Equatable {
    let surface: Color
    let gradient: [Color]
    let content: Color
    let secondary: Color
    let accent: Color
    /// A card's diagonal body and its rim (see [LyricsPalette.cardGradient]).
    let cardGradient: [Color]
    let rim: Color

    init(_ palette: LyricsPalette) {
        cardGradient = palette.cardGradient.map { Color(argb: $0) }
        rim = Color(argb: palette.rim)
        surface = Color(argb: palette.surface)
        gradient = palette.gradient.map { Color(argb: $0) }
        content = Color(argb: palette.content)
        secondary = Color(argb: palette.secondary)
        accent = Color(argb: palette.accent)
    }
}

/// Derived palettes by artwork file: each artwork is sampled once, small and off the main thread.
actor LyricsPaletteCache {
    static let shared = LyricsPaletteCache()
    private static let samplePixels = 32
    private nonisolated let memory = PaletteMemory()

    /// Safe to read while constructing a view: no actor hop, file IO, decoding or placeholder frame.
    nonisolated func cachedPalette(for url: URL) -> LyricsPalette? {
        memory.get(url, revision: ArtworkLoader.shared.revision(for: url.path))
    }

    func palette(for url: URL) async -> LyricsPalette {
        let revision = ArtworkLoader.shared.revision(for: url.path)
        if let cached = memory.get(url, revision: revision) { return cached }
        let image = await ArtworkLoader.shared.image(for: url, maxPixels: Self.samplePixels * 4)
        let palette = image?.cgImage.flatMap(Self.sample).map(LyricsPalette.fromPixels) ?? .fallback
        memory.put(palette, url: url, revision: revision)
        return palette
    }

    /// ARGB pixels of [image] scaled to 32 × 32.
    private static func sample(_ image: CGImage) -> [UInt32]? {
        let size = samplePixels
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        var pixels: [UInt32] = []
        pixels.reserveCapacity(size * size)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = UInt32(rgba[i + 3]) << 24
            let red = UInt32(rgba[i]) << 16
            let green = UInt32(rgba[i + 1]) << 8
            pixels.append(alpha | red | green | UInt32(rgba[i + 2]))
        }
        return pixels
    }
}

private struct LyricsColorsKey: EnvironmentKey {
    static let defaultValue: LyricsColors? = nil
}

extension EnvironmentValues {
    /// The playing song's lyrics colours, when lyrics sit on an artwork-coloured surface.
    var lyricsColors: LyricsColors? {
        get { self[LyricsColorsKey.self] }
        set { self[LyricsColorsKey.self] = newValue }
    }
}

/// NSCache is thread-safe; immutable entries can be read from views and written by the cache actor.
private final class PaletteMemory: @unchecked Sendable {
    private final class Entry: NSObject {
        let value: LyricsPalette
        init(_ value: LyricsPalette) { self.value = value }
    }
    private let cache = NSCache<NSString, Entry>()
    init() { cache.countLimit = 64 }
    private func key(_ url: URL, _ revision: Int) -> NSString { "\(url.path)|\(revision)" as NSString }
    func get(_ url: URL, revision: Int) -> LyricsPalette? { cache.object(forKey: key(url, revision))?.value }
    func put(_ value: LyricsPalette, url: URL, revision: Int) { cache.setObject(Entry(value), forKey: key(url, revision)) }
}

/// A view's async result belongs to one file revision. Never reuse its colour for a new song.
struct ArtworkPaletteState {
    private var url: URL?
    private var revision: Int = -1
    private var value: LyricsPalette?

    func palette(for url: URL?) -> LyricsPalette {
        guard let url else { return .fallback }
        if self.url == url, revision == ArtworkLoader.shared.revision(for: url.path), let value { return value }
        return LyricsPaletteCache.shared.cachedPalette(for: url) ?? .fallback
    }
    mutating func set(_ value: LyricsPalette, for url: URL, revision: Int) {
        self.url = url
        self.revision = revision
        self.value = value
    }
}
