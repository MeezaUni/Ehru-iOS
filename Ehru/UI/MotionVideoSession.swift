import AVFoundation
import CoreImage
import UIKit

/// One lazy, resident decoder owned by playback. Rebinding the same album keeps its buffer and position;
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
    private weak var outputItem: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?

    func attach(_ next: MotionVideoHost, url: URL, playing: Bool, frozen: Bool) {
        if self.url != url {
            stop()
            self.url = url
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 3
            looper = AVPlayerLooper(player: player, templateItem: item)
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.bindOutput() }
            }
        }
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
            bindOutput()
            let buffer = output?.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
            surface.freeze(buffer)
        } else if !frozen { surface.unfreeze() }
        if playing && !frozen { if player.rate == 0 { player.play() } }
        else { player.pause() }
    }

    private func bindOutput() {
        guard let player = residentPlayer else { return }
        guard outputItem !== player.currentItem else { return }
        if let output, let outputItem { outputItem.remove(output) }
        output = nil
        outputItem = player.currentItem
        if let item = outputItem {
            // Native decoded pixels; no second player or continuous snapshot polling.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            item.add(output)
            self.output = output
        }
    }

    func detach(_ old: MotionVideoHost) {
        guard host === old else { return }
        residentPlayer?.pause()
        residentSurface?.removeFromSuperview()
        host = nil
        // Keep the same decoded layer/frame for a card <-> flight-overlay reparent.
    }

    func pause() { residentPlayer?.pause() }

    func stop() {
        residentPlayer?.pause()
        readiness = nil
        itemObservation = nil
        if let output, let outputItem { outputItem.remove(output) }
        output = nil; outputItem = nil
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
/// between them, retaining the exact AVPlayerLayer, frozen frame and readiness during flight.
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
    private let still = UIImageView()
    private(set) var isFrozen = false
    private var ready = false
    private var generation = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        videoLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(videoLayer)
        still.contentMode = .scaleAspectFill
        still.clipsToBounds = true
        addSubview(still)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        still.frame = bounds
        CATransaction.commit()
    }

    func reset() {
        generation = UUID(); isFrozen = false; ready = false
        still.image = nil
        updateVisibility()
    }

    func setReady(_ value: Bool) {
        ready = value
        if ready && !isFrozen { still.image = nil }
        updateVisibility()
    }

    func freeze(_ buffer: CVPixelBuffer?) {
        isFrozen = true
        let token = UUID(); generation = token
        guard let buffer else { return } // Keep the paused live frame if no output frame is ready yet.
        MotionFrameRasterizer.shared.image(buffer) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.isFrozen, self.generation == token, let image else { return }
                self.still.image = UIImage(cgImage: image)
                self.updateVisibility()
            }
        }
    }

    func unfreeze() {
        guard isFrozen else { return }
        generation = UUID(); isFrozen = false
        if ready { still.image = nil }
        updateVisibility()
    }

    private func updateVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.opacity = ready && still.image == nil ? 1 : 0
        still.isHidden = still.image == nil
        CATransaction.commit()
    }
}

/// One bounded conversion per gesture, off the UI thread. The full video is never decoded
/// into images; the current pixel buffer is retained only until this conversion finishes.
private final class MotionFrameRasterizer: @unchecked Sendable {
    static let shared = MotionFrameRasterizer()
    private let queue = DispatchQueue(label: "ehru.motion-frame", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    func image(_ buffer: CVPixelBuffer, completion: @escaping (CGImage?) -> Void) {
        queue.async {
            let input = CIImage(cvPixelBuffer: buffer)
            let scale = min(1200 / max(input.extent.width, input.extent.height), 1)
            let image = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            completion(self.context.createCGImage(image, from: image.extent))
        }
    }
}
