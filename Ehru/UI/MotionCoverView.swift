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
struct MotionCoverView: View {
    let song: Song?
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
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let url = song.flatMap { store.url(for: $0) }
        ZStack {
            SongArtworkView(song: song, maxPixels: maxPixels)
                .modifier(MovingArtwork(isPlaying: animateStill && playing && !suspended && url == nil,
                                        enabled: animateStill && url == nil))
            if rendersVideo, visible, sectionVisible, scenePhase == .active, !reduceMotion, budget.allowsDecorativeMotion, let url, (!playerInMotion || videoSession?.url == url) {
                // Reuse a prepared decoder during flight. A cold video waits until the cover
                // has arrived, keeping AVPlayer construction off the opening animation.
                LoopingMotionVideo(url: url, isPlaying: playing && !playerInMotion && !suspended,
                                   frozen: playerInMotion || suspended, session: videoSession)
                    .id(videoSession.map(ObjectIdentifier.init))
                    .transition(.identity)
                    .modifier(MotionVideoDissolve())
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

/// The frozen video frame blends into the same poster the mini-player will show. Native
/// opacity animation follows the cover transform, without resizing or restarting the decoder.
private struct MotionVideoDissolve: ViewModifier {
    @Environment(\.playerCoverProgress) private var progress
    func body(content: Content) -> some View { content.opacity(Double(progress.clamped(0, 1))) }
}
