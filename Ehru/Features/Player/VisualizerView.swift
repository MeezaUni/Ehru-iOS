import SwiftUI

/// The visualizer: what is playing as spectrum bars, a circle of spokes around the artwork, or a
/// waveform. It only reads what the engine plays (never changes playback, the EQ or the audio),
/// and only while it is on screen.
struct VisualizerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var engine: VisualizerEngine?
    @State private var status: VisualizerStatus = .waiting

    var body: some View {
        let song = player.state.currentSong
        let options = settings.visualizer
        VStack(spacing: Spacing.md) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close visualizer")
                Text("Visualizer").font(.title2.weight(.bold))
                Spacer()
                optionsMenu(options)
            }
            Picker("Mode", selection: Binding(get: { options.mode }, set: { mode in settings.visualizer.mode = mode })) {
                Text("Bars").tag(VisualizerMode.spectrumBars)
                Text("Circle").tag(VisualizerMode.circularSpectrum)
                Text("Waveform").tag(VisualizerMode.oscilloscope)
            }
            .pickerStyle(.segmented)
            ZStack {
                GeometryReader { geometry in
                    if options.mode == .circularSpectrum, let song {
                        let side = min(geometry.size.width, geometry.size.height) * 0.24 * 2 * 0.86
                        SongArtworkView(song: song, maxPixels: 600)
                            .frame(width: side, height: side)
                            .clipShape(Circle())
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                }
                if let engine {
                    TimelineView(.animation(minimumInterval: options.reduceMotion ? 1.0 / 20 : 1.0 / 60)) { context in
                        Canvas { canvas, size in
                            engine.update(now: context.date.timeIntervalSince1970, isPlaying: player.state.isPlaying)
                            draw(engine, mode: options.mode, in: &canvas, size: size)
                        }
                        .onChange(of: context.date) { _, _ in if engine.status != status { status = engine.status } }
                    }
                    .accessibilityLabel(description(options.mode))
                }
                statusMessage(song)
            }
            .frame(maxHeight: .infinity)
            if let song {
                VStack(spacing: Spacing.xs) {
                    Text(song.title).font(.headline).lineLimit(1)
                    Text(song.artist).font(.subheadline).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                }
            }
            HStack(spacing: Spacing.xxl) {
                Button { player.skipPrevious() } label: { Image(systemName: "backward.fill").font(.title) }
                    .accessibilityLabel("Previous")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(palette.onPrimary)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(palette.primary))
                }
                .accessibilityLabel(player.state.isPlaying ? "Pause" : "Play")
                Button { player.skipNext() } label: { Image(systemName: "forward.fill").font(.title) }
                    .accessibilityLabel("Next")
            }
            .foregroundStyle(palette.onSurface)
            .padding(.vertical, Spacing.lg)
        }
        .padding(.horizontal, Spacing.lg)
        .buttonStyle(.plain)
        .background(palette.background.ignoresSafeArea())
        .onAppear {
            let made = VisualizerEngine(tap: player.engine.tap)
            made.apply(settings.visualizer)
            made.outputLatency = player.engine.outputLatency
            engine = made
            player.engine.tap.acquire()
        }
        .onDisappear {
            player.engine.tap.release()
            engine?.reset()
            engine = nil
        }
        .onChange(of: settings.visualizer) { _, new in engine?.apply(new) }
    }

    private func optionsMenu(_ options: VisualizerSettings) -> some View {
        Menu {
            Picker("Sensitivity", selection: Binding(get: { options.sensitivity }, set: { settings.visualizer.sensitivity = $0 })) {
                Text("Low").tag(VisualizerSensitivity.low)
                Text("Normal").tag(VisualizerSensitivity.normal)
                Text("High").tag(VisualizerSensitivity.high)
            }
            Picker("Smoothing", selection: Binding(get: { options.smoothing }, set: { settings.visualizer.smoothing = $0 })) {
                Text("Responsive").tag(VisualizerSmoothing.responsive)
                Text("Balanced").tag(VisualizerSmoothing.balanced)
                Text("Smooth").tag(VisualizerSmoothing.smooth)
            }
            Toggle("Reduce motion", isOn: Binding(get: { options.reduceMotion }, set: { settings.visualizer.reduceMotion = $0 }))
        } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(Rectangle()) }
        .menuStyle(.button)
        .accessibilityLabel("Visualizer options")
    }

    @ViewBuilder
    private func statusMessage(_ song: Song?) -> some View {
        let text: String? = song == nil ? "Play something to see it here."
            : status == .unavailable ? "The visualizer cannot read this audio. Playback is not affected."
            : status == .waiting ? "Listening…"
            : status == .paused ? "Paused" : nil
        if let text {
            Text(text).font(.subheadline).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center).padding(Spacing.xl)
        }
    }

    private func description(_ mode: VisualizerMode) -> String {
        switch mode {
        case .spectrumBars: "Spectrum of the music playing"
        case .circularSpectrum: "Circular spectrum of the music playing"
        case .oscilloscope: "Waveform of the music playing"
        }
    }

    private func draw(_ engine: VisualizerEngine, mode: VisualizerMode, in context: inout GraphicsContext, size: CGSize) {
        let accent = palette.primary
        let soft = palette.onSurface.opacity(0.25)
        switch mode {
        case .spectrumBars:
            let levels = engine.spectrum
            let slot = size.width / CGFloat(levels.count)
            let barWidth = slot * 0.62
            let baseline = size.height * 0.78
            let maxHeight = size.height * 0.62
            for (i, level) in levels.enumerated() {
                let height = max(CGFloat(level) * maxHeight, 2)
                let rect = CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2, y: baseline - height, width: barWidth, height: height)
                let color = level > 0.02 ? accent.opacity(0.55 + 0.45 * Double(level)) : soft
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        case .circularSpectrum:
            let levels = engine.spectrum
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let inner = min(size.width, size.height) * 0.24
            let reach = min(size.width, size.height) * 0.22
            let spokes = levels.count * 2
            let stroke = 2 * .pi * inner / CGFloat(spokes) * 0.55
            context.stroke(Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)),
                           with: .color(soft), lineWidth: 1)
            // Mirrored halves: bass at the top, treble at the bottom on both sides.
            for s in 0..<spokes {
                let band = s < levels.count ? s : spokes - 1 - s
                let level = CGFloat(levels[band])
                let angle = 2 * .pi * CGFloat(s) / CGFloat(spokes) - .pi / 2
                let dx = cos(angle), dy = sin(angle)
                let start = CGPoint(x: center.x + dx * (inner + stroke), y: center.y + dy * (inner + stroke))
                let length = max(level * reach, 2)
                var line = Path()
                line.move(to: start)
                line.addLine(to: CGPoint(x: start.x + dx * length, y: start.y + dy * length))
                let color = level > 0.02 ? accent.opacity(0.55 + 0.45 * Double(level)) : soft
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            }
        case .oscilloscope:
            let samples = engine.waveform
            let mid = size.height / 2
            let amplitude = size.height * 0.32
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(axis, with: .color(soft), lineWidth: 1)
            var path = Path()
            let step = size.width / CGFloat(max(samples.count - 1, 1))
            for (i, sample) in samples.enumerated() {
                let point = CGPoint(x: CGFloat(i) * step, y: mid - CGFloat(sample) * amplitude)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
