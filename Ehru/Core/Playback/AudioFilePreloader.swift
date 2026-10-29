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

/// Opens only adjacent file headers off the UI thread. Each handle is consumed once, so two
/// decks never share a mutable AVAudioFile reader. No audio samples are predecoded or retained.
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
                guard let before = AudioFileFingerprint.read(url), let file = try? AVAudioFile(forReading: url),
                      AudioFileFingerprint.read(url) == before else { return nil }
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
