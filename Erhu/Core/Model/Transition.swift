import Foundation

/// The kinds of collection that can carry their own transition settings.
enum CollectionKind: String, CaseIterable, Codable, Hashable {
    case album
    case playlist
}

/// A stable reference to an album or playlist: its database id, never a title or list position.
struct CollectionRef: Hashable, Codable {
    let kind: CollectionKind
    let id: Int64

    /// Storage form, e.g. "album:123" (used in settings and on queue entries).
    var key: String { "\(kind.rawValue):\(id)" }

    static func fromKey(_ key: String?) -> CollectionRef? {
        guard let parts = key?.split(separator: ":", omittingEmptySubsequences: false), parts.count == 2,
              let kind = CollectionKind(rawValue: String(parts[0])), let id = Int64(parts[1])
        else { return nil }
        return CollectionRef(kind: kind, id: id)
    }

    static func album(_ id: Int64) -> CollectionRef { CollectionRef(kind: .album, id: id) }
    static func playlist(_ id: Int64) -> CollectionRef { CollectionRef(kind: .playlist, id: id) }
}

/// One occurrence of a song in a collection. Album tracks are unique, so the song id is enough
/// ([slot] nil). A playlist can hold a song more than once: [slot] is the entry's playlist
/// position, which never changes once the entry exists.
struct TrackOccurrence: Hashable, Codable {
    let songId: Int64
    var slot: Int?

    init(_ songId: Int64, _ slot: Int? = nil) {
        self.songId = songId
        self.slot = slot
    }

    var key: String { slot.map { "s\(songId)@\($0)" } ?? "s\(songId)" }

    static func fromKey(_ key: String?) -> TrackOccurrence? {
        guard let key, key.hasPrefix("s") else { return nil }
        let body = key.dropFirst()
        let parts = body.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let songId = Int64(parts[0]) else { return nil }
        if parts.count == 1 { return TrackOccurrence(songId) }
        guard let slot = Int(parts[1]) else { return nil }
        return TrackOccurrence(songId, slot)
    }
}

/// Where a queue entry came from: the collection it was started from and which occurrence it is.
struct QueueOrigin: Hashable, Codable {
    let collection: CollectionRef
    let occurrence: TrackOccurrence

    /// Storage form on queue entries: "playlist:5#s12@3".
    var key: String { "\(collection.key)#\(occurrence.key)" }

    /// Also accepts the older form without an occurrence ("album:7"), with [songId] filled in.
    static func fromKey(_ key: String?, songId: Int64) -> QueueOrigin? {
        guard let key, !key.isEmpty else { return nil }
        let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let collection = CollectionRef.fromKey(String(parts[0])) else { return nil }
        let occurrence = parts.count == 2 ? TrackOccurrence.fromKey(String(parts[1])) : TrackOccurrence(songId)
        return occurrence.map { QueueOrigin(collection: collection, occurrence: $0) }
    }
}

/// One specific transition: from one occurrence to the next, inside one collection. Order matters.
struct TransitionPairKey: Hashable {
    let collection: CollectionRef
    let from: TrackOccurrence
    let to: TrackOccurrence

    var key: String { "\(collection.key)|\(from.key)>\(to.key)" }

    static func fromKey(_ key: String?) -> TransitionPairKey? {
        guard let key else { return nil }
        let halves = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let collection = CollectionRef.fromKey(String(halves[0])), halves.count == 2 else { return nil }
        let pair = halves[1].split(separator: ">", omittingEmptySubsequences: false)
        guard pair.count == 2,
              let from = TrackOccurrence.fromKey(String(pair[0])),
              let to = TrackOccurrence.fromKey(String(pair[1]))
        else { return nil }
        return TransitionPairKey(collection: collection, from: from, to: to)
    }
}

/// Volume curve shape. Equal power keeps the summed power of two unrelated signals steady.
enum TransitionCurve: String, CaseIterable, Codable {
    case linear = "LINEAR"
    case equalPower = "EQUAL_POWER"
    case custom = "CUSTOM"

    var label: String {
        switch self {
        case .linear: "Linear"
        case .equalPower: "Equal power"
        case .custom: "Custom"
        }
    }
}

/// Named starting points. Each one is exactly what the audio engine plays; none is decorative.
enum TransitionPreset: String, CaseIterable, Codable {
    case fade = "FADE"
    case rise = "RISE"
    case bassSwap = "BASS_SWAP"
    case blend = "BLEND"
    case melt = "MELT"
    case slam = "SLAM"
    case custom = "CUSTOM"

