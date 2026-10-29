import SwiftUI

/// Only this thin overlay refreshes during audition. Waveform decoding and drawing remain still.
struct TransitionPreviewPlayhead: View {
    let preview: PairTransitionPreview
    let viewport: TransitionWaveformViewport

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !preview.isPlaying)) { _ in
            GeometryReader { geometry in
                if let time = preview.positionMs() {
                    TransitionPlayheadStroke(fraction: viewport.fraction(at: time))
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Explicit paths span the complete plot; position() on an unbounded thin Rectangle can
/// otherwise give it its ideal (tiny) height instead of the waveform's height.
struct TransitionPlayheadStroke: View {
    let fraction: Double
    var body: some View {
        Canvas { context, size in
            guard fraction.isFinite else { return }
            if (0...1).contains(fraction) {
                let x = CGFloat(fraction) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.black.opacity(0.75)), lineWidth: 5)
                context.stroke(line, with: .color(.green), lineWidth: 2)
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: 0, width: 8, height: 8)), with: .color(.green))
            } else {
                context.draw(Text(fraction < 0 ? "←" : "→").font(.caption.bold()).foregroundColor(.green),
                             at: CGPoint(x: fraction < 0 ? 12 : size.width - 12, y: 12))
            }
        }
        .allowsHitTesting(false)
    }
}

struct TransitionPreviewReadout: View {
    let preview: PairTransitionPreview
    let durationMs: Int
    @Environment(\.palette) private var palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !preview.isPlaying)) { _ in
            if preview.isPlaying || preview.isPreparing {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    if let position = preview.positionMs() {
                        Text(position < 0 ? "Lead-in" : position > Double(durationMs) ? "Tail" : "Preview")
                        Text((position < 0 ? "−" : "") + transitionTimestamp(abs(position)))
                            .monospacedDigit()
                    } else { Text("Starting preview…") }
                }
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            }
        }
    }
}
