import Foundation
import ImageIO
import UIKit

/// Loads embedded cover art (Android's ArtworkLoader): read from the audio file's own tags,
/// decoded and downsampled off the main thread, kept in a size-keyed memory cache. Files with no
/// picture are remembered too, so they are not read again.
final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()
    static let didChange = Notification.Name("ArtworkLoader.didChange")
    private let revisionsLock = NSLock()
    private var revisions: [String: Int] = [:]

    func revision(for path: String) -> Int { revisionsLock.withLock { revisions[path, default: 0] } }

    private func key(for url: URL, maxPixels: Int) -> NSString {
        "\(url.path)|\(maxPixels)|\(revision(for: url.path))" as NSString
    }

    private let cache = NSCache<NSString, UIImage>()
    private let misses = NSCache<NSString, NSNumber>()
    private let queue = DispatchQueue(label: "erhu.artwork", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
        misses.countLimit = 2_000
    }

    /// The cover of the file at [url], at most [maxPixels] on its longer side, or nil.
    func image(for url: URL, maxPixels: Int) async -> UIImage? {
        let key = key(for: url, maxPixels: maxPixels)
        let missKey = "\(url.path)|\(revision(for: url.path))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if misses.object(forKey: missKey) != nil { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = TagReader.artwork(url) else {
                    self.misses.setObject(1, forKey: missKey)
                    continuation.resume(returning: nil)
                    return
                }
                let image = Self.downsample(data, maxPixels: maxPixels)
                if let image { self.cache.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
                continuation.resume(returning: image)
            }
        }
    }

    /// A cached image without loading (for drawing the first frame without a flash).
    func cachedImage(for url: URL, maxPixels: Int, fallbackSizes: [Int] = []) -> UIImage? {
        for size in [maxPixels] + fallbackSizes {
            if let image = cache.object(forKey: key(for: url, maxPixels: size)) { return image }
        }
        return nil
    }

    /// An image file (custom artist or playlist cover) at [path], downsampled.
    func image(atPath path: String, maxPixels: Int) async -> UIImage? {
        let key = fileKey(path, maxPixels: maxPixels)
        if let cached = cache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = FileManager.default.contents(atPath: path), let image = Self.downsample(data, maxPixels: maxPixels)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                self.cache.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
                continuation.resume(returning: image)
            }
        }
    }

    func cachedImage(atPath path: String, maxPixels: Int) -> UIImage? {
        cache.object(forKey: fileKey(path, maxPixels: maxPixels))
    }

    private func fileKey(_ path: String, maxPixels: Int) -> NSString {
        "file:\(path)|\(maxPixels)|\(revision(for: path))" as NSString
    }

    func forget(path: String) {
        revisionsLock.withLock { revisions[path, default: 0] += 1 }
        // Versioned keys isolate this file, including reads already in flight.
        NotificationCenter.default.post(name: Self.didChange, object: path)
    }

    static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
