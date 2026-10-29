import SwiftUI

/// Only this thin overlay refreshes during audition. Waveform decoding and drawing remain still.
struct TransitionPreviewPlayhead: View {
    let preview: PairTransitionPreview
    let viewport: TransitionWaveformViewport

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !preview.isPlaying)) { _ in
            GeometryReader { geometry in
                if let time = preview.positionMs() {
                    let fraction = viewport.fraction(at: time)
                    if (0...1).contains(fraction) {
                        let x = CGFloat(fraction) * geometry.size.width
                        Rectangle().fill(.black.opacity(0.45)).frame(width: 4)
                            .overlay(Rectangle().fill(.green).frame(width: 2))
                            .overlay(alignment: .top) { Circle().fill(.green).frame(width: 7, height: 7) }
                            .position(x: x, y: geometry.size.height / 2)
                    } else {
                        Image(systemName: fraction < 0 ? "arrow.left" : "arrow.right")
                            .font(.caption.bold()).foregroundStyle(.green)
                            .position(x: fraction < 0 ? 12 : geometry.size.width - 12, y: 12)
                    }
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
