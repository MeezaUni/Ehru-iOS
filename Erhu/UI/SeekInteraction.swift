import SwiftUI
import UIKit

enum HorizontalGestureIntent {
    static func accepts(_ translation: CGSize) -> Bool {
        abs(translation.width) > 0 && abs(translation.width) > abs(translation.height) * 1.25
    }
}

enum SongSwipeAction: Equatable {
    case queue, like

    static func committed(translation: CGSize, startedHorizontally: Bool) -> SongSwipeAction? {
        guard startedHorizontally, abs(translation.width) >= 72 else { return nil }
        return translation.width > 0 ? .queue : .like
    }
}

/// Reject unwanted pans before recognition, allowing the surrounding ScrollView to take them.
/// Filtering a SwiftUI drag's onChanged is too late: that drag has already won the touch.
struct PanInteraction: UIViewRepresentable {
    struct Sample {
        let startLocation: CGPoint
        let location: CGPoint
        let translation: CGSize
    }
    let canBegin: (CGPoint, CGSize) -> Bool
    let change: (Sample) -> Void
    let end: (Sample) -> Void
    let cancel: () -> Void
    let tap: (CGPoint) -> Void
    var touchDown: ((CGPoint) -> Void)? = nil

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: PanInteraction
        init(_ owner: PanInteraction) { self.owner = owner }

        private func sample(_ pan: UIPanGestureRecognizer) -> Sample {
            let point = pan.location(in: pan.view)
            let delta = pan.translation(in: pan.view)
            return Sample(startLocation: CGPoint(x: point.x - delta.x, y: point.y - delta.y), location: point,
                          translation: CGSize(width: delta.x, height: delta.y))
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let value = sample(pan)
            return owner.canBegin(value.startLocation, value.translation)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // Give our narrowly accepted pan first refusal. It fails for scrolling gestures;
            // otherwise the scroll view waits rather than racing a genuine scrub/control drag.
            guard recognizer is UIPanGestureRecognizer, let view = recognizer.view,
                  let scroll = other.view as? UIScrollView else { return false }
            return view.isDescendant(of: scroll)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (recognizer as? UILongPressGestureRecognizer)?.minimumPressDuration == 0
                || (other as? UILongPressGestureRecognizer)?.minimumPressDuration == 0
        }

        @objc func press(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { owner.touchDown?(recognizer.location(in: recognizer.view)) }
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: owner.change(sample(recognizer))
            case .ended: owner.end(sample(recognizer))
            case .cancelled, .failed: owner.cancel()
            default: break
            }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { owner.tap(recognizer.location(in: recognizer.view)) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pan)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        if touchDown != nil {
            let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
            press.minimumPressDuration = 0
            press.cancelsTouchesInView = false
            press.delegate = context.coordinator
            view.addGestureRecognizer(press)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.owner = self }
}

struct SeekInteraction: View {
    let preview: (CGFloat?) -> Void
    let commit: (CGFloat) -> Void

    var body: some View {
        PanInteraction(canBegin: { _, translation in HorizontalGestureIntent.accepts(translation) },
                       change: { preview($0.location.x) },
                       end: { commit($0.location.x); preview(nil) },
                       cancel: { preview(nil) },
                       tap: { commit($0.x) })
    }
}
