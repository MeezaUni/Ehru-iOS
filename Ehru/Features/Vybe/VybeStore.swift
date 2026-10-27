import Foundation
import Observation

/// One result row: the library song and why VYBE picked it.
struct VybeResult: Identifiable, Equatable {
    let song: Song
    let reasons: [String]
    var id: Int64 { song.id }
}

/// What the results answer, for the header above them.
struct VybeResults: Equatable {
    let title: String
    let note: String?
    let songs: [VybeResult]
}

/// The screen's query state.
enum VybeQueryState: Equatable {
    case idle
    case searching(String)
    case done(String, VybeResults)
    case error(String, String)
}

/// VYBE for the screens (Android's VybeViewModel): the engine's status, the running query and its
/// results as library songs. Queries run when submitted, never per keystroke.
@MainActor
@Observable
final class VybeStore {
    static let resultLimit = 30
    private static let weakNote = "Your library's tags barely tell songs apart for this, so the order says little."

    private(set) var status: VybeStatus = .loadingModel
    private(set) var timings = VybeTimings()
    private(set) var query: VybeQueryState = .idle
    var message: String?

    let engine: VybeEngine
    private let database: LibraryDatabase
    private let player: PlayerController
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(database: LibraryDatabase, player: PlayerController) {
        self.database = database
        self.player = player
        let box = WeakBox<VybeStore>()
        engine = VybeEngine(database: database) { status, timings in
            Task { @MainActor in
                box.value?.status = status
                box.value?.timings = timings
            }
        }
        box.value = self
    }

    /// Loads the model and indexes, if not already; library changes then re-index (debounced).
    func start() {
        guard !started else { return }
        started = true
        Task { await engine.refresh() }
        observer = NotificationCenter.default.addObserver(forName: SQLiteDatabase.didChange, object: database.db, queue: .main) { [weak self] note in
            guard SQLiteDatabase.affects(note, tables: ["songs"]) else { return }
            MainActor.assumeIsolated { self?.libraryChanged() }
        }
    }

    private func libraryChanged() {
        pendingRefresh?.cancel()
        let engine = engine
        pendingRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await engine.refresh()
        }
    }

    /// Runs [text] (submitted).
    func submit(_ text: String) {
        let trimmed = text.trimmed
        if trimmed.isEmpty { return }
        let engine = engine
        run(trimmed) { try await engine.search(trimmed, limit: Self.resultLimit) }
    }

    /// Songs like the playing one.
    func similarToCurrent() {
        guard let song = player.state.currentSong else { return }
        let engine = engine
        run("Like \"\(song.title)\"") { await engine.similarTo(song.id, limit: Self.resultLimit) }
    }

    func clear() {
        running?.cancel()
        query = .idle
    }

    func play(_ results: [VybeResult], index: Int) {
        if results.isEmpty { return }
        player.setShuffleModeEnabled(false)
        player.playCollection(results.map(\.song), startIndex: min(max(index, 0), results.count - 1), origin: nil)
    }

    func shuffle(_ results: [VybeResult]) {
        if results.isEmpty { return }
        player.setShuffleModeEnabled(true)
        player.playCollection(results.map(\.song), startIndex: Int.random(in: 0..<results.count), origin: nil)
    }

    func addAllToQueue(_ results: [VybeResult]) {
        for result in results { player.addToQueue(result.song) }
        message = "Added \(results.count) songs to the queue"
    }

    private func run(_ label: String, _ answer: @escaping () async throws -> VybeAnswer?) {
        running?.cancel()
        query = .searching(label)
        running = Task {
            let state: VybeQueryState
            do {
                if let result = try await answer() {
                    state = .done(label, present(result))
                } else {
                    state = .error(label, "VYBE isn't ready yet")
                }
            } catch {
                state = .error(label, error.localizedDescription)
            }
            if !Task.isCancelled { query = state }
        }
    }

    /// Turns an answer into rows of library songs, with a header that says what was matched how.
    private func present(_ answer: VybeAnswer) -> VybeResults {
        switch answer {
        case .named(let kind, let name, let songIds, let similar):
            let named = songs(songIds.map { VybeHit(songId: $0, score: 1, reasons: ["\(Self.label(kind)) match"]) })
            return VybeResults(
                title: "\(Self.label(kind)): \(name)",
                note: similar.isEmpty ? "Found by name in your library."
                    : "Found by name, then the closest songs by genre and tempo (your tags carry no mood, so \"like\" means that).",
                songs: named + songs(similar)
            )
        case .described(_, let hits, let weak, let unknownName):
            let note = [
                unknownName.map { "\"\($0)\" isn't in your library, so this is matched as a description." },
                "Matched against each song's genres, tempo and artist; there is no mood or audio analysis.",
                weak ? Self.weakNote : nil,
            ].compactMap { $0 }.joined(separator: " ")
            return VybeResults(title: "Closest in your library", note: note, songs: songs(hits))
        case .similarTo(_, let hits):
            return VybeResults(title: "Like what's playing", note: "Closest songs by genre, tempo and artist.", songs: songs(hits))
        }
    }

    private func songs(_ hits: [VybeHit]) -> [VybeResult] {
        let found = (try? database.songs(ids: hits.map(\.songId))) ?? []
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return hits.compactMap { hit in byId[hit.songId].map { VybeResult(song: $0, reasons: hit.reasons) } }
    }

    private static func label(_ kind: EntityKind) -> String {
        switch kind {
        case .artist: "Artist"
        case .album: "Album"
        case .title: "Title"
        }
    }
}
