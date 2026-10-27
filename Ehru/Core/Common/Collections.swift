import Foundation

extension Sequence {
    /// Kotlin's `groupBy`: groups in the order their first element appears, elements in order.
    func orderedGrouped<Key: Hashable>(by key: (Element) -> Key) -> [(key: Key, items: [Element])] {
        var index: [Key: Int] = [:]
        var out: [(key: Key, items: [Element])] = []
        for element in self {
            let k = key(element)
            if let i = index[k] {
                out[i].items.append(element)
            } else {
                index[k] = out.count
                out.append((k, [element]))
            }
        }
        return out
    }

    /// Kotlin's `distinctBy`: the first element of each key, in order.
    func distinct<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }

    /// Kotlin's `groupingBy { }.eachCount()`.
    func counts<Key: Hashable>(by key: (Element) -> Key) -> [Key: Int] {
        var out: [Key: Int] = [:]
        for element in self {
            out[key(element), default: 0] += 1
        }
        return out
    }
}

/// Two strings as one dictionary key (Kotlin's `Pair<String, String>`).
struct StringPair: Hashable {
    let first: String
    let second: String
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