    var label: String {
        switch self {
        case .fade: "Fade"
        case .rise: "Rise"
        case .bassSwap: "Bass Swap"
        case .blend: "Blend"
        case .melt: "Melt"
        case .slam: "Slam"
        case .custom: "Custom"
        }
    }
}

/// A point of a volume curve: [t] is the progress through the transition (0..1), [gain] the level (0..1).
struct CurvePoint: Equatable, Codable {
    let t: Float
    let gain: Float
}

/// Which track a curve shapes.
enum TransitionRole {
    case outgoing
    case incoming
}

/// A piecewise-linear volume curve over the transition. Valid curves start at t = 0, end at t = 1,
/// have strictly increasing times, gains within 0..1, and the fixed end levels of their role.
struct VolumeCurve: Equatable, Codable {
    let points: [CurvePoint]

    static let minPoints = 2
    static let maxPoints = 8
    /// Smallest time step between neighbouring points (1 % of the transition).
    static let minGap: Float = 0.01
    private static let gapTolerance: Float = 1e-4

    func gainAt(_ t: Float) -> Float {
        let x = t.clamped(0, 1)
        guard let after = points.firstIndex(where: { $0.t >= x }), after > 0 else { return points[0].gain }
        let a = points[after - 1]
        let b = points[after]
        return a.gain + (b.gain - a.gain) * (x - a.t) / (b.t - a.t)
    }

    func isValid(_ role: TransitionRole) -> Bool {
        guard (Self.minPoints...Self.maxPoints).contains(points.count),
              points.first!.t == 0, points.last!.t == 1,
              !points.contains(where: { !$0.t.isFinite || !$0.gain.isFinite || !(0...1).contains($0.gain) }),
              !zip(points, points.dropFirst()).contains(where: { a, b in b.t - a.t < Self.minGap - Self.gapTolerance })
        else { return false }
        switch role {
        case .outgoing: return points.first!.gain == 1 && points.last!.gain == 0
        case .incoming: return points.last!.gain == 1
        }
    }

    static func of(_ points: (Float, Float)...) -> VolumeCurve {
        VolumeCurve(points: points.map { CurvePoint(t: $0.0, gain: $0.1) })
    }

    /// Points that follow [curve] for [role], for drawing and as the start of a custom edit.
    static func sampled(_ curve: TransitionCurve, role: TransitionRole, count: Int = 5) -> VolumeCurve {
        VolumeCurve(points: (0..<count).map { i in
            let t = Float(i) / Float(count - 1)
            return CurvePoint(t: t, gain: CurveMath.gain(curve, role: role, t: t))
        })
    }
}

/// Gain formulas of the built-in curves.
enum CurveMath {
    static func gain(_ curve: TransitionCurve, role: TransitionRole, t: Float) -> Float {
        let x = t.clamped(0, 1)
        // Exact end levels (cos(pi/2) is not exactly 0 in floating point).
        if x == 0 { return role == .incoming ? 0 : 1 }
        if x == 1 { return role == .incoming ? 1 : 0 }
        switch role {
        case .incoming:
            return curve == .equalPower ? Float(sin(Double(x) * .pi / 2)) : x
        case .outgoing:
            return curve == .equalPower ? Float(cos(Double(x) * .pi / 2)) : 1 - x
        }
    }
}

/// Filter type of a filter sweep.
enum PassType: Equatable {
    case highPass
    case lowPass
}

/// A filter at one moment of a transition: [type] at cutoff [hz].
struct FilterSetting: Equatable {
    let type: PassType
    let hz: Float
}

/// Filter sweeps a transition can play, each on the track(s) it names. A high-pass "in" thins the
/// incoming track at first and opens it up by the middle; a high-pass "out" thins the outgoing
/// track through the second half; a low-pass "out" darkens it.
enum TransitionFilter: String, CaseIterable, Codable {
    case none = "NONE"
    case highPassIn = "HIGH_PASS_IN"
    case highPassOut = "HIGH_PASS_OUT"
    case highPassInOut = "HIGH_PASS_IN_OUT"
    case highPassInLowPassOut = "HIGH_PASS_IN_LOW_PASS_OUT"
    case lowPassOut = "LOW_PASS_OUT"

