import SwiftUI
import UIKit

/// The colours picked from a cover (Android's DominantColorExtractor): the dominant colour and a
/// vibrant accent, as 0xAARRGGBB.
struct ArtworkColors: Equatable, Sendable {
    let primary: UInt32
    let accent: UInt32

    static let fallback = ArtworkColors(primary: 0xFF1E_2228, accent: 0xFFE5_3935)
}

enum DominantColorExtractor {
    static let sampleSize = 64

    /// The colours of [image], read from a 64 × 64 copy.
    static func colors(of image: UIImage?) -> ArtworkColors {
        guard let pixels = image.flatMap(samplePixels) else { return .fallback }
        return colors(pixels: pixels)
    }

    /// [pixels]: 0xAARRGGBB, row by row.
    static func colors(pixels: [UInt32]) -> ArtworkColors {
        guard !pixels.isEmpty else { return .fallback }
        let primary = dominant(pixels[...]) ?? average(pixels) ?? ArtworkColors.fallback.primary
        let accent = vibrantAccent(pixels, main: primary) ?? primary
        return ArtworkColors(primary: primary, accent: accent)
    }

    private static func samplePixels(_ image: UIImage) -> [UInt32]? {
        guard let cgImage = image.cgImage else { return nil }
        let side = sampleSize
        var data = [UInt32](repeating: 0, count: side * side)
        let made = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return made ? data : nil
    }

    private static func channels(_ pixel: UInt32) -> (a: Int, r: Int, g: Int, b: Int) {
        (Int(pixel >> 24 & 0xFF), Int(pixel >> 16 & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel & 0xFF))
    }

