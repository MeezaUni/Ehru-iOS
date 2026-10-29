import AVFoundation
import Foundation
import MediaPlayer
import Observation
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
            generator.maximumSize = CGSize(width: 1200, height: 1600)
            let (image, _) = try await generator.image(at: .zero)
            try Task.checkCancellation()
            guard let aspect = LockScreenMotionAspect(size: CGSize(width: image.width, height: image.height)) else {
                throw MotionArtworkError("This motion cover has no supported lock-screen aspect ratio.")
            }
            return LockScreenMotionAsset(url: leased, preview: image, aspect: aspect,
                                         artworkID: "ehru-motion-v3-\(source.lastPathComponent)-\(leased.lastPathComponent)")
        } catch {
            try? FileManager.default.removeItem(at: leased)
            throw error
        }
    }

    @available(iOS 26.0, *)
    func info(supported: [String], onVideoRequest: (@Sendable () -> Void)? = nil) -> [String: Any] {
        guard let key = aspect.key(supported: supported) else { return [:] }
        let artwork = MPMediaItemAnimatedArtwork(
            artworkID: artworkID,
            previewImageRequestHandler: { [self] _ in UIImage(cgImage: preview) },
            videoAssetFileURLRequestHandler: { [self] _ in
                onVideoRequest?()
                return url
            }
        )
        return [key: artwork]
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Preparation happens once per downloaded clip, outside the playback/UI executor. Stale work
/// cannot replace the current song's artwork. No video player runs in the app for the lock screen.
@MainActor
@Observable
final class LockScreenMotionArtwork {
    enum Status: Equatable {
        case idle, preparing, ready, unavailable(String)

        var message: String {
            switch self {
            case .idle: "Play an album with a downloaded motion cover."
            case .preparing: "Preparing Lock Screen artwork…"
            case .ready: "Ready for the Lock Screen. Tap the cover there to expand it."
            case .unavailable(let reason): reason
            }
        }
    }

    private struct Source: Hashable, Sendable {
        let url: URL
        let size: Int
        let modified: Date?
        init(_ url: URL) {
            self.url = url
            let values = try? FileManager.default.attributesOfItem(atPath: url.path)
            size = (values?[.size] as? NSNumber)?.intValue ?? -1
            modified = values?[.modificationDate] as? Date
        }
    }
    private struct Selection: Equatable, Sendable {
        let sources: [Source]
        let supported: [String]
    }

    private(set) var status = Status.idle
    private(set) var videoRequested = false
    @ObservationIgnored private var selection: Selection?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private(set) var info: [String: Any] = [:]
    @ObservationIgnored private var assets: [Source: LockScreenMotionAsset] = [:]
    @ObservationIgnored private var assetOrder: [Source] = []
    @ObservationIgnored private let supportedKeys: () -> [String]

    init(supportedKeys: @escaping () -> [String] = {
        if #available(iOS 26.0, *) { return MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys }
        return []
    }) {
        self.supportedKeys = supportedKeys
    }

    func retry() { selection = nil }

    func update(sources: [URL], onReady: @escaping @MainActor () -> Void) {
        let next = Selection(sources: sources.distinct(by: { $0 }).map(Source.init), supported: supportedKeys().sorted())
        // Capabilities can change independently of the song; do not cache just the file URL.
        guard next != selection else { return }
        pending?.cancel()
        pending = nil
        selection = next
        let requestID = UUID()
        self.requestID = requestID
        info = [:]
        videoRequested = false
        guard #available(iOS 26.0, *) else {
            status = .unavailable("Animated Lock Screen artwork requires iOS 26 or later.")
            return
        }
        guard !next.sources.isEmpty else { status = .idle; return }
        guard !next.supported.isEmpty else {
            status = .unavailable("iOS is not accepting animated artwork on this device.")
            return
        }
        if next.sources.allSatisfy({ assets[$0] != nil }) {
            for source in next.sources {
                if let asset = assets[source] { info.merge(entry(asset, supported: next.supported, requestID: requestID)) { current, _ in current } }
            }
            status = info.isEmpty ? .unavailable("The downloaded cover has no supported shape.") : .ready
            return
        }
        status = .preparing
        pending = Task { [weak self] in
            var prepared: [String: Any] = [:]
            var lastError: String?
            // Publish both shapes when available. A bad/missing portrait must not discard a
            // usable square, and each key must describe the video's actual aspect ratio.
            for source in next.sources {
                guard !Task.isCancelled else { return }
                do {
                    let asset: LockScreenMotionAsset
                    if let cached = self?.assets[source] { asset = cached }
                    else {
                        let preparation = Task.detached(priority: .utility) { try await LockScreenMotionAsset.prepare(source: source.url) }
                        asset = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                    }
                    guard !Task.isCancelled, let self else { return }
                    self.remember(asset, source: source)
                    prepared.merge(self.entry(asset, supported: next.supported, requestID: requestID)) { existing, _ in existing }
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = error.localizedDescription
                }
            }
            guard !Task.isCancelled, let self, self.requestID == requestID else { return }
            self.info = prepared
            self.status = prepared.isEmpty
                ? .unavailable(lastError.map { "Could not prepare Lock Screen artwork: \($0)" }
                    ?? "The downloaded cover has no shape supported by this device. Try Download again.")
                : .ready
            self.pending = nil
            onReady()
        }
    }
    private func entry(_ asset: LockScreenMotionAsset, supported: [String], requestID: UUID) -> [String: Any] {
        guard #available(iOS 26.0, *) else { return [:] }
        return asset.info(supported: supported) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == requestID else { return }
                self.videoRequested = true
            }
        }
    }

    private func remember(_ asset: LockScreenMotionAsset, source: Source) {
        assets[source] = asset
        assetOrder.removeAll { $0 == source }
        assetOrder.append(source)
        while assetOrder.count > 4 { assets.removeValue(forKey: assetOrder.removeFirst()) }
    }

}
