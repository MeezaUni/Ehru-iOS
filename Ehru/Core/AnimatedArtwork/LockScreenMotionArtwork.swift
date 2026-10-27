import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// The system only accepts correctly shaped artwork for a supported presentation key.
enum LockScreenMotionAspect: Equatable {
    case square, portrait

    init?(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        if abs(ratio - 1) <= 0.02 { self = .square }
        else if abs(ratio - 0.75) <= 0.02 { self = .portrait }
        else { return nil }
    }

    @available(iOS 26.0, *)
    func key(supported: [String]) -> String? {
        let key = self == .square ? MPNowPlayingInfoProperty1x1AnimatedArtwork : MPNowPlayingInfoProperty3x4AnimatedArtwork
        return supported.contains(key) ? key : nil
    }
}

/// Own an immutable file for as long as the system holds the artwork or either request handler.
/// A hard link avoids copying the video, while allowing the user to remove/replace the download.
final class LockScreenMotionAsset: @unchecked Sendable {
    let url: URL
    let preview: CGImage
    let aspect: LockScreenMotionAspect
    let artworkID: String

    private static let folder: URL = {
        let folder = LibraryPaths.supportFolder.appendingPathComponent("lock-screen-motion", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Handlers from a previous app process no longer exist. Remove only our old leases.
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        return folder
    }()

    private init(url: URL, preview: CGImage, aspect: LockScreenMotionAspect, artworkID: String) {
        self.url = url
        self.preview = preview
        self.aspect = aspect
        self.artworkID = artworkID
    }

    static func prepare(source: URL) async throws -> LockScreenMotionAsset {
        guard source.isFileURL else { throw MotionArtworkError("Lock-screen artwork must be downloaded first.") }
        let leased = folder.appendingPathComponent(UUID().uuidString + ".mp4")
        do { try FileManager.default.linkItem(at: source, to: leased) }
        catch { try FileManager.default.copyItem(at: source, to: leased) }
        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: leased))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 600, height: 600)
            let (image, _) = try await generator.image(at: .zero)
            try Task.checkCancellation()
            guard let aspect = LockScreenMotionAspect(size: CGSize(width: image.width, height: image.height)) else {
                throw MotionArtworkError("This motion cover has no supported lock-screen aspect ratio.")
            }
            return LockScreenMotionAsset(url: leased, preview: image, aspect: aspect,
                                         artworkID: "ehru-motion-\(source.lastPathComponent)")
        } catch {
            try? FileManager.default.removeItem(at: leased)
            throw error
        }
    }

    @available(iOS 26.0, *)
    func info(supported: [String]) -> [String: Any] {
        guard let key = aspect.key(supported: supported) else { return [:] }
        let artwork = MPMediaItemAnimatedArtwork(
            artworkID: artworkID,
            previewImageRequestHandler: { [self] _ in UIImage(cgImage: preview) },
            videoAssetFileURLRequestHandler: { [self] _ in url }
        )
        return [key: artwork]
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Preparation happens once per downloaded clip, outside the playback/UI executor. Stale work
/// cannot replace the current song's artwork. No video player runs in the app for the lock screen.
@MainActor
final class LockScreenMotionArtwork {
    private var source: URL?
    private var pending: Task<Void, Never>?
    private(set) var info: [String: Any] = [:]

    func update(source: URL?, onReady: @escaping @MainActor () -> Void) {
        guard source != self.source else { return }
        pending?.cancel()
        self.source = source
        info = [:]
        guard let source, #available(iOS 26.0, *) else { return }
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        guard !supported.isEmpty else { return }
        pending = Task { [weak self] in
            let preparation = Task.detached(priority: .utility) { try await LockScreenMotionAsset.prepare(source: source) }
            let asset = try? await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
            guard !Task.isCancelled, let self, self.source == source, let asset else { return }
            self.info = asset.info(supported: supported)
            self.pending = nil
            onReady()
        }
    }
}
