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
    @State private var inspectedMs: Double = 0
    @State private var preview = PairTransitionPreview()

    private var timing: PairTransitionTiming? {
        PairTransitionTiming(spec: spec, outgoingMs: pair.from.song.durationMs, incomingMs: pair.to.song.durationMs)
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
        timing.map { Request(from: pair.from.song, to: pair.to.song,
                             outStart: $0.outgoingRange.lowerBound, outEnd: $0.outgoingRange.upperBound,
                             inStart: $0.incomingRange.lowerBound, inEnd: $0.incomingRange.upperBound) }
    }

    var body: some View {
        StudioPanel {
            sourceLine("Outgoing", pair.from.song, outgoing)
            if let timing {
                PairAudioPlot(timing: timing, outgoing: outgoing, incoming: incoming, inspectedMs: inspection(timing))
                    .frame(height: 244)
                sourceLine("Incoming", pair.to.song, incoming)
                HStack {
                    Text("PCM peak / RMS · white line: volume gain")
                        .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                    Spacer(minLength: 0)
                    if loading { ProgressView().controlSize(.small) }
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
            outgoing = nil
            incoming = nil
            loading = true
            guard let timing else { loading = false; return }
            // A duration/cue drag does not start a decode for every intermediate value.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            async let out = TransitionAnalysisStore.shared.slice(url: pair.from.song.url, range: timing.outgoingRange)
            async let inc = TransitionAnalysisStore.shared.slice(url: pair.to.song.url, range: timing.incomingRange)
            let result = await (out, inc)
            guard !Task.isCancelled else { return }
            outgoing = result.0
            incoming = result.1
            loading = false
        }
        .onChange(of: spec) { _, _ in preview.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preview.stop(resume: false) } }
        .onChange(of: player.state.isPlaying) { _, playing in
            if playing { preview.stop(resume: false) }
        }
        .onChange(of: player.state.currentEntry?.id) { _, _ in preview.stop(resume: false) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in preview.stop(resume: false) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in preview.stop(resume: false) }
        .onDisappear { preview.stop(resume: scenePhase == .active) }
    }

    private func inspection(_ timing: PairTransitionTiming) -> Double { inspectedMs.clamped(0, Double(timing.plan.durationMs)) }

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
            .disabled(loading || outgoing == nil || incoming == nil)
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
                detailRow("Source peak", outgoing.map { TransitionAudioSlice.dbFS($0.peak) } ?? "Unavailable",
                          incoming.map { TransitionAudioSlice.dbFS($0.peak) } ?? "Unavailable")
                detailRow("Source RMS", outgoing.map { TransitionAudioSlice.dbFS($0.meanRMS) } ?? "Unavailable",
                          incoming.map { TransitionAudioSlice.dbFS($0.meanRMS) } ?? "Unavailable")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(palette.onSurfaceVariant)
            Text("Peak/RMS are measured over each displayed source window before processing. Gain, shelf and cutoff are the engine's automation targets at the inspection point. BPM is the file's tag; beatmatching and key analysis are unavailable.")
                .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
        }
    }

    private func detailRow(_ label: String, _ out: String, _ inc: String) -> some View {
        GridRow { Text(label); Text(out); Text(inc) }
    }

    private func gain(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        let value = timing.automation(role).gainAt(inspection(timing))
        return value > 0 ? String(format: "%.1f dB", 20 * log10(value)) : "−∞ dB"
    }

    private func bass(_ timing: PairTransitionTiming, _ role: TransitionRole) -> String {
        spec.bassSwap ? String(format: "%.1f dB", timing.automation(role).bassDbAt(inspection(timing))) : "Bypass"
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

private struct PairAudioPlot: View {
    let timing: PairTransitionTiming
    let outgoing: TransitionAudioSlice?
    let incoming: TransitionAudioSlice?
    let inspectedMs: Double
    @Environment(\.palette) private var palette

    var body: some View {
        Canvas { context, size in
            let width = size.width, height = size.height
            let total = Double(timing.totalMs)
            func x(_ ms: Double) -> CGFloat { CGFloat((ms + Double(timing.leadMs)) / total) * width }
            let begin = x(0), end = x(Double(timing.plan.durationMs))
            context.fill(Path(CGRect(x: begin, y: 0, width: end - begin, height: height)), with: .color(palette.primary.opacity(0.08)))
            for (index, role) in [TransitionRole.outgoing, .incoming].enumerated() {
                let center = height * (index == 0 ? 0.25 : 0.75)
                let amplitude = height * 0.20
                let slice = index == 0 ? outgoing : incoming
                let color = index == 0 ? Color.orange : AutomationColors.volume
                if let slice {
                    let offset = Double(role == .outgoing ? timing.plan.startAtMs : timing.plan.incomingStartMs)
                    for bin in slice.peaks.indices {
                        let time = slice.startMs + (Double(bin) + 0.5) * slice.durationMs / Double(slice.peaks.count) - offset
                        let position = x(time)
                        let peak = CGFloat(min(slice.peaks[bin], 1)) * amplitude
                        let rms = CGFloat(min(slice.rms[bin], 1)) * amplitude
                        let barWidth = max(CGFloat(slice.durationMs / Double(slice.peaks.count) / total) * width, 0.5)
                        context.fill(Path(CGRect(x: position - barWidth / 2, y: center - peak, width: barWidth, height: peak * 2)), with: .color(color.opacity(0.35)))
                        context.fill(Path(CGRect(x: position - barWidth / 2, y: center - rms, width: barWidth, height: rms * 2)), with: .color(color.opacity(0.85)))
                    }
                } else {
                    context.draw(Text("Source waveform unavailable").font(.caption2).foregroundColor(palette.onSurfaceVariant), at: CGPoint(x: width / 2, y: center))
                }
                var curve = Path()
                for step in 0...160 {
                    let time = Double(timing.plan.durationMs) * Double(step) / 160
                    let gain = timing.automation(role).gainAt(time)
                    let point = CGPoint(x: x(time), y: center + amplitude - CGFloat(gain) * amplitude * 2)
                    if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(palette.onSurface), style: StrokeStyle(lineWidth: 1.5, dash: index == 0 ? [] : [4, 3]))
            }
            for position in [begin, end, x(inspectedMs)] {
                var line = Path()
                line.move(to: CGPoint(x: position, y: 0)); line.addLine(to: CGPoint(x: position, y: height))
                context.stroke(line, with: .color(palette.onSurface.opacity(position == x(inspectedMs) ? 0.7 : 0.2)), lineWidth: 1)
            }
        }
        .background(palette.background.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement()
        .accessibilityLabel("Decoded source waveforms with volume automation")
        .accessibilityValue("\(TransitionSpec.durationLabel(timing.plan.durationMs)) overlap. Use the inspection slider for exact values.")
    }
}
