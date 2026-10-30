import Foundation

/// Kotlin's `Random(seed: Long)` (XorWow), so a mix gets exactly the cover it has on Android.
struct KotlinRandom {
    private var x: Int32, y: Int32, z: Int32, w: Int32, v: Int32, addend: Int32

    init(seed: Int64) {
        let seed1 = Int32(truncatingIfNeeded: seed)
        let seed2 = Int32(truncatingIfNeeded: seed >> 32)
        x = seed1
        y = seed2
        z = 0
        w = 0
        v = ~seed1
        addend = (seed1 << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
        for _ in 0..<64 { _ = nextInt() }
    }

    mutating func nextInt() -> Int32 {
        var t = x
        t = t ^ Int32(bitPattern: UInt32(bitPattern: t) >> 2)
        x = y
        y = z
        z = w
        let v0 = v
        w = v0
        t = (t ^ (t << 1)) ^ v0 ^ (v0 << 4)
        v = t
        addend = addend &+ 362_437
        return t &+ addend
    }

    mutating func nextBits(_ bitCount: Int) -> Int32 {
        let value = UInt32(bitPattern: nextInt())
        return bitCount == 0 ? 0 : Int32(bitPattern: value >> UInt32(32 - bitCount))
    }

    /// 0 ..< until.
    mutating func nextInt(_ until: Int) -> Int { nextInt(0, until) }

    /// from ..< until.
    mutating func nextInt(_ from: Int, _ until: Int) -> Int {
        let n = Int32(until - from)
        precondition(n > 0, "empty range")
        let result: Int32
        if n & -n == n {
            result = nextBits(31 - n.leadingZeroBitCount)
        } else {
            var value: Int32
            var bits: Int32
            repeat {
                bits = Int32(bitPattern: UInt32(bitPattern: nextInt()) >> 1)
                value = bits % n
            } while bits &- value &+ (n &- 1) < 0
            result = value
        }
        return from + Int(result)
    }

    mutating func nextFloat() -> Float { Float(nextBits(24)) / Float(1 << 24) }
}

/// Colours as ARGB. [background] runs top to bottom; [accents] are drawn over it.
struct ArtPalette: Hashable, Sendable {
    let name: String
    let background: [UInt32]
    let accents: [UInt32]
    let dark: Bool
}

/// One drawing primitive, in unit coordinates of the cover (positions in 0..1 of the width and
/// height, sizes in 0..1 of the shorter side).
enum ArtLayer: Equatable, Sendable {
    case backdrop(colors: [UInt32], angleDeg: Float)
    case glow(x: Float, y: Float, radius: Float, color: UInt32, alpha: Float)
    case blob(x: Float, y: Float, radius: Float, wobble: [Float], rotation: Float, color: UInt32, alpha: Float)
    case ribbon(points: [Float], width: Float, color: UInt32, alpha: Float)
    case ring(x: Float, y: Float, radius: Float, wobble: [Float], stroke: Float, color: UInt32, alpha: Float)
    case disc(x: Float, y: Float, radius: Float, color: UInt32, alpha: Float)
    case sector(x: Float, y: Float, radius: Float, startDeg: Float, sweepDeg: Float, color: UInt32, alpha: Float)
    case shard(points: [Float], color: UInt32, alpha: Float)
    case block(left: Float, top: Float, right: Float, bottom: Float, corner: Float, color: UInt32, alpha: Float)
}

/// Original cover art for the smart mixes, generated from a seed: no album art, photos or network.
/// The seed comes from the mix's identity, so a mix always looks the same.
struct MixArt: Equatable, Sendable {
    enum Composition: CaseIterable, Sendable { case ribbons, blobs, contours, geometric, particles, burst }

    /// Where the art is drawn: [aspect] = width / height; the left [clear] share of the width is
    /// kept for text (only the backdrop and soft light reach into it).
    struct Frame: Equatable {
        let aspect: Float
        let clear: Float
        static let cover = Frame(aspect: 1, clear: 0)
    }

    /// A mix's art direction: the palettes and compositions its cover may use.
    struct Direction {
        let palettes: [ArtPalette]
        let compositions: [Composition]
    }

    /// The share of a banner's width kept clear for its text.
    static let bannerTextSide: Float = 0.46

    let palette: ArtPalette
    let composition: Composition
    let layers: [ArtLayer]

    static func generate(_ kind: MixKind) -> MixArt { generate(seed: seedOf(kind.key), direction: direction(kind)) }

