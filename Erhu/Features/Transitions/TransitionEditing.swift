import Foundation

/// One track on the Studio timeline: the song and which occurrence of it this is.
struct StudioTrack: Hashable {
    let song: Song
    let occurrence: TrackOccurrence
}

/// The transition between two adjacent timeline tracks, with its own setting and what will play.
struct StudioPair: Hashable {
    let key: TransitionPairKey
    let from: StudioTrack
    let to: StudioTrack
    let choice: TransitionChoice
    /// What plays at this boundary when the collection is played in this order (nil: no transition).
    let resolved: TransitionSpec?

    static func == (a: StudioPair, b: StudioPair) -> Bool {
        a.key == b.key && a.from == b.from && a.to == b.to && a.choice == b.choice && a.resolved == b.resolved
    }

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Pairs between adjacent tracks, in timeline order. A pair is keyed by its two occurrences (not by
/// song ids or list positions), so reordering, adding or removing tracks only changes which pairs
/// are adjacent; a setting never moves to a different pair, and the two copies of a duplicated song
/// keep separate settings.
func studioPairs(_ collection: CollectionRef, tracks: [StudioTrack], config: TransitionConfig) -> [StudioPair] {
    zip(tracks, tracks.dropFirst()).map { from, to in
        let key = TransitionPairKey(collection: collection, from: from.occurrence, to: to.occurrence)
        let resolved = TransitionResolver.resolve(
            config,
            outgoing: QueueOrigin(collection: collection, occurrence: from.occurrence),
            incoming: QueueOrigin(collection: collection, occurrence: to.occurrence)
        ).spec
        return StudioPair(key: key, from: from, to: to, choice: config.pair(key), resolved: resolved)
    }
}

/// Short label for a pair chip: Auto (inherits), Off, or the preset name.
func pairLabel(_ choice: TransitionChoice) -> String {
    switch choice {
    case .inherit: "Auto"
    case .off: "Off"
    case .custom(let spec): spec.preset.label
    }
}

func specSummary(_ spec: TransitionSpec?) -> String {
    guard let spec else { return "No crossfade" }
    return "\(spec.preset.label) · \(TransitionSpec.durationLabel(spec.durationMs))"
}

/// Edits of a [TransitionSpec] made in the editor. Every function returns a valid spec: times stay
/// inside the transition and in order, gains stay within 0..1, fixed end levels stay fixed, and
/// editing one track's curve never changes the other's.
enum TransitionEditing {
    /// Part of a track that always plays, whatever the cue points.
    static let minPlayedMs: Int64 = 1_000

    static func applyPreset(_ spec: TransitionSpec, _ preset: TransitionPreset) -> TransitionSpec {
        TransitionSpec.preset(preset, base: spec).sanitized()
    }

    static func setDuration(_ spec: TransitionSpec, _ durationMs: Int) -> TransitionSpec {
        var out = spec
        out.durationMs = TransitionSpec.clampDuration(durationMs)
        return out
    }

    static func setCurve(_ spec: TransitionSpec, _ curve: TransitionCurve) -> TransitionSpec {
        if curve == .custom { return TransitionSpec.preset(.custom, base: spec).sanitized() }
        var out = spec
        out.curve = curve
        out.outgoingCurve = nil
        out.incomingCurve = nil
        out.preset = spec.preset == .bassSwap ? .bassSwap : .fade
        return out.sanitized()
    }

    /// A named volume shape; marks the transition Custom unless it is still exactly its preset.
    static func setVolumeShape(_ spec: TransitionSpec, _ shape: VolumeShape) -> TransitionSpec {
        relabel(shape.applyTo(spec))
    }

    static func setEqMove(_ spec: TransitionSpec, _ move: EqMove) -> TransitionSpec {
        relabel(move.applyTo(spec))
    }

    static func setFilter(_ spec: TransitionSpec, _ filter: TransitionFilter) -> TransitionSpec {
        var out = spec
        out.filter = filter
        out.incomingFilterAt = nil; out.outgoingFilterAt = nil
        out.incomingFilterHz = nil; out.outgoingFilterHz = nil
        return relabel(out)
    }

    static func setFilterKnee(_ spec: TransitionSpec, role: TransitionRole, t: Float, hz: Float) -> TransitionSpec {
        guard t.isFinite, hz.isFinite, spec.filter.affects(role) else { return spec }
        var out = spec
        if role == .incoming { out.incomingFilterAt = t.clamped(0.05, 0.95); out.incomingFilterHz = hz.clamped(20, 18_000) }
        else { out.outgoingFilterAt = t.clamped(0.05, 0.95); out.outgoingFilterHz = hz.clamped(20, 18_000) }
        return relabel(out)
    }

    /// The preset whose settings [spec] still matches exactly (duration aside), or Custom.
    static func relabel(_ spec: TransitionSpec) -> TransitionSpec {
        let matching = TransitionPreset.allCases.first { preset in
            guard preset != .custom else { return false }
            var candidate = TransitionSpec.preset(preset, base: spec)
            candidate.preset = spec.preset
            return candidate == spec
        }
        var out = spec
        out.preset = matching ?? .custom
        return out
    }

    static func setBassSwap(_ spec: TransitionSpec, _ enabled: Bool) -> TransitionSpec {
        var out = spec
        out.bassSwap = enabled
        if enabled && spec.curve != .custom {
            out.preset = .bassSwap
        } else if !enabled && spec.preset == .bassSwap {
            out.preset = .fade
        }
        return out
    }

    static func setBassSwapAt(_ spec: TransitionSpec, _ at: Float) -> TransitionSpec {
        var out = spec
        out.bassSwap = true
        out.bassSwapAt = at.clamped(TransitionSpec.minBassSwapAt, TransitionSpec.maxBassSwapAt)
        return relabel(out)
    }

    /// Moves a cue point by a horizontal drag of [deltaMs] (positive = the waveform moved right):
    /// the outgoing track hands over earlier (more of its end is skipped), the incoming one starts
    /// earlier. At least a second of each track always plays.
    static func shiftCue(_ spec: TransitionSpec, _ role: TransitionRole, deltaMs: Float,
                         outgoingDurationMs: Int64, incomingDurationMs: Int64) -> TransitionSpec {
        guard deltaMs.isFinite else { return spec }
        var out = spec
        switch role {
        case .outgoing:
            out.outgoingCutMs = Int(Int64(Float(spec.outgoingCutMs) + deltaMs).clamped(0, maxCue(outgoingDurationMs)))
        case .incoming:
            out.incomingStartMs = Int(Int64(Float(spec.incomingStartMs) - deltaMs).clamped(0, maxCue(incomingDurationMs)))
        }
        return out
    }

    private static func maxCue(_ trackMs: Int64) -> Int64 {
        (trackMs - minPlayedMs).clamped(0, Int64(TransitionSpec.maxCueMs))
    }

    /// The editable curve of [role]: the custom one, or the built-in curve sampled into points.
    static func curveOf(_ spec: TransitionSpec, _ role: TransitionRole) -> VolumeCurve {
        let custom = role == .outgoing ? spec.outgoingCurve : spec.incomingCurve
        if spec.curve == .custom, let custom { return custom }
        return VolumeCurve.sampled(spec.curve, role: role)
    }

    /// Moves point [index] of [role]'s curve towards ([t], [gain]); the result is clamped to what is
    /// allowed. A built-in curve becomes a custom one (the other track keeps its shape as points).
    static func movePoint(_ spec: TransitionSpec, _ role: TransitionRole, index: Int, t: Float, gain: Float) -> TransitionSpec {
        let points = curveOf(spec, role).points
        guard points.indices.contains(index) else { return spec }
        let last = points.count - 1
        let newT: Float
        switch index {
        case 0: newT = 0
        case last: newT = 1
        default: newT = t.clamped(points[index - 1].t + VolumeCurve.minGap, points[index + 1].t - VolumeCurve.minGap)
        }
        let newGain = fixedGain(role, index: index, last: last) ?? gain.clamped(0, 1)
        var updated = points
        updated[index] = CurvePoint(t: newT, gain: newGain)
        return withCurve(spec, role, VolumeCurve(points: updated))
    }

    /// Adds a point on [role]'s curve at [t] (on the curve's current level); no-op at the limit or too close to another point.
    static func addPoint(_ spec: TransitionSpec, _ role: TransitionRole, t: Float) -> TransitionSpec {
        let curve = curveOf(spec, role)
        let points = curve.points
        let fits = points.count < VolumeCurve.maxPoints && t > 0 && t < 1
        guard fits, !points.contains(where: { abs($0.t - t) < VolumeCurve.minGap }) else { return spec }
        let updated = (points + [CurvePoint(t: t, gain: curve.gainAt(t))]).sorted { $0.t < $1.t }
        return withCurve(spec, role, VolumeCurve(points: updated))
    }

    /// Removes an interior point; the end points always stay.
    static func removePoint(_ spec: TransitionSpec, _ role: TransitionRole, index: Int) -> TransitionSpec {
        var points = curveOf(spec, role).points
        guard index > 0, index < points.count - 1 else { return spec }
        points.remove(at: index)
        return withCurve(spec, role, VolumeCurve(points: points))
    }

    /// Gain a point must keep, or nil when it can move: the outgoing track starts full and ends silent, the incoming one ends full.
    static func fixedGain(_ role: TransitionRole, index: Int, last: Int) -> Float? {
        if role == .outgoing && index == 0 { return 1 }
        if role == .outgoing && index == last { return 0 }
        if role == .incoming && index == last { return 1 }
        return nil
    }

    private static func withCurve(_ spec: TransitionSpec, _ role: TransitionRole, _ curve: VolumeCurve) -> TransitionSpec {
        let otherCurve = curveOf(spec, role == .outgoing ? .incoming : .outgoing)
        let outgoing = role == .outgoing ? curve : otherCurve
        let incoming = role == .incoming ? curve : otherCurve
        guard outgoing.isValid(.outgoing), incoming.isValid(.incoming) else { return spec }
        var out = spec
        out.preset = .custom
        out.curve = .custom
        out.outgoingCurve = outgoing
        out.incomingCurve = incoming
        return out
    }
}

/// What the editor is editing.
enum EditorTarget: Equatable {
    case global
    case collection(CollectionRef)
    case pair(StudioPair)
}

/// A preset card in the editor.
enum PresetChoice: Hashable {
    case auto
    case off
    case preset(TransitionPreset)
}

/// Whether the edited level inherits, is off, or has its own transition.
enum EditorMode: Equatable {
    case inherit
    case off
    case custom
}

/// Unsaved editor state. Nothing is written until Save.
struct EditorDraft: Equatable, Identifiable {
    static let undoLimit = 30

    let id = UUID()
    let target: EditorTarget
    var mode: EditorMode
    /// The custom transition being edited (kept while another mode is selected, so switching back loses nothing).
    var spec: TransitionSpec
    /// What the level would play when it inherits.
    let inherited: TransitionSpec?
    let original: TransitionChoice
    var undo: [(EditorMode, TransitionSpec)] = []

    static func == (a: EditorDraft, b: EditorDraft) -> Bool {
        a.id == b.id && a.target == b.target && a.mode == b.mode && a.spec == b.spec && a.inherited == b.inherited
            && a.original == b.original && a.undo.count == b.undo.count
            && zip(a.undo, b.undo).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// A draft for [target] from the saved settings.
    static func open(_ target: EditorTarget, config: TransitionConfig) -> EditorDraft {
        let original: TransitionChoice
        let inherited: TransitionSpec?
        switch target {
        case .global:
            original = config.global.defaultChoice
            inherited = nil
        case .collection(let collection):
            original = config.collection(collection)
            inherited = config.global.defaultChoice.specOrNil
        case .pair(let pair):
            original = config.pair(pair.key)
            inherited = TransitionResolver.collectionDefault(config, collection: pair.key.collection)
        }
        let mode: EditorMode
        switch original {
        case .inherit: mode = .inherit
        case .off: mode = .off
        case .custom: mode = .custom
        }
        let spec = original.specOrNil ?? inherited ?? TransitionSpec()
        return EditorDraft(target: target, mode: mode, spec: spec, inherited: inherited, original: original)
    }

    /// What an edit starts from: the inherited transition while inheriting (so "tweak Auto" works), else this level's own.
    var editBase: TransitionSpec { mode == .inherit ? inherited ?? spec : spec }

    /// What plays with the current choice (nil: no transition).
    var shown: TransitionSpec? {
        switch mode {
        case .inherit: inherited
        case .off: nil
        case .custom: spec
        }
    }

    var choice: TransitionChoice {
        switch mode {
        case .inherit: .inherit
        case .off: .off
        case .custom: .custom(spec)
        }
    }

    var isDirty: Bool { choice != original }

    /// The pair being edited, when the target is one pair.
    var pair: StudioPair? {
        if case .pair(let pair) = target { return pair }
        return nil
    }

    var selectedCard: PresetChoice {
        switch mode {
        case .inherit: .auto
        case .off: .off
        case .custom: .preset(spec.preset)
        }
    }

    /// A preset card: Auto (inherit), Off, or a preset, which becomes this level's own transition.
    mutating func choose(_ card: PresetChoice) {
        record { draft in
            switch card {
            case .auto: draft.mode = .inherit
            case .off: draft.mode = .off
            case .preset(let preset):
                draft.spec = TransitionEditing.applyPreset(draft.editBase, preset)
                draft.mode = .custom
            }
        }
    }

    /// Direct plot interaction and the Custom button share one idempotent activation.
    /// Starting from Auto preserves its inherited automation, EQ, filter and source cues.
    mutating func activateCurveEditing() {
        guard mode != .custom || spec.preset != .custom || spec.curve != .custom else { return }
        edit { TransitionEditing.setCurve($0, .custom) }
    }

    /// One discrete edit (a tap, or the end of a drag), recorded for undo; it makes the level custom.
    mutating func edit(_ transform: (TransitionSpec) -> TransitionSpec) {
        record { draft in
            draft.spec = transform(draft.editBase).sanitized()
            draft.mode = .custom
        }
    }

    /// A drag in progress: updates without filling the undo history; [beginDrag] recorded the state before it.
    mutating func drag(_ transform: (TransitionSpec) -> TransitionSpec) {
        spec = transform(editBase)
        mode = .custom
    }

    mutating func beginDrag() {
        undo = Array((undo + [(mode, spec)]).suffix(Self.undoLimit))
    }

    mutating func undoLast() {
        guard let last = undo.last else { return }
        mode = last.0
        spec = last.1
        undo.removeLast()
    }

    /// Back to the current preset's own settings (or Fade for a custom one).
    mutating func resetToPreset() {
        edit { spec in TransitionEditing.applyPreset(spec, spec.preset == .custom ? .fade : spec.preset) }
    }

    private mutating func record(_ change: (inout EditorDraft) -> Void) {
        var next = self
        change(&next)
        guard next.mode != mode || next.spec != spec else { return }
        next.undo = Array((undo + [(mode, spec)]).suffix(Self.undoLimit))
        self = next
    }
}

extension TransitionSettingsStore {
    /// Writes the draft to its level. The global default is never "inherit": Auto there means off.
    func save(_ draft: EditorDraft) {
        switch draft.target {
        case .global:
            var global = config.global
            global.defaultChoice = draft.mode == .custom ? .custom(draft.spec) : .off
            setGlobal(global)
        case .collection(let collection):
            setCollection(collection, draft.choice)
        case .pair(let pair):
            setPair(pair.key, draft.choice)
        }
    }
}
