import AVFoundation
import SwiftUI
import UIKit

/// A downloaded movie's real first frame, shared by the mini player, flight and video fallback.
/// Extraction, JPEG I/O and decoding run off the UI executor and are coalesced per local clip.
@MainActor
final class MotionCoverPosterCache {
    static let shared = MotionCoverPosterCache()
    private let images = NSCache<NSURL, UIImage>()
    private var pending: [URL: Task<UIImage?, Never>] = [:]

    init() {
        images.countLimit = 8
        images.totalCostLimit = 24 * 1024 * 1024
    }

    nonisolated static func posterURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("cover.jpg")
    }

    func cached(_ video: URL) -> UIImage? { images.object(forKey: video as NSURL) }

    func image(for video: URL) async -> UIImage? {
        if let image = cached(video) { return image }
        if let task = pending[video] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard video.isFileURL, !Task.isCancelled else { return nil }
            let poster = Self.posterURL(for: video)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let modified = try? video.resourceValues(forKeys: keys).contentModificationDate
            let posterModified = try? poster.resourceValues(forKeys: keys).contentModificationDate
            if let modified, let posterModified, posterModified >= modified,
               let image = UIImage(contentsOfFile: poster.path) { return image.preparingForDisplay() ?? image }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1200, height: 1200)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let (frame, _) = try? await generator.image(at: .zero), !Task.isCancelled else { return nil }
            let image = UIImage(cgImage: frame)
            if let data = image.jpegData(compressionQuality: 0.94) { try? data.write(to: poster, options: .atomic) }
            return image
        }
        pending[video] = task
        let image = await task.value
        pending[video] = nil
        if let image { images.setObject(image, forKey: video as NSURL, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)) }
        return image
    }

    func forget(_ video: URL) {
        pending.removeValue(forKey: video)?.cancel()
        images.removeObject(forKey: video as NSURL)
    }
}

struct MotionCoverPoster: View {
    let song: Song?
    var maxPixels = 1200
    @Environment(AnimatedArtworkStore.self) private var store
    @State private var image: UIImage?
    @State private var source: URL?

    var body: some View {
        let video = song.flatMap { store.url(for: $0) }
        let poster = video.flatMap { source == $0 ? image : MotionCoverPosterCache.shared.cached($0) }
        ZStack {
            SongArtworkView(song: song, maxPixels: maxPixels)
            if let poster { FillImage(image: poster).transition(.opacity) }
        }
        .task(id: video) {
            source = video
            image = video.flatMap { MotionCoverPosterCache.shared.cached($0) }
            guard let video, image == nil else { return }
            let loaded = await MotionCoverPosterCache.shared.image(for: video)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.16)) { image = loaded }
        }
    }
}
