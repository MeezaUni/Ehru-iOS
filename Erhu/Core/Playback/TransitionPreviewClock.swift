import Foundation

/// Converts rendered player samples to transition-relative, approximately audible time.
/// No wall clock or UI timer advances this value. Incoming samples take over when that deck
/// has actually begun rendering, including after the outgoing segment has been released.
struct TransitionPreviewClock: Equatable {
    let leadMs: Double
    let durationMs: Double
    let tailMs: Double

    init(timing: PairTransitionTiming) {
        leadMs = Double(timing.leadMs)
        durationMs = Double(timing.plan.durationMs)
        tailMs = Double(timing.tailMs)
    }

    /// Some routes expose sample time without a host-time flag. Positive rendered samples
    /// are still a real clock; zero without a host timestamp cannot prove a scheduled start.
    static func elapsed(sampleTime: Int64, sampleRate: Double, renderHost: UInt64?, scheduledHost: UInt64) -> Double? {
        guard sampleTime >= 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        if let renderHost, renderHost < scheduledHost { return nil }
        guard sampleTime > 0 || renderHost != nil else { return nil }
        return Double(sampleTime) / sampleRate * 1000
    }

    func position(outgoingElapsedMs: Double?, incomingElapsedMs: Double?, latencyMs: Double) -> Double? {
        let incoming = incomingElapsedMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let outgoing = outgoingElapsedMs.flatMap { $0.isFinite && $0 >= 0 ? $0 - leadMs : nil }
        guard let rendered = incoming ?? outgoing else { return nil }
        let latency = latencyMs.isFinite ? max(latencyMs, 0) : 0
        return (rendered - latency).clamped(-leadMs, durationMs + tailMs)
    }
}
