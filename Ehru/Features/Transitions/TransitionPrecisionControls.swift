import SwiftUI

struct TransitionDetailsSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) { content }
                    .padding(Spacing.lg)
            }
            .background(palette.background)
            .foregroundStyle(palette.onSurface)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct TransitionDurationControl: View {
    let spec: TransitionSpec
    let enabled: Bool
    let pair: StudioPair
    let beginDrag: () -> Void
    let drag: (Int) -> Void
    let choose: (Int) -> Void
    @State private var showing = false
    @Environment(\.palette) private var palette

    var body: some View {
        let effective = spec.effectiveDurationMs(outgoingDurationMs: pair.from.song.durationMs, incomingDurationMs: pair.to.song.durationMs)
        Button { showing = true } label: {
            HStack(spacing: 3) {
                Text(enabled ? TransitionSpec.durationLabel(effective) : "Off").monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.semibold)).frame(minWidth: 52, minHeight: 44)
        }
        .accessibilityLabel("Overlap duration, \(enabled ? TransitionSpec.durationLabel(effective) : "off")")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                DurationBlock(spec: enabled ? spec : nil, base: spec, pair: pair,
                              beginDrag: beginDrag, drag: drag, choose: choose)
                Stepper(value: Binding(get: { spec.durationMs }, set: choose),
                        in: TransitionSpec.minDurationMs...TransitionSpec.maxDurationMs, step: TransitionSpec.durationStepMs) {
                    Text("\(spec.durationMs) ms requested").font(.caption.monospacedDigit())
                }
                Text("100 ms steps · effective length is limited by both songs and their cue points.")
                    .font(.caption2).foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(Spacing.lg).frame(idealWidth: 310)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Numeric editing is committed once, using exactly the same validated point edit as touch.
struct TransitionPointEditor: View {
    let spec: TransitionSpec
    let handle: TransitionCurveHandle
    let durationMs: Int
    let apply: (TransitionSpec) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var timeMs: Double
    @State private var gainDb: Double
    @State private var silence: Bool

    init(spec: TransitionSpec, handle: TransitionCurveHandle, durationMs: Int, apply: @escaping (TransitionSpec) -> Void) {
        self.spec = spec; self.handle = handle; self.durationMs = durationMs; self.apply = apply
        let points = TransitionEditing.curveOf(spec, handle.role).points
        let point = points.indices.contains(handle.index) ? points[handle.index] : CurvePoint(t: 0, gain: 0)
        _timeMs = State(initialValue: Double(point.t) * Double(durationMs))
        _gainDb = State(initialValue: point.gain > 0 ? Double(20 * log10(point.gain)) : -96)
        _silence = State(initialValue: point.gain == 0)
    }

    private var count: Int { TransitionEditing.curveOf(spec, handle.role).points.count }
    private var fixed: Bool { TransitionEditing.fixedGain(handle.role, index: handle.index, last: count - 1) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section(handle.role == .outgoing ? "Outgoing volume point" : "Incoming volume point") {
                    LabeledContent("Time in overlap · ms") {
                        TextField("Milliseconds", value: $timeMs, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .disabled(handle.index == 0 || handle.index == count - 1)
                    }
                    LabeledContent("Gain · dB") {
                        TextField("Decibels", value: $gainDb, format: .number)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                            .disabled(fixed || silence)
                    }
                    Toggle("Silence · −∞ dB", isOn: $silence).disabled(fixed)
                }
                Section {
                    Text("Time is relative to the actual overlap. Points stay between their neighbours. Fixed endpoint times and levels are preserved. Gain is limited to −96…0 dB; use Silence for exact zero.")
                        .font(.caption)
                }
            }
            .navigationTitle("Exact point values").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(TransitionPointPrecision.updated(spec, handle: handle, durationMs: durationMs,
                                                               timeMs: timeMs, gainDb: gainDb, silence: silence))
                        dismiss()
                    }
                    .disabled(!timeMs.isFinite || !gainDb.isFinite || durationMs <= 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
