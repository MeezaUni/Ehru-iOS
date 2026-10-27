import SwiftUI

/// The track's real amplitude envelope as a seek bar: the played part in the accent, bookmark
/// ticks along the bottom and the A–B loop region. Tap to seek; drag to preview and seek once on
/// release. A flat placeholder shows while the waveform loads (or when the file has none).
struct WaveformSeekBar: View {
    let levels: [Float]?
    let positionMs: Int64
    let durationMs: Int64
    let bookmarks: [Int64]
    let loop: AbLoopState?
    @Binding var previewMs: Int64?
    let onSeek: (Int64) -> Void
    @Environment(\.palette) private var palette

    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
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
        .frame(height: 56)
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue("\(formatDuration(positionMs)) of \(formatDuration(durationMs))")
        .accessibilityAdjustableAction { direction in
            let step: Int64 = 10_000
            switch direction {
            case .increment: onSeek(min(positionMs + step, durationMs))
            case .decrement: onSeek(max(positionMs - step, 0))
            @unknown default: break
            }
        }
    }

    private func position(at x: CGFloat, width: CGFloat) -> Int64 {
        width <= 0 ? 0 : WaveformTimeline.positionAt(Float(x / width), durationMs)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let step = Self.barWidth + Self.barGap
        let count = max(Int((size.width + Self.barGap) / step), 1)
        let bars = Self.barLevels(levels, count)
        let playedX = CGFloat(WaveformTimeline.fractionOf(previewMs ?? positionMs, durationMs)) * size.width
        if let loop {
            let start = loop.startMs.map { CGFloat(WaveformTimeline.fractionOf($0, durationMs)) * size.width }
            let end = loop.endMs.map { CGFloat(WaveformTimeline.fractionOf($0, durationMs)) * size.width }
            if let start, let end, end > start {
                context.fill(Path(CGRect(x: start, y: 0, width: end - start, height: size.height)),
                             with: .color(palette.onSurfaceVariant.opacity(loop.enabled ? 0.16 : 0.07)))
            }
            for x in [start, end].compactMap({ $0 }) {
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(palette.onSurfaceVariant))
            }
        }
        for (i, level) in bars.enumerated() {
            let x = CGFloat(i) * step
            let height = max(CGFloat(level) * size.height, 2)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
            let color = x + Self.barWidth / 2 <= playedX ? palette.primary : palette.onSurfaceVariant.opacity(0.35)
            context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(color))
        }
        for ms in bookmarks {
            let x = CGFloat(WaveformTimeline.fractionOf(ms, durationMs)) * size.width
            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: size.height - 5, width: 5, height: 5)), with: .color(palette.onSurface))
        }
    }

    /// [count] bar heights 0..1 (the loudest level of each slice), or a flat placeholder.
    static func barLevels(_ levels: [Float]?, _ count: Int) -> [Float] {
        guard let levels, !levels.isEmpty else { return Array(repeating: 0.12, count: count) }
        return (0..<count).map { bar in
            let from = bar * levels.count / count
            let to = min(max((bar + 1) * levels.count / count, from + 1), levels.count)
            return levels[from..<to].max() ?? 0
        }
    }
}
