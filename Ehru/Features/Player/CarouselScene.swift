import Foundation
import SwiftUI

struct CarouselSelection: Equatable {
    let previous: QueueEntry?
    let current: QueueEntry?
    let next: QueueEntry?

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
    mutating func select(_ next: CarouselSelection) -> Bool {
        let changed = next.current?.id != selection.current?.id
        let direction: Int
        if changed, let id = next.current?.id, id == selection.next?.id { direction = 1 }
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
        if let previous = selection.previous { result.append(Item(ordinal: center - 1, entry: previous)) }
        result.append(Item(ordinal: center, entry: current))
        if let next = selection.next { result.append(Item(ordinal: center + 1, entry: next)) }
        return result
    }
}

/// A compositor sample, not published view state. A new touch can pick up a settling strip
/// at its visible position instead of jumping to the previous animation's target.
final class CarouselPresentationMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CGFloat?
    func record(_ focus: CGFloat) { lock.withLock { value = focus } }
    func read(fallback: CGFloat) -> CGFloat { lock.withLock { value ?? fallback } }
}

struct CarouselPose {
    let scale: CGFloat
    let x: CGFloat
    let turn: Double
    let opacity: Double

    static func page(width: CGFloat) -> CGFloat { width * 0.94 + 12 }

    init(distance: CGFloat, width: CGFloat, stack: CGFloat, hideLeft: Bool, reduceMotion: Bool) {
        let away = abs(distance), near = min(abs(distance), 1)
        let sideScale: CGFloat = reduceMotion ? 0.86 : 0.78
        scale = (1 - (1 - sideScale) * near) * (1 - stack) + (1 + 0.06 * near) * stack
        x = distance * Self.page(width: width) * (1 - stack)
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
    let meter: CarouselPresentationMeter
    var animatableData: CGFloat {
        get { focus }
        set { focus = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        meter.record(focus)
        return ProjectionTransform(CGAffineTransform.identity)
    }
}