    /// The same art composed for a wide banner with text on its left.
    static func banner(_ kind: MixKind, aspect: Float) -> MixArt {
        generate(seed: seedOf(kind.key), direction: direction(kind), frame: Frame(aspect: aspect, clear: bannerTextSide))
    }

    static func generate(seed: Int64, direction: Direction, frame: Frame = .cover) -> MixArt {
        var random = KotlinRandom(seed: seed)
        let palette = direction.palettes[random.nextInt(direction.palettes.count)]
        let composition = direction.compositions[random.nextInt(direction.compositions.count)]
        let composer = ArtComposer(random: random, palette: palette, frame: frame)
        return MixArt(palette: palette, composition: composition, layers: composer.compose(composition))
    }

    /// A stable 64-bit seed for a mix key (FNV-1a over UTF-16).
    static func seedOf(_ key: String) -> Int64 { IdentityHash.of(key) }

    static func direction(_ kind: MixKind) -> Direction {
        typealias P = Palettes
        switch kind {
        case .highEnergy: return Direction(palettes: [P.sunrise, P.citrus, P.ember, P.bubblegum], compositions: [.burst, .geometric])
        case .lateNight: return Direction(palettes: [P.midnight, P.violetDusk], compositions: [.particles, .contours])
        case .chill: return Direction(palettes: [P.mint, P.lagoon, P.sky, P.peach], compositions: [.blobs, .ribbons])
        case .deepCuts: return Direction(palettes: [P.ember, P.meadow, P.violetDusk, P.lagoon], compositions: [.contours, .particles, .geometric])
        case .rotation: return Direction(palettes: [P.citrus, P.sunrise, P.bubblegum], compositions: [.geometric, .burst])
        case .yourSound: return Direction(palettes: [P.sky, P.violetDusk, P.lagoon], compositions: [.ribbons, .contours])
        case .forgotten: return Direction(palettes: [P.peach, P.burgundy, P.sky], compositions: [.blobs, .particles])
        case .aLittleDifferent: return Direction(palettes: [P.meadow, P.bubblegum, P.mint], compositions: [.geometric, .blobs])
        case .spotlight: return Direction(palettes: [P.soul, P.burgundy], compositions: [.contours])
        case .throwbacks: return Direction(palettes: [P.vintage], compositions: [.contours])
        case .quickHits: return Direction(palettes: [P.citrus, P.ember], compositions: [.geometric, .burst])
        case .longListens: return Direction(palettes: [P.nightDrive, P.slate], compositions: [.ribbons])
        case .yetToHear: return Direction(palettes: [P.midnight, P.nightDrive], compositions: [.particles])
        case .favourites: return Direction(palettes: [P.bubblegum, P.sunrise], compositions: [.blobs])
        case .fresh: return Direction(palettes: [P.meadow, P.lagoon], compositions: [.ribbons])
        }
    }
}

/// The palettes: bright and fresh as well as deep and atmospheric.
enum Palettes {
    static let sunrise = ArtPalette(name: "Sunrise", background: [0xFFFFD23F, 0xFFFF9F1C],
                                    accents: [0xFFFF6F59, 0xFFFFF3D6, 0xFFEF476F, 0xFFFFB627], dark: false)
    static let citrus = ArtPalette(name: "Citrus", background: [0xFFFFF1C1, 0xFFFFC94D],
                                   accents: [0xFFFB8500, 0xFFFF5D73, 0xFF219EBC, 0xFF023047], dark: false)
    static let mint = ArtPalette(name: "Mint", background: [0xFFE8FFF6, 0xFFB8F2E6],
                                 accents: [0xFF2EC4B6, 0xFF7BE0AD, 0xFF0F8B8D, 0xFFFFE5A5], dark: false)
    static let lagoon = ArtPalette(name: "Lagoon", background: [0xFF90E0EF, 0xFF0096C7],
                                   accents: [0xFFCAF0F8, 0xFF48CAE4, 0xFF023E8A, 0xFFFFD6A5], dark: false)
    static let meadow = ArtPalette(name: "Meadow", background: [0xFFFCEFB4, 0xFFA7E8BD],
                                   accents: [0xFF4CAF50, 0xFF2D6A4F, 0xFFF77F00, 0xFF5FA8D3], dark: false)
    static let sky = ArtPalette(name: "Sky", background: [0xFFD7E9FF, 0xFFB8B8FF],
                                accents: [0xFF3A86FF, 0xFF6A4C93, 0xFFFF8FAB, 0xFFFFFFFF], dark: false)
    static let bubblegum = ArtPalette(name: "Bubblegum", background: [0xFFFFF1E6, 0xFFFFC8DD],
                                      accents: [0xFFFF5D8F, 0xFF7B2CBF, 0xFF2EC4B6, 0xFFFFB703], dark: false)
    static let peach = ArtPalette(name: "Peach", background: [0xFFFFE5D9, 0xFFFFCAD4],
                                  accents: [0xFFF4978E, 0xFFF8AD9D, 0xFF9D8189, 0xFFFFF8F0], dark: false)
    static let midnight = ArtPalette(name: "Midnight", background: [0xFF0B132B, 0xFF1C2541],
                                     accents: [0xFF5BC0BE, 0xFF3A86FF, 0xFFFFD166, 0xFFE0FBFC], dark: true)
    static let violetDusk = ArtPalette(name: "Violet dusk", background: [0xFF240046, 0xFF5A189A],
                                       accents: [0xFF9D4EDD, 0xFFE0AAFF, 0xFFFF8FAB, 0xFF4CC9F0], dark: true)
    static let burgundy = ArtPalette(name: "Burgundy", background: [0xFF2B0A12, 0xFF6A0F2B],
                                     accents: [0xFFC0365A, 0xFFF7B267, 0xFFFFE8D6, 0xFFE36588], dark: true)
    static let ember = ArtPalette(name: "Ember", background: [0xFF1F1F24, 0xFF34343E],
                                  accents: [0xFFFF7A45, 0xFFFFD166, 0xFF06D6A0, 0xFFF5F5F5], dark: true)
    static let nightDrive = ArtPalette(name: "Night drive", background: [0xFF101A3A, 0xFF2E2350],
                                       accents: [0xFFFFB86B, 0xFF6C7BD9, 0xFFE07A5F, 0xFFF2E9DC], dark: true)
    static let soul = ArtPalette(name: "Soul", background: [0xFF2A1A12, 0xFF4A2E1E],
                                 accents: [0xFFD9A441, 0xFFF3D9A4, 0xFFB5523B, 0xFF8C6A4F], dark: true)
    static let vintage = ArtPalette(name: "Vintage", background: [0xFFF4E7CF, 0xFFE9CFA3],
                                    accents: [0xFFD9733B, 0xFF2F7F7A, 0xFF8E3B2E, 0xFFF1B24A], dark: false)
    static let slate = ArtPalette(name: "Slate", background: [0xFF1E2A33, 0xFF34495A],
                                  accents: [0xFF8FB3C9, 0xFFC9D6DF, 0xFF5D7A8C, 0xFFE8C07D], dark: true)

