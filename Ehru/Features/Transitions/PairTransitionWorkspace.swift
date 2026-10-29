import AVFoundation
import SwiftUI

/// Source audio, exact cue windows, and engine automation for this one pair only.
struct PairTransitionWorkspace: View {
    let pair: StudioPair
    let spec: TransitionSpec
    let transitionEnabled: Bool
    @Binding var editingVolume: Bool
    let beginDrag: () -> Void
    let drag: ((TransitionSpec) -> TransitionSpec) -> Void
    let edit: ((TransitionSpec) -> TransitionSpec) -> Void
    @Environment(PlayerController.self) private var player
    @Environment(SoundStore.self) private var sound
    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @State private var outgoing: TransitionAudioSlice?
    @State private var incoming: TransitionAudioSlice?
    @State private var loading = true
    @State private var inspectedMs: Double?
    @State private var preview = PairTransitionPreview()
    @State private var timeZoom: Double = 1
    @State private var viewFocusMs: Double?
    @State private var waveHeight = TransitionWaveformHeight.auto
    @State private var cueSession: TransitionWaveformDrag?
    @State private var draggedSpec: TransitionSpec?
    @State private var cueDisplayGain: Float?
    @State private var showsEQ = true
    @State private var showsFilter = true
    @State private var showsInspector = false
    @State private var showsCues = false
    @State private var showsPointEditor = false
    @State private var selectedLine: TransitionLineTarget?
    @State private var effectSession: TransitionEffectDrag?
    @State private var curveSession: TransitionCurveDrag?
    @State private var selectedHandle: TransitionCurveHandle?
    @State private var pinchViewport: TransitionWaveformViewport?
    @State private var pinchZoom: Double?
    @GestureState private var pinching = false

    private var workingSpec: TransitionSpec { draggedSpec ?? spec }

    private var timing: PairTransitionTiming? {
        PairTransitionTiming(spec: transitionEnabled ? workingSpec : nil, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
    }

    private struct Request: Hashable {
        let from: Song
        let to: Song
        let outStart: Int64
        let outEnd: Int64
        let inStart: Int64
        let inEnd: Int64
    }

    private var request: Request? {
        // Only committed cues request decoding. Finger movement remaps the buffered samples.
        PairTransitionTiming(spec: transitionEnabled ? spec : nil, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs).map {
            let out = $0.analysisRange(.outgoing, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
            let inc = $0.analysisRange(.incoming, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
            return Request(from: pair.from.song, to: pair.to.song, outStart: out.lowerBound, outEnd: out.upperBound,
                           inStart: inc.lowerBound, inEnd: inc.upperBound)
        }
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            sourceLine("Outgoing", pair.from.song)
            if let timing { stage(timing) }
            else {
                Text("No playable overlap. Adjust the cue points or choose a shorter transition.")
                    .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity, minHeight: 180)
                Button("Edit cue points") { showsCues = true }
                sourceLine("Incoming", pair.to.song)
            }
        }
        .task(id: request) {
            loading = true
            guard let request else { outgoing = nil; incoming = nil; loading = false; return }
            // A duration/cue drag does not start a decode for every intermediate value.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            async let out = TransitionAnalysisStore.shared.slice(url: request.from.url, range: request.outStart..<request.outEnd, bins: 8192)
            async let inc = TransitionAnalysisStore.shared.slice(url: request.to.url, range: request.inStart..<request.inEnd, bins: 8192)
            let result = await (out, inc)
            guard !Task.isCancelled else { return }
            outgoing = result.0
            incoming = result.1
            loading = false
        }
        .sheet(isPresented: $showsInspector) {
            TransitionDetailsSheet(title: "Analysis & automation") {
                if let timing {
                    TimelineView(.animation(minimumInterval: 0.1, paused: !preview.isPlaying)) { _ in
                        inspector(timing)
                    }
                    audition(timing)
                    Text("BPM is read from file tags. Beat grid, musical key analysis, beatmatching, reverb, echo and looping are not available for this transition.")
                        .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                }
            }
        }
        .sheet(isPresented: $showsCues) {
            TransitionDetailsSheet(title: "Source cues") {
                cues(timing)
                    .disabled(!transitionEnabled)
                if !transitionEnabled { Text("Choose a transition preset to enable cue trimming. Off plays the full outgoing track and the incoming track from its beginning.").font(.caption) }
            }
        }
        .sheet(isPresented: $showsPointEditor) {
            if let handle = selectedHandle, let timing {
                TransitionPointEditor(spec: spec, handle: handle, durationMs: timing.plan.durationMs) { result in
                    edit { _ in result }
                }
            }
        }
        .onChange(of: spec) { _, value in
            preview.stop(); cancelCueDrag()
            if let selectedLine {
                switch selectedLine {
                case .bass where !value.bassSwap: self.selectedLine = .volume(selectedLine.role)
                case .filter where !value.filter.affects(selectedLine.role): self.selectedLine = .volume(selectedLine.role)
                default: break
                }
            }
        }
        .onChange(of: transitionEnabled) { _, _ in preview.stop(); cancelCueDrag(); selectedHandle = nil }
        .onChange(of: editingVolume) { _, active in
            if !active { cancelCueDrag(); selectedHandle = nil; selectedLine = nil }
            else if selectedLine == nil { selectedLine = .volume(.outgoing) }
        }
        .onChange(of: pinching) { _, active in if !active { pinchViewport = nil; pinchZoom = nil } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preview.stop(resume: false); cancelCueDrag() } }
        .onChange(of: player.state.isPlaying) { _, playing in
            if playing { preview.stop(resume: false) }
        }
        .onChange(of: player.state.currentEntry?.id) { _, _ in preview.stop(resume: false) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in preview.stop(resume: false) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in preview.stop(resume: false) }
        .onDisappear { preview.stop(resume: scenePhase == .active); cancelCueDrag() }
    }

