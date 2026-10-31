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
    mutating func select(_ next: CarouselSelection, preferredDirection: Int? = nil, deferFarPages: Bool = false) -> Bool {
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
        for item in fresh {
            // The approaching card and its next neighbour are already mounted. Defer creation
            // of the newly exposed far card until settlement, outside the release frame.
            if deferFarPages, direction != 0, abs(item.ordinal - center) > 1, nearby[item.ordinal] == nil { continue }
            nearby[item.ordinal] = item
        }
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

    static func page(width: CGFloat) -> CGFloat {
        position(distance: 1, width: width, stack: 0, reduceMotion: false)
    }
    static func depth(distance: CGFloat) -> Double { 2 - Double(abs(distance)) }

    init(distance: CGFloat, width: CGFloat, stack: CGFloat, reduceMotion: Bool) {
        let away = abs(distance), near = min(abs(distance), 1)
        let sideScale: CGFloat = reduceMotion ? 0.86 : 0.78
        scale = (1 - (1 - sideScale) * near) * (1 - stack) + (1 - 0.12 * near) * stack
        // A stacked card starts directly behind the centre, peeks out along the appropriate
        // side halfway through the turnover, then returns to the centre as the front card.
        // Its short arc is distinct from the spread layout's full sideways page travel.
        let deckX = Self.deckOffset(distance: distance, width: width, reduceMotion: reduceMotion)
        x = stack == 1 ? deckX : Self.position(distance: distance, width: width, stack: stack, reduceMotion: reduceMotion) * (1 - stack) + deckX * stack
        y = -34 * near * stack
        let deckTurn = away < 1 ? -sin(Double(distance) * .pi) * 55 : 0
        turn = reduceMotion ? 0 : -Double(distance.clamped(-1, 1)) * 32 * Double(1 - stack) + deckTurn * Double(stack)
        let vanish = (1 - max(away - 1, 0) / 0.6).clamped(0, 1)
        // The two exchanging cards remain opaque. Their edges separate at the depth
        // crossover, so handing front-to-back order over cannot expose a crossfade.
        let accessibleFade = reduceMotion ? stack * near : 0
        opacity = Double(vanish * (1 - accessibleFade))
    }

    static func gap(width: CGFloat) -> CGFloat { (width * 0.04).clamped(8, 16) }

    private static func deckOffset(distance: CGFloat, width: CGFloat, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, abs(distance) < 1 else { return 0 }
        return sin(distance * .pi) * width * 0.32
    }

    private static func edge(_ distance: CGFloat, width: CGFloat, stack: CGFloat, reduceMotion: Bool, inward: Bool) -> CGFloat {
        let near = min(abs(distance), 1)
        let scale = (1 - (reduceMotion ? 0.14 : 0.22) * near) * (1 - stack) + (1 - 0.12 * near) * stack
        let angle = reduceMotion ? 0 : near * 32 * (1 - stack) * .pi / 180
        // Measure the same projection used to paint a right-hand card. Perspective makes
        // its inward and outward edges different; assuming a symmetric box hides the peeks.
        let projection = CarouselProjection.transform(size: CGSize(width: 1, height: 1), scale: scale,
                                                      turn: -Double(angle) * 180 / .pi)
        let left = projection.m31 / projection.m33
        let right = (projection.m11 + projection.m31) / (projection.m13 + projection.m33)
        return width * (inward ? 0.5 - left : right - 0.5)
    }

    private static func position(distance: CGFloat, width: CGFloat, stack: CGFloat, reduceMotion: Bool) -> CGFloat {
        let away = abs(distance), whole = Int(away.rounded(.down)), fraction = away - CGFloat(whole)
        func half(_ d: CGFloat, inward: Bool = true) -> CGFloat {
            edge(d, width: width, stack: stack, reduceMotion: reduceMotion, inward: inward)
        }
        let gap = gap(width: width)
        var result = fraction * (half(fraction) + half(1 - fraction) + gap)
        if whole > 0 {
            for step in 1...whole {
                result += half(fraction + CGFloat(step - 1), inward: false) + half(fraction + CGFloat(step)) + gap
            }
        }
        return distance < 0 ? -result : result
    }
}

enum CarouselProjection {
    static func transform(size: CGSize, scale: CGFloat, turn: Double, x: CGFloat = 0, y: CGFloat = 0) -> ProjectionTransform {
        if turn == 0 {
            return ProjectionTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: size.width * (1 - scale) / 2 + x, ty: size.height * (1 - scale) / 2 + y))
        }
        var rotation = CATransform3DIdentity
        rotation.m34 = -0.45 / max(size.width, 1)
        rotation = CATransform3DRotate(rotation, CGFloat(turn * .pi / 180), 0, 1, 0)
        return ProjectionTransform(CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
            .concatenating(ProjectionTransform(rotation))
            .concatenating(ProjectionTransform(CGAffineTransform(scaleX: scale, y: scale)))
            .concatenating(ProjectionTransform(CGAffineTransform(translationX: size.width / 2 + x, y: size.height / 2 + y)))
    }
}

/// Build the expensive card contents only when selection or direct input changes. A small
/// animatable layer stack then interpolates pose, shading and ordering around those same views.
struct CarouselStrip<Card: View>: View {
    let items: [CarouselScene.Item]
    let focus: CGFloat
    let frontOrdinal: Int
    let stack: CGFloat
    let viewport: CGSize
    let cardSize: CGSize
    let reduceMotion: Bool
    let meter: CarouselPresentationMeter
    @ViewBuilder var card: (CarouselScene.Item) -> Card

    var body: some View {
        CarouselLayers(cards: items.map { CarouselLayer(id: $0.id, ordinal: $0.ordinal, content: card($0)) },
                       focus: focus, stack: stack, frontOrdinal: frontOrdinal, cardSize: cardSize,
                       reduceMotion: reduceMotion, meter: meter)
            .frame(width: viewport.width, height: viewport.height)
    }
}

private struct CarouselLayer<Card: View>: Identifiable {
    let id: String
    let ordinal: Int
    let content: Card
}

private struct CarouselLayers<Card: View>: View, Animatable {
    let cards: [CarouselLayer<Card>]
    var focus: CGFloat
    var stack: CGFloat
    let frontOrdinal: Int
    let cardSize: CGSize
    let reduceMotion: Bool
    let meter: CarouselPresentationMeter

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(focus, stack) }
        set {
            focus = newValue.first; stack = newValue.second
            // Sample the visible renderer, rather than an invisible probe SwiftUI can elide.
            // This never publishes state, changes playback, or schedules another frame.
            meter.record(focus, stack: stack)
        }
    }

    var body: some View {
        ZStack {
            ForEach(cards) { card in
                let distance = CGFloat(card.ordinal) - focus
                let pose = CarouselPose(distance: distance, width: cardSize.width, stack: stack,
                                        reduceMotion: reduceMotion)
                // A depth handoff happens at half travel while the rotated edges are apart.
                // Spread cards retain their old order; their full-width gap avoids occlusion.
                let depthFocus = reduceMotion ? CGFloat(frontOrdinal) : CGFloat(frontOrdinal) * (1 - stack) + focus * stack
                card.content
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.large + CardMetrics.padding, style: .continuous)
                            .fill(.black.opacity(Double(min(abs(distance), 1)) * 0.32))
                            .allowsHitTesting(false)
                    }
                    .modifier(DepthCard(distance: distance, width: cardSize.width, stack: stack,
                                        reduceMotion: reduceMotion))
                    .opacity(pose.opacity)
                    .zIndex(CarouselPose.depth(distance: CGFloat(card.ordinal) - depthFocus))
            }
        }
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
