import AVFoundation
import UIKit

/// One lazy, resident decoder per visible/prepared card. Rebinding its host keeps its buffer and position;
/// an old view's teardown cannot stop the layer that has just taken ownership.
@MainActor
final class MotionVideoSession {
    private var residentPlayer: AVQueuePlayer?
    private var residentSurface: MotionVideoSurface?
    var hasResidentPlayer: Bool { residentPlayer != nil }
    var hasResidentSurface: Bool { residentSurface != nil }

    var player: AVQueuePlayer {
        if let residentPlayer { return residentPlayer }
        let player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false // Complete local clips, already prerolled.
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        residentPlayer = player
        return player
    }
    private var looper: AVPlayerLooper?
    private(set) var url: URL?
    var surface: MotionVideoSurface {
        if let residentSurface { return residentSurface }
        let surface = MotionVideoSurface(frame: .zero)
        residentSurface = surface
        return surface
    }
    private weak var host: MotionVideoHost?
    private var readiness: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var itemReadiness: NSKeyValueObservation?
    private var playerReadiness: NSKeyValueObservation?
    private var generation = UUID()
    private var wantsPlayback = false
    private var prerolling = false
    private var primed = false

    /// Prepare local media before a swipe. Preroll decodes its first frame without advancing
    /// the movie; the paused neighbour keeps its own layer instead of borrowing the main one.
    func prepare(url: URL) {
        if self.url != url {
            stop()
            self.url = url
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 3
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerReadiness = player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.prerollIfReady() }
            }
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.observeReadiness() }
            }
        }
    }

    func attach(_ next: MotionVideoHost, url: URL, playing: Bool, frozen: Bool) {
        prepare(url: url)
        wantsPlayback = playing && !frozen
        if host !== next {
            host = next
            next.mount(surface)
            if surface.videoLayer.player !== player { surface.videoLayer.player = player }
            if readiness == nil {
                readiness = surface.videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.surface.setReady(self.surface.videoLayer.isReadyForDisplay)
                    }
                }
            }
        }
        if frozen && !surface.isFrozen {
            player.pause()
            surface.freeze()
        } else if !frozen { surface.unfreeze() }
        if wantsPlayback {
            if prerolling { player.cancelPendingPrerolls(); prerolling = false }
            if player.rate == 0 { player.play() }
            primed = true
        } else {
            if player.rate != 0 { player.pause() }
            prerollIfReady()
        }
    }

    private func observeReadiness() {
        itemReadiness = nil
        guard let item = residentPlayer?.currentItem else { return }
        itemReadiness = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.prerollIfReady() }
        }
    }

    private func prerollIfReady() {
        guard !wantsPlayback, !primed, !prerolling, let player = residentPlayer, player.status == .readyToPlay,
              player.currentItem?.status == .readyToPlay else { return }
        prerolling = true
        let token = generation
        player.preroll(atRate: 1) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.prerolling = false
                self.primed = finished
            }
        }
    }

    func detach(_ old: MotionVideoHost) {
        guard host === old else { return }
        residentPlayer?.pause()
        residentSurface?.removeFromSuperview()
        host = nil
        // Keep the same decoded layer/frame for mini <-> flight <-> card handoffs.
    }

    func pause() { wantsPlayback = false; residentPlayer?.pause() }

    func stop() {
        residentPlayer?.pause()
        residentPlayer?.cancelPendingPrerolls()
        generation = UUID(); wantsPlayback = false; prerolling = false; primed = false
        readiness = nil
        itemObservation = nil
        itemReadiness = nil
        playerReadiness = nil
        residentSurface?.videoLayer.player = nil
        residentSurface?.removeFromSuperview()
        residentSurface?.reset()
        host = nil
        looper?.disableLooping(); looper = nil
        residentPlayer?.removeAllItems()
        url = nil
    }
}

/// SwiftUI owns these lightweight hosts. The session moves its one resident video surface
/// between them, retaining the exact paused AVPlayerLayer and readiness during flight.
@MainActor
final class MotionVideoHost: UIView {
    func mount(_ surface: MotionVideoSurface) {
        surface.removeFromSuperview()
        addSubview(surface)
        setNeedsLayout()
        layoutIfNeeded()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        subviews.first?.frame = bounds
        subviews.first?.layoutIfNeeded()
        CATransaction.commit()
    }
}

/// A regular container owns the AVPlayerLayer. Layout updates never get Core Animation's
/// default implicit resize animation, which otherwise trails the SwiftUI cover transform.
@MainActor
final class MotionVideoSurface: UIView {
    let videoLayer = AVPlayerLayer()
    private(set) var isFrozen = false
    private var ready = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.opacity = 0
        layer.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    func reset() {
        isFrozen = false; ready = false
        videoLayer.removeAnimation(forKey: "first-frame")
        updateVisibility()
    }

    func setReady(_ value: Bool) {
        // Once displayed, keep the last decoded picture during temporary readiness changes.
        // Only a new asset/power fallback resets it; visibility never exposes the poster again.
        guard value else { return }
        let firstFrame = !ready
        ready = true
        updateVisibility()
        if firstFrame {
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = 0
            reveal.toValue = 1
            reveal.duration = 0.16
            videoLayer.add(reveal, forKey: "first-frame")
        }
    }

    /// Pausing AVPlayer preserves the native decoded surface. A flight transforms its host;
    /// it does not sample, rasterize or replace the picture with a separate image.
    func freeze() { isFrozen = true }
    func unfreeze() { isFrozen = false }

    private func updateVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.opacity = ready ? 1 : 0
        CATransaction.commit()
    }
}