    static let all = [sunrise, citrus, mint, lagoon, meadow, sky, bubblegum, peach, midnight, violetDusk, burgundy, ember,
                      nightDrive, soul, vintage, slate]
}

/// Lays out one composition with a seeded random source. The order of random draws is the
/// Android composer's, call for call.
private final class ArtComposer {
    /// Shapes may reach this far into the text side (a share of it), so the two sides meet softly.
    private static let textEdge: Float = 0.85
    /// 1 / (1 / 3) is 2.9999998 in floats: the cover must still get its three columns.
    private static let columnEpsilon: Float = 1e-3
    /// Start angle (in quarter turns) of the quarter disc anchored at each cell corner.
    private static let quarterStarts: [Float] = [0, 1, 3, 2]
    private static let pi = Float.pi

    var random: KotlinRandom
    let palette: ArtPalette
    let frame: MixArt.Frame
    private var layers: [ArtLayer] = []

    init(random: KotlinRandom, palette: ArtPalette, frame: MixArt.Frame) {
        self.random = random
        self.palette = palette
        self.frame = frame
    }

    func compose(_ composition: MixArt.Composition) -> [ArtLayer] {
        let angle = range(20, 160)
        layers.append(.backdrop(colors: palette.background, angleDeg: angle))
        switch composition {
        case .ribbons: ribbons()
        case .blobs: blobs()
        case .contours: contours()
        case .geometric: geometric()
        case .particles: particles()
        case .burst: burst()
        }
        return layers
    }

    /// A horizontal position for a focal element: [from]..[to] of the width beside the text side.
    private func fx(_ from: Float, _ to: Float) -> Float { frame.clear + range(from, to) * (1 - frame.clear) }

