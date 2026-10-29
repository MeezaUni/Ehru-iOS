import SwiftUI

struct PairAudioPlot: View {
    let timing: PairTransitionTiming
    let viewport: TransitionWaveformViewport
    let outgoing: TransitionAudioSlice?
    let incoming: TransitionAudioSlice?
    let inspectedMs: Double
    let displayGain: Float
    let activeRole: TransitionRole?
    @Environment(\.palette) private var palette

    var body: some View {
        Canvas { context, size in
            let width = size.width, height = size.height
            func x(_ ms: Double) -> CGFloat { CGFloat(viewport.fraction(at: ms)) * width }
            let left = max(x(0), 0), right = min(x(Double(timing.plan.durationMs)), width)
            if right > left {
                context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: height)), with: .color(palette.primary.opacity(0.08)))
            }
            drawRuler(context, size)
            for (index, role) in [TransitionRole.outgoing, .incoming].enumerated() {
                let lane = CGRect(x: 0, y: CGFloat(index) * height / 2, width: width, height: height / 2)
                let center = lane.minY + lane.height / 2 + 7
                let amplitude = (lane.height - 50) / 2
                let slice = index == 0 ? outgoing : incoming
                let color = index == 0 ? Color.orange : AutomationColors.volume
                if activeRole == role {
                    context.fill(Path(lane), with: .color(color.opacity(0.06)))
                    context.stroke(Path(lane.insetBy(dx: 1, dy: 1)), with: .color(color.opacity(0.5)), lineWidth: 1)
                }
                let sourceStart = Double(role == .outgoing ? timing.plan.startAtMs : timing.plan.incomingStartMs)
                if let slice {
                    drawAudio(slice, role: role, sourceStart: sourceStart, center: center, amplitude: amplitude,
                              color: color, context: context, width: width)
                } else {
                    context.draw(Text("Source waveform unavailable").font(.caption2).foregroundColor(palette.onSurfaceVariant),
                                 at: CGPoint(x: width / 2, y: center))
                }
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: center)); zero.addLine(to: CGPoint(x: width, y: center))
                context.stroke(zero, with: .color(palette.onSurface.opacity(0.1)), lineWidth: 0.5)
                var curve = Path()
                for step in 0...160 {
                    let time = Double(timing.plan.durationMs) * Double(step) / 160
                    let gain = timing.automation(role).gainAt(time)
                    let point = CGPoint(x: x(time), y: center + amplitude - CGFloat(gain) * amplitude * 2)
                    if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(palette.onSurface), style: StrokeStyle(lineWidth: 1.5, dash: index == 0 ? [] : [4, 3]))
                let title = role == .outgoing ? "OUT · drag" : "IN · drag"
                context.draw(Text(title).font(.caption2.weight(.semibold)).foregroundColor(color),
                             at: CGPoint(x: 8, y: lane.minY + 13), anchor: .leading)
                let times = "\(sourceTimeLabel(sourceStart + viewport.startMs)) – \(sourceTimeLabel(sourceStart + viewport.endMs))"
                context.draw(Text(times).font(.caption2.monospacedDigit()).foregroundColor(palette.onSurfaceVariant),
                             at: CGPoint(x: width - 8, y: lane.minY + 13), anchor: .trailing)
            }
            var divider = Path()
            divider.move(to: CGPoint(x: 0, y: height / 2)); divider.addLine(to: CGPoint(x: width, y: height / 2))
            context.stroke(divider, with: .color(palette.outline.opacity(0.4)), lineWidth: 1)
            for time in [0.0, Double(timing.plan.durationMs)] where (0...1).contains(viewport.fraction(at: time)) {
                var line = Path()
                line.move(to: CGPoint(x: x(time), y: 26)); line.addLine(to: CGPoint(x: x(time), y: height - 20))
                context.stroke(line, with: .color(palette.onSurface.opacity(0.25)), lineWidth: 1)
            }
            if (0...1).contains(viewport.fraction(at: inspectedMs)) {
                var line = Path()
                line.move(to: CGPoint(x: x(inspectedMs), y: 26)); line.addLine(to: CGPoint(x: x(inspectedMs), y: height - 20))
                context.stroke(line, with: .color(palette.primary.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .background(palette.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement()
        .accessibilityLabel("Outgoing and incoming audio waveforms")
        .accessibilityValue("\(TransitionSpec.durationLabel(timing.plan.durationMs)) overlap. \(String(format: "%.2f", viewport.durationMs / 1000)) seconds visible.")
        .accessibilityHint("Drag each waveform horizontally to move its cue. Pinch to zoom.")
    }

    private func sourceTimeLabel(_ ms: Double) -> String {
        ms < 0 ? "−" + transitionTimestamp(-ms) : transitionTimestamp(ms)
    }

    private func drawRuler(_ context: GraphicsContext, _ size: CGSize) {
        let steps: [Double] = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000]
        let step = steps.first { $0 >= viewport.durationMs / 4 } ?? 10_000
        var time = ceil(viewport.startMs / step) * step
        while time <= viewport.endMs {
            let x = CGFloat(viewport.fraction(at: time)) * size.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: 26)); line.addLine(to: CGPoint(x: x, y: size.height - 20))
            context.stroke(line, with: .color(palette.outline.opacity(0.14)), lineWidth: 0.5)
            context.draw(Text(String(format: "%+.2f s", time / 1000)).font(.system(size: 9, design: .monospaced)).foregroundColor(palette.onSurfaceVariant),
                         at: CGPoint(x: x.clamped(25, max(size.width - 25, 25)), y: size.height - 8))
            time += step
        }
    }

    private func drawAudio(_ slice: TransitionAudioSlice, role: TransitionRole, sourceStart: Double,
                           center: CGFloat, amplitude: CGFloat, color: Color, context: GraphicsContext, width: CGFloat) {
        guard slice.durationMs > 0, !slice.peaks.isEmpty else { return }
        let count = slice.peaks.count
        let first = Int(floor((sourceStart + viewport.startMs - slice.startMs) / slice.durationMs * Double(count))).clamped(0, count)
        let last = Int(ceil((sourceStart + viewport.endMs - slice.startMs) / slice.durationMs * Double(count))).clamped(0, count)
        guard first < last else { return }
        // Reduce to at most two columns per point; four batched paths keep finger tracking light.
        let step = max(Int(ceil(Double(last - first) / Double(max(width * 2, 1)))), 1)
        var peaks = Path(), rms = Path(), contextPeaks = Path(), contextRMS = Path()
        var index = first
        while index < last {
            let end = min(index + step, last)
            let time = slice.startMs + (Double(index + end) / 2) * slice.durationMs / Double(count) - sourceStart
            let x = CGFloat(viewport.fraction(at: time)) * width
            let peak = CGFloat(min((slice.peaks[index..<end].max() ?? 0) * displayGain, 1)) * amplitude
            let level = CGFloat(min((slice.rms[index..<end].max() ?? 0) * displayGain, 1)) * amplitude
            let barWidth = max(CGFloat(Double(end - index) * slice.durationMs / Double(count) / viewport.durationMs) * width, 0.5)
            let p = CGRect(x: x - barWidth / 2, y: center - peak, width: barWidth, height: peak * 2)
            let r = CGRect(x: x - barWidth / 2, y: center - level, width: barWidth, height: level * 2)
            let plays = role == .outgoing ? time <= Double(timing.plan.durationMs) : time >= 0
            if plays { peaks.addRect(p); rms.addRect(r) }
            else { contextPeaks.addRect(p); contextRMS.addRect(r) }
            index = end
        }
        context.fill(contextPeaks, with: .color(color.opacity(0.12)))
        context.fill(contextRMS, with: .color(color.opacity(0.18)))
        context.fill(peaks, with: .color(color.opacity(0.4)))
        context.fill(rms, with: .color(color.opacity(0.9)))
    }
}

