import AVFoundation
import SwiftUI

/// The audio inspector: what the playing file is, what the engine does with it, what iOS reports
/// for the output, and a sample-peak meter. The file is inspected once per track; the output and
/// the meter refresh once a second while the screen is open. Nothing here changes playback or
/// sound settings, and the report it copies or shares leaves out paths and device names.
struct AudioDetailsView: View {
    @Environment(PlayerController.self) private var player
    @Environment(SoundStore.self) private var sound
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var source: SourceState = .loading
    @State private var output: OutputDiagnostics?
    @State private var peak: PeakReading?
    @State private var copied = false

    enum SourceState: Equatable {
        case loading
        case nothingPlaying
        case ready(SourceDiagnostics)
    }

    var body: some View {
        let runtime = sound.runtimeState
        let eq = DspDiagnostics.eqStage(runtime, settings: sound.settings)
        let headroom = DspDiagnostics.headroom(eq, sampleRateHz: runtime.sampleRateHz)
        NavigationStack {
            List {
                sourceSection
                playbackSection
                chainSection(eq)
                outputSection
                analysisSection(eq, headroom)
            }
            .navigationTitle("Audio details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = report(eq, headroom)
                        copied = true
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .accessibilityLabel("Copy audio details")
                    ShareLink(item: report(eq, headroom)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share audio details")
                }
            }
        }
        .task(id: player.state.currentSong?.id) { await inspect() }
        .task { await meter() }
    }

    private func inspect() async {
        guard let song = player.state.currentSong else {
            source = .nothingPlaying
            return
        }
        source = .loading
        let diagnostics = await Task.detached(priority: .utility) { SourceInspector.inspect(song) }.value
        guard !Task.isCancelled else { return }
        source = .ready(diagnostics)
    }

