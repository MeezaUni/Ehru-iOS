import SwiftUI

/// The transition editor for one level (all music, a whole collection, or one pair). Edits stay in
/// the draft until Save; Cancel or a swipe on an unchanged draft discards them.
struct TransitionEditorView: View {
    @Binding var draft: EditorDraft?
    let noun: String
    @Environment(TransitionSettingsStore.self) private var transitions
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            if let current = draft {
                content(current)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbar(current) }
                    .interactiveDismissDisabled(current.isDirty)
            }
        }
        .presentationDetents([.large])
    }

    private func content(_ current: EditorDraft) -> some View {
        let base = current.shown ?? current.editBase
        let pair = current.pair
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if let pair {
                    EditorTrackLine(role: "Outgoing", song: pair.from.song, cue: outgoingCue(base, pair))
                }
                TransitionLanes(spec: base, active: current.shown != nil,
                                beginDrag: { draft?.beginDrag() },
                                drag: { transform in draft?.drag(transform) },
                                edit: { transform in draft?.edit(transform) })
                DurationBlock(spec: current.shown, base: current.editBase, pair: pair,
                              beginDrag: { draft?.beginDrag() },
                              drag: { ms in draft?.drag { TransitionEditing.setDuration($0, ms) } },
                              choose: { ms in draft?.edit { TransitionEditing.setDuration($0, ms) } })
                if let pair {
                    EditorTrackLine(role: "Incoming", song: pair.to.song, cue: incomingCue(base))
                }
                PresetCards(current: current) { draft?.choose($0) }
                Text(statusLine(current)).font(.caption).foregroundStyle(palette.onSurfaceVariant)
                sections(current)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effects, looping, beatmatching").font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
                    Text("Not available: the audio engine has no echo, reverb or loop stage, and your library has no BPM or beat data.")
                        .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                }
                .padding(.top, Spacing.xs)
            }
            .padding(Spacing.lg)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ current: EditorDraft) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { draft = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Cancel and discard changes")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text("Transition").font(.headline)
                Text(targetLabel(current.target)).font(.caption).foregroundStyle(palette.onSurfaceVariant)
            }
        }
        ToolbarItemGroup(placement: .confirmationAction) {
            Menu {
                Button { draft?.undoLast() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(current.undo.isEmpty)
                if case .pair = current.target {
                    Button { draft?.edit { spec in
                        var reset = spec
                        reset.outgoingCutMs = 0
                        reset.incomingStartMs = 0
                        return reset
                    } } label: { Label("Reset cue points", systemImage: "arrow.left.and.right") }
                }
                Button { draft?.resetToPreset() } label: { Label("Reset to preset", systemImage: "arrow.counterclockwise") }
                    .disabled(current.mode != .custom)
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("More options")
            Button("Save") {
                transitions.save(current)
                draft = nil
            }
            .disabled(!current.isDirty)
        }
    }

    private func targetLabel(_ target: EditorTarget) -> String {
        switch target {
        case .global: "All music"
        case .collection: "Whole \(noun)"
        case .pair: "This transition"
        }
    }

    private func statusLine(_ current: EditorDraft) -> String {
        switch current.mode {
        case .inherit: "Follows the level above: \(specSummary(current.inherited)). Change anything below to make it its own."
        case .off: "Off here, even if a more general setting has a crossfade: the tracks play back to back."
        case .custom: "Its own transition: \(specSummary(current.spec))."
        }
    }

    private func outgoingCue(_ spec: TransitionSpec, _ pair: StudioPair) -> String? {
        spec.outgoingCutMs > 0 ? "Hands over at \(formatDuration(spec.outgoingEndMs(pair.from.song.durationMs)))" : nil
    }

    private func incomingCue(_ spec: TransitionSpec) -> String? {
        spec.incomingStartMs > 0 ? "Starts at \(formatDuration(Int64(spec.incomingStartMs)))" : nil
    }

    @ViewBuilder
    private func sections(_ current: EditorDraft) -> some View {
        let shown = current.shown
        let base = current.editBase
        VStack(spacing: 0) {
            Menu {
                ForEach(VolumeShape.allCases, id: \.self) { shape in
                    Button { draft?.edit { TransitionEditing.setVolumeShape($0, shape) } } label: {
                        checked(shape.label, shown.flatMap { VolumeShape.of($0) } == shape)
                    }
                }
                Divider()
                Button { draft?.edit { TransitionEditing.setCurve($0, .custom) } } label: {
                    Label("Customize curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            } label: {
                SectionRow(title: "Volume", color: AutomationColors.volume,
                           value: shown.map { VolumeShape.of($0)?.label ?? "Custom curve" } ?? "None")
            }
            Divider()
            Menu {
                ForEach(EqMove.allCases, id: \.self) { move in
                    Button { draft?.edit { TransitionEditing.setEqMove($0, move) } } label: {
                        checked(move.label, shown.flatMap { EqMove.of($0) } == move)
                    }
                }
            } label: {
                SectionRow(title: "EQ", color: AutomationColors.eq,
                           value: shown.map { EqMove.of($0)?.label ?? "Bass swap at \(percent($0.bassSwapAt)) %" } ?? "None")
            }
            if base.bassSwap && shown != nil {
                BassSwapSlider(value: base.bassSwapAt,
                               begin: { draft?.beginDrag() },
                               change: { at in draft?.drag { TransitionEditing.setBassSwapAt($0, at) } })
                    .padding(.bottom, Spacing.sm)
            }
            Divider()
            Menu {
                ForEach(TransitionFilter.allCases, id: \.self) { filter in
                    Button { draft?.edit { TransitionEditing.setFilter($0, filter) } } label: {
                        checked(filter.label, shown?.filter == filter)
                    }
                }
            } label: {
                SectionRow(title: "Filter", color: AutomationColors.filter, value: shown?.filter.label ?? "None")
            }
        }
        .padding(.horizontal, Spacing.md)
        .background(palette.surfaceVariant.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func checked(_ label: String, _ selected: Bool) -> some View {
        if selected { Label(label, systemImage: "checkmark") } else { Text(label) }
    }
}

func percent(_ value: Float) -> Int { Int((value * 100).rounded()) }

private struct SectionRow: View {
    let title: String
    let color: Color
    let value: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.md) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurface)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Change \(title)")
    }
}

private struct BassSwapSlider: View {
    let value: Float
    let begin: () -> Void
    let change: (Float) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Bass swap at \(percent(value)) % of the transition").font(.caption)
            Slider(value: Binding(get: { Double(value) }, set: { change(Float($0)) }),
                   in: Double(TransitionSpec.minBassSwapAt)...Double(TransitionSpec.maxBassSwapAt), step: 0.01) { editing in
                if editing { begin() }
            }
            .tint(AutomationColors.eq)
            Text("The incoming track's bass (below \(Int(TransitionSpec.bassShelfHz)) Hz) is held down until the swap point, then moves over from the outgoing track. Your equalizer settings are not changed.")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
        }
    }
}

