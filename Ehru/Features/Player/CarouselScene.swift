import Foundation
import SwiftUI

struct CarouselSelection: Equatable {
    let previous: QueueEntry?
    let current: QueueEntry?
    let next: QueueEntry?
    var previousTwo: QueueEntry? = nil
    var nextTwo: QueueEntry? = nil

    func canMove(_ direction: Int) -> Bool {
        guard let current else { return false }
        let neighbour = direction == 1 ? next : direction == -1 ? previous : nil
        return neighbour != nil && neighbour?.id != current.id
    }
}

/// Stable, unbounded page coordinates: changing the current entry never rebases the strip.
/// Keeping departing pages through settlement preserves their SwiftUI and artwork identity.
struct CarouselScene {
    struct Item: Identifiable {
        let ordinal: Int
        let entry: QueueEntry
        var id: String { "\(entry.id)#\(ordinal)" }
    }
    private(set) var selection = CarouselSelection(previous: nil, current: nil, next: nil)
    private(set) var center = 0
    private(set) var items: [Item] = []
    var currentKey: String? { selection.current.map { "\($0.id)#\(center)" } }

    /// True for an adjacent change; unrelated jumps can replace the scene without sliding.
    @discardableResult
    mutating func select(_ next: CarouselSelection, preferredDirection: Int? = nil) -> Bool {
        let changed = next.current?.id != selection.current?.id
        let direction: Int
        if changed, preferredDirection == -1, let id = next.current?.id, id == selection.previous?.id { direction = -1 }
        else if changed, let id = next.current?.id, id == selection.next?.id { direction = 1 }
        else if changed, let id = next.current?.id, id == selection.previous?.id { direction = -1 }
        else { direction = 0 }
        if changed && direction == 0 { items = []; center = 0 }
        else { center += direction }
        selection = next
        let fresh = targetItems
        // Far pages are already invisible. Keep one occurrence per coordinate and at most
        // seven nearby pages even if the user interrupts every settlement with another swipe.
        var nearby: [Int: Item] = [:]
        for item in items where abs(item.ordinal - center) <= 3 { nearby[item.ordinal] = item }
        for item in fresh { nearby[item.ordinal] = item }
        items = nearby.values.sorted { $0.ordinal < $1.ordinal }
        return direction != 0
    }

    mutating func settle() { items = targetItems }

    private var targetItems: [Item] {
        guard let current = selection.current else { return [] }
        var result: [Item] = []
        if let previous = selection.previousTwo { result.append(Item(ordinal: center - 2, entry: previous)) }
        if let previous = selection.previous { result.append(Item(ordinal: center - 1, entry: previous)) }
        result.append(Item(ordinal: center, entry: current))
        if let next = selection.next { result.append(Item(ordinal: center + 1, entry: next)) }
        if let next = selection.nextTwo { result.append(Item(ordinal: center + 2, entry: next)) }
        return result
    }
}

/// A compositor sample, not published view state. A new touch can pick up a settling strip
/// at its visible position instead of jumping to the previous animation's target.
struct CarouselPresentationSample: Equatable {
    let focus: CGFloat
    let stack: CGFloat
}

final class CarouselPresentationMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CarouselPresentationSample?

    func record(_ focus: CGFloat, stack: CGFloat = 0) {
        lock.withLock { value = CarouselPresentationSample(focus: focus, stack: stack) }
    }
    func read(fallback: CGFloat) -> CGFloat { lock.withLock { value?.focus ?? fallback } }
    func sample(fallback: CarouselPresentationSample) -> CarouselPresentationSample { lock.withLock { value ?? fallback } }
}

struct CarouselPose {
    let scale: CGFloat
    let x: CGFloat
    let y: CGFloat
    let turn: Double
    let opacity: Double

    static func page(width: CGFloat) -> CGFloat { width * 0.66 }
    static func depth(distance: CGFloat) -> Double { 2 - Double(abs(distance)) }

    init(distance: CGFloat, width: CGFloat, stack: CGFloat, hideLeft: Bool, reduceMotion: Bool) {
        let away = abs(distance), near = min(abs(distance), 1)
        let sideScale: CGFloat = reduceMotion ? 0.86 : 0.78
        scale = (1 - (1 - sideScale) * near) * (1 - stack) + (1 - 0.06 * near) * stack
        x = distance * (Self.page(width: width) * (1 - stack) + 12 * stack)
        y = -20 * near * stack
        turn = reduceMotion ? 0 : -Double(distance.clamped(-1, 1)) * 32 * Double(1 - stack)
        let vanish = (1 - max(away - 1, 0) / 0.6).clamped(0, 1)
        let gathered = hideLeft ? min(stack * min(max(-distance, 0), 1) * 1.5, 1) : 0
        opacity = Double(vanish * (1 - gathered))
    }
}

/// One stable animation probe; inserted/retiring cards cannot overwrite the visible focus
/// with their own target while their opacity transition is being installed.
struct CarouselFocusProbe: GeometryEffect {
    var focus: CGFloat
    var stack: CGFloat = 0
    let meter: CarouselPresentationMeter
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(focus, stack) }
        set { focus = newValue.first; stack = newValue.second }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        meter.record(focus, stack: stack)
        return ProjectionTransform(CGAffineTransform.identity)
    }
}

/// The transforms animate natively; the z-index remains a direct trait of each ZStack child.
/// Depth changes only with direct input or a new destination; sampling never mutates view state.
struct CarouselStrip<Card: View>: View {
    let items: [CarouselScene.Item]
    let focus: CGFloat
    let frontOrdinal: Int
    let stack: CGFloat
    let viewport: CGSize
    let cardSize: CGSize
    let hideLeft: Bool
    let reduceMotion: Bool
    let meter: CarouselPresentationMeter
    @ViewBuilder var card: (CarouselScene.Item) -> Card

    var body: some View {
        ZStack {
            ForEach(items) { item in
                let distance = CGFloat(item.ordinal) - focus
                let pose = CarouselPose(distance: distance, width: cardSize.width, stack: stack,
                                        hideLeft: hideLeft, reduceMotion: reduceMotion)
                card(item)
                    .modifier(DepthCard(distance: distance, width: cardSize.width, stack: stack,
                                        hideLeft: hideLeft, reduceMotion: reduceMotion))
                    .opacity(pose.opacity)
                    .zIndex(CarouselPose.depth(distance: CGFloat(item.ordinal - frontOrdinal)))
            }
            Color.clear.frame(width: 1, height: 1)
                .modifier(CarouselFocusProbe(focus: focus, stack: stack, meter: meter))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(width: viewport.width, height: viewport.height)
    }
}

enum CarouselDragLimit {
    static func focus(_ proposed: CGFloat, center: Int, canPrevious: Bool, canNext: Bool) -> CGFloat {
        let base = CGFloat(center)
        guard proposed.isFinite else { return base }
        let low = base - (canPrevious ? 1 : 0), high = base + (canNext ? 1 : 0)
        let clipped = proposed.clamped(low, high)
        let excess = proposed - clipped
        return clipped + excess / (1 + abs(excess)) * 0.12
    }
}
