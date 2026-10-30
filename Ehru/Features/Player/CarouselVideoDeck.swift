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
    @ObservationIgnored private var parked: Slot?
    var currentSession: MotionVideoSession? { currentKey.flatMap { slots[$0]?.session } }
    var residentCount: Int { slots.count + (parked == nil ? 0 : 1) }

    func configure(_ requests: [Request], current: String?, prepareNeighbours: Bool = true, allowNewSessions: Bool = true) {
        let wanted = Array(requests.prefix(3))
        let keys = Set(wanted.map(\.key))
        // A newly opened carousel starts its coordinates at zero. Carry the current
        // surface across that coordinate change, rather than restarting the same album
        // immediately after its cover has flown into place.
        if let current, slots[current] == nil,
           let request = wanted.first(where: { $0.key == current }),
           let oldKey = currentKey, !keys.contains(oldKey), let old = slots[oldKey], old.url == request.url {
            slots.removeValue(forKey: oldKey)
            slots[current] = old
        }
        for key in Array(slots.keys) where !keys.contains(key) {
            guard let retired = slots.removeValue(forKey: key) else { continue }
            retired.session.pause()
            parked?.session.stop()
            parked = retired
        }
        for request in wanted {
            if let old = slots[request.key], old.url == request.url { continue }
            // Do not create a newly revealed far neighbour in the middle of a turnover.
            // Its slot is filled at settlement, before the next gesture starts.
            guard prepareNeighbours || request.key == current else { continue }
            slots.removeValue(forKey: request.key)?.session.stop()
            if let ready = parked, ready.url == request.url {
                // Rotate the departing neighbour into the new neighbour's slot. Swiping
                // through one album reuses all three movies, with no new asset or decoder.
                parked = nil
                slots[request.key] = ready
            } else {
                guard allowNewSessions else { continue }
                if residentCount >= 3 { parked?.session.stop(); parked = nil }
                let session = MotionVideoSession()
                session.prepare(url: request.url)
                slots[request.key] = Slot(url: request.url, session: session)
            }
        }
        currentKey = current
        if prepareNeighbours || !wanted.contains(where: { slots[$0.key] == nil && $0.url == parked?.url }) {
            parked?.session.stop(); parked = nil
        }
    }

    /// Keep the current frame warm for reopening; hidden neighbour decoders are released.
    func retainCurrent() {
        parked?.session.stop(); parked = nil
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
