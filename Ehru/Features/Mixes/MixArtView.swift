import SwiftUI

extension Color {
    /// An ARGB colour as stored by the Android code.
    init(argb: UInt32, alpha: Double? = nil) {
        let a = alpha ?? Double((argb >> 24) & 0xFF) / 255
        self.init(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255, opacity: a)
    }
}

/// A smart mix's generated cover. Give it a square frame (and clip it to the card's shape).
struct MixArtworkView: View {
    let kind: MixKind

    var body: some View {
        MixArtCanvas(art: MixArtCache.cover(kind))
            .accessibilityLabel("\(kind.title) cover")
    }
}

/// Generated art is laid out once per mix (and banner shape) and reused.
@MainActor
enum MixArtCache {
    private static var covers: [MixKind: MixArt] = [:]
    private static var banners: [String: (MixArt, BannerLook)] = [:]

    static func cover(_ kind: MixKind) -> MixArt {
        if let art = covers[kind] { return art }
        let art = MixArt.generate(kind)
        covers[kind] = art
        return art
    }

    /// Banners of nearly the same shape share their art.
    static func banner(_ kind: MixKind, aspect: Float) -> (MixArt, BannerLook) {
        let bucket = Float(Int(aspect * 20)) / 20
        let key = "\(kind.key)@\(bucket)"
        if let found = banners[key] { return found }
        let art = MixArt.banner(kind, aspect: bucket)
        let made = (art, BannerLook.of(art.palette))
        banners[key] = made
        return made
    }
}

/// Draws composed [art] at whatever size it is given.
struct MixArtCanvas: View {
    let art: MixArt

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            for layer in art.layers { draw(layer, in: &context, size: size, side: side) }
        }
    }

    private func draw(_ layer: ArtLayer, in context: inout GraphicsContext, size: CGSize, side: CGFloat) {
        func p(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height) }
        switch layer {
        case .backdrop(let colors, let angleDeg):
            let angle = Double(angleDeg) * .pi / 180
            let dx = Float(cos(angle) / 2)
            let dy = Float(sin(angle) / 2)
            let gradient = Gradient(colors: colors.map { Color(argb: $0) })
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(gradient, startPoint: p(0.5 - dx, 0.5 - dy), endPoint: p(0.5 + dx, 0.5 + dy)))
        case .glow(let x, let y, let radius, let color, let alpha):
            let center = p(x, y)
            let r = CGFloat(radius) * side
            let gradient = Gradient(colors: [Color(argb: color, alpha: Double(alpha)), Color(argb: color, alpha: 0)])
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: r))
        case .blob(let x, let y, let radius, let wobble, let rotation, let color, let alpha):
            let path = Self.wobblyPath(center: p(x, y), radius: CGFloat(radius) * side, wobble: wobble, rotationDeg: rotation)
            context.fill(path, with: .color(Color(argb: color, alpha: Double(alpha))))
        case .ring(let x, let y, let radius, let wobble, let stroke, let color, let alpha):
            let path = Self.wobblyPath(center: p(x, y), radius: CGFloat(radius) * side, wobble: wobble, rotationDeg: 0)
            context.stroke(path, with: .color(Color(argb: color, alpha: Double(alpha))),
                           style: StrokeStyle(lineWidth: CGFloat(stroke) * side, lineCap: .round, lineJoin: .round))
        case .ribbon(let points, let width, let color, let alpha):
            let path = Self.smoothPath(stride(from: 0, to: points.count - 1, by: 2).map { p(points[$0], points[$0 + 1]) })
            context.stroke(path, with: .color(Color(argb: color, alpha: Double(alpha))),
                           style: StrokeStyle(lineWidth: CGFloat(width) * side, lineCap: .round, lineJoin: .round))
        case .disc(let x, let y, let radius, let color, let alpha):
            let center = p(x, y)
            let r = CGFloat(radius) * side
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color(argb: color, alpha: Double(alpha))))
        case .sector(let x, let y, let radius, let startDeg, let sweepDeg, let color, let alpha):
            // Angles as on Android: degrees clockwise from 3 o'clock on a y-down canvas.
            let center = p(x, y)
            let r = CGFloat(radius) * side
            var path = Path()
            path.move(to: center)
            let steps = 32
            for i in 0...steps {
                let angle = Double(startDeg + sweepDeg * Float(i) / Float(steps)) * .pi / 180
                path.addLine(to: CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle)))
            }
            path.closeSubpath()
            context.fill(path, with: .color(Color(argb: color, alpha: Double(alpha))))
        case .shard(let points, let color, let alpha):
            var path = Path()
            for i in stride(from: 0, to: points.count - 1, by: 2) {
                let point = p(points[i], points[i + 1])
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.fill(path, with: .color(Color(argb: color, alpha: Double(alpha))))
        case .block(let left, let top, let right, let bottom, let corner, let color, let alpha):
            let topLeft = p(left, top)
            let bottomRight = p(right, bottom)
            let rect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            let r = CGFloat(corner) * side
            context.fill(Path(roundedRect: rect, cornerSize: CGSize(width: r, height: r)), with: .color(Color(argb: color, alpha: Double(alpha))))
        }
    }

    /// A closed curve around [center] whose radius follows [wobble] smoothly.
    private static func wobblyPath(center: CGPoint, radius: CGFloat, wobble: [Float], rotationDeg: Float) -> Path {
        let n = max(wobble.count, 3)
        let rotation = Double(rotationDeg) * .pi / 180
        let points = (0..<n).map { i -> CGPoint in
            let angle = rotation + 2 * .pi * Double(i) / Double(n)
            let r = radius * CGFloat(wobble[i % wobble.count])
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        return smoothPath(points, closed: true)
    }

    /// A Catmull-Rom spline through [points] as cubic Béziers.
    private static func smoothPath(_ points: [CGPoint], closed: Bool = false) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let n = points.count
        func at(_ i: Int) -> CGPoint { closed ? points[((i % n) + n) % n] : points[min(max(i, 0), n - 1)] }
        path.move(to: points[0])
        for i in 0..<(closed ? n : n - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
        return path
    }
}
