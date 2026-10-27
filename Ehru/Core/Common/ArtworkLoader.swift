import Foundation
import ImageIO
import UIKit

/// Loads embedded cover art (Android's ArtworkLoader): read from the audio file's own tags,
/// decoded and downsampled off the main thread, kept in a size-keyed memory cache. Files with no
/// picture are remembered too, so they are not read again.
final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let misses = NSCache<NSString, NSNumber>()
    private let queue = DispatchQueue(label: "ehru.artwork", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 300
        misses.countLimit = 2_000
    }

    /// The cover of the file at [url], at most [maxPixels] on its longer side, or nil.
    func image(for url: URL, maxPixels: Int) async -> UIImage? {
        let key = "\(url.path)|\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if misses.object(forKey: url.path as NSString) != nil { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = TagReader.artwork(url) else {
                    self.misses.setObject(1, forKey: url.path as NSString)
                    continuation.resume(returning: nil)
                    return
                }
                let image = Self.downsample(data, maxPixels: maxPixels)
                if let image { self.cache.setObject(image, forKey: key) }
                continuation.resume(returning: image)
            }
        }
    }

    /// A cached image without loading (for drawing the first frame without a flash).
    func cachedImage(for url: URL, maxPixels: Int) -> UIImage? {
        cache.object(forKey: "\(url.path)|\(maxPixels)" as NSString)
    }

    /// An image file (custom artist or playlist cover) at [path], downsampled.
    func image(atPath path: String, maxPixels: Int) async -> UIImage? {
        let key = "file:\(path)|\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = FileManager.default.contents(atPath: path), let image = Self.downsample(data, maxPixels: maxPixels)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                self.cache.setObject(image, forKey: key)
                continuation.resume(returning: image)
            }
        }
    }

    func forget(path: String) {
        cache.removeAllObjects()
        misses.removeObject(forKey: path as NSString)
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
