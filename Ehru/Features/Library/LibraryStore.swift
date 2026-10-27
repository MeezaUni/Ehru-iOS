import Foundation
import Observation

/// The library as the screens see it, reloaded whenever the database changes (Android's
/// LibraryRepository flows). Scans run off the main thread.
@MainActor
@Observable
final class LibraryStore {
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [Playlist] = []
    private(set) var scanProgress: ScanProgress?
    private(set) var errorMessage: String?
    var isShowingError = false

    let database: LibraryDatabase
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var rescanRequested = false

    var isScanning: Bool { scanProgress != nil }

    init(database: LibraryDatabase) {
        self.database = database
        reload()
        observer = NotificationCenter.default.addObserver(forName: SQLiteDatabase.didChange, object: database.db, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        do {
            songs = try database.allSongs()
            albums = try database.allAlbums()
            artists = try database.allArtists()
            playlists = try database.playlists()
        } catch {
            report("Couldn't read the library: \(error)")
        }
    }

    /// Rescans the music folder. A request during a scan runs once more after it, so a change is never missed.
    func scan() {
        guard scanProgress == nil else {
            rescanRequested = true
            return
        }
        scanProgress = ScanProgress()
        let scanner = LibraryScanner(database: database)
        let store = self
        Task.detached(priority: .utility) {
            do {
                _ = try scanner.scan { progress in
                    Task { @MainActor in store.updateProgress(progress) }
                }
            } catch {
                let message = "The library scan failed: \(error)"
                await store.report(message)
            }
            await store.scanFinished()
        }
    }

    private func updateProgress(_ progress: ScanProgress) {
        if scanProgress != nil { scanProgress = progress }
    }

    private func scanFinished() {
        scanProgress = nil
        reload()
        if rescanRequested {
            rescanRequested = false
            scan()
        }
    }

    /// Copies files picked in the document picker into the music folder, then rescans.
    func importFiles(_ urls: [URL]) {
        let folder = LibraryPaths.musicFolder
        let store = self
        Task.detached(priority: .userInitiated) {
            var failed: [String] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let destination = uniqueDestination(for: url.lastPathComponent, in: folder)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            let failures = failed
            await MainActor.run {
                if !failures.isEmpty { store.report("Couldn't import: \(failures.joined(separator: ", "))") }
                store.scan()
            }
        }
    }

    func report(_ message: String) {
        errorMessage = message
        isShowingError = true
    }
}

/// `folder/name`, or `folder/name 2.ext`, `3`, … if that name is taken.
func uniqueDestination(for fileName: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var candidate = folder.appendingPathComponent(fileName)
    var counter = 2
    while exists(candidate) {
        candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
        counter += 1
    }
    return candidate
}
