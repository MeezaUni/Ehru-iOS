import Foundation

enum RepeatMode: Sendable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// Order of play, kept free of AVFoundation so it can be unit tested.
struct PlaybackQueue<Item: Hashable> {
    private(set) var items: [Item] = []
    private(set) var currentIndex: Int?
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off

    /// The order before shuffling, restored when shuffle is turned off.
    private var unshuffledItems: [Item] = []

    var current: Item? { currentIndex.map { items[$0] } }

    mutating func load(_ newItems: [Item], startingAt index: Int) {
        items = newItems
        unshuffledItems = newItems
        isShuffled = false
        currentIndex = newItems.indices.contains(index) ? index : nil
    }

    /// The current item finished playing by itself.
    mutating func advanceAfterCompletion() -> Item? {
        guard let index = currentIndex else { return nil }
        if repeatMode == .one { return current }
        return move(to: index + 1)
    }

    /// The user pressed next. Repeat-one doesn't hold them on the same song.
    mutating func skipForward() -> Item? {
        guard let index = currentIndex else { return nil }
        return move(to: index + 1)
    }

    /// The user pressed previous. At the start of the queue this stays on the first item,
    /// unless repeat-all wraps round to the last.
    mutating func skipBackward() -> Item? {
        guard let index = currentIndex else { return nil }
        if index > 0 {
            currentIndex = index - 1
        } else if repeatMode == .all {
            currentIndex = items.count - 1
        }
        return current
    }

    /// Shuffling keeps the current item playing and puts it first; the rest are shuffled after it.
    mutating func setShuffled<G: RandomNumberGenerator>(_ shuffled: Bool, using generator: inout G) {
        guard shuffled != isShuffled else { return }
        let playing = current
        if shuffled {
            var rest = items
            if let currentIndex { rest.remove(at: currentIndex) }
            rest.shuffle(using: &generator)
            items = (playing.map { [$0] } ?? []) + rest
            currentIndex = playing == nil ? nil : 0
        } else {
            items = unshuffledItems
            currentIndex = playing.flatMap { items.firstIndex(of: $0) }
        }
        isShuffled = shuffled
    }

    mutating func setShuffled(_ shuffled: Bool) {
        var generator = SystemRandomNumberGenerator()
        setShuffled(shuffled, using: &generator)
    }

    /// Returns nil, leaving the position alone, when there is nothing after the end.
    private mutating func move(to index: Int) -> Item? {
        if items.indices.contains(index) {
            currentIndex = index
            return current
        }
        if repeatMode == .all, !items.isEmpty {
            currentIndex = 0
            return current
        }
        return nil
    }
}