    private func stage(_ timing: PairTransitionTiming) -> some View {
        VStack(spacing: 6) {
            waveform(timing)
            auditionButton(timing)
                .padding(.top, 4)
            sourceLine("Incoming", pair.to.song)
                .padding(.vertical, Spacing.xs)
            HStack(spacing: Spacing.sm) {
                if transitionEnabled {
                    Picker("Waveform tool", selection: $editingVolume) {
                        Text("Move audio").tag(false)
                        Text("Edit curves").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                } else {
                    Text("No crossfade").font(.caption).foregroundStyle(palette.onSurfaceVariant)
                    Spacer(minLength: 0)
                }
                TransitionDurationControl(spec: spec, enabled: transitionEnabled, pair: pair,
                                          beginDrag: beginDrag, drag: { ms in drag { TransitionEditing.setDuration($0, ms) } },
                                          choose: { ms in edit { TransitionEditing.setDuration($0, ms) } })
                waveformTools(timing)
            }
            .disabled(cueSession != nil || curveSession != nil || effectSession != nil)
            if timeZoom > 1.01 || viewFocusMs != nil {
                TransitionWaveformOverview(timing: timing, viewport: viewport(timing)) { viewFocusMs = $0 }
                    .allowsHitTesting(cueSession == nil && curveSession == nil && effectSession == nil)
            }
            stageStatus(timing)
            if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading) }
            if !loading && (outgoing == nil || incoming == nil) {
                Text("A source waveform is unavailable. Check that both audio files are readable.")
                    .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            }
            if let error = preview.error { Text(error).font(.caption2).foregroundStyle(palette.onSurfaceVariant) }
        }
    }

    private func stageStatus(_ timing: PairTransitionTiming) -> some View {
        HStack(spacing: Spacing.sm) {
            if transitionEnabled {
                Text(editingHint)
                    .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            if let selected = selectedHandle, editingVolume, transitionEnabled, effectSession == nil, isEditingGain {
                selectedPointMenu(selected)
            }
            if transitionEnabled {
                HStack(spacing: 4) {
                    legend("Vol", AutomationColors.volume)
                    if showsEQ && workingSpec.bassSwap { legend("200 Hz", AutomationColors.eq) }
                    if showsFilter && workingSpec.filter != .none { legend("Cutoff", AutomationColors.filter) }
                }
            }
        }
        .frame(minHeight: 22)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 8, height: 2)
            Text(title).font(.system(size: 9)).foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private func selectedPointMenu(_ handle: TransitionCurveHandle) -> some View {
        Menu {
            Button("Edit exact time & gain") { showsPointEditor = true }
            Button(role: .destructive) {
                edit { TransitionEditing.removePoint($0, handle.role, index: handle.index) }
                selectedHandle = nil
            } label: { Label("Remove point", systemImage: "minus.circle") }
            .disabled(handle.index == 0 || handle.index >= TransitionEditing.curveOf(spec, handle.role).points.count - 1)
            Button("Deselect") { selectedHandle = nil }
        } label: { Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").frame(width: 36, height: 28) }
        .accessibilityLabel("Selected volume point")
    }

    private func inspection(_ timing: PairTransitionTiming) -> Double {
        (preview.positionMs() ?? inspectedMs ?? Double(timing.plan.durationMs) / 2).clamped(0, Double(timing.plan.durationMs))
    }

    private func viewport(_ timing: PairTransitionTiming) -> TransitionWaveformViewport {
        cueSession?.viewport ?? TransitionWaveformViewport(timing: timing, zoom: timeZoom, focusMs: viewFocusMs, includesPreviewContext: true)
    }

    private func displayGain(_ timing: PairTransitionTiming) -> Float {
        if let cueDisplayGain { return cueDisplayGain }
        let view = viewport(timing)
        let outPeak = outgoing?.visiblePeak(sourceStartMs: Double(timing.plan.startAtMs), viewport: view) ?? 0
        let inPeak = incoming?.visiblePeak(sourceStartMs: Double(timing.plan.incomingStartMs), viewport: view) ?? 0
        return waveHeight.gain(visiblePeak: max(outPeak, inPeak))
    }

    private func waveformTools(_ timing: PairTransitionTiming) -> some View {
        Menu {
            Section("Time zoom") {
                ForEach([1.0, 2, 4, 8], id: \.self) { zoom in
                    Button(zoom == 1 ? "Fit preview" : "\(Int(zoom))×") {
                        timeZoom = zoom
                        viewFocusMs = zoom == 1 ? nil : inspection(timing)
                    }
                }
            }
            Section("Waveform height · display only") {
                ForEach(TransitionWaveformHeight.allCases) { height in
                    Button { waveHeight = height } label: {
                        if height == waveHeight { Label(height.label, systemImage: "checkmark") }
                        else { Text(height.label) }
                    }
                }
            }
            Section("Automation overlays") {
                Toggle("Bass shelf gain · 200 Hz", isOn: $showsEQ)
                Toggle("Filter cutoff · logarithmic", isOn: $showsFilter)
            }
            Divider()
            Button { showsCues = true } label: { Label("Precise source cues", systemImage: "arrow.left.and.right") }
            Button { showsInspector = true } label: { Label("Analysis & automation", systemImage: "waveform.path.ecg") }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.subheadline).frame(width: 40, height: 44)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityLabel("Zoom, overlays & technical controls")
    }

    private func waveform(_ timing: PairTransitionTiming) -> some View {
        GeometryReader { geometry in
            waveformPlot(timing)
                .overlay { waveformInteraction(timing, size: geometry.size) }
                .simultaneousGesture(magnification(timing))
                .overlay { TransitionPreviewPlayhead(preview: preview, viewport: viewport(timing)) }
                .accessibilityAction(named: "Move outgoing cue earlier") { nudge(.outgoing, delta: 100) }
                .accessibilityAction(named: "Move outgoing cue later") { nudge(.outgoing, delta: -100) }
                .accessibilityAction(named: "Move incoming cue earlier") { nudge(.incoming, delta: 100) }
                .accessibilityAction(named: "Move incoming cue later") { nudge(.incoming, delta: -100) }
        }
        .frame(height: 280)
    }

    private func waveformPlot(_ timing: PairTransitionTiming) -> some View {
        PairAudioPlot(timing: timing, viewport: viewport(timing), outgoing: outgoing, incoming: incoming,
                      inspectedMs: preview.isPlaying ? nil : inspectedMs, displayGain: displayGain(timing),
                      activeRole: cueSession?.role ?? curveSession?.handle.role ?? effectSession?.target.role,
                      showsEQ: showsEQ, showsFilter: showsFilter, editingVolume: editingVolume && transitionEnabled, selectedHandle: selectedHandle,
                      selectedLine: editingVolume ? selectedLine : nil)
    }

    private func waveformInteraction(_ timing: PairTransitionTiming, size: CGSize) -> some View {
        PanInteraction(canBegin: { start, delta in
            guard !pinching, transitionEnabled else { return false }
            let layout = curveLayout(timing, size)
            return layout.nearestLine(start, spec: workingSpec, showsEQ: showsEQ, showsFilter: showsFilter,
                                      selected: selectedLine) != nil || HorizontalGestureIntent.accepts(delta)
        }, change: { gesture in
            if cueSession != nil { updateCueDrag(gesture, size: size, timing: timing); return }
            if curveSession != nil { updateCurveDrag(gesture, size: size, timing: timing); return }
            if effectSession != nil { updateEffectDrag(gesture); return }
            let layout = curveLayout(timing, size)
            if let line = layout.nearestLine(gesture.startLocation, spec: spec, showsEQ: showsEQ, showsFilter: showsFilter,
                                             selected: selectedLine) {
                selectLine(line, at: gesture.startLocation, timing: timing, size: size)
                if case .volume = line { updateCurveDrag(gesture, size: size, timing: timing) }
                else {
                    preview.stop()
                    effectSession = TransitionEffectDrag(base: spec, target: line, layout: layout)
                    updateEffectDrag(gesture)
                }
            } else { updateCueDrag(gesture, size: size, timing: timing) }
        }, end: { gesture in
            if curveSession != nil { finishCurveDrag(gesture) }
            else if let session = effectSession {
                let result = session.moved(translation: gesture.translation)
                cancelCueDrag()
                if result != spec { edit { _ in result } }
            } else { finishCueDrag(gesture) }
        }, cancel: cancelCueDrag, tap: { location in
            guard transitionEnabled else { return }
            let layout = curveLayout(timing, size)
            if let line = layout.nearestLine(location, spec: spec, showsEQ: showsEQ, showsFilter: showsFilter, selected: selectedLine) {
                selectLine(line, at: location, timing: timing, size: size)
            } else if editingVolume && isEditingGain { selectOrAddPoint(location, size: size, timing: timing) }
            else { inspectedMs = viewport(timing).time(at: Double(location.x / max(size.width, 1))) }
        }, touchDown: { location in
            guard transitionEnabled, !pinching else { return }
            if let line = curveLayout(timing, size).nearestLine(location, spec: spec, showsEQ: showsEQ, showsFilter: showsFilter,
                                                               selected: selectedLine) {
                selectLine(line, at: location, timing: timing, size: size)
            }
        })
    }

    private var isEditingGain: Bool {
        if let selectedLine { if case .volume = selectedLine { return true }; return false }
        return true
    }

    private var editingHint: String {
        guard editingVolume, let selectedLine else { return "Touch a curve to edit · drag audio to move cues" }
        switch selectedLine {
        case .volume: return "Volume · drag points · tap a lane to add"
        case .bass: return "EQ · drag the yellow handle to move the handover"
        case .filter: return "Filter · drag the pink handle for time and cutoff"
        }
    }

    private func selectLine(_ line: TransitionLineTarget, at location: CGPoint, timing: PairTransitionTiming, size: CGSize) {
        selectedLine = line
        editingVolume = true
        if case .volume(let role) = line {
            selectedHandle = curveLayout(timing, size).nearest(location, spec: workingSpec)
            if selectedHandle?.role != role { selectedHandle = nil }
        } else { selectedHandle = nil }
    }

    private func updateEffectDrag(_ sample: PanInteraction.Sample) {
        guard let session = effectSession else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { draggedSpec = session.moved(translation: sample.translation) }
    }

    private func magnification(_ timing: PairTransitionTiming) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .updating($pinching) { _, active, _ in active = true }
            .onChanged { value in
                cancelCueDrag()
                let initial = PairTransitionTiming(spec: transitionEnabled ? spec : nil, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs) ?? timing
                if pinchViewport == nil { pinchViewport = viewport(initial); pinchZoom = timeZoom }
                guard let base = pinchViewport, let zoom = pinchZoom else { return }
                let next = (zoom * Double(value.magnification)).clamped(1, 8)
                let view = base.zoomed(timing: initial, zoom: next, anchor: Double(value.startAnchor.x))
                timeZoom = next
                viewFocusMs = view.centerMs
            }
            .onEnded { _ in pinchViewport = nil; pinchZoom = nil }
    }

    private func auditionButton(_ timing: PairTransitionTiming) -> some View {
        Button { toggleAudition(timing) } label: {
            HStack(spacing: 8) {
                auditionIcon
                Text(preview.isPreparing ? "Preparing preview…" : preview.isPlaying ? "Stop preview" : "Play preview")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if preview.isPlaying { TransitionPreviewReadout(preview: preview, durationMs: timing.plan.durationMs) }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .disabled(loading || outgoing == nil || incoming == nil || cueSession != nil || curveSession != nil || effectSession != nil)
        .accessibilityLabel(preview.isPreparing || preview.isPlaying ? "Stop transition preview" : "Audition this transition")
    }

    @ViewBuilder
    private var auditionIcon: some View {
        if preview.isPreparing { ProgressView().tint(palette.onSurface) }
        else { Image(systemName: preview.isPlaying ? "stop.fill" : "play.fill").font(.title3.weight(.semibold)) }
    }

    private func updateCueDrag(_ gesture: PanInteraction.Sample, size: CGSize, timing: PairTransitionTiming) {
        guard !pinching, size.width > 0 else { return }
        if cueSession == nil {
            preview.stop()
            cueDisplayGain = displayGain(timing)
            cueSession = TransitionWaveformDrag(base: spec, role: gesture.startLocation.y < size.height / 2 ? .outgoing : .incoming,
                                                viewport: viewport(timing), width: Double(size.width))
        }
        guard let session = cueSession else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggedSpec = session.shifted(points: Double(gesture.translation.width), outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
        }
    }

    private func finishCueDrag(_ gesture: PanInteraction.Sample) {
        guard let session = cueSession else { return }
        let result = session.shifted(points: Double(gesture.translation.width), outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
        cancelCueDrag()
        if result != session.base { edit { _ in result } }
    }

    private func cancelCueDrag() { cueSession = nil; curveSession = nil; effectSession = nil; draggedSpec = nil; cueDisplayGain = nil }

    private func curveLayout(_ timing: PairTransitionTiming, _ size: CGSize) -> TransitionCurveLayout {
        TransitionCurveLayout(viewport: viewport(timing), durationMs: Double(timing.plan.durationMs), size: size)
    }

    private func updateCurveDrag(_ gesture: PanInteraction.Sample, size: CGSize, timing: PairTransitionTiming) {
        if curveSession == nil {
            let layout = curveLayout(timing, size)
            let role = selectedLine?.role ?? layout.role(at: gesture.startLocation)
            var base = spec
            var handle = layout.nearest(gesture.startLocation, spec: base)
            if handle?.role != role { handle = nil }
            if handle == nil {
                let t = layout.value(at: gesture.startLocation, role: role).t
                base = TransitionEditing.addPoint(spec, role, t: t)
                if let index = TransitionEditing.curveOf(base, role).points.firstIndex(where: { abs($0.t - t) < 1e-6 }) {
                    handle = TransitionCurveHandle(role: role, index: index)
                }
            }
            guard let handle else { return }
            preview.stop()
            selectedHandle = handle
            curveSession = TransitionCurveDrag(base: base, handle: handle, layout: layout)
        }
        guard let session = curveSession else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { draggedSpec = session.moved(translation: gesture.translation) }
    }

    private func finishCurveDrag(_ gesture: PanInteraction.Sample) {
        guard let session = curveSession else { return }
        let result = session.moved(translation: gesture.translation)
        cancelCueDrag()
        if result != spec { edit { _ in result } }
    }

    private func selectOrAddPoint(_ location: CGPoint, size: CGSize, timing: PairTransitionTiming) {
        let layout = curveLayout(timing, size)
        if let handle = layout.nearest(location, spec: spec) { selectedHandle = handle; return }
        let role = layout.role(at: location)
        let point = layout.value(at: location, role: role)
        selectedHandle = nil
        edit { TransitionEditing.addPoint($0, role, t: point.t) }
    }

    private func toggleAudition(_ timing: PairTransitionTiming) {
        inspectedMs = nil
        if preview.isPlaying || preview.isPreparing { preview.stop() }
        else { preview.play(pair: pair, timing: timing, player: player, sound: sound.settings) }
    }

    private func nudge(_ role: TransitionRole, delta: Float) {
        guard transitionEnabled else { return }
        edit { TransitionEditing.shiftCue($0, role, deltaMs: delta, outgoingDurationMs: pair.from.song.durationMs, incomingDurationMs: pair.to.song.durationMs) }
    }

    private func sourceLine(_ role: String, _ song: Song) -> some View {
        HStack(spacing: Spacing.sm) {
            SongArtworkView(song: song, maxPixels: 120)
                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(song.artist).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                Text(role == "Outgoing"
                     ? "Hands over at \(transitionTimestamp(Double(transitionEnabled ? workingSpec.outgoingEndMs(song.durationMs) : song.durationMs)))"
                     : "Starts at \(transitionTimestamp(Double(transitionEnabled ? workingSpec.incomingStartMs : 0)))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(palette.primary).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text((role == "Outgoing" ? "OUT · " : "IN · ") + (song.bpm.map { "\($0) BPM tag" } ?? "BPM —")).font(.caption2)
                Text(transitionTimestamp(Double(song.durationMs))).font(.caption2.monospacedDigit())

            }
        }
        .foregroundStyle(palette.onSurface)
        .accessibilityElement(children: .combine)
    }

    private func audition(_ timing: PairTransitionTiming) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("\(transitionTimestamp(Double(timing.plan.startAtMs))) → \(transitionTimestamp(Double(timing.outgoingRange.upperBound))) out · \(transitionTimestamp(Double(timing.plan.incomingStartMs))) → \(transitionTimestamp(Double(timing.incomingRange.upperBound))) in")
                .font(.caption2.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
            Text("Preview uses the current equalizer and saved audio files; it pauses your music and resumes it afterward.")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            Text("The green playhead follows rendered audio samples with output-route latency compensation. Filter lines show cutoff targets on a logarithmic frequency scale, not a measured spectrum.")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private func inspector(_ timing: PairTransitionTiming) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Inspect automation").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.3f / %.3f s", inspection(timing) / 1000, Double(timing.plan.durationMs) / 1000))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: Binding(get: { inspection(timing) }, set: { inspectedMs = $0 }), in: 0...Double(max(timing.plan.durationMs, 1)), step: 1)
                .disabled(!timing.hasOverlap || preview.isPlaying)
                .accessibilityLabel("Inspection position in the overlap")
                .tint(palette.primary)
            Grid(alignment: .leading, horizontalSpacing: Spacing.md, verticalSpacing: Spacing.xs) {
                GridRow { Text(""); Text("Out"); Text("In") }.fontWeight(.semibold)
                detailRow("Decoded format", audioFormat(outgoing), audioFormat(incoming))
                detailRow("Source time", transitionTimestamp(timing.sourceTime(.outgoing, elapsedMs: inspection(timing))),
                          transitionTimestamp(timing.sourceTime(.incoming, elapsedMs: inspection(timing))))
                detailRow("Volume", gain(timing, .outgoing), gain(timing, .incoming))
                detailRow("Bass shelf · 200 Hz", bass(timing, .outgoing), bass(timing, .incoming))
                detailRow("Filter cutoff target", filter(timing, .outgoing), filter(timing, .incoming))
                detailRow("Loaded audio peak", outgoing.map { TransitionAudioSlice.dbFS($0.peak) } ?? "Unavailable",
                          incoming.map { TransitionAudioSlice.dbFS($0.peak) } ?? "Unavailable")
                detailRow("Loaded audio RMS", outgoing.map { TransitionAudioSlice.dbFS($0.meanRMS) } ?? "Unavailable",
                          incoming.map { TransitionAudioSlice.dbFS($0.meanRMS) } ?? "Unavailable")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(palette.onSurfaceVariant)
            Text("Peak/RMS measure the loaded source audio before processing, including nearby audio for dragging. Wave height changes only the display. Gain, shelf and cutoff are the engine's automation targets at the inspection point. BPM is the file's tag; beatmatching and key analysis are unavailable.")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            Text(String(format: "Wave height +%.1f dB · display only", 20 * log10(displayGain(timing))))
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            if let outgoing { loadedRange("Out", outgoing) }
            if let incoming { loadedRange("In", incoming) }
        }
    }

    private func audioFormat(_ slice: TransitionAudioSlice?) -> String {
        slice.map { String(format: "%.1f kHz · %d ch", $0.sampleRate / 1000, $0.channels) } ?? "Unavailable"
    }

    private func loadedRange(_ title: String, _ slice: TransitionAudioSlice) -> some View {
        Text("\(title) loaded \(transitionTimestamp(slice.startMs))–\(transitionTimestamp(slice.startMs + slice.durationMs))")
            .font(.caption2.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
    }

    private func detailRow(_ label: String, _ out: String, _ inc: String) -> some View {
        GridRow { Text(label); Text(out); Text(inc) }
    }

    private func gain(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        let value = timing.gainAt(role, elapsedMs: inspection(timing))
        return value > 0 ? String(format: "%.1f dB", 20 * log10(value)) : "−∞ dB"
    }

    private func bass(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        transitionEnabled && workingSpec.bassSwap ? String(format: "%.1f dB", timing.automation(role).bassDbAt(inspection(timing))) : "Bypass"
    }

    private func filter(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        guard transitionEnabled, let setting = timing.automation(role).filterAt(inspection(timing)) else { return "Bypass" }
        return "\(setting.type == .highPass ? "HP" : "LP") \(Int(setting.hz.rounded())) Hz"
    }

    private func cues(_ timing: PairTransitionTiming?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            cue("Outgoing end", role: .outgoing, song: pair.from.song,
                value: Double(spec.outgoingEndMs(pair.from.song.durationMs)))
            cue("Incoming start", role: .incoming, song: pair.to.song, value: Double(spec.incomingStartMs))
            Button("Reset both cue points") {
                edit { spec in var reset = spec; reset.outgoingCutMs = 0; reset.incomingStartMs = 0; return reset }
            }
            .font(.caption)
        }
        .padding(.top, Spacing.sm)
    }

    private func cue(_ title: String, role: TransitionRole, song: Song, value: Double) -> some View {
        let maximum = max(Double(song.durationMs - TransitionEditing.minPlayedMs), 0)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(transitionTimestamp(value)).font(.caption.monospacedDigit())
            }
            Slider(value: Binding(get: { value.clamped(role == .outgoing ? min(1000, Double(song.durationMs)) : 0, role == .outgoing ? max(Double(song.durationMs), 1) : max(maximum, 1)) }, set: { target in
                let delta = Float(value - target)
                drag { TransitionEditing.shiftCue($0, role, deltaMs: delta,
                                                   outgoingDurationMs: pair.from.song.durationMs, incomingDurationMs: pair.to.song.durationMs) }
            }), in: role == .outgoing ? min(1000, Double(song.durationMs))...max(Double(song.durationMs), 1) : 0...max(maximum, 1), step: 10) { editing in
                if editing { beginDrag() }
            }
            .disabled(song.durationMs <= 1000)
            HStack {
                Button("−100 ms") { edit { TransitionEditing.shiftCue($0, role, deltaMs: 100, outgoingDurationMs: pair.from.song.durationMs, incomingDurationMs: pair.to.song.durationMs) } }
                Spacer()
                Button("+100 ms") { edit { TransitionEditing.shiftCue($0, role, deltaMs: -100, outgoingDurationMs: pair.from.song.durationMs, incomingDurationMs: pair.to.song.durationMs) } }
            }
            .font(.caption)
        }
    }
}

func transitionTimestamp(_ ms: Double) -> String {
    let safe = max(Int64(ms.rounded()), 0)
    return String(format: "%lld:%02lld.%03lld", safe / 60_000, (safe / 1000) % 60, safe % 1000)
}
