import AVFoundation
import SwiftUI

/// Source audio, exact cue windows, and engine automation for this one pair only.
struct PairTransitionWorkspace: View {
    let pair: StudioPair
    let spec: TransitionSpec
    let masterEnabled: Bool
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
    @State private var pinchViewport: TransitionWaveformViewport?
    @State private var pinchZoom: Double?
    @GestureState private var pinching = false

    private var workingSpec: TransitionSpec { draggedSpec ?? spec }

    private var timing: PairTransitionTiming? {
        PairTransitionTiming(spec: workingSpec, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
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
        PairTransitionTiming(spec: spec, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs).map {
            let out = $0.analysisRange(.outgoing, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
            let inc = $0.analysisRange(.incoming, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
            return Request(from: pair.from.song, to: pair.to.song, outStart: out.lowerBound, outEnd: out.upperBound,
                           inStart: inc.lowerBound, inEnd: inc.upperBound)
        }
    }

    var body: some View {
        StudioPanel {
            sourceLine("Outgoing", pair.from.song, outgoing)
            if let timing {
                waveformControls(timing)
                waveform(timing)
                TransitionWaveformOverview(timing: timing, viewport: viewport(timing)) { viewFocusMs = $0 }
                    .allowsHitTesting(cueSession == nil)
                sourceLine("Incoming", pair.to.song, incoming)
                HStack {
                    Text(String(format: "Wave height +%.1f dB · display only", 20 * log10(displayGain(timing))))
                        .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                    Spacer(minLength: 0)
                    if loading { ProgressView().controlSize(.small) }
                }
                Text("Drag the upper/lower waveform to move its cue. Pinch to zoom; use the strip to move the view. White lines: volume. Dimmed audio is outside playback.")
                    .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                if cueSession != nil {
                    Text("Out end \(transitionTimestamp(Double(workingSpec.outgoingEndMs(pair.from.song.durationMs)))) · In start \(transitionTimestamp(Double(workingSpec.incomingStartMs)))")
                        .font(.caption.monospacedDigit()).foregroundStyle(palette.primary)
                }
                if !loading && (outgoing == nil || incoming == nil) {
                    Text("Audio analysis unavailable for \(outgoing == nil && incoming == nil ? "both files" : outgoing == nil ? "the outgoing file" : "the incoming file"). Check that the file is present and readable.")
                        .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                }
                audition(timing)
                Divider()
                inspector(timing)
                DisclosureGroup("Cue points · precise editing") { cues(timing) }
                    .font(.subheadline)
                if !masterEnabled {
                    Text("Automatic crossfades are off. This draft can be auditioned, but saved transitions will play only when the master switch is on.")
                        .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                }
            } else {
                sourceLine("Incoming", pair.to.song, nil)
                Text("No playable overlap: the track durations or cue points leave less than 0.3 seconds. Adjust the cues or use longer tracks.")
                    .font(.caption).foregroundStyle(palette.onSurfaceVariant)
                cues(nil)
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
        .onChange(of: spec) { _, _ in preview.stop(); cancelCueDrag() }
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

    private func inspection(_ timing: PairTransitionTiming) -> Double {
        (inspectedMs ?? Double(timing.plan.durationMs) / 2).clamped(0, Double(timing.plan.durationMs))
    }

    private func viewport(_ timing: PairTransitionTiming) -> TransitionWaveformViewport {
        cueSession?.viewport ?? TransitionWaveformViewport(timing: timing, zoom: timeZoom, focusMs: viewFocusMs)
    }

    private func displayGain(_ timing: PairTransitionTiming) -> Float {
        if let cueDisplayGain { return cueDisplayGain }
        let view = viewport(timing)
        let outPeak = outgoing?.visiblePeak(sourceStartMs: Double(timing.plan.startAtMs), viewport: view) ?? 0
        let inPeak = incoming?.visiblePeak(sourceStartMs: Double(timing.plan.incomingStartMs), viewport: view) ?? 0
        return waveHeight.gain(visiblePeak: max(outPeak, inPeak))
    }

    private func waveformControls(_ timing: PairTransitionTiming) -> some View {
        HStack(spacing: Spacing.xs) {
            ForEach([1.0, 2, 4, 8], id: \.self) { zoom in
                Button {
                    timeZoom = zoom
                    viewFocusMs = zoom == 1 ? nil : inspection(timing)
                } label: {
                    Text(zoom == 1 ? "Fit" : "\(Int(zoom))×")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 38, minHeight: 44)
                        .background(abs(timeZoom - zoom) < 0.05 ? palette.primary.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel(zoom == 1 ? "Fit transition in view" : "Time zoom \(Int(zoom)) times")
                .accessibilityAddTraits(abs(timeZoom - zoom) < 0.05 ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(TransitionWaveformHeight.allCases) { height in
                    Button { waveHeight = height } label: {
                        if height == waveHeight { Label(height.label, systemImage: "checkmark") }
                        else { Text(height.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                    Text(waveHeight.label)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .font(.caption).frame(minHeight: 44)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .accessibilityLabel("Waveform display height: \(waveHeight.label)")
        }
        .buttonStyle(.plain)
        .disabled(cueSession != nil)
    }

    private func waveform(_ timing: PairTransitionTiming) -> some View {
        GeometryReader { geometry in
            PairAudioPlot(timing: timing, viewport: viewport(timing), outgoing: outgoing, incoming: incoming,
                          inspectedMs: inspection(timing), displayGain: displayGain(timing), activeRole: cueSession?.role)
                .overlay {
                    PanInteraction(canBegin: { _, delta in !pinching && HorizontalGestureIntent.accepts(delta) },
                                   change: { updateCueDrag($0, size: geometry.size, timing: timing) },
                                   end: { finishCueDrag($0) }, cancel: cancelCueDrag,
                                   tap: { inspectedMs = viewport(timing).time(at: Double($0.x / max(geometry.size.width, 1))) })
                }
                .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.02)
                    .updating($pinching) { _, active, _ in active = true }
                    .onChanged { value in
                        cancelCueDrag()
                        let initial = PairTransitionTiming(spec: spec, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs) ?? timing
                        if pinchViewport == nil { pinchViewport = viewport(initial); pinchZoom = timeZoom }
                        guard let base = pinchViewport, let zoom = pinchZoom else { return }
                        let next = (zoom * Double(value.magnification)).clamped(1, 8)
                        let view = base.zoomed(timing: initial, zoom: next, anchor: Double(value.startAnchor.x))
                        timeZoom = next
                        viewFocusMs = view.centerMs
                    }
                    .onEnded { _ in pinchViewport = nil; pinchZoom = nil })
                .accessibilityAction(named: "Move outgoing cue earlier") { nudge(.outgoing, delta: 100) }
                .accessibilityAction(named: "Move outgoing cue later") { nudge(.outgoing, delta: -100) }
                .accessibilityAction(named: "Move incoming cue earlier") { nudge(.incoming, delta: 100) }
                .accessibilityAction(named: "Move incoming cue later") { nudge(.incoming, delta: -100) }
        }
        .frame(height: 300)
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

    private func cancelCueDrag() { cueSession = nil; draggedSpec = nil; cueDisplayGain = nil }

    private func nudge(_ role: TransitionRole, delta: Float) {
        edit { TransitionEditing.shiftCue($0, role, deltaMs: delta, outgoingDurationMs: pair.from.song.durationMs, incomingDurationMs: pair.to.song.durationMs) }
    }

    private func sourceLine(_ role: String, _ song: Song, _ slice: TransitionAudioSlice?) -> some View {
        HStack(spacing: Spacing.sm) {
            SongArtworkView(song: song, maxPixels: 120)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(role.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(palette.onSurfaceVariant)
                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(song.artist).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(song.bpm.map { "\($0) BPM · tag" } ?? "BPM untagged").font(.caption)
                Text(transitionTimestamp(Double(song.durationMs))).font(.caption2.monospacedDigit())
                if let slice {
                    Text(String(format: "%.1f kHz · %d ch", slice.sampleRate / 1000, slice.channels))
                        .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                }
            }
        }
        .foregroundStyle(palette.onSurface)
        .accessibilityElement(children: .combine)
    }

    private func audition(_ timing: PairTransitionTiming) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                if preview.isPlaying || preview.isPreparing { preview.stop() }
                else { preview.play(pair: pair, timing: timing, player: player, sound: sound.settings) }
            } label: {
                Label(preview.isPreparing ? "Preparing preview…" : preview.isPlaying ? "Stop preview" : "Audition this transition",
                      systemImage: preview.isPlaying || preview.isPreparing ? "stop.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(palette.primary.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loading || outgoing == nil || incoming == nil || cueSession != nil)
            Text("\(transitionTimestamp(Double(timing.plan.startAtMs))) → \(transitionTimestamp(Double(timing.outgoingRange.upperBound))) out · \(transitionTimestamp(Double(timing.plan.incomingStartMs))) → \(transitionTimestamp(Double(timing.incomingRange.upperBound))) in")
                .font(.caption2.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
            Text("Preview uses the current equalizer and saved audio files; it pauses your music and resumes it afterward.")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            if let error = preview.error { Text(error).font(.caption).foregroundStyle(palette.onSurfaceVariant) }
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
            Slider(value: Binding(get: { inspection(timing) }, set: { inspectedMs = $0 }), in: 0...Double(timing.plan.durationMs), step: 1)
                .accessibilityLabel("Inspection position in the overlap")
                .tint(palette.primary)
            Grid(alignment: .leading, horizontalSpacing: Spacing.md, verticalSpacing: Spacing.xs) {
                GridRow { Text(""); Text("Out"); Text("In") }.fontWeight(.semibold)
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
            if let outgoing { loadedRange("Out", outgoing) }
            if let incoming { loadedRange("In", incoming) }
        }
    }

    private func loadedRange(_ title: String, _ slice: TransitionAudioSlice) -> some View {
        Text("\(title) loaded \(transitionTimestamp(slice.startMs))–\(transitionTimestamp(slice.startMs + slice.durationMs))")
            .font(.caption2.monospacedDigit()).foregroundStyle(palette.onSurfaceVariant)
    }

    private func detailRow(_ label: String, _ out: String, _ inc: String) -> some View {
        GridRow { Text(label); Text(out); Text(inc) }
    }

    private func gain(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        let value = timing.automation(role).gainAt(inspection(timing))
        return value > 0 ? String(format: "%.1f dB", 20 * log10(value)) : "−∞ dB"
    }

    private func bass(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        workingSpec.bassSwap ? String(format: "%.1f dB", timing.automation(role).bassDbAt(inspection(timing))) : "Bypass"
    }

    private func filter(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        guard let setting = timing.automation(role).filterAt(inspection(timing)) else { return "Bypass" }
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