/// A separate time navigator: dragging this strip moves the zoomed view, never a song cue.
struct TransitionWaveformOverview: View {
    let timing: PairTransitionTiming
    let viewport: TransitionWaveformViewport
    let focus: (Double) -> Void
    @Environment(\.palette) private var palette
    @State private var dragCenter: Double?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let bounds = TransitionWaveformViewport.bounds(timing)
                let span = bounds.upperBound - bounds.lowerBound
                func x(_ time: Double) -> CGFloat { CGFloat((time - bounds.lowerBound) / span) * size.width }
                let track = CGRect(x: 0, y: 12, width: size.width, height: 20)
                context.fill(Path(roundedRect: track, cornerRadius: 6), with: .color(palette.onSurface.opacity(0.05)))
                let window = CGRect(x: x(viewport.startMs), y: 12, width: x(viewport.endMs) - x(viewport.startMs), height: 20)
                context.fill(Path(roundedRect: window, cornerRadius: 6), with: .color(palette.primary.opacity(0.22)))
                context.stroke(Path(roundedRect: window.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6), with: .color(palette.primary.opacity(0.6)), lineWidth: 1)
                for time in [0.0, Double(timing.plan.durationMs)] {
                    let mark = CGRect(x: x(time) - 0.5, y: 15, width: 1, height: 14)
                    context.fill(Path(mark), with: .color(palette.onSurface.opacity(0.4)))
                }
            }
            .overlay {
                PanInteraction(canBegin: { _, delta in HorizontalGestureIntent.accepts(delta) },
                               change: { move($0, width: geometry.size.width) },
                               end: { move($0, width: geometry.size.width); dragCenter = nil }, cancel: { dragCenter = nil },
                               tap: { focus(time(at: $0.x, width: geometry.size.width)) })
            }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Visible timeline window")
        .accessibilityValue(String(format: "%.2f seconds visible", viewport.durationMs / 1000))
        .accessibilityHint("Adjust to move the view without moving either cue.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: focus(viewport.centerMs + viewport.durationMs / 4)
            case .decrement: focus(viewport.centerMs - viewport.durationMs / 4)
            @unknown default: break
            }
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        let bounds = TransitionWaveformViewport.bounds(timing)
        return bounds.lowerBound + Double((x / max(width, 1)).clamped(0, 1)) * (bounds.upperBound - bounds.lowerBound)
    }

    private func move(_ sample: PanInteraction.Sample, width: CGFloat) {
        let bounds = TransitionWaveformViewport.bounds(timing)
        if dragCenter == nil {
            let start = time(at: sample.startLocation.x, width: width)
            dragCenter = (viewport.startMs...viewport.endMs).contains(start) ? viewport.centerMs : start
        }
        guard let center = dragCenter else { return }
        focus(center + Double(sample.translation.width / max(width, 1)) * (bounds.upperBound - bounds.lowerBound))
    }
}
