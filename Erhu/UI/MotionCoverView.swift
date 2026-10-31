import AVFoundation
import SwiftUI
import UIKit

private struct MotionCoverVisibilityKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var motionCoverVisible: Bool {
        get { self[MotionCoverVisibilityKey.self] }
        set { self[MotionCoverVisibilityKey.self] = newValue }
    }
}

/// Local animated artwork. Carousel neighbours may keep a supplied, paused session warm;
/// playback of decorative art is independent of the audio transport's paused state.
/// Occlusion and scrolling pause the mounted layer; only power/accessibility fallback removes it.
struct MotionCoverView: View {
    let song: Song?
    /// Callers that already resolved the local asset can avoid looking it up again.
    var videoURL: URL? = nil
    var playing = false
    var rendersVideo = true
    var maxPixels = 1200
    var animateStill = false
    var suspended = false
    var videoSession: MotionVideoSession? = nil
    var tracksScrollVisibility = true
    @Environment(AnimatedArtworkStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.motionCoverVisible) private var sectionVisible
    @Environment(\.playerInMotion) private var playerInMotion
    @Environment(\.visualWorkBudget) private var budget
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let url = videoURL ?? song.flatMap { store.url(for: $0) }
        ZStack {
            MotionCoverPoster(song: song, maxPixels: maxPixels)
                .modifier(MovingArtwork(isPlaying: animateStill && playing && !suspended && url == nil,
                                        enabled: animateStill && url == nil))
            if rendersVideo, !reduceMotion, budget.allowsDecorativeMotion, let url, (!playerInMotion || videoSession?.url == url) {
                // Reuse a prepared decoder during flight. A cold video waits until the cover
                // has arrived, keeping AVPlayer construction off the opening animation.
                LoopingMotionVideo(url: url, isPlaying: playing && visible && sectionVisible && scenePhase == .active && !playerInMotion && !suspended,
                                   frozen: playerInMotion || suspended, session: videoSession)
                    .id(videoSession.map(ObjectIdentifier.init))
                    .transition(.identity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .reportsScrollVisibility(enabled: tracksScrollVisibility) { visible = $0 }
    }
}

private struct LoopingMotionVideo: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let frozen: Bool
    let session: MotionVideoSession?

    @MainActor
    final class Coordinator {
        let session: MotionVideoSession
        let ownsSession: Bool
        init(_ supplied: MotionVideoSession?) {
            ownsSession = supplied == nil
            session = supplied ?? MotionVideoSession()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    func makeUIView(context: Context) -> MotionVideoHost {
        let surface = MotionVideoHost()
        context.coordinator.session.attach(surface, url: url, playing: isPlaying, frozen: frozen)
        return surface
    }
    func updateUIView(_ surface: MotionVideoHost, context: Context) {
        context.coordinator.session.attach(surface, url: url, playing: isPlaying, frozen: frozen)
    }
    static func dismantleUIView(_ surface: MotionVideoHost, coordinator: Coordinator) {
        coordinator.session.detach(surface)
        if coordinator.ownsSession { coordinator.session.stop() }
    }
}
