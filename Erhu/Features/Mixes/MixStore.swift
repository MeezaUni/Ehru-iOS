import Foundation
import Observation

/// The smart mixes, kept up to date, and Smart Radio on demand (Android's SmartMixRepository and
/// RadioRepository). Mixes are rebuilt off the main thread when the library or a counted play
/// changes (debounced; the first build runs at once), never on screen entry. Everything is local:
/// the database, the clock, and VYBE's stored vectors (never its model).
@MainActor
@Observable
final class MixStore {
    static let changeDebounce: Duration = .milliseconds(1_500)
    private static let tasteLimit = 300
    private static let similarLimit = 500

    /// Nil until the first build.
    private(set) var mixes: SmartMixes?
    /// Songs hidden from Smart Playlists: never offered, though their plays still shape the taste.
    private(set) var hidden: Set<Int64>

    private let database: LibraryDatabase
    private let vybe: VybeEngine
    @ObservationIgnored private let store = JSONStore<Set<Int64>>(name: "hidden_from_mixes.json", debounce: .zero)
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var building: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(database: LibraryDatabase, vybe: VybeEngine) {
        self.database = database
        self.vybe = vybe
        hidden = store.load() ?? []
    }

    /// Starts keeping the mixes current (the first time they are shown).
    func start() {
        guard !started else { return }
        started = true
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: SQLiteDatabase.didChange, object: database.db, queue: .main) { [weak self] note in
            guard SQLiteDatabase.affects(note, tables: ["songs", "listening_stats"]) else { return }
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
    }

    func mix(_ key: String) -> SmartMix? { mixes?.mixes.first { $0.kind.key == key } }

    /// Hides [songId] from (or returns it to) Smart Playlists; nothing else about the song changes.
    func setHidden(_ songId: Int64, _ isHidden: Bool) {
        if isHidden { hidden.insert(songId) } else { hidden.remove(songId) }
        store.saveNow(hidden)
        rebuild()
    }

    /// A radio from [seed]: built when asked, never in the background. [exclude]: earlier picks
    /// (when refreshing), which come back only if too few other songs are left.
    func radio(_ seed: RadioSeed, exclude: Set<Int64> = [], startSongId: Int64? = nil) async -> RadioPlan? {
        let database = database
        let vybe = vybe
        let hidden = hidden
        let now = Self.now()
        guard let profile = await Task.detached(priority: .userInitiated, operation: {
            try? SmartMixEngine.profile(tracks: database.trackFacts(), plays: database.monthlyPlays(), now: now, hidden: hidden)
        }).value else { return nil }
        let anchors = RadioEngine.anchors(profile, seed)
        if anchors.isEmpty { return nil }
        // VYBE only refines the radio: no index means metadata and history alone.
        let seeds = Dictionary(anchors.map { ($0.songId, Float(1)) }, uniquingKeysWith: { a, _ in a })
        let similarity = await vybe.tasteNeighbours(seeds, limit: Self.similarLimit)
        return await Task.detached(priority: .userInitiated) {
            RadioEngine.build(profile, seed: seed, similarity: similarity, exclude: exclude, startSongId: startSongId)
        }.value
    }

    private func scheduleRebuild() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: Self.changeDebounce)
            if !Task.isCancelled { rebuild() }
        }
    }

    private func rebuild() {
        building?.cancel()
        let database = database
        let vybe = vybe
        let hidden = hidden
        let now = Self.now()
        building = Task {
            let built = await Self.build(database: database, vybe: vybe, hidden: hidden, now: now)
            if !Task.isCancelled, let built, built != mixes { mixes = built }
        }
    }

    nonisolated static func build(database: LibraryDatabase, vybe: VybeEngine, hidden: Set<Int64>, now: Int64) async -> SmartMixes? {
        guard let profile = await Task.detached(priority: .utility, operation: {
            try? SmartMixEngine.profile(tracks: database.trackFacts(), plays: database.monthlyPlays(), now: now, hidden: hidden)
        }).value else { return nil }
        // VYBE is an enhancement: the mixes stand on their own without it.
        let taste = profile.isPersonal ? await vybe.tasteNeighbours(SmartMixEngine.tasteSeeds(profile), limit: tasteLimit) : nil
        return await Task.detached(priority: .utility) { SmartMixEngine.build(profile, taste: taste) }.value
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
