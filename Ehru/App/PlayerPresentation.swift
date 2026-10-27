import Observation
import SwiftUI

private struct PlayerMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var playerInMotion: Bool {
        get { self[PlayerMotionKey.self] }
        set { self[PlayerMotionKey.self] = newValue }
    }
}

/// Only this lightweight container observes the finger's position. Updating a drag must not
/// rebuild the carousel, lyrics and blurred background on every touch event.
struct PlayerPresentation: View {
    @State private var drag = PlayerDragState()

    var body: some View {
        NowPlayingView(drag: drag)
            .environment(\.playerInMotion, drag.isMoving)
            .offset(y: drag.translation)
            .onAppear { drag.finishEntrance() }
    }
}

@MainActor
@Observable
final class PlayerDragState {
    private(set) var translation: CGFloat = 0
    private(set) var isMoving = true
    @ObservationIgnored private var settling: Task<Void, Never>?

    func update(_ distance: CGFloat) {
        settling?.cancel()
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            isMoving = true
            translation = max(distance, 0)
        }
    }

    func finishEntrance() { settle(after: .milliseconds(350)) }

    func beginDismissal() {
        settling?.cancel()
        isMoving = true
    }

    func restore() {
        isMoving = true
        withAnimation(.smooth(duration: 0.24)) { translation = 0 }
        settle(after: .milliseconds(260))
    }

    private func settle(after delay: Duration) {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isMoving = false
        }
    }
}
