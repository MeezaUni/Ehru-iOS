import Observation
import Foundation

/// Three persistent card surfaces: one current cover and two paused, prerolled neighbours.
/// Sessions belong to queue occurrences, so two songs on one album never fight over a layer.
@MainActor
@Observable
final class CarouselVideoDeck {
    struct Request: Equatable {
        let key: String
        let url: URL
    }
    struct Slot {
        let url: URL
        let session: MotionVideoSession
    }
    private(set) var slots: [String: Slot] = [:]
    private(set) var currentKey: String?
    var currentSession: MotionVideoSession? { currentKey.flatMap { slots[$0]?.session } }

    func configure(_ requests: [Request], current: String?, prepareNeighbours: Bool = true) {
        let wanted = Array(requests.prefix(3))
        let keys = Set(wanted.map(\.key))
        for key in Array(slots.keys) where !keys.contains(key) {
            slots.removeValue(forKey: key)?.session.stop()
        }
        for request in wanted {
            if let old = slots[request.key], old.url == request.url { continue }
            // Do not create a newly revealed far neighbour in the middle of a turnover.
            // Its slot is filled at settlement, before the next gesture starts.
            guard prepareNeighbours || request.key == current else { continue }
            slots.removeValue(forKey: request.key)?.session.stop()
            let session = MotionVideoSession()
            session.prepare(url: request.url)
            slots[request.key] = Slot(url: request.url, session: session)
        }
        currentKey = current
    }

    /// Keep the current frame warm for reopening; hidden neighbour decoders are released.
    func retainCurrent() {
        for key in Array(slots.keys) {
            if key == currentKey { slots[key]?.session.pause() }
            else { slots.removeValue(forKey: key)?.session.stop() }
        }
    }

    func stop() { configure([], current: nil) }

    static func shouldAnimate(distance: CGFloat, current: Bool) -> Bool {
        // Start the approaching cover after about a quarter swipe, before it is centred.
        abs(distance) < 1.1 && (current || abs(distance) < 0.78)
    }
}
