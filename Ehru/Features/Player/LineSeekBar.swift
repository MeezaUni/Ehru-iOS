import SwiftUI

/// Now Playing's seek bar (Android's LinearSeekBar): one slim line with rounded ends. The played
/// part runs in the artwork's [accent], brightening toward its leading edge, which ends in a small
/// round head with a soft glow (quieter while paused). Scrubbing thickens the line and grows the
/// head. Bookmarks are dots under the line, the A–B loop a band with its two markers. Tap to seek;
/// drag to preview and seek once on release. The head follows the engine's exact position, smoothly.
struct LineSeekBar: View {
    let durationMs: Int64
    let isPlaying: Bool
    let bookmarks: [Int64]
    let loop: AbLoopState?
    let accent: Color
    @Binding var previewMs: Int64?
    let onSeek: (Int64) -> Void
    @Environment(PlayerController.self) private var player
    @Environment(\.palette) private var palette

    private static let touchHeight: CGFloat = 48
    private static let thin: CGFloat = 4
    private static let thick: CGFloat = 6
    private static let headRadius: CGFloat = 5
    private static let knobRadius: CGFloat = 7
    private static let glowRadius: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying || previewMs != nil)) { _ in
                let position = previewMs ?? player.currentPositionMs()
                Canvas { context, size in draw(in: &context, size: size, position: position) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in previewMs = position(at: value.location.x, width: geometry.size.width) }
                    .onEnded { value in
                        onSeek(position(at: value.location.x, width: geometry.size.width))
                        previewMs = nil
                    }
            )
        }
        .frame(height: Self.touchHeight)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: previewMs != nil)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue("\(formatDuration(player.clock.positionMs)) of \(formatDuration(durationMs))")
        .accessibilityAdjustableAction { direction in
            let now = player.currentPositionMs()
            switch direction {
            case .increment: onSeek(min(now + 10_000, durationMs))
            case .decrement: onSeek(max(now - 10_000, 0))
            @unknown default: break
            }
        }
    }

    private func position(at x: CGFloat, width: CGFloat) -> Int64 {
        width <= 0 ? 0 : WaveformTimeline.positionAt(Float(min(max(x / width, 0), 1)), durationMs)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, position: Int64) {
        let scrubbing = previewMs != nil
        let y = size.height / 2
        let thickness = scrubbing ? Self.thick : Self.thin
        let headX = CGFloat(WaveformTimeline.fractionOf(position, durationMs)) * size.width
        let glow = isPlaying || scrubbing ? 1.0 : 0.5
        let body = accent.lifted(0.18)
        let head = accent.lifted(0.28)

        if let loop {
            let start = loop.startMs.map { CGFloat(WaveformTimeline.fractionOf($0, durationMs)) * size.width }
            let end = loop.endMs.map { CGFloat(WaveformTimeline.fractionOf($0, durationMs)) * size.width }
            if let start, let end, end > start {
                context.fill(Path(CGRect(x: start, y: y - 8, width: end - start, height: 16)),
                             with: .color(accent.opacity(loop.enabled ? 0.28 : 0.12)))
            }
            for x in [start, end].compactMap({ $0 }) {
                context.fill(Path(roundedRect: CGRect(x: x - 1, y: y - 6, width: 2, height: 12), cornerRadius: 1), with: .color(accent))
            }
        }
        // The track, then the played part over it.
        let track = CGRect(x: 0, y: y - thickness / 2, width: size.width, height: thickness)
        context.fill(Path(roundedRect: track, cornerRadius: thickness / 2), with: .color(palette.onSurface.opacity(0.22)))
        if headX > 0 {
            let played = CGRect(x: 0, y: y - thickness / 2, width: headX, height: thickness)
            context.fill(Path(roundedRect: played, cornerRadius: thickness / 2),
                         with: .linearGradient(Gradient(colors: [body.opacity(0.55), body]), startPoint: .zero, endPoint: CGPoint(x: headX, y: 0)))
        }
        for ms in bookmarks {
            let x = CGFloat(WaveformTimeline.fractionOf(ms, durationMs)) * size.width
            context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y + 7 - 2, width: 4, height: 4)), with: .color(palette.onSurface.opacity(0.8)))
        }
        // The head: a soft glow, a faint dark rim, the knob with a lighter contour and a bright centre.
        let radius = scrubbing ? Self.knobRadius : Self.headRadius
        let center = CGPoint(x: headX, y: y)
        context.fill(Path(ellipseIn: CGRect(x: headX - Self.glowRadius, y: y - Self.glowRadius, width: Self.glowRadius * 2, height: Self.glowRadius * 2)),
                     with: .radialGradient(Gradient(colors: [accent.opacity(0.5 * glow), accent.opacity(0.2 * glow), .clear]),
                                           center: center, startRadius: 0, endRadius: Self.glowRadius))
        let shade = radius + 1.5
        context.fill(Path(ellipseIn: CGRect(x: headX - shade, y: y - shade, width: shade * 2, height: shade * 2)), with: .color(.black.opacity(0.22)))
        context.fill(Path(ellipseIn: CGRect(x: headX - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(head))
        context.stroke(Path(ellipseIn: CGRect(x: headX - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(head.lifted(0.5).opacity(0.7)), lineWidth: 1.5)
        let inner = radius * 0.45
        context.fill(Path(ellipseIn: CGRect(x: headX - inner, y: y - inner, width: inner * 2, height: inner * 2)),
                     with: .color(head.lifted(0.7)))
    }
}

extension Color {
    /// This colour moved [amount] (0…1) of the way toward white.
    func lifted(_ amount: Double) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        let t = CGFloat(amount)
        return Color(red: r + (1 - r) * t, green: g + (1 - g) * t, blue: b + (1 - b) * t, opacity: a)
    }
}
