import AVFoundation
import Foundation

private struct AudioFileFingerprint: Equatable {
    let size: Int64
    let modified: Date
    static func read(_ url: URL) -> AudioFileFingerprint? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = values[.size] as? NSNumber, let date = values[.modificationDate] as? Date else { return nil }
        return AudioFileFingerprint(size: size.int64Value, modified: date)
    }
}
private struct PreparedAudioFile: @unchecked Sendable {
    let file: AVAudioFile
    let fingerprint: AudioFileFingerprint
}

/// Opens adjacent readers and primes one small PCM block off the UI thread. Codec allocation
/// and the first decode stay out of a swipe commit. Each reader is consumed once; no PCM is kept.
@MainActor
final class AudioFilePreloader {
    private var files: [URL: PreparedAudioFile] = [:]
    private var generation = UUID()

    func warm(_ urls: [URL]) async {
        let token = UUID(); generation = token
        var wanted: [URL] = []
        for url in urls where !wanted.contains(url) {
            wanted.append(url)
            if wanted.count == 2 { break }
        }
        files = files.filter { wanted.contains($0.key) }
        for url in wanted {
            guard !Task.isCancelled, generation == token else { return }
            if files[url] != nil { continue }
            let result = await Task.detached(priority: .userInitiated) { () -> PreparedAudioFile? in
                guard let before = AudioFileFingerprint.read(url), let file = try? AVAudioFile(forReading: url) else { return nil }
                let count = AVAudioFrameCount(min(max(file.length, 0), 4096))
                if count > 0 {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                          (try? file.read(into: buffer, frameCount: count)) != nil else { return nil }
                    file.framePosition = 0
                }
                guard AudioFileFingerprint.read(url) == before else { return nil }
                return PreparedAudioFile(file: file, fingerprint: before)
            }.value
            guard !Task.isCancelled, generation == token else { return }
            if let result { files[url] = result }
        }
    }

    func take(_ url: URL) -> AVAudioFile? {
        guard let value = files.removeValue(forKey: url), AudioFileFingerprint.read(url) == value.fingerprint else { return nil }
        return value.file
    }
}
