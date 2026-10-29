import Foundation

/// Transition-relative milliseconds. Fit gives the overlap most of the screen, with a little context.
struct TransitionWaveformViewport: Equatable {
    let startMs: Double
    let durationMs: Double
    var endMs: Double { startMs + durationMs }
    var centerMs: Double { startMs + durationMs / 2 }

    init(timing: PairTransitionTiming, zoom: Double, focusMs: Double? = nil) {
        let bounds = Self.bounds(timing)
        let fit = min(bounds.upperBound - bounds.lowerBound, Double(timing.plan.durationMs) * 1.25)
        durationMs = fit / (zoom.isFinite ? zoom.clamped(1, 8) : 1)
        let center = focusMs.flatMap { $0.isFinite ? $0 : nil } ?? Double(timing.plan.durationMs) / 2
        startMs = (center - durationMs / 2).clamped(bounds.lowerBound, bounds.upperBound - durationMs)
    }

    static func bounds(_ timing: PairTransitionTiming) -> ClosedRange<Double> {
        (-Double(timing.leadMs))...(Double(timing.plan.durationMs) + Double(timing.tailMs))
    }

    func time(at fraction: Double) -> Double { startMs + fraction * durationMs }
    func fraction(at time: Double) -> Double { (time - startMs) / durationMs }

    /// Keep the time under the fingers fixed while pinching, except at the available edges.
    func zoomed(timing: PairTransitionTiming, zoom: Double, anchor: Double) -> TransitionWaveformViewport {
        let fraction = anchor.isFinite ? anchor.clamped(0, 1) : 0.5
        let span = TransitionWaveformViewport(timing: timing, zoom: zoom).durationMs
        let center = time(at: fraction) + (0.5 - fraction) * span
        return TransitionWaveformViewport(timing: timing, zoom: zoom, focusMs: center)
    }
}

/// A drag is always relative to its initial cue, lane and time scale, never a previous update.
struct TransitionWaveformDrag {
    let base: TransitionSpec
    let role: TransitionRole
    let viewport: TransitionWaveformViewport
    let width: Double

    func shifted(points: Double, outgoingMs: Int64, incomingMs: Int64) -> TransitionSpec {
        guard width.isFinite, width > 0, points.isFinite else { return base }
        let delta = points / width * viewport.durationMs
        return TransitionEditing.shiftCue(base, role, deltaMs: Float(delta),
                                          outgoingDurationMs: outgoingMs, incomingDurationMs: incomingMs)
    }
}

enum TransitionWaveformHeight: String, CaseIterable, Identifiable {
    case auto, original, four, sixteen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .original: "1×"
        case .four: "4×"
        case .sixteen: "16×"
        }
    }

    func gain(visiblePeak: Float) -> Float {
        switch self {
        case .auto: visiblePeak > 0 ? (0.85 / visiblePeak).clamped(1, 32) : 1
        case .original: 1
        case .four: 4
        case .sixteen: 16
        }
    }
}

extension TransitionAudioSlice {
    /// Peek at the actual bins in view; a single shared display gain preserves the two tracks' ratio.
    func visiblePeak(sourceStartMs: Double, viewport: TransitionWaveformViewport) -> Float {
        let from = sourceStartMs + viewport.startMs
        let to = sourceStartMs + viewport.endMs
        guard durationMs > 0, !peaks.isEmpty else { return 0 }
        let first = Int(floor((from - startMs) / durationMs * Double(peaks.count))).clamped(0, peaks.count)
        let last = Int(ceil((to - startMs) / durationMs * Double(peaks.count))).clamped(0, peaks.count)
        return first < last ? peaks[first..<last].max() ?? 0 : 0
    }
}
