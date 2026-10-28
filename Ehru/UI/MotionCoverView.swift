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

/// Only the visible current cover instantiates a decoder. Grid tiles and carousel neighbours
/// remain still; no network request is made by this view.
struct MotionCoverView: View {
    let song: Song?
    var playing = false
    var rendersVideo = true
    var maxPixels = 1200
    var animateStill = false
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
                .modifier(MovingArtwork(isPlaying: animateStill && playing && url == nil))
            if rendersVideo, visible, sectionVisible, scenePhase == .active, !reduceMotion, budget.allowsDecorativeMotion, let url {
                // Pause the existing decoder instead of destroying/recreating it on every pause.
                LoopingMotionVideo(url: url, isPlaying: playing && !playerInMotion)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .reportsScrollVisibility { visible = $0 }
    }
}

private struct LoopingMotionVideo: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    final class Coordinator {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        var url: URL?
        var observation: NSKeyValueObservation?
        init() {
            player.isMuted = true
            player.volume = 0
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.audiovisualBackgroundPlaybackPolicy = .pauses
        }
        func load(_ url: URL, surface: Surface, playing: Bool) {
            guard self.url != url else { setPlaying(playing); return }
            stop()
            self.url = url
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 3
            looper = AVPlayerLooper(player: player, templateItem: item)
            // Keep the still visible until the first decoded frame is ready (also on failure).
            surface.videoLayer.opacity = 0.02
            observation = surface.videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                DispatchQueue.main.async { surface.videoLayer.opacity = layer.isReadyForDisplay ? 1 : 0.02 }
            }
            setPlaying(playing)
        }
        private func setPlaying(_ playing: Bool) {
            if playing { if player.rate == 0 { player.play() } }
            else { player.pause() }
        }
        func stop() {
            player.pause()
            observation = nil
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            url = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        surface.backgroundColor = .clear
        surface.videoLayer.videoGravity = .resizeAspectFill
        surface.videoLayer.player = context.coordinator.player
        context.coordinator.load(url, surface: surface, playing: isPlaying)
        return surface
    }
    func updateUIView(_ surface: Surface, context: Context) { context.coordinator.load(url, surface: surface, playing: isPlaying) }
    static func dismantleUIView(_ surface: Surface, coordinator: Coordinator) {
        coordinator.stop()
        surface.videoLayer.player = nil
    }
}
