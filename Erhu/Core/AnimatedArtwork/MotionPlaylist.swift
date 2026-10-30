import Foundation

struct MotionArtworkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// The offline format is an unencrypted, finite fragmented-MP4 HLS presentation.
/// Transport streams, changing initialization maps and encrypted streams are refused.
enum MotionPlaylist {
    struct Part: Equatable {
        let url: URL
        let offset: Int64?
        let length: Int64?
    }
    struct Variant: Equatable {
        let url: URL
        let width: Int
        let height: Int
        let bandwidth: Int
    }

    static func attributes(_ text: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=("[^"]*"|[^,]*)"#)
        let source = text as NSString
        return Dictionary(regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            (source.substring(with: $0.range(at: 1)), source.substring(with: $0.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }, uniquingKeysWith: { _, last in last })
    }

    static func trustedURL(_ raw: String, relativeTo base: URL? = nil) throws -> URL {
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              host == "music.apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".mzstatic.com") else {
            throw MotionArtworkError("Apple returned an unsupported video address.")
        }
        return url
    }

    static func variants(_ text: String, base: URL) throws -> [Variant] {
        let lines = text.components(separatedBy: .newlines).map(\.trimmed)
        guard lines.first == "#EXTM3U" else { throw MotionArtworkError("Invalid video playlist.") }
        var result: [Variant] = []
        for i in lines.indices where lines[i].hasPrefix("#EXT-X-STREAM-INF:") {
            let fields = attributes(lines[i])
            if let range = fields["VIDEO-RANGE"], range != "SDR" { continue }
            let codec = fields["CODECS"] ?? ""
            guard !codec.contains("dvh1"), !codec.contains("dvhe"), i + 1 < lines.count,
                  !lines[i + 1].isEmpty, !lines[i + 1].hasPrefix("#") else { continue }
            let size = (fields["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
            guard size.count == 2, size.allSatisfy({ $0 > 0 }) else { continue }
            result.append(Variant(url: try trustedURL(lines[i + 1], relativeTo: base), width: size[0], height: size[1],
                                  bandwidth: Int(fields["BANDWIDTH"] ?? "") ?? 0))
        }
        return result
    }

    /// Target a 1080-pixel short edge for expanded artwork. Sparse Apple ladders can jump from
    /// 486 straight to 768, so a 720 target can otherwise select a visibly soft sub-500 cover.
    static func displayVariant(_ variants: [Variant]) -> Variant? {
        let sorted = variants.sorted {
            let left = min($0.width, $0.height), right = min($1.width, $1.height)
            return left == right ? $0.bandwidth < $1.bandwidth : left < right
        }
        if let preferred = sorted.last(where: { min($0.width, $0.height) <= 1080 }) { return preferred }
        guard let smallest = sorted.first else { return nil }
        // If all renditions exceed the target, use the smallest resolution, preferring the
        // higher bitrate at that resolution regardless of the master's ordering.
        return sorted.last { min($0.width, $0.height) == min(smallest.width, smallest.height) }
    }

    static func parts(_ text: String, base: URL) throws -> [Part] {
        let lines = text.components(separatedBy: .newlines).map(\.trimmed)
        guard lines.first == "#EXTM3U", lines.contains("#EXT-X-ENDLIST") else {
            throw MotionArtworkError("Only complete motion-cover clips can be downloaded.")
        }
        var result: [Part] = []
        var nextRange: String?
        var previous: Part?
        var hasMap = false
        func part(_ raw: String, range: String?) throws -> Part {
            let url = try trustedURL(raw, relativeTo: base)
            guard let range else { return Part(url: url, offset: nil, length: nil) }
            let values = range.split(separator: "@", omittingEmptySubsequences: false)
            guard values.count <= 2, let first = values.first, let length = Int64(first), length > 0, length <= 64 * 1024 * 1024 else {
                throw MotionArtworkError("Invalid video byte range.")
            }
            let offset: Int64?
            if values.count == 2 { offset = Int64(values[1]) }
            else if let previous, previous.url == url, let old = previous.offset, let count = previous.length { offset = old + count }
            else { offset = nil }
            guard let offset, offset >= 0, offset <= Int64.max - length else { throw MotionArtworkError("Invalid video byte offset.") }
            return Part(url: url, offset: offset, length: length)
        }
        for line in lines {
            if line.hasPrefix("#EXT-X-KEY:"), attributes(line)["METHOD"] != "NONE" {
                throw MotionArtworkError("Encrypted motion artwork is not supported.")
            }
            if line == "#EXT-X-DISCONTINUITY" { throw MotionArtworkError("This video format is not supported for offline covers.") }
            if line.hasPrefix("#EXT-X-MAP:") {
                guard !hasMap, let raw = attributes(line)["URI"] else { throw MotionArtworkError("Unsupported video initialization map.") }
                let initial = try part(raw, range: attributes(line)["BYTERANGE"])
                result.append(initial); previous = initial; hasMap = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                nextRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard hasMap else { throw MotionArtworkError("This cover is not an MP4 video.") }
                let segment = try part(line, range: nextRange)
                result.append(segment); previous = segment; nextRange = nil
            }
        }
        guard hasMap, result.count > 1, result.count <= 300, nextRange == nil else { throw MotionArtworkError("The motion cover has no complete video.") }
        return result
    }
}