    /// A horizontal length in shape units as a share of the width.
    private func wide(_ length: Float) -> Float { length / frame.aspect }

    /// How far (in shape units) a shape at [x] may reach to the left before entering the text side.
    private func leftReach(_ x: Float) -> Float {
        frame.clear <= 0 ? .greatestFiniteMagnitude : (x - frame.clear * Self.textEdge) * frame.aspect
    }

    private func accent(_ i: Int) -> UInt32 {
        let n = palette.accents.count
        return palette.accents[((i % n) + n) % n]
    }

    private func anyAccent() -> UInt32 { palette.accents[random.nextInt(palette.accents.count)] }

    private func range(_ from: Float, _ to: Float) -> Float { from + random.nextFloat() * (to - from) }

    private func wobble(_ points: Int, _ amount: Float) -> [Float] {
        var out: [Float] = []
        for _ in 0..<points { out.append(1 + range(-amount, amount)) }
        return out
    }

    private func glow(_ alpha: Float = 0.55) {
        let x = fx(0.15, 0.85)
        let y = range(0.1, 0.6)
        let radius = range(0.45, 0.8)
        let color = anyAccent()
        layers.append(.glow(x: x, y: y, radius: radius, color: color, alpha: alpha))
    }

    private func disc(x: Float, y: Float, radius: Float, color: UInt32, alpha: Float) {
        layers.append(.disc(x: x, y: y, radius: radius, color: color, alpha: alpha))
    }

    /// Flowing waves across the cover, like sound.
    private func ribbons() {
        glow(0.35)
        let count = random.nextInt(3, 6)
        let baseY = range(0.25, 0.4)
        let spacing = range(0.08, 0.14)
        let frequency = range(1.2, 2.4)
        // On a banner the waves rise out of the text side's edge and run off to the right.
        let start: Float = frame.clear > 0 ? frame.clear * Self.textEdge : -0.1
        for i in 0..<count {
            let amplitude = range(0.05, 0.14)
            let phase = range(0, 2 * Self.pi)
            let y0 = baseY + Float(i) * spacing
            var points: [Float] = []
            for step in 0...16 {
                let x = start + Float(step) * (1.1 - start) / 16
                points.append(x)
                points.append(y0 + amplitude * sin(phase + x * frequency * 2 * Self.pi))
            }
            let width = range(0.035, 0.11)
            let alpha = range(0.75, 0.95)
            layers.append(.ribbon(points: points, width: width, color: accent(i), alpha: alpha))
        }
        dust(random.nextInt(6, 12), 0.006, 0.014)
    }

    /// Large overlapping organic forms.
    private func blobs() {
        glow(0.4)
        let count = random.nextInt(3, 5)
        for i in 0..<count {
            let x = fx(0.15, 0.85)
            let y = range(0.15, 0.85)
            // A banner's forms stay out of its text side; a cover's are unchanged.
            let radius = min(range(0.22, 0.42), leftReach(x))
            let shape = wobble(8, 0.18)
            let rotation = range(0, 360)
            let alpha = range(0.7, 0.95)
            layers.append(.blob(x: x, y: y, radius: radius, wobble: shape, rotation: rotation, color: accent(i), alpha: alpha))
        }
        for _ in 0..<random.nextInt(2, 5) {
            let x = fx(0.1, 0.9)
            let y = range(0.1, 0.9)
            let radius = range(0.02, 0.06)
            disc(x: x, y: y, radius: radius, color: anyAccent(), alpha: 0.9)
        }
    }

    /// Concentric contour lines around an off-centre point.
    private func contours() {
        glow(0.45)
        let x = fx(0.25, 0.75)
        let y = range(0.25, 0.75)
        disc(x: x, y: y, radius: range(0.05, 0.1), color: accent(0), alpha: 0.95)
        let count = random.nextInt(7, 12)
        let step = range(0.055, 0.08)
        let shape = wobble(7, 0.12)
        for i in 1...count {
            let drift = wobble(7, 0.04)
            // Rings stop where they would reach into the text side.
            if 0.06 + Float(i) * step > leftReach(x) { break }
            let stroke = range(0.006, 0.016)
            let alpha = min(max(1 - Float(i) / (Float(count) + 2), 0.3), 0.95)
            layers.append(.ring(x: x, y: y, radius: 0.06 + Float(i) * step, wobble: zip(shape, drift).map { $0 * $1 },
                                stroke: stroke, color: accent(i), alpha: alpha))
        }
    }

