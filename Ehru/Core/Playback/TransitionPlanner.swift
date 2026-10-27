import Foundation

/// What the planner needs to know about the current queue boundary.
struct BoundaryInfo: Equatable {
    /// The transition the settings give for this exact boundary, or nil.
    let spec: TransitionSpec?
    /// Queue index of the next entry in play order, or -1 when nothing follows.
    let nextIndex: Int
    let repeatMode: RepeatMode
    let abLoopEnabled: Bool
    let outgoingDurationMs: Int64
    let incomingDurationMs: Int64
}

/// Why a boundary plays the normal (gapless) way.
enum NoTransitionReason: Equatable {
    case notConfigured
    case repeatOne
    case abLoop
    case noNext
    case unknownDuration
    case tooShort
}

enum TransitionDecision: Equatable {
    case planned(Planned)
    case none(NoTransitionReason)

    struct Planned: Equatable {
        let nextIndex: Int
        /// Position in the outgoing track where the transition starts.
        let startAtMs: Int64
        /// Effective duration (the setting, shortened to fit both tracks).
        let durationMs: Int
        let spec: TransitionSpec
        /// Where the incoming track starts (its cue point; 0 = the beginning).
        var incomingStartMs: Int64 = 0
    }

    var planned: Planned? {
        if case .planned(let plan) = self { return plan }
        return nil
    }

    var reason: NoTransitionReason? {
        if case .none(let reason) = self { return reason }
        return nil
    }
}

/// Decides whether and how the boundary after the current entry is crossed. Pure.
enum TransitionPlanner {
    /// Transitions shorter than this are skipped rather than squeezed in.
    static let minEffectiveMs = 300

    static func plan(_ info: BoundaryInfo) -> TransitionDecision {
        guard let spec = info.spec?.sanitized() else { return .none(.notConfigured) }
        if info.repeatMode == .one { return .none(.repeatOne) }
        if info.abLoopEnabled { return .none(.abLoop) }
        if info.nextIndex < 0 { return .none(.noNext) }
        if info.outgoingDurationMs <= 0 || info.incomingDurationMs <= 0 { return .none(.unknownDuration) }
        let duration = spec.effectiveDurationMs(outgoingDurationMs: info.outgoingDurationMs, incomingDurationMs: info.incomingDurationMs)
        if duration < minEffectiveMs { return .none(.tooShort) }
        // The transition ends at the outgoing cue point (the track's end unless part of it is cut).
        return .planned(Planned(
            nextIndex: info.nextIndex,
            startAtMs: spec.outgoingEndMs(info.outgoingDurationMs) - Int64(duration),
            durationMs: duration,
            spec: spec,
            incomingStartMs: Int64(spec.incomingStartMs)
        ))
    }
}

typealias Planned = TransitionDecision.Planned