    /// High-pass cutoffs: 20 Hz is practically open, 1.5 kHz leaves only the top of the mix.
    static let highPassOpenHz: Float = 20
    static let highPassThinHz: Float = 1_500
    /// Low-pass cutoffs (the processor caps the open value below the Nyquist frequency).
    static let lowPassOpenHz: Float = 18_000
    static let lowPassDarkHz: Float = 350
    private static let half: Float = 0.5

    var label: String {
        switch self {
        case .none: "None"
        case .highPassIn: "High-pass in"
        case .highPassOut: "High-pass out"
        case .highPassInOut: "High-pass in, high-pass out"
        case .highPassInLowPassOut: "High-pass in, low-pass out"
        case .lowPassOut: "Low-pass out"
        }
    }

    private var incomingHighPass: Bool { self == .highPassIn || self == .highPassInOut || self == .highPassInLowPassOut }
    private var outgoingHighPass: Bool { self == .highPassOut || self == .highPassInOut }
    private var outgoingLowPass: Bool { self == .lowPassOut || self == .highPassInLowPassOut }

    /// Whether [role]'s track is filtered at all.
    func affects(_ role: TransitionRole) -> Bool {
        role == .incoming ? incomingHighPass : outgoingHighPass || outgoingLowPass
    }

    /// The filter on [role]'s track at progress [t], or nil when that track is not filtered. While a
    /// track is filtered the filter stays in (at a transparent cutoff outside its sweep).
    func settingAt(_ role: TransitionRole, _ t: Float) -> FilterSetting? {
        let x = t.clamped(0, 1)
        let h = Self.half
        if role == .incoming && incomingHighPass {
            return FilterSetting(type: .highPass, hz: Self.sweep(Self.highPassThinHz, Self.highPassOpenHz, x / h))
        }
        if role == .outgoing && outgoingHighPass {
            return FilterSetting(type: .highPass, hz: Self.sweep(Self.highPassOpenHz, Self.highPassThinHz, (x - h) / h))
        }
        if role == .outgoing && outgoingLowPass {
            return FilterSetting(type: .lowPass, hz: Self.sweep(Self.lowPassOpenHz, Self.lowPassDarkHz, (x - h) / h))
        }
        return nil
    }

    /// Exponential (even in pitch) from [from] to [to] as [u] goes 0..1; held at the ends.
    static func sweep(_ from: Float, _ to: Float, _ u: Float) -> Float {
        from * pow(to / from, u.clamped(0, 1))
    }
}

/// One transition's full description, in the form the playback engine executes.
struct TransitionSpec: Equatable, Codable {
    var durationMs: Int = TransitionSpec.defaultDurationMs
    var preset: TransitionPreset = .fade
    var curve: TransitionCurve = .equalPower
    /// Used when [curve] is custom.
    var outgoingCurve: VolumeCurve?
    var incomingCurve: VolumeCurve?
    var bassSwap = false
    var bassSwapAt: Float = TransitionSpec.defaultBassSwapAt
    /// Filter sweep on one or both tracks.
    var filter: TransitionFilter = .none
    /// Optional direct-manipulation overrides. Missing fields preserve every existing preset.
    var incomingFilterAt: Float?
    var outgoingFilterAt: Float?
    var incomingFilterHz: Float?
    var outgoingFilterHz: Float?
    /// Cue points (per pair): how much of the outgoing track's end is skipped, and where the incoming track starts.
    var outgoingCutMs = 0
    var incomingStartMs = 0

    static let durationPresetsMs = [500, 1_000, 2_000, 4_000, 6_000, 8_000]
    static let defaultDurationMs = 2_000
    static let minDurationMs = 500
    static let maxDurationMs = 12_000
    /// Cue points are kept within an hour; the planner fits them to the actual tracks.
    static let maxCueMs = 3_600_000
    static let durationStepMs = 100
    static let bassCutDb: Float = -24
    static let bassShelfHz: Float = 200
    /// The bass changes hands over this share of the transition, centred on the swap point.
    static let bassRamp: Float = 0.1
    static let defaultBassSwapAt: Float = 0.5
    static let minBassSwapAt: Float = 0.1
    static let maxBassSwapAt: Float = 0.9

    /// Never more than half of what plays of either track, so a transition never takes over a whole short track.
    func effectiveDurationMs(outgoingDurationMs: Int64, incomingDurationMs: Int64) -> Int {
        let outgoingPlayed = max(outgoingDurationMs - Int64(outgoingCutMs), 0)
        let incomingPlayed = max(incomingDurationMs - Int64(incomingStartMs), 0)
        return Int(min(Int64(durationMs), outgoingPlayed / 2, incomingPlayed / 2))
    }