private struct EditorTrackLine: View {
    let role: String
    let song: Song
    let cue: String?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.sm) {
            SongArtworkView(song: song, maxPixels: 96)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(role.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(palette.onSurfaceVariant)
                Text(song.title).font(.subheadline).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let cue { Text(cue).font(.caption).foregroundStyle(palette.onSurfaceVariant) }
        }
    }
}

/// Duration: the requested length, what these two tracks allow, quick choices and fine control.
private struct DurationBlock: View {
    let spec: TransitionSpec?
    let base: TransitionSpec
    let pair: StudioPair?
    let beginDrag: () -> Void
    let drag: (Int) -> Void
    let choose: (Int) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let requested = (spec ?? base).durationMs
        let effective = pair.map {
            (spec ?? base).effectiveDurationMs(outgoingDurationMs: $0.from.song.durationMs, incomingDurationMs: $0.to.song.durationMs)
        }
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Duration").font(.subheadline.weight(.semibold))
                Spacer()
                Text(spec == nil ? "None" : TransitionSpec.durationLabel(requested)).font(.subheadline.monospacedDigit())
            }
            if spec != nil, let effective, effective < requested {
                Text("Shortened to \(TransitionSpec.durationLabel(max(effective, 0))) for these tracks")
                    .font(.caption).foregroundStyle(palette.onSurfaceVariant)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(TransitionSpec.durationPresetsMs, id: \.self) { ms in
                        let selected = spec != nil && requested == ms
                        Button { choose(ms) } label: {
                            Text(TransitionSpec.durationLabel(ms))
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, 6)
                                .foregroundStyle(selected ? palette.onPrimary : palette.onSurface)
                                .background(selected ? palette.primary : palette.surfaceVariant, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Slider(value: Binding(get: { Double(base.durationMs) }, set: { drag(Int($0)) }),
                   in: Double(TransitionSpec.minDurationMs)...Double(TransitionSpec.maxDurationMs),
                   step: Double(TransitionSpec.durationStepMs)) { editing in
                if editing { beginDrag() }
            }
            .accessibilityLabel("Duration")
            Text("Choose how long the tracks overlap. A transition never takes more than half of either track.")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
        }
    }
}

