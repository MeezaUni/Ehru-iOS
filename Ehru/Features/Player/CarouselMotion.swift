import Observation
import SwiftUI

/// One finite animation for position and layout. Rendering only samples this state; it never
/// dispatches a state change back into the animation that is currently being rendered.
@MainActor
@Observable
final class CarouselMotion {
    private(set) var focus: CGFloat = 0
    private(set) var stack: CGFloat = 0
    private(set) var frontOrdinal = 0
    private(set) var moving = false
    @ObservationIgnored let meter = CarouselPresentationMeter()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var settlement: Task<Void, Never>?
    @ObservationIgnored private var origin: CarouselPresentationSample?

    static let duration: TimeInterval = 0.28

    func hold() {
        settlement?.cancel(); settlement = nil
        generation = UUID()
        moving = true
    }

    func drag(translation: CGFloat, page: CGFloat, center: Int, canPrevious: Bool, canNext: Bool) {
        guard translation.isFinite, page.isFinite, page > 0 else { return }
        if origin == nil {
            hold()
            origin = meter.sample(fallback: CarouselPresentationSample(focus: focus, stack: stack))
        }
        guard let origin else { return }
        let distance = -translation / page
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) {
            focus = CarouselDragLimit.focus(origin.focus + distance, center: center, canPrevious: canPrevious, canNext: canNext)
            // A depth-deck swipe remains a depth-deck swipe; only the layout button spreads it.
            stack = origin.stack
            frontOrdinal = Int(focus.rounded())
        }
    }

    func settle(center: Int, stacked: Bool, reduceMotion: Bool, completion: @escaping () -> Void = {}) {
        origin = nil
        settlement?.cancel()
        let token = UUID(); generation = token
        let duration = reduceMotion ? 0.16 : Self.duration
        let animation = Animation.timingCurve(0.22, 0.8, 0.25, 1, duration: duration)
        withAnimation(animation) {
            moving = true
            focus = CGFloat(center)
            stack = stacked ? 1 : 0
            frontOrdinal = center
        }
        // Cleanup is bounded independently of SwiftUI's render/visibility completion callbacks.
        // Native interpolation still draws every frame; this task only releases interaction state.
        settlement = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.settlement = nil
            self.meter.record(self.focus, stack: self.stack)
            self.moving = false
            completion()
        }
    }

    func snap(center: Int, stacked: Bool) {
        cancel()
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) {
            focus = CGFloat(center)
            stack = stacked ? 1 : 0
            frontOrdinal = center
            moving = false
        }
        meter.record(focus, stack: stack)
    }

    func endGesture() { origin = nil }
    func cancel() { settlement?.cancel(); settlement = nil; generation = UUID(); origin = nil; moving = false }
}

enum CarouselSwipeIntent {
    /// The gesture's own travel determines direction, even when it interrupts a previous slide.
    static func direction(translation: CGFloat, predicted: CGFloat, page: CGFloat) -> Int {
        guard translation.isFinite, predicted.isFinite, page.isFinite, page > 0 else { return 0 }
        let projected = predicted - translation
        if abs(projected) > 180 { return projected < 0 ? 1 : -1 }
        guard abs(translation) > page * 0.25 else { return 0 }
        return translation < 0 ? 1 : -1
    }
}