    /// Where in the outgoing track the transition ends (its end, minus the cut).
    func outgoingEndMs(_ outgoingDurationMs: Int64) -> Int64 {
        max(outgoingDurationMs - Int64(outgoingCutMs), 0)
    }

    func gain(_ role: TransitionRole, _ t: Float) -> Float {
        let custom = role == .outgoing ? outgoingCurve : incomingCurve
        if curve == .custom, let custom { return custom.gainAt(t) }
        return CurveMath.gain(curve, role: role, t: t)
    }

    /// Low-shelf gain in dB for [role] at [t], or 0 without a bass swap.
    func bassDb(_ role: TransitionRole, _ t: Float) -> Float {
        guard bassSwap else { return 0 }
        let ramp = ((t - (bassSwapAt - Self.bassRamp / 2)) / Self.bassRamp).clamped(0, 1)
        return role == .outgoing ? Self.bassCutDb * ramp : Self.bassCutDb * (1 - ramp)
    }

    func filterKnee(_ role: TransitionRole) -> (t: Float, hz: Float)? {
        guard filter.affects(role), let start = filter.settingAt(role, 0), let end = filter.settingAt(role, 1) else { return nil }
        let at = role == .incoming ? incomingFilterAt : outgoingFilterAt
        let hz = role == .incoming ? incomingFilterHz : outgoingFilterHz
        return ((at ?? 0.5).clamped(0.05, 0.95), (hz ?? (role == .incoming ? end.hz : start.hz)).clamped(20, 18_000))
    }

    func filterSetting(_ role: TransitionRole, _ t: Float) -> FilterSetting? {
        let at = role == .incoming ? incomingFilterAt : outgoingFilterAt
        let hz = role == .incoming ? incomingFilterHz : outgoingFilterHz
        guard at != nil || hz != nil else { return filter.settingAt(role, t) }
        guard let knee = filterKnee(role), let start = filter.settingAt(role, 0), let end = filter.settingAt(role, 1) else { return nil }
        let value = t <= knee.t
            ? TransitionFilter.sweep(start.hz, knee.hz, t / knee.t)
            : TransitionFilter.sweep(knee.hz, end.hz, (t - knee.t) / (1 - knee.t))
        return FilterSetting(type: start.type, hz: value)
    }

    /// A valid version of this spec: duration clamped and rounded, broken custom curves replaced.
    func sanitized() -> TransitionSpec {
        var clean = self
        clean.durationMs = Self.clampDuration(durationMs)
        clean.bassSwapAt = bassSwapAt.isFinite ? bassSwapAt.clamped(Self.minBassSwapAt, Self.maxBassSwapAt) : Self.defaultBassSwapAt
        clean.outgoingCutMs = outgoingCutMs.clamped(0, Self.maxCueMs)
        clean.incomingStartMs = incomingStartMs.clamped(0, Self.maxCueMs)
        clean.incomingFilterAt = incomingFilterAt.flatMap { $0.isFinite ? $0.clamped(0.05, 0.95) : nil }
        clean.outgoingFilterAt = outgoingFilterAt.flatMap { $0.isFinite ? $0.clamped(0.05, 0.95) : nil }
        clean.incomingFilterHz = incomingFilterHz.flatMap { $0.isFinite ? $0.clamped(20, 18_000) : nil }
        clean.outgoingFilterHz = outgoingFilterHz.flatMap { $0.isFinite ? $0.clamped(20, 18_000) : nil }
        let customValid = curve == .custom
            && outgoingCurve?.isValid(.outgoing) == true
            && incomingCurve?.isValid(.incoming) == true
        if customValid { return clean }
        if curve == .custom { clean.curve = .equalPower }
        clean.outgoingCurve = nil
        clean.incomingCurve = nil
        return clean
    }

    static func clampDuration(_ ms: Int) -> Int {
        let steps = (Float(ms) / Float(durationStepMs) + 0.5).rounded(.down)
        return (Int(steps) * durationStepMs).clamped(minDurationMs, maxDurationMs)
    }

    /// "0.5 s", "2 s", "2.4 s".
    static func durationLabel(_ ms: Int) -> String {
        ms % 1000 == 0 ? "\(ms / 1000) s" : "\(Double(ms) / 1000) s"
    }

