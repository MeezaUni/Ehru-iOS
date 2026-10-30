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

/// Direct hits use the same gain/frequency geometry as rendering; only visible, active lines
/// participate. Tapping a segment reveals its editor even when the tool is Move audio.
enum TransitionLineTarget: Equatable {
    case volume(TransitionRole), bass(TransitionRole), filter(TransitionRole)
    var role: TransitionRole {
        switch self { case .volume(let role), .bass(let role), .filter(let role): role }
    }
}

extension TransitionCurveLayout {
    func position(time: Float, level: Float, role: TransitionRole) -> CGPoint {
        position(CurvePoint(t: time, gain: level), role: role)
    }

    static func frequencyLevel(_ hz: Float) -> Float { (log(hz.clamped(20, 18_000) / 20) / log(Float(900))).clamped(0, 1) }
    static func frequency(_ level: Float) -> Float { 20 * pow(900, level.clamped(0, 1)) }

    func nearestLine(_ location: CGPoint, spec: TransitionSpec, showsEQ: Bool, showsFilter: Bool,
                     selected: TransitionLineTarget? = nil, radius: CGFloat = 18) -> TransitionLineTarget? {
        var targets: [TransitionLineTarget] = []
        for role in [TransitionRole.outgoing, .incoming] {
            targets.append(.volume(role))
            if showsEQ && spec.bassSwap { targets.append(.bass(role)) }
            if showsFilter && spec.filter.affects(role) { targets.append(.filter(role)) }
        }
        var best: TransitionLineTarget?
        var bestGap = radius
        for target in targets {
            var previous: CGPoint?
            for step in 0...160 {
                let t = Float(step) / 160
                let level: Float
                switch target {
                case .volume(let role): level = spec.gain(role, t)
                case .bass(let role): level = pow(10, spec.bassDb(role, t) / 20)
                case .filter(let role):
                    guard let setting = spec.filterSetting(role, t) else { continue }
                    level = Self.frequencyLevel(setting.hz)
                }
                let p = position(time: t, level: level, role: target.role)
                defer { previous = p }
                guard p.x >= -radius, p.x <= size.width + radius, let a = previous else { continue }
                let dx = p.x - a.x, dy = p.y - a.y
                let length = dx * dx + dy * dy
                let u = length > 0 ? (((location.x - a.x) * dx + (location.y - a.y) * dy) / length).clamped(0, 1) : 0
                let gap = hypot(location.x - a.x - u * dx, location.y - a.y - u * dy)
                if gap < bestGap - 0.25 || (gap <= bestGap + 0.25 && target == selected) {
                    bestGap = gap; best = target
                }
            }
        }
        return best
    }

    func effectHandle(_ target: TransitionLineTarget, spec: TransitionSpec) -> CGPoint? {
        switch target {
        case .bass(let role):
            return position(time: spec.bassSwapAt, level: pow(10, spec.bassDb(role, spec.bassSwapAt) / 20), role: role)
        case .filter(let role):
            return spec.filterKnee(role).map { position(time: $0.t, level: Self.frequencyLevel($0.hz), role: role) }
        case .volume: return nil
        }
    }
}

struct TransitionEffectDrag {
    let base: TransitionSpec
    let target: TransitionLineTarget
    let layout: TransitionCurveLayout

    func moved(translation: CGSize) -> TransitionSpec {
        guard translation != .zero, translation.width.isFinite, translation.height.isFinite,
              let start = layout.effectHandle(target, spec: base) else { return base }
        let value = layout.value(at: CGPoint(x: start.x + translation.width, y: start.y + translation.height), role: target.role)
        switch target {
        case .bass: return TransitionEditing.setBassSwapAt(base, value.t)
        case .filter(let role): return TransitionEditing.setFilterKnee(base, role: role, t: value.t, hz: TransitionCurveLayout.frequency(value.gain))
        case .volume: return base
        }
    }
}