    /// A grid of bold circles, half and quarter discs and blocks.
    private func geometric() {
        let rows = 3
        let size: Float = 1 / Float(rows)
        let cellWidth = wide(size)
        let columns = max(Int((1 - frame.clear) / cellWidth + Self.columnEpsilon), 1)
        // A cover's grid starts exactly at 0; a banner's ends at the right edge.
        let left: Float = frame.clear <= 0 ? 0 : 1 - Float(columns) * cellWidth
        for row in 0..<rows {
            for column in 0..<columns { cell(left + Float(column) * cellWidth, Float(row) * size, cellWidth, size) }
        }
        for _ in 0..<random.nextInt(1, 4) {
            let x = fx(0.05, 0.95)
            let y = range(0.05, 0.95)
            let radius = range(0.015, 0.035)
            disc(x: x, y: y, radius: radius, color: anyAccent(), alpha: 1)
        }
    }

    /// One grid cell: an optional backing tile, then a bold primitive in another accent.
    private func cell(_ left: Float, _ top: Float, _ width: Float, _ size: Float) {
        let count = palette.accents.count
        let backing = random.nextInt(count)
        if random.nextFloat() < 0.55 {
            layers.append(.block(left: left, top: top, right: left + width, bottom: top + size, corner: 0, color: accent(backing), alpha: 0.92))
        }
        let color = accent(backing + 1 + random.nextInt(count - 1))
        let centreX = left + width / 2
        let centreY = top + size / 2
        switch random.nextInt(5) {
        case 0:
            layers.append(.disc(x: centreX, y: centreY, radius: size * range(0.34, 0.46), color: color, alpha: 1))
        case 1:
            // A quarter disc anchored in one of the cell's corners, opening into the cell.
            let corner = random.nextInt(4)
            let cx = left + (corner % 2 == 0 ? 0 : width)
            let cy = top + (corner < 2 ? 0 : size)
            layers.append(.sector(x: cx, y: cy, radius: size, startDeg: 90 * Self.quarterStarts[corner], sweepDeg: 90, color: color, alpha: 1))
        case 2:
            let start = 90 * Float(random.nextInt(4))
            layers.append(.sector(x: centreX, y: centreY, radius: size / 2, startDeg: start, sweepDeg: 180, color: color, alpha: 1))
        case 3:
            let inset = size * 0.14
            let insetX = wide(inset)
            layers.append(.block(left: left + insetX, top: top + inset, right: left + width - insetX, bottom: top + size - inset,
                                 corner: size * 0.2, color: color, alpha: 1))
        default:
            layers.append(.ring(x: centreX, y: centreY, radius: size * 0.3, wobble: Array(repeating: 1, count: 6), stroke: size * 0.12,
                                color: color, alpha: 1))
        }
    }

    /// A drift of light points along a curved band, with a couple of bright stars.
    private func particles() {
        glow(0.6)
        glow(0.4)
        let tilt = range(-0.4, 0.4)
        let bend = range(0.1, 0.3)
        let clear = frame.clear
        func bandY(_ t: Float) -> Float { 0.5 + tilt * (t - 0.5) + bend * sin(t * Self.pi) - bend / 2 }
        func bandX(_ t: Float) -> Float { clear + t * (1 - clear) }
        // Soft forms along the band give the drift a body.
        for i in 0..<3 {
            let t = 0.2 + Float(i) * 0.3 + range(-0.08, 0.08)
            let radius = range(0.14, 0.22)
            let shape = wobble(8, 0.2)
            let rotation = range(0, 360)
            let alpha = range(0.22, 0.35)
            layers.append(.blob(x: bandX(t), y: bandY(t), radius: radius, wobble: shape, rotation: rotation, color: accent(i), alpha: alpha))
        }
        let count = random.nextInt(110, 160)
        for i in 0..<count {
            let t = random.nextFloat()
            let jitter = random.nextFloat() - 0.5
            let spread = jitter * range(0.12, 0.4)
            let radius = range(0.004, 0.017)
            let alpha = range(0.5, 1)
            disc(x: bandX(t), y: bandY(t) + spread, radius: radius, color: accent(i), alpha: alpha)
        }
        for _ in 0..<random.nextInt(2, 4) {
            let x = fx(0.15, 0.85)
            let y = range(0.15, 0.85)
            layers.append(.glow(x: x, y: y, radius: range(0.08, 0.14), color: accent(3), alpha: 0.6))
            disc(x: x, y: y, radius: range(0.012, 0.02), color: accent(3), alpha: 1)
        }
    }