    /// The spec a preset starts from, keeping [base]'s duration. Every preset uses only what the engine plays.
    static func preset(_ preset: TransitionPreset, base: TransitionSpec = TransitionSpec()) -> TransitionSpec {
        // Cue points belong to the pair, not to the preset: they are kept.
        let plain = TransitionSpec(
            durationMs: base.durationMs, preset: preset,
            outgoingCutMs: base.outgoingCutMs, incomingStartMs: base.incomingStartMs
        )
        switch preset {
        case .fade:
            var spec = plain
            spec.curve = base.curve == .custom ? .equalPower : base.curve
            return spec
        case .rise:
            var spec = plain
            spec.curve = .custom
            spec.outgoingCurve = .of((0, 1), (0.6, 0.9), (1, 0))
            spec.incomingCurve = .of((0, 0), (0.4, 0.8), (1, 1))
            spec.filter = .highPassIn
            return spec
        case .bassSwap:
            return EqMove.centerBassSwap.applyTo(plain)
        case .blend:
            var spec = VolumeShape.overlap.applyTo(EqMove.centerBassSwap.applyTo(plain))
            spec.filter = .highPassInOut
            return spec
        case .melt:
            var spec = plain
            spec.filter = .lowPassOut
            return spec
        case .slam:
            return VolumeShape.centerCut.applyTo(plain)
        case .custom:
            var spec = base
            spec.preset = preset
            spec.curve = .custom
            let builtIn: TransitionCurve = base.curve == .custom ? .equalPower : base.curve
            spec.outgoingCurve = base.outgoingCurve ?? VolumeCurve.sampled(builtIn, role: .outgoing)
            spec.incomingCurve = base.incomingCurve ?? VolumeCurve.sampled(builtIn, role: .incoming)
            return spec
        }
    }
}

/// Named volume shapes offered in the editor. Each produces the two curves the engine plays.
enum VolumeShape: String, CaseIterable {
    case crossfade = "CROSSFADE"
    case linear = "LINEAR"
    case overlap = "OVERLAP"
    case fadeOutThenIn = "FADE_OUT_THEN_IN"
    case cutInFadeOut = "CUT_IN_FADE_OUT"
    case fadeInCutOut = "FADE_IN_CUT_OUT"
    case centerCut = "CENTER_CUT"

    var label: String {
        switch self {
        case .crossfade: "Crossfade"
        case .linear: "Linear crossfade"
        case .overlap: "Overlap"
        case .fadeOutThenIn: "Fade out, then in"
        case .cutInFadeOut: "Cut in, fade out"
        case .fadeInCutOut: "Fade in, cut out"
        case .centerCut: "Center cut"
        }
    }

    /// [spec] with this shape's volume curves; everything else is kept.
    func applyTo(_ spec: TransitionSpec) -> TransitionSpec {
        var out = spec
        switch self {
        case .crossfade:
            out.curve = .equalPower
            out.outgoingCurve = nil
            out.incomingCurve = nil
        case .linear:
            out.curve = .linear
            out.outgoingCurve = nil
            out.incomingCurve = nil
        case .overlap:
            out = Self.custom(spec, out: [(0, 1), (0.97, 1), (1, 0)], inc: [(0, 0), (0.03, 1), (1, 1)])
        case .fadeOutThenIn:
            out = Self.custom(spec, out: [(0, 1), (0.5, 0), (1, 0)], inc: [(0, 0), (0.5, 0), (1, 1)])
        case .cutInFadeOut:
            out = Self.custom(spec, out: [(0, 1), (1, 0)], inc: [(0, 1), (1, 1)])
        case .fadeInCutOut:
            out = Self.custom(spec, out: [(0, 1), (0.97, 1), (1, 0)], inc: [(0, 0), (1, 1)])
        case .centerCut:
            out = Self.custom(spec, out: [(0, 1), (0.48, 1), (0.52, 0), (1, 0)], inc: [(0, 0), (0.48, 0), (0.52, 1), (1, 1)])
        }
        return out
    }

    /// The named shape [spec]'s volume curves match, or nil for hand-edited curves.
    static func of(_ spec: TransitionSpec) -> VolumeShape? {
        allCases.first { shape in
            let shaped = shape.applyTo(spec)
            return shaped.curve == spec.curve && shaped.outgoingCurve == spec.outgoingCurve && shaped.incomingCurve == spec.incomingCurve
        }
    }

