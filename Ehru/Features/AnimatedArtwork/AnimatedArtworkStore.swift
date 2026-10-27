import Foundation
import Observation

struct SavedMotionCover: Codable, Equatable {
    let albumId: Int64
    let album: String
    let artist: String
    let catalogId: Int64
    let storefront: String
    let fileName: String
}

enum MotionCoverStatus: Equatable {
    case downloading, saved, notFound, failed(String)
    var label: String {
        switch self {
        case .downloading: "Finding and downloading…"
        case .saved: "Downloaded · available offline"
        case .notFound: "No matching motion cover found"
        case .failed(let message): message
        }
    }
}

@MainActor
@Observable
final class AnimatedArtworkStore {
    struct Saved: Codable, Equatable {
        var enabled = true
        var covers: [String: SavedMotionCover] = [:]
    }
    private(set) var saved: Saved
    private(set) var status: [Int64: MotionCoverStatus] = [:]
    private(set) var downloading: Int64?
    @ObservationIgnored private let persistence = JSONStore<Saved>(name: "motion-covers.json")
    @ObservationIgnored private let service = AppleMotionService()
    @ObservationIgnored private var pending: Task<Void, Never>?

    init() { saved = persistence.load() ?? Saved() }

    var enabled: Bool {
        get { saved.enabled }
        set { saved.enabled = newValue; persistence.saveNow(saved) }
    }

    private static var folder: URL { LibraryPaths.supportFolder.appendingPathComponent("motion-covers", isDirectory: true) }

    func url(for song: Song) -> URL? {
        // Album artist can differ from individual track credits; the album id is authoritative.
        guard enabled, let cover = saved.covers[String(song.albumId)] else { return nil }
        let url = Self.folder.appendingPathComponent(cover.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ album: Album) {
        guard downloading == nil else { return }
        downloading = album.id
        status[album.id] = .downloading
        pending = Task {
            defer { downloading = nil; pending = nil }
            var destination: URL?
            do {
                let country = Locale.current.region?.identifier ?? "us"
                guard let match = try await service.find(album: album.title, artist: album.artist, country: country) else {
                    status[album.id] = .notFound
                    return
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                let name = UUID().uuidString + ".mp4"
                let url = Self.folder.appendingPathComponent(name)
                destination = url
                try await service.download(match, to: url)
                try Task.checkCancellation()
                let old = saved.covers[String(album.id)]
                saved.covers[String(album.id)] = SavedMotionCover(albumId: album.id, album: album.title, artist: album.artist,
                                                                  catalogId: match.catalogId, storefront: match.storefront, fileName: name)
                persistence.saveNow(saved)
                if let old { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(old.fileName)) }
                status[album.id] = .saved
            } catch {
                if let destination { try? FileManager.default.removeItem(at: destination) }
                if error is CancellationError || Task.isCancelled { status[album.id] = nil }
                else { status[album.id] = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() { pending?.cancel() }

    func remove(_ album: Album) {
        guard downloading != album.id else { return }
        if let old = saved.covers.removeValue(forKey: String(album.id)) {
            persistence.saveNow(saved)
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(old.fileName))
        }
        status[album.id] = nil
    }
}
