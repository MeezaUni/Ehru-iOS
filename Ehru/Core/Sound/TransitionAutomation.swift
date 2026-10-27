import Foundation

/// One track's side of a transition, in content time from the moment the automation starts.
///
/// [leadInMs] of audio play before the transition starts (previews): the outgoing track at its
/// starting level, the incoming one silent. [entryRampMs] rises from silence at the very start.
/// After the transition the outgoing track stays silent; the incoming one plays on unchanged.
struct TransitionAutomation: Equatable {
    let role: TransitionRole
    let spec: TransitionSpec
    /// Effective duration (the spec's, shortened to fit both tracks).
    let durationMs: Int
    var entryRampMs = 0
    var leadInMs = 0

    private func progress(_ ms: Double) -> Float {
        Float((ms - Double(leadInMs)) / Double(max(durationMs, 1)))
    }

    func gainAt(_ ms: Double) -> Float {
        let t = progress(ms)
        let shaped = t < 0 ? (role == .outgoing ? spec.gain(role, 0) : 0) : spec.gain(role, t)
        let entry: Float = entryRampMs > 0 ? Float(ms / Double(entryRampMs)).clamped(0, 1) : 1
        return (shaped * entry).clamped(0, 1)
    }

    /// Low-shelf gain in dB at [ms]; 0 without a bass swap.
    func bassDbAt(_ ms: Double) -> Float {
        spec.bassSwap ? spec.bassDb(role, progress(ms).clamped(0, 1)) : 0
    }

    /// The filter sweep on this track at [ms], or nil when this track is not filtered.
    func filterAt(_ ms: Double) -> FilterSetting? {
        spec.filter.settingAt(role, progress(ms))
    }

    /// True once an incoming automation is over and the audio plays unchanged again.
    func isFinished(_ ms: Double) -> Bool {
        role == .incoming && progress(ms) >= 1
    }

    /// True once an outgoing automation has faded to silence for good.
    func isSilentForGood(_ ms: Double) -> Bool {
        role == .outgoing && progress(ms) >= 1
    }
}