    private static func custom(_ spec: TransitionSpec, out: [(Float, Float)], inc: [(Float, Float)]) -> TransitionSpec {
        var shaped = spec
        shaped.curve = .custom
        shaped.outgoingCurve = VolumeCurve(points: out.map { CurvePoint(t: $0.0, gain: $0.1) })
        shaped.incomingCurve = VolumeCurve(points: inc.map { CurvePoint(t: $0.0, gain: $0.1) })
        return shaped
    }
}

/// EQ moves offered in the editor: the bass swap and where it happens.
enum EqMove: String, CaseIterable {
    case none = "NONE"
    case startBassSwap = "START_BASS_SWAP"
    case centerBassSwap = "CENTER_BASS_SWAP"
    case endBassSwap = "END_BASS_SWAP"

    var label: String {
        switch self {
        case .none: "None"
        case .startBassSwap: "Start bass swap"
        case .centerBassSwap: "Center bass swap"
        case .endBassSwap: "End bass swap"
        }
    }

    /// Swap point, or nil for no bass swap.
    var swapAt: Float? {
        switch self {
        case .none: nil
        case .startBassSwap: 0.15
        case .centerBassSwap: 0.5
        case .endBassSwap: 0.85
        }
    }

    func applyTo(_ spec: TransitionSpec) -> TransitionSpec {
        var out = spec
        if let swapAt {
            out.bassSwap = true
            out.bassSwapAt = swapAt
        } else {
            out.bassSwap = false
        }
        return out
    }

    /// The named move [spec] matches, or nil for a custom swap point.
    static func of(_ spec: TransitionSpec) -> EqMove? {
        spec.bassSwap ? allCases.first { $0.swapAt == spec.bassSwapAt } : EqMove.none
    }
}

/// A level's setting: follow the level above, no transition, or this transition.
enum TransitionChoice: Equatable, Codable {
    case inherit
    case off
    case custom(TransitionSpec)

    var specOrNil: TransitionSpec? {
        if case .custom(let spec) = self { return spec }
        return nil
    }
}

/// The app-wide part. [masterEnabled] off disables every automatic transition. [defaultChoice] is
/// off or custom, never inherit. Nothing crossfades until a collection is set up.
struct GlobalTransitionSettings: Equatable, Codable {
    var masterEnabled = true
    var defaultChoice: TransitionChoice = .off
}

/// Everything the resolver needs. Collections and pairs missing from the maps inherit.
struct TransitionConfig: Equatable {
    var global = GlobalTransitionSettings()
    var collections: [CollectionRef: TransitionChoice] = [:]
    var pairs: [TransitionPairKey: TransitionChoice] = [:]

    func collection(_ ref: CollectionRef) -> TransitionChoice { collections[ref] ?? .inherit }
    func pair(_ key: TransitionPairKey) -> TransitionChoice { pairs[key] ?? .inherit }
}

/// Which level decided a boundary.
enum TransitionSource {
    case masterOff
    case pair
    case collection
    case globalDefault
}

struct ResolvedTransition: Equatable {
    /// The transition to play, or nil for the normal (gapless) boundary.
    let spec: TransitionSpec?
    let source: TransitionSource
}

/// Precedence: the master switch, then the exact pair, then the collection, then the global
/// default. A level set to Off stops there. Only a boundary between two entries started from the
/// same collection uses that collection's pair and collection settings.
enum TransitionResolver {
    static func resolve(_ config: TransitionConfig, outgoing: QueueOrigin?, incoming: QueueOrigin?) -> ResolvedTransition {
        guard config.global.masterEnabled else { return ResolvedTransition(spec: nil, source: .masterOff) }
        if let outgoing, let incoming, outgoing.collection == incoming.collection {
            let collection = outgoing.collection
            let pair = config.pair(TransitionPairKey(collection: collection, from: outgoing.occurrence, to: incoming.occurrence))
            if pair != .inherit { return ResolvedTransition(spec: pair.specOrNil, source: .pair) }
            let own = config.collection(collection)
            if own != .inherit { return ResolvedTransition(spec: own.specOrNil, source: .collection) }
        }
        return ResolvedTransition(spec: config.global.defaultChoice.specOrNil, source: .globalDefault)
    }

    /// What a collection's pairs inherit: its own choice, or the global default.
    static func collectionDefault(_ config: TransitionConfig, collection: CollectionRef) -> TransitionSpec? {
        guard config.global.masterEnabled else { return nil }
        let own = config.collection(collection)
        return own == .inherit ? config.global.defaultChoice.specOrNil : own.specOrNil
    }
}