    /// Shards radiating from an off-centre focus, with a bold disc: energy.
    private func burst() {
        let x = fx(0.3, 0.7)
        let y = range(0.3, 0.7)
        glow(0.5)
        let rays = random.nextInt(10, 17)
        let offset = range(0, 360)
        for i in 0..<rays {
            let degrees = offset + Float(i) * 360 / Float(rays) + range(-6, 6)
            let angle = Double(degrees) * .pi / 180
            let width = Double(range(4, 11)) * .pi / 180
            let reach = range(0.55, 0.95)
            let inner = range(0.08, 0.16)
            // Rays pointing at the text side end before it.
            let leftward = -Float(cos(angle))
            let length = leftward > 0 ? min(reach, leftReach(x) / leftward) : reach
            if length <= inner { continue }
            let alpha = range(0.7, 0.95)
            let points: [Float] = [
                x + wide(inner * Float(cos(angle - width))), y + inner * Float(sin(angle - width)),
                x + wide(length * Float(cos(angle))), y + length * Float(sin(angle)),
                x + wide(inner * Float(cos(angle + width))), y + inner * Float(sin(angle + width)),
            ]
            layers.append(.shard(points: points, color: accent(i), alpha: alpha))
        }
        disc(x: x, y: y, radius: range(0.1, 0.16), color: accent(1), alpha: 1)
        layers.append(.ring(x: x, y: y, radius: range(0.2, 0.26), wobble: Array(repeating: 1, count: 6), stroke: 0.012, color: accent(3), alpha: 0.9))
        dust(random.nextInt(8, 14), 0.008, 0.02)
    }

    private func dust(_ count: Int, _ from: Float, _ to: Float) {
        for _ in 0..<count {
            let x = fx(0.05, 0.95)
            let y = range(0.05, 0.95)
            let radius = range(from, to)
            let color = anyAccent()
            disc(x: x, y: y, radius: radius, color: color, alpha: range(0.6, 1))
        }
    }
}

/// How a banner's text sits on its art: light text on dark palettes, dark on light ones, and a
/// veil of the palette's own tone behind it only as strong as contrast needs.
struct BannerLook: Equatable {
    static let targetContrast = 6.0
    static let secondaryAlpha = 0.8
    private static let glowShare: Float = 0.45
    private static let veilDepth: Float = 0.62
    private static let maxVeil: Float = 0.92
    private static let veilStep: Float = 0.02
    private static let lightText: UInt32 = 0xFFF7F3F2
    private static let darkText: UInt32 = 0xFF17141A

    let text: UInt32
    let onText: UInt32
    let veil: UInt32
    let veilAlpha: Float

    static func of(_ palette: ArtPalette) -> BannerLook {
        let light = palette.dark
        let text = light ? lightText : darkText
        let veil = mix(light ? 0xFF000000 : 0xFFFFFFFF, palette.background[0], veilDepth)
        let textSide = palette.background + palette.accents.flatMap { accent in palette.background.map { mix(accent, $0, glowShare) } }
        func readable(_ alpha: Float) -> Bool { textSide.allSatisfy { contrast(text, mix(veil, $0, alpha)) >= targetContrast } }
        var alpha: Float = 0
        while alpha < maxVeil && !readable(alpha) { alpha += veilStep }
        return BannerLook(text: text, onText: light ? darkText : lightText, veil: veil, veilAlpha: min(alpha, maxVeil))
    }

    /// [top] over [bottom] at [share] (opaque result).
    static func mix(_ top: UInt32, _ bottom: UInt32, _ share: Float) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Float((top >> shift) & 0xFF)
            let b = Float((bottom >> shift) & 0xFF)
            return (UInt32(a * share + b * (1 - share)) & 0xFF) << shift
        }
        return 0xFF00_0000 | channel(16) | channel(8) | channel(0)
    }
}

/// WCAG contrast ratio of two ARGB colours.
func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = relativeLuminance(a)
    let lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// WCAG relative luminance of an ARGB colour.
func relativeLuminance(_ argb: UInt32) -> Double {
    func channel(_ shift: UInt32) -> Double {
        let c = Double((argb >> shift) & 0xFF) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
}
