import Foundation
import Observation

/// The song library is whatever audio sits in the app's Documents folder. That folder shows up as
/// "empee3" under On My iPhone in the Files app, so music can be dropped in from there as well as
/// imported with the + button.
@MainActor
@Observable
final class LibraryStore {
    private(set) var songs: [Song] = []
    private(set) var isScanning = false
    private(set) var errorMessage: String?
    var isShowingError = false

    let musicFolder: URL

    /// How many files have their tags read at the same time during a scan.
    private static let metadataReadWidth = 8

    init(musicFolder: URL = URL.documentsDirectory) {
        self.musicFolder = musicFolder
    }

    func reload() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let folder = musicFolder
        let files = await Task.detached(priority: .userInitiated) {
            MusicFiles.audioFiles(in: folder)
        }.value

        let loaded = await withTaskGroup(of: Song.self) { group in
            var pending = files.makeIterator()
            for _ in 0..<Self.metadataReadWidth {
                guard let file = pending.next() else { break }
                group.addTask { await SongMetadata.read(file) }
            }
            var result: [Song] = []
            result.reserveCapacity(files.count)
            for await song in group {
                result.append(song)
                if let file = pending.next() {
                    group.addTask { await SongMetadata.read(file) }
                }
            }
            return result
        }

        songs = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Copies files picked in the document picker into the library.
    func importFiles(_ urls: [URL]) async {
        let folder = musicFolder
        let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
            var failed: [String] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let destination = MusicFiles.uniqueDestination(for: url.lastPathComponent, in: folder) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            return failed
        }.value

        if !failures.isEmpty {
            report("Couldn't import: \(failures.joined(separator: ", "))")
        }
        await reload()
    }

    func delete(_ song: Song) {
        do {
            try FileManager.default.removeItem(at: song.url)
            songs.removeAll { $0.id == song.id }
        } catch {
            report("Couldn't delete \(song.title).")
        }
    }

    private func report(_ message: String) {
        errorMessage = message
        isShowingError = true
    }
}