/// The preset cards: Auto (or Default), Off, every preset, and Custom when that is what is edited.
private struct PresetCards: View {
    let current: EditorDraft
    let onChoose: (PresetChoice) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let selected = current.selectedCard
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Presets").font(.subheadline.weight(.semibold)).foregroundStyle(palette.onSurfaceVariant)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(cards) { card in
                        let choice = card.choice
                        let label = card.label
                        let isSelected = choice == selected
                        Button {
                            // Custom is where edits land; tapping it again changes nothing.
                            if choice != .preset(.custom) { onChoose(choice) }
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                if choice == .auto { Image(systemName: "sparkles").font(.footnote) }
                                Text(label).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            .frame(width: 104, height: 52)
                            .foregroundStyle(isSelected ? palette.onPrimary : palette.onSurface)
                            .background(isSelected ? palette.primary : palette.surfaceVariant,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressScaleStyle())
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private struct Card: Identifiable {
        let choice: PresetChoice
        let label: String
        var id: String { label }
    }

    private var cards: [Card] {
        var cards: [Card] = []
        switch current.target {
        case .global: break
        case .collection: cards.append(Card(choice: .auto, label: "Default"))
        case .pair: cards.append(Card(choice: .auto, label: "Auto"))
        }
        cards.append(Card(choice: .off, label: "Off"))
        for preset in TransitionPreset.allCases where preset != .custom {
            cards.append(Card(choice: .preset(preset), label: preset.label))
        }
        if current.mode == .custom && current.spec.preset == .custom {
            cards.append(Card(choice: .preset(.custom), label: "Custom"))
        }
        return cards
    }
}

/// The automation lanes of one transition over its length: volume curves of both tracks (drag a
/// point, tap the lane to add one, select an inner point to remove it), the bass swap point
/// (drag it), and the filter sweeps.
private struct TransitionLanes: View {
    let spec: TransitionSpec
    /// False when the level is off: the lanes show what an edit would start from, dimmed.
    let active: Bool
    let beginDrag: () -> Void
    let drag: ((TransitionSpec) -> TransitionSpec) -> Void
    let edit: ((TransitionSpec) -> TransitionSpec) -> Void
    @Environment(\.palette) private var palette
    @State private var dragging: (role: TransitionRole, index: Int, began: Bool)?
    @State private var selected: (role: TransitionRole, index: Int)?
    @State private var swapDragging = false

    private static let volumeHeight: CGFloat = 150
    private static let laneHeight: CGFloat = 40
    private static let hitRadius: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            laneTitle("Volume", AutomationColors.volume)
            volumeLane
            if let selected, isRemovable(selected) {
                Button(role: .destructive) {
                    edit { TransitionEditing.removePoint($0, selected.role, index: selected.index) }
                    self.selected = nil
                } label: { Label("Remove point", systemImage: "minus.circle") }
                .font(.caption)
            }
            laneTitle("EQ", AutomationColors.eq)
            eqLane
            laneTitle("Filter", AutomationColors.filter)
            filterLane
            HStack {
                Text("0 s")
                Spacer()
                Text(TransitionSpec.durationLabel(spec.durationMs))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(palette.onSurfaceVariant)
            Text("Drag the points · tap the lane to add one · select an inner point to remove it")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
        }
        .opacity(active ? 1 : 0.45)
    }