    /// Holds the tap (so the meter measures) while the screen is open, refreshing once a second.
    private func meter() async {
        let tap = player.engine.tap
        tap.acquire()
        defer { tap.release() }
        while !Task.isCancelled {
            peak = tap.meterReading()
            output = OutputDiagnostics.current()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func report(_ eq: EqStage, _ headroom: HeadroomEstimate) -> String {
        var diagnostics: SourceDiagnostics?
        if case .ready(let ready) = source { diagnostics = ready }
        return DiagnosticsReport.build(DiagnosticsSnapshot(
            source: diagnostics, state: stateText.lowercased(),
            decoderInput: pcmFormatText(player.engine.decodedFormat), sentToSystem: pcmFormatText(player.engine.outputFormat),
            eq: eq, headroom: headroom, peak: peak, output: output, transitionFading: player.engine.isCrossfading
        ))
    }

    private var stateText: String {
        switch player.state.status {
        case .playing: "Playing"
        case .paused: "Paused"
        default: player.state.currentSong == nil ? "Idle" : "Stopped"
        }
    }

    // MARK: - Sections

    private var sourceSection: some View {
        Section {
            switch source {
            case .loading: DetailNote("Inspecting the file…")
            case .nothingPlaying: DetailNote("Nothing is playing.")
            case .ready(let s):
                DetailRow("Title", s.title)
                DetailRow("Artist", s.artist)
                DetailRow("Album", s.album)
                DetailRow("Container", s.container)
                DetailRow("Codec", s.codec)
                DetailRow("Sample rate", s.sampleRate)
                DetailRow("Channels", s.channels)
                DetailRow("Bit depth", s.bitDepth, note: s.bitDepthNote)
                DetailRow("Bitrate", s.bitrate)
                DetailRow("Duration", s.duration)
                DetailRow("File size", s.fileSize)
                if let problem = s.problem { DetailNote(problem) }
            }
        } header: {
            Text("Source file")
        } footer: {
            Text("Read from the file itself without decoding it. \"File header\" values come from the audio header and are exact; \"Container\" values are what Core Audio reports for the file (estimates for some formats); \"Library index\" values were recorded when the library was scanned. Bit depth exists only for lossless formats that store it.")
        }
    }

    private var playbackSection: some View {
        Section {
            DetailRow("State", Fact(stateText, .player))
            DetailRow("Decoder", Fact("Core Audio file reader", .player))
            DetailRow("Decoder output", pcmFormatText(player.engine.decodedFormat).map { Fact($0, .player) },
                      note: player.engine.decodedFormat == nil ? "Reported when a track starts" : nil)
            DetailRow("Sent to iOS audio", pcmFormatText(player.engine.outputFormat).map { Fact($0, .player) },
                      note: player.engine.outputFormat == nil ? "Reported once audio output starts" : nil)
        } header: {
            Text("Playback")
        } footer: {
            Text("What the app's audio engine reports for the current track: the format the file is decoded to, and the format it hands to iOS after the app's processing.")
        }
    }

    private func chainSection(_ eq: EqStage) -> some View {
        let engine = player.engine
        let playing = engine.isRunning && player.state.isPlaying
        let spatial = output?.spatialAudio == true
        return Section {
            ChainStep(title: "Decoder", state: playing ? "Running" : "Idle", appControlled: true, detail: "Core Audio file reader")
            ChainStep(title: "Transition", state: engine.isCrossfading ? "Fading" : "Unity", appControlled: true,
                      detail: "Changes levels only while a transition set up in the Transition Studio plays")
            if engine.hasProcessing {
                ChainStep(title: "Equalizer", state: eq.status.rawValue, appControlled: true,
                          detail: eq.reason + (eq.status == .active ? "; samples beyond full scale are clipped" : ""))
            } else {
                ChainStep(title: "Equalizer", state: "Unavailable", appControlled: true,
                          detail: "The processing units could not be loaded; audio plays without them")
            }
            ChainStep(title: "Visualizer tap", state: engine.tap.isCollecting ? "Reading" : "Idle", appControlled: true,
                      detail: "Read-only copy for the visualizer and the peak meter below; never changes the audio")
            ChainStep(title: "iOS audio system", state: "Not visible", appControlled: false,
                      detail: "Mixing, possible resampling, system effects" + (spatial ? "; spatial audio on" : ""))
            ChainStep(title: "Output", state: output?.route.first?.typeName ?? "Unknown", appControlled: false,
                      detail: output.map { $0.route.map(\.typeName).joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 } ?? "Route not reported")
            NavigationLink("Equalizer settings") { EqualizerView() }
        } header: {
            Text("Processing")
        } footer: {
            Text("The processing the app itself performs, in its real order. After the app, iOS mixes, may resample, and may apply system effects (and Bluetooth re-encodes); that part is hidden from apps, so it is shown as one step. The app has no preamp, bass boost, virtualizer, loudness or limiter stage.")
        }
    }

    private var outputSection: some View {
        Section {
            if let output {
                if output.route.isEmpty { DetailRow("Route", nil as Fact?) }
                ForEach(Array(output.route.enumerated()), id: \.offset) { _, port in
                    DetailRow("Device", Fact([port.typeName, port.name].joined(separator: " · "), .platform))
                }
                DetailRow("Session sample rate", output.sampleRateHz.map { Fact(MediaFormats.sampleRateText($0), .platform) })
                DetailRow("Output channels", output.channels.map { Fact(MediaFormats.channelsText($0), .platform) })
                DetailRow("Buffer", output.bufferMs.map { Fact(String(format: "%.1f ms", $0), .platform) })
                DetailRow("Output latency", output.latencyMs.map { Fact(String(format: "%.0f ms", $0), .platform) })
                DetailRow("Spatial audio", Fact(output.spatialAudio ? "On" : "Off", .platform))
            } else {
                DetailNote("Reading the audio route…")
            }
        } header: {
            Text("Output")
        } footer: {
            Text("What iOS reports for the audio session. The session sample rate is what the hardware runs at now; iOS converts the app's output to it when they differ.")
        }
    }

    private func analysisSection(_ eq: EqStage, _ headroom: HeadroomEstimate) -> some View {
        Section {
            DetailRow("Clipping risk from EQ",
                      Fact(headroom.risk == .none ? headroom.risk.rawValue
                           : String(format: "%@ (max boost %+.1f dB)", headroom.risk.rawValue, headroom.maxBoostDb), .player),
                      note: headroom.advice)
            let measured = peak.flatMap { $0.frames > 0 ? $0 : nil }
            DetailRow("Sample peak after EQ", measured?.peakDbfs.map { Fact(String(format: "%.1f dBFS", $0), .player) },
                      note: measured.map { String(format: "Over %.0f s · %lld samples at full scale", $0.secondsMeasured, $0.fullScaleSamples) }
                          ?? "Measured while music plays with this screen open")
            Button("Reset measurement") {
                player.engine.tap.resetMeter()
                peak = player.engine.tap.meterReading()
            }
        } header: {
            Text("Headroom")
        } footer: {
            Text("The estimate comes from the EQ settings: any boost can push loud music past full scale (0 dBFS), where the EQ clips. The measurement shows the largest sample after the EQ while this screen is open. It cannot see peaks between samples (true peak) or what iOS does afterwards, and full-scale samples may already be in the recording.")
        }
    }
}

/// A value with its origin; nil shows as "Unavailable", never as 0 or a guess.
private struct DetailRow: View {
    let label: String
    let fact: Fact?
    var note: String?
    @Environment(\.palette) private var palette

    init(_ label: String, _ fact: Fact?, note: String? = nil) {
        self.label = label
        self.fact = fact
        self.note = note
    }

    /// Plain metadata from the library (title, artist, album).
    init(_ label: String, _ text: String) {
        self.init(label, text.isEmpty ? nil : Fact(text, .library))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(palette.onSurfaceVariant)
                Spacer(minLength: Spacing.md)
                Text(fact?.value ?? "Unavailable")
                    .foregroundStyle(fact == nil ? palette.onSurfaceVariant : palette.onSurface)
                    .multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
            if let fact {
                Text(fact.provenance.rawValue).font(.caption2).foregroundStyle(palette.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DetailNote: View {
    let text: String
    @Environment(\.palette) private var palette

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(palette.onSurfaceVariant)
    }
}

/// One step of the processing chain: who controls it, its state, and what it does.
private struct ChainStep: View {
    let title: String
    let state: String
    let appControlled: Bool
    let detail: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(state)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 3)
                    .background(palette.surfaceVariant, in: Capsule())
            }
            Text((appControlled ? "App · " : "System · ") + detail)
                .font(.caption).foregroundStyle(palette.onSurfaceVariant)
        }
        .accessibilityElement(children: .combine)
    }
}
