import SwiftUI

/// The equaliser: on / off, presets (save and delete your own), the response curve with draggable
/// band nodes, the active band count, and the selected band's type, frequency, gain and Q.
struct EqualizerView: View {
    @Environment(SoundStore.self) private var sound
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        let settings = sound.settings
        let selected = settings.selectedBandIndex.clamped(0, settings.activeBandCount - 1)
        let band = settings.bands.indices.contains(selected) ? settings.bands[selected] : SoundSettings.defaultBands()[selected]
        Form {
            Section {
                Toggle("Equalizer", isOn: Binding(get: { settings.isEqEnabled }, set: { sound.setEqEnabled($0) }))
            }
            Section("Preset & curve") {
                HStack {
                    Menu {
                        ForEach(settings.allPresets) { preset in
                            Button(preset.name) { sound.applyPreset(preset.id) }
                        }
                        let customs = settings.customPresets
                        if !customs.isEmpty {
                            Menu("Delete a custom preset") {
                                ForEach(customs) { preset in
                                    Button(preset.name, role: .destructive) { sound.deleteCustomPreset(preset.id) }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Preset")
                            Spacer()
                            Text(settings.allPresets.first { $0.id == settings.activePresetId }?.name ?? "Flat").foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { savingPreset = true } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Save custom preset")
                    Button { sound.resetToFlat() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Reset to flat")
                }
                EqCurve(settings: settings, selected: selected,
                        onSelect: { sound.setSelectedBandIndex($0) },
                        onDrag: { index, hz, gain in sound.setBandFrequencyAndGain(index, hz, gain) })
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.sm, bottom: Spacing.sm, trailing: Spacing.sm))
            }
            Section("Bands") {
                Stepper("Active bands: \(settings.activeBandCount)", value: Binding(get: { settings.activeBandCount }, set: { sound.setActiveBandCount($0) }),
                        in: Equalizer.minBandCount...Equalizer.bandCount)
                    .disabled(!settings.isEqEnabled)
                Picker("Band", selection: Binding(get: { selected }, set: { sound.setSelectedBandIndex($0) })) {
                    ForEach(0..<settings.activeBandCount, id: \.self) { Text("\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Band \(selected + 1)") {
                let isFirst = selected == 0
                let isLast = selected == settings.activeBandCount - 1
                if isFirst || isLast {
                    let shelf: FilterType = isFirst ? .lowShelf : .highShelf
                    Picker("Filter type", selection: Binding(get: { band.filterType == shelf ? 1 : 0 },
                                                             set: { sound.setFilterType(selected, $0 == 1 ? shelf : .peaking) })) {
                        Text("Bell").tag(0)
                        Text("Shelf").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                labeledSlider("Center frequency", value: formatFrequency(band.frequencyHz),
                              binding: Binding(get: { frequencyToNormalized(band.frequencyHz) },
                                               set: { sound.setBandFrequency(selected, normalizedToFrequency($0)) }), range: 0...1)
                labeledSlider("Gain", value: formatGain(band.gainDb),
                              binding: Binding(get: { band.gainDb }, set: { sound.setBandGain(selected, $0) }),
                              range: Equalizer.minGainDb...Equalizer.maxGainDb)
                labeledSlider("Q-factor (sharpness)", value: String(format: "%.2f", band.q),
                              binding: Binding(get: { band.q }, set: { sound.setBandQ(selected, $0) }), range: Equalizer.minQ...Equalizer.maxQ)
            }
            .disabled(!settings.isEqEnabled)
        }
        .navigationTitle("Equalizer")
        .alert("Save custom preset", isPresented: $savingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                sound.saveCustomPreset(presetName)
                presetName = ""
            }
        }
    }

    private func labeledSlider(_ label: String, value: String, binding: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(Color.accentColor).monospacedDigit()
            }
            Slider(value: binding, in: range)
        }
    }

    private func frequencyToNormalized(_ hz: Float) -> Float {
        let low = log10(Equalizer.minFreqHz), high = log10(Equalizer.maxFreqHz)
        return (log10(hz.clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz)) - low) / (high - low)
    }

    private func normalizedToFrequency(_ norm: Float) -> Float {
        let low = log10(Equalizer.minFreqHz), high = log10(Equalizer.maxFreqHz)
        return pow(10, low + norm.clamped(0, 1) * (high - low)).clamped(Equalizer.minFreqHz, Equalizer.maxFreqHz)
    }

    private func formatFrequency(_ hz: Float) -> String { hz >= 1000 ? "\(Int((hz / 1000).rounded())) kHz" : "\(Int(hz.rounded())) Hz" }

    private func formatGain(_ db: Float) -> String { (db > 0 ? "+" : "") + String(format: "%.1f dB", db) }
}

/// The combined response of the active bands, with a draggable numbered node per band.
private struct EqCurve: View {
    let settings: SoundSettings
    let selected: Int
    let onSelect: (Int) -> Void
    let onDrag: (Int, Float, Float) -> Void
    @Environment(\.palette) private var palette
    @State private var dragged: Int?

    private static let minFreq: Float = 20
    private static let maxFreq: Float = 20_000
    private static let points: [Float] = (0..<120).map { i in
        let low = log10(minFreq), high = log10(maxFreq)
        return pow(10, low + Float(i) / 119 * (high - low))
    }

    var body: some View {
        let response = EqKernel.response(of: settings, at: Self.points)
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, _ in
                for db: Float in [12, 6, 0, -6, -12] {
                    var line = Path()
                    let y = gainToY(db, size.height)
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(palette.outline.opacity(db == 0 ? 0.8 : 0.35)), lineWidth: db == 0 ? 1.5 : 1)
                }
                for hz: Float in [60, 250, 1000, 4000, 12000] {
                    var line = Path()
                    let x = freqToX(hz, size.width)
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(palette.outline.opacity(0.35)), lineWidth: 1)
                }
                var curve = Path()
                for (i, hz) in Self.points.enumerated() {
                    let point = CGPoint(x: freqToX(hz, size.width), y: gainToY(response[i], size.height))
                    if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(palette.primary), lineWidth: 3)
                for index in 0..<settings.activeBandCount {
                    let band = settings.bands[index]
                    let center = CGPoint(x: freqToX(band.frequencyHz, size.width), y: gainToY(band.gainDb, size.height))
                    let isSelected = index == selected
                    if isSelected {
                        context.fill(Path(ellipseIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)),
                                     with: .color(palette.surfaceVariant))
                        context.fill(Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)), with: .color(palette.primary))
                    } else {
                        context.stroke(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                                       with: .color(palette.primary), lineWidth: 2)
                    }
                    context.draw(Text("\(index + 1)").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? palette.onPrimary : palette.primary), at: center)
                }
            }
            .background(palette.onSurface.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragged == nil {
                            dragged = nearest(to: value.startLocation, in: size)
                            if let dragged { onSelect(dragged) }
                        }
                        guard let dragged, value.translation != .zero else { return }
                        onDrag(dragged, xToFreq(value.location.x, size.width), yToGain(value.location.y, size.height))
                    }
                    .onEnded { _ in dragged = nil }
            )
            .disabled(!settings.isEqEnabled)
            .accessibilityLabel("Equalizer curve")
        }
    }

    private func nearest(to point: CGPoint, in size: CGSize) -> Int? {
        var best: Int?
        var bestDistance: CGFloat = 48
        for index in 0..<settings.activeBandCount {
            let band = settings.bands[index]
            let distance = hypot(point.x - freqToX(band.frequencyHz, size.width), point.y - gainToY(band.gainDb, size.height))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func freqToX(_ hz: Float, _ width: CGFloat) -> CGFloat {
        let low = log10(Self.minFreq), high = log10(Self.maxFreq)
        return CGFloat((log10(hz.clamped(Self.minFreq, Self.maxFreq)) - low) / (high - low)) * width
    }

    private func xToFreq(_ x: CGFloat, _ width: CGFloat) -> Float {
        let low = log10(Self.minFreq), high = log10(Self.maxFreq)
        return pow(10, low + Float(x / max(width, 1)).clamped(0, 1) * (high - low))
    }

    private func gainToY(_ db: Float, _ height: CGFloat) -> CGFloat {
        CGFloat((Equalizer.maxGainDb - db.clamped(Equalizer.minGainDb, Equalizer.maxGainDb)) / (Equalizer.maxGainDb - Equalizer.minGainDb)) * height
    }

    private func yToGain(_ y: CGFloat, _ height: CGFloat) -> Float {
        (Equalizer.maxGainDb - Float(y / max(height, 1)) * (Equalizer.maxGainDb - Equalizer.minGainDb)).clamped(Equalizer.minGainDb, Equalizer.maxGainDb)
    }
}