    private func laneTitle(_ title: String, _ color: Color) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
    }

    private func isRemovable(_ point: (role: TransitionRole, index: Int)) -> Bool {
        let count = TransitionEditing.curveOf(spec, point.role).points.count
        return point.index > 0 && point.index < count - 1
    }

    private var volumeLane: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, _ in
                drawGrid(context, size)
                for role in [TransitionRole.outgoing, .incoming] {
                    let points = TransitionEditing.curveOf(spec, role).points
                    var path = Path()
                    for (i, point) in points.enumerated() {
                        let p = position(point, size)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    let style = role == .outgoing
                        ? StrokeStyle(lineWidth: 2.5, lineJoin: .round)
                        : StrokeStyle(lineWidth: 2.5, lineJoin: .round, dash: [6, 4])
                    context.stroke(path, with: .color(AutomationColors.volume), style: style)
                    for (i, point) in points.enumerated() {
                        let p = position(point, size)
                        let isSelected = selected.map { $0.role == role && $0.index == i } ?? false
                        let radius: CGFloat = isSelected ? 8 : 5.5
                        let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
                        context.fill(dot, with: .color(role == .outgoing ? AutomationColors.volume : palette.surface))
                        context.stroke(dot, with: .color(AutomationColors.volume), lineWidth: 2)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(volumeGesture(size))
        }
        .frame(height: Self.volumeHeight)
        .background(palette.surfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) {
            HStack(spacing: Spacing.sm) {
                legend("Out", dashed: false)
                legend("In", dashed: true)
            }
            .padding(6)
        }
        .accessibilityElement()
        .accessibilityLabel("Volume curves")
        .accessibilityValue(VolumeShape.of(spec)?.label ?? "Custom curve")
    }

    private func legend(_ label: String, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 14, y: 4))
            }
            .stroke(AutomationColors.volume, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
            .frame(width: 14, height: 8)
            Text(label).font(.caption2).foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        for fraction in [0.25, 0.5, 0.75] {
            var line = Path()
            line.move(to: CGPoint(x: size.width * fraction, y: 0))
            line.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            context.stroke(line, with: .color(palette.outline.opacity(0.35)), lineWidth: 1)
        }
    }

    private func inset(_ size: CGSize) -> CGRect { CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10) }

    private func position(_ point: CurvePoint, _ size: CGSize) -> CGPoint {
        let box = inset(size)
        return CGPoint(x: box.minX + CGFloat(point.t) * box.width, y: box.maxY - CGFloat(point.gain) * box.height)
    }

    private func value(_ location: CGPoint, _ size: CGSize) -> (t: Float, gain: Float) {
        let box = inset(size)
        let t = Float((location.x - box.minX) / max(box.width, 1))
        let gain = Float((box.maxY - location.y) / max(box.height, 1))
        return (t.clamped(0, 1), gain.clamped(0, 1))
    }

    private func nearest(_ location: CGPoint, _ size: CGSize) -> (role: TransitionRole, index: Int)? {
        var best: (role: TransitionRole, index: Int, distance: CGFloat)?
        for role in [TransitionRole.outgoing, .incoming] {
            for (i, point) in TransitionEditing.curveOf(spec, role).points.enumerated() {
                let p = position(point, size)
                let distance = hypot(p.x - location.x, p.y - location.y)
                if distance <= Self.hitRadius && distance < (best?.distance ?? .infinity) { best = (role, i, distance) }
            }
        }
        return best.map { ($0.role, $0.index) }
    }

    private func volumeGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragging == nil, let hit = nearest(gesture.startLocation, size) {
                    dragging = (hit.role, hit.index, false)
                }
                guard let current = dragging else { return }
                let moved = hypot(gesture.translation.width, gesture.translation.height) > 4
                guard moved else { return }
                if !current.began {
                    beginDrag()
                    dragging = (current.role, current.index, true)
                    selected = nil
                }
                let target = value(gesture.location, size)
                drag { TransitionEditing.movePoint($0, current.role, index: current.index, t: target.t, gain: target.gain) }
            }
            .onEnded { gesture in
                defer { dragging = nil }
                if let current = dragging {
                    if !current.began { selected = (current.role, current.index) }
                    return
                }
                guard hypot(gesture.translation.width, gesture.translation.height) <= 4 else { return }
                // A tap away from the points adds one to the curve nearest the tap.
                let tap = value(gesture.location, size)
                let outGap = abs(TransitionEditing.curveOf(spec, .outgoing).gainAt(tap.t) - tap.gain)
                let inGap = abs(TransitionEditing.curveOf(spec, .incoming).gainAt(tap.t) - tap.gain)
                let role: TransitionRole = outGap <= inGap ? .outgoing : .incoming
                selected = nil
                edit { TransitionEditing.addPoint($0, role, t: tap.t) }
            }
    }

    private var eqLane: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let box = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 10, dy: 0)
            ZStack(alignment: .leading) {
                Rectangle().fill(palette.outline.opacity(0.5)).frame(height: 1)
                if spec.bassSwap {
                    let x = box.minX + CGFloat(spec.bassSwapAt) * box.width
                    let ramp = CGFloat(TransitionSpec.bassRamp) * box.width
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AutomationColors.eq.opacity(0.25))
                        .frame(width: ramp, height: Self.laneHeight - 8)
                        .position(x: x, y: Self.laneHeight / 2)
                    Capsule()
                        .fill(AutomationColors.eq)
                        .frame(width: swapDragging ? 8 : 5, height: Self.laneHeight - 6)
                        .position(x: x, y: Self.laneHeight / 2)
                    Text("Bass swap").font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                        .position(x: min(max(x, 40), width - 40), y: 8)
                } else {
                    Text("No bass swap").font(.caption2).foregroundStyle(palette.onSurfaceVariant).padding(.leading, 10)
                }
            }
            .frame(width: width, height: Self.laneHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { gesture in
                        guard spec.bassSwap else { return }
                        if !swapDragging {
                            beginDrag()
                            swapDragging = true
                        }
                        let at = Float((gesture.location.x - box.minX) / max(box.width, 1))
                        drag { TransitionEditing.setBassSwapAt($0, at) }
                    }
                    .onEnded { _ in swapDragging = false }
            )
        }
        .frame(height: Self.laneHeight)
        .background(palette.surfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel("EQ")
        .accessibilityValue(spec.bassSwap ? "Bass swap at \(percent(spec.bassSwapAt)) %" : "None")
    }

    /// How much a filter takes away, 0 (open) to 1 (thinnest or darkest), even in pitch.
    private static func filteredAmount(_ setting: FilterSetting) -> Float {
        let amount: Float
        switch setting.type {
        case .highPass:
            let span = log(TransitionFilter.highPassThinHz / TransitionFilter.highPassOpenHz)
            amount = log(setting.hz / TransitionFilter.highPassOpenHz) / span
        case .lowPass:
            let span = log(TransitionFilter.lowPassOpenHz / TransitionFilter.lowPassDarkHz)
            amount = log(TransitionFilter.lowPassOpenHz / setting.hz) / span
        }
        return amount.clamped(0, 1)
    }

    private var filterLane: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 6)
            for role in [TransitionRole.outgoing, .incoming] where spec.filter.affects(role) {
                var path = Path()
                for step in 0...48 {
                    let t = Float(step) / 48
                    guard let setting = spec.filter.settingAt(role, t) else { continue }
                    let amount = CGFloat(Self.filteredAmount(setting))
                    let p = CGPoint(x: box.minX + CGFloat(t) * box.width, y: box.maxY - amount * box.height)
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let style = role == .outgoing ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 2, dash: [5, 3])
                context.stroke(path, with: .color(AutomationColors.filter), style: style)
            }
        }
        .frame(height: Self.laneHeight)
        .overlay(alignment: .leading) {
            if spec.filter == .none {
                Text("No filter").font(.caption2).foregroundStyle(palette.onSurfaceVariant).padding(.leading, 10)
            }
        }
        .background(palette.surfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel("Filter")
        .accessibilityValue(spec.filter.label)
    }
}
