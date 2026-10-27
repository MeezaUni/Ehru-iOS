import Foundation

enum MusicFiles {
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "mp4",
    ]

    /// Every playable file under `folder`, including subfolders.
    static func audioFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where audioExtensions.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        return files
    }

    /// `folder/fileName`, or `folder/fileName 2.ext`, `3`, … if that name is taken.
    static func uniqueDestination(for fileName: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 2
        while exists(candidate) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