    private static func argb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0xFF00_0000 | UInt32(r.clamped(0, 255)) << 16 | UInt32(g.clamped(0, 255)) << 8 | UInt32(b.clamped(0, 255))
    }

    private static func average(_ pixels: [UInt32]) -> UInt32? {
        var sum = (r: 0, g: 0, b: 0)
        var count = 0
        for pixel in pixels {
            let c = channels(pixel)
            if c.a < 128 { continue }
            sum.r += c.r
            sum.g += c.g
            sum.b += c.b
            count += 1
        }
        return count == 0 ? nil : argb(sum.r / count, sum.g / count, sum.b / count)
    }

    /// The heaviest 16 × 16 × 16 colour bin, chromatic pixels weighted by saturation.
    private static func dominant(_ pixels: ArraySlice<UInt32>) -> UInt32? {
        var weights: [Int: Float] = [:]
        var sums: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for pixel in pixels {
            let c = channels(pixel)
            if c.a < 128 { continue }
            let hsl = rgbToHsl(c.r, c.g, c.b)
            if hsl.l < 0.05 || hsl.l > 0.82 || hsl.s < 0.08 { continue }
            let key = (c.r >> 4) << 8 | (c.g >> 4) << 4 | c.b >> 4
            weights[key, default: 0] += 1 + hsl.s * 2
            let old = sums[key] ?? (0, 0, 0, 0)
            sums[key] = (old.r + c.r, old.g + c.g, old.b + c.b, old.n + 1)
        }
        if weights.isEmpty { return unweightedDominant(pixels) }
        guard let best = weights.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key,
              let sum = sums[best], sum.n > 0 else { return nil }
        return argb(sum.r / sum.n, sum.g / sum.n, sum.b / sum.n)
    }

    private static func unweightedDominant(_ pixels: ArraySlice<UInt32>) -> UInt32? {
        var sums: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for pixel in pixels {
            let c = channels(pixel)
            if c.a < 128 { continue }
            let key = (c.r >> 4) << 8 | (c.g >> 4) << 4 | c.b >> 4
            let old = sums[key] ?? (0, 0, 0, 0)
            sums[key] = (old.r + c.r, old.g + c.g, old.b + c.b, old.n + 1)
        }
        guard let best = sums.max(by: { $0.value.n < $1.value.n || ($0.value.n == $1.value.n && $0.key > $1.key) })?.value,
              best.n > 0 else { return nil }
        return argb(best.r / best.n, best.g / best.n, best.b / best.n)
    }

    private static func vibrantAccent(_ pixels: [UInt32], main: UInt32) -> UInt32? {
        let m = channels(main)
        let mainHsl = rgbToHsl(m.r, m.g, m.b)
        return scoreAccent(pixels, mainH: mainHsl.h, mainL: mainHsl.l, minS: 0.40, minL: 0.25, maxL: 0.80, relaxed: false)
            ?? scoreAccent(pixels, mainH: mainHsl.h, mainL: mainHsl.l, minS: 0.20, minL: 0.15, maxL: 0.88, relaxed: true)
    }

    /// The best 10° hue cluster: saturated, mid-light, populous enough to be more than noise, and
    /// (on a dark cover) a hue away from the dominant one.
    private static func scoreAccent(_ pixels: [UInt32], mainH: Float, mainL: Float, minS: Float, minL: Float, maxL: Float,
                                    relaxed: Bool) -> UInt32? {
        var buckets: [Int: [UInt32]] = [:]
        var total = 0
        for pixel in pixels {
            let c = channels(pixel)
            if c.a < 128 { continue }
            let hsl = rgbToHsl(c.r, c.g, c.b)
            if hsl.s < minS || hsl.l < minL || hsl.l > maxL { continue }
            total += 1
            buckets[Int(hsl.h / 10).clamped(0, 35), default: []].append(pixel)
        }
        guard total > 0 else { return nil }
        let dark = mainL < 0.22
        let fraction: Float = dark ? (relaxed ? 0.0035 : 0.0015) : (relaxed ? 0.0100 : 0.0200)
        let minCluster = max(Int((Float(total) * fraction).rounded()), 3)
        var bestScore: Float = -1
        var best: UInt32?
        for bin in buckets.keys.sorted() {
            guard let cluster = buckets[bin], cluster.count >= minCluster else { continue }
            var sum = (r: 0, g: 0, b: 0)
            for pixel in cluster {
                let c = channels(pixel)
                sum.r += c.r
                sum.g += c.g
                sum.b += c.b
            }
            let r = sum.r / cluster.count, g = sum.g / cluster.count, b = sum.b / cluster.count
            let hsl = rgbToHsl(r, g, b)
            let hueDiff = (180 - abs(abs(hsl.h - mainH) - 180)) / 180
            let lightness = 1 - min(max(abs(hsl.l - 0.55) / 0.45, 0), 1)
            let population = min(max(Float(cluster.count) / Float(total), 0), 0.5) * 2
            let score: Float = dark
                ? hsl.s * 2.2 + hueDiff * 2.8 + lightness + population * 0.5
                : hsl.s * 1.5 + population * 2.5 + lightness * 1.2 + hueDiff * 0.8
            if score > bestScore {
                bestScore = score
                best = argb(r, g, b)
            }
        }
        return best
    }

    /// The dark theme Android builds from the colours ("Dominant Color"): background and surfaces
    /// in the cover's hue, the accent brightened enough to read.
    static func palette(_ colors: ArtworkColors) -> AppPalette {
        let m = channels(colors.primary)
        let main = rgbToHsl(m.r, m.g, m.b)
        let background: UInt32, surface: UInt32, container: UInt32
        if main.s > 0.08 {
            if (20...50).contains(main.h) {
                let s = min(max(main.s * 0.90, 0.22), 0.50)
                background = hslToArgb(main.h, s, 0.09)
                surface = hslToArgb(main.h, s * 0.85, 0.13)
                container = hslToArgb(main.h, s * 0.75, 0.19)
            } else {
                let s = min(max(main.s * 0.85, 0.25), 0.65)
                background = hslToArgb(main.h, s, 0.07)
                surface = hslToArgb(main.h, s * 0.75, 0.11)
                container = hslToArgb(main.h, s * 0.65, 0.17)
            }
        } else {
            background = 0xFF0F_1014
            surface = 0xFF1B_1D22
            container = 0xFF28_2B32
        }
        let a = channels(colors.accent)
        let accentHsl = rgbToHsl(a.r, a.g, a.b)
        let accent = hslToArgb(accentHsl.h, max(accentHsl.s, 0.65), min(max(accentHsl.l, 0.50), 0.68))
        let f = channels(accent)
        let luminance = 0.299 * Float(f.r) / 255 + 0.587 * Float(f.g) / 255 + 0.114 * Float(f.b) / 255
        return AppPalette(
            primary: Color(argb: accent), onPrimary: Color(argb: luminance > 0.60 ? 0xFF0A_0C0E : 0xFFFF_FFFF),
            background: Color(argb: background), surface: Color(argb: surface), surfaceVariant: Color(argb: container),
            onSurface: Color(argb: 0xFFF8_F9FA), onSurfaceVariant: Color(argb: 0xFFA0_AEC0), outline: Color(argb: container)
        )
    }

    static func rgbToHsl(_ r: Int, _ g: Int, _ b: Int) -> (h: Float, s: Float, l: Float) {
        let rf = Float(r) / 255, gf = Float(g) / 255, bf = Float(b) / 255
        let maxC = max(rf, gf, bf), minC = min(rf, gf, bf)
        let delta = maxC - minC
        let l = (maxC + minC) / 2
        let s: Float = delta == 0 ? 0 : (l <= 0.5 ? delta / (maxC + minC) : delta / (2 - maxC - minC))
        var h: Float
        if delta == 0 {
            h = 0
        } else if maxC == rf {
            h = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == gf {
            h = (bf - rf) / delta + 2
        } else {
            h = (rf - gf) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    static func hslToArgb(_ h: Float, _ s: Float, _ l: Float) -> UInt32 {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let sat = min(max(s, 0), 1), light = min(max(l, 0), 1)
        let c = (1 - abs(2 * light - 1)) * sat
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = light - c / 2
        let rgb: (Float, Float, Float)
        switch hue {
        case ..<60: rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return argb(Int(((rgb.0 + m) * 255).rounded()), Int(((rgb.1 + m) * 255).rounded()), Int(((rgb.2 + m) * 255).rounded()))
    }
}
