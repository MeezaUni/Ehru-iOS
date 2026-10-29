import Foundation

/// Transition-relative milliseconds. Fit gives the overlap most of the screen, with a little context.
struct TransitionWaveformViewport: Equatable {
    let includesPreviewContext: Bool
    let startMs: Double
    let durationMs: Double
    var endMs: Double { startMs + durationMs }
    var centerMs: Double { startMs + durationMs / 2 }

    init(timing: PairTransitionTiming, zoom: Double, focusMs: Double? = nil, includesPreviewContext: Bool = false) {
        let bounds = Self.bounds(timing)
        self.includesPreviewContext = includesPreviewContext || !timing.hasOverlap
        let fit = self.includesPreviewContext ? bounds.upperBound - bounds.lowerBound
            : min(bounds.upperBound - bounds.lowerBound, Double(timing.plan.durationMs) * 1.25)
        durationMs = fit / (zoom.isFinite ? zoom.clamped(1, 8) : 1)
        let center = focusMs.flatMap { $0.isFinite ? $0 : nil } ?? (self.includesPreviewContext ? (bounds.lowerBound + bounds.upperBound) / 2 : Double(timing.plan.durationMs) / 2)
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
        let span = TransitionWaveformViewport(timing: timing, zoom: zoom, includesPreviewContext: includesPreviewContext).durationMs
        let center = time(at: fraction) + (0.5 - fraction) * span
        return TransitionWaveformViewport(timing: timing, zoom: zoom, focusMs: center, includesPreviewContext: includesPreviewContext)
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

/// The same geometry is used for drawing and touching the on-waveform gain handles.
struct TransitionCurveHandle: Equatable {
    let role: TransitionRole
    let index: Int
}

struct TransitionCurveLayout {
    let viewport: TransitionWaveformViewport
    let durationMs: Double
    let size: CGSize

    func role(at point: CGPoint) -> TransitionRole { point.y < size.height / 2 ? .outgoing : .incoming }

    func position(_ point: CurvePoint, role: TransitionRole) -> CGPoint {
        let laneHeight = size.height / 2
        let center = (role == .outgoing ? 0 : laneHeight) + laneHeight / 2 + 7
        let amplitude = max((laneHeight - 50) / 2, 1)
        return CGPoint(x: CGFloat(viewport.fraction(at: Double(point.t) * durationMs)) * size.width,
                       y: center + amplitude - CGFloat(point.gain) * amplitude * 2)
    }

    func value(at location: CGPoint, role: TransitionRole) -> CurvePoint {
        let laneHeight = size.height / 2
        let center = (role == .outgoing ? 0 : laneHeight) + laneHeight / 2 + 7
        let amplitude = max((laneHeight - 50) / 2, 1)
        return CurvePoint(t: Float(viewport.time(at: Double(location.x / max(size.width, 1))) / max(durationMs, 1)).clamped(0, 1),
                          gain: Float((center + amplitude - location.y) / (2 * amplitude)).clamped(0, 1))
    }

    func nearest(_ point: CGPoint, spec: TransitionSpec, radius: CGFloat = 26) -> TransitionCurveHandle? {
        var best: TransitionCurveHandle?
        var gap = radius
        for role in [TransitionRole.outgoing, .incoming] {
            for (index, control) in TransitionEditing.curveOf(spec, role).points.enumerated() {
                let p = position(control, role: role)
                guard p.x >= 0, p.x <= size.width else { continue }
                let distance = hypot(p.x - point.x, p.y - point.y)
                if distance <= gap { gap = distance; best = TransitionCurveHandle(role: role, index: index) }
            }
        }
        return best
    }
}

/// One transient edit, committed once on release. Keeping the initial grab offset avoids
/// a jump when a finger lands beside a small dot, and avoids compounding intermediate updates.
struct TransitionCurveDrag {
    let base: TransitionSpec
    let handle: TransitionCurveHandle
    let layout: TransitionCurveLayout

    func moved(translation: CGSize) -> TransitionSpec {
        guard translation != .zero else { return base }
        let points = TransitionEditing.curveOf(base, handle.role).points
        guard points.indices.contains(handle.index), translation.width.isFinite, translation.height.isFinite else { return base }
        let start = layout.position(points[handle.index], role: handle.role)
        let value = layout.value(at: CGPoint(x: start.x + translation.width, y: start.y + translation.height), role: handle.role)
        return TransitionEditing.movePoint(base, handle.role, index: handle.index, t: value.t, gain: value.gain)
    }
}

/// Conversion of the technical editor's values to the engine's linear-gain points.
enum TransitionPointPrecision {
    static func updated(_ spec: TransitionSpec, handle: TransitionCurveHandle, durationMs: Int,
                        timeMs: Double, gainDb: Double, silence: Bool) -> TransitionSpec {
        guard durationMs > 0, timeMs.isFinite, gainDb.isFinite else { return spec }
        let gain: Float = silence ? 0 : Float(pow(10, gainDb.clamped(-96, 0) / 20))
        let points = TransitionEditing.curveOf(spec, handle.role).points
        guard points.indices.contains(handle.index) else { return spec }
        let updated = TransitionEditing.movePoint(spec, handle.role, index: handle.index,
                                                  t: Float((timeMs / Double(durationMs)).clamped(0, 1)), gain: gain)
        let original = points[handle.index]
        let result = TransitionEditing.curveOf(updated, handle.role).points[handle.index]
        if abs(original.t - result.t) < 1e-7 && abs(original.gain - result.gain) < 1e-7 { return spec }
        return updated
    }
}
