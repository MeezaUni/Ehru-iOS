import Foundation
import Observation

/// Where the shown lyrics come from.
enum LyricsOrigin: Equatable {
    /// The file's own tags.
    case file
    /// Fetched online earlier and kept in the app.
    case onlineSaved
    /// Fetched online just now.
    case online
}

/// The online lookup for the playing song, as the lyrics page shows it.
enum LyricsLookup: Equatable {
    case idle, searching, notFound, instrumental, offline
    case rateLimited(retryAtMs: Int64)
    case failed(String)
}

/// A manual online search started from the lyrics page.
enum ManualLyricsSearch: Equatable {
    case idle, searching
    case results([LyricsCandidate])
    case resultsWithNotice([LyricsCandidate], String)
    case error(String)
}

/// What the lyrics page shows for one song.
struct SongLyrics: Equatable {
    let songId: Int64
    let text: String?
    var origin: LyricsOrigin = .file
    var provider: String?
    var timing: LyricsTiming?
    var lookup: LyricsLookup = .idle
    /// The file has readable lyrics of its own.
    var hasFileLyrics = false
    var search: ManualLyricsSearch = .idle

    var parsed: Lyrics? { LyricsParser.parse(text) }
    var syncedServiceNotice: String? {
        switch lookup {
        case .failed(let reason): return LyricsFailureMessage.text(reason)
        case .offline: return "Synced lyrics couldn’t be checked while offline."
        case .rateLimited: return "The synced lyrics service is temporarily limiting requests."
        default: return nil
        }
    }
}

/// The playing song's lyrics: real embedded/saved synchronization can paint immediately;
/// embedded or saved plain text waits for a successful check that no synced match is available. Lookups start when the lyrics are shown,
/// send only title, artist, album and duration, and are kept so they work offline.
@MainActor
@Observable
final class LyricsStore {
    private(set) var current: SongLyrics?

    private let database: LibraryDatabase
    private let repository: OnlineLyricsRepository
    @ObservationIgnored private var song: Song?
    @ObservationIgnored private var embedded: String?
    @ObservationIgnored private var online: OnlineView?
    @ObservationIgnored private var manual: ManualLyricsSearch = .idle
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// The online lookup state of one song.
    private struct OnlineView {
        let songId: Int64
        var lookup: LyricsLookup
        var candidate: LyricsCandidate?
        var fromCache = false
        var userChosen = false
    }

    init(database: LibraryDatabase, repository: OnlineLyricsRepository) {
        self.database = database
        self.repository = repository
    }

    /// The lyrics page shows [song]: read its file lyrics and look online if needed (once per song).
    func shown(_ song: Song) {
        if self.song?.id != song.id || embedded == nil {
            cancelSearch()
            self.song = song
            embedded = try? database.lyrics(songId: song.id)
            manual = .idle
        }
        if online?.songId != song.id { startLookup(refresh: false) }
        publish()
    }

    func refresh() { startLookup(refresh: true) }

    func search(_ text: String) {
        guard let song else { return }
        cancelSearch()
        manual = .searching
        publish()
        let repository = repository
        searchTask = Task {
            let response = await repository.search(song.lyricsTrack, freeText: text)
            guard !Task.isCancelled, self.song?.id == song.id else { return }
            searchTask = nil
            switch response {
            case .success(let result):
                if let notice = result.syncedServiceNotice { manual = .resultsWithNotice(result.candidates, notice) }
                else { manual = .results(result.candidates) }
            case .notFound: manual = .results([])
            case .offline: manual = .error("You are offline.")
            case .rateLimited: manual = .error("A lyrics service asked to wait a moment. Try again shortly.")
            case .failed(let reason): manual = .error(LyricsFailureMessage.text(reason))
            }
            publish()
        }
    }

    /// The user picked a result: it is shown, kept, and preferred for this song (the file is never changed).
    func choose(_ candidate: LyricsCandidate) {
        guard let song else { return }
        lookupTask?.cancel()
        cancelSearch()
        manual = .idle
        let repository = repository
        Task {
            let result = await repository.choose(song.lyricsTrack, candidate)
            guard self.song?.id == song.id else { return }
            online = view(of: result, songId: song.id, previous: nil)
            publish()
        }
    }

    /// Back to the file's own lyrics: the online result for this song is forgotten.
    func useFileLyrics() {
        guard let song else { return }
        lookupTask?.cancel()
        cancelSearch()
        let repository = repository
        Task {
            await repository.forget(song.lyricsTrack)
            online = OnlineView(songId: song.id, lookup: .idle)
            publish()
        }
    }

    func closeSearch() {
        cancelSearch()
        manual = .idle
        publish()
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func startLookup(refresh: Bool) {
        guard let song else { return }
        lookupTask?.cancel()
        cancelSearch()
        manual = .idle
        let track = song.lyricsTrack
        let repository = repository
        let previous = online?.songId == song.id ? online : nil
        let previousSync = previous?.candidate.flatMap { $0.timing >= .line ? $0 : nil }
        // Hold unverified plain text while synchronization is checked, including old fallback
        // cache entries. Real embedded synchronization and saved synchronization can paint now.
        online = OnlineView(songId: song.id, lookup: .searching, candidate: previousSync,
                            fromCache: previous?.fromCache == true)
        publish()
        lookupTask = Task {
            let cached = await repository.cached(track)
            guard !Task.isCancelled, self.song?.id == song.id else { return }
            let savedSync = cached?.candidate.flatMap { $0.timing >= .line ? $0 : nil }
            let keep = previousSync ?? savedSync
            if !refresh, Self.timing(embedded) >= .line,
               !(cached?.userChosen == true && savedSync != nil) {
                online = OnlineView(songId: song.id, lookup: .idle)
                publish()
                return
            }
            online = OnlineView(songId: song.id, lookup: .searching, candidate: keep,
                                fromCache: keep != nil && cached?.candidate?.id == keep?.id,
                                userChosen: cached?.userChosen == true)
            publish()
            let recheckEmbeddedPlain = Self.timing(embedded) == .plain && savedSync == nil
            let result = await repository.lookup(track, refresh: refresh || recheckEmbeddedPlain)
            guard !Task.isCancelled, self.song?.id == song.id else { return }
            online = view(of: result, songId: song.id, previous: keep)
            publish()
        }
    }

    private static func timing(_ text: String?) -> LyricsTiming {
        guard let parsed = LyricsParser.parse(text) else { return .none }
        switch parsed {
        case .plain: return .plain
        case .synced: return parsed.hasWordTiming ? .word : .line
        }
    }

    private func view(of result: OnlineLyricsResult, songId: Int64, previous: LyricsCandidate?) -> OnlineView {
        switch result {
        case .found(let candidate, let fromCache, let userChosen, _):
            return OnlineView(songId: songId, lookup: .idle, candidate: candidate, fromCache: fromCache, userChosen: userChosen)
        case .notFound: return OnlineView(songId: songId, lookup: .notFound, candidate: previous, fromCache: previous != nil)
        case .instrumental: return OnlineView(songId: songId, lookup: .instrumental)
        case .offline: return OnlineView(songId: songId, lookup: .offline, candidate: previous, fromCache: previous != nil)
        case .rateLimited(let at): return OnlineView(songId: songId, lookup: .rateLimited(retryAtMs: at), candidate: previous, fromCache: previous != nil)
        case .failed(let reason): return OnlineView(songId: songId, lookup: .failed(reason), candidate: previous, fromCache: previous != nil)
        }
    }

    /// The file's own lyrics when it has readable ones (unless the user picked an online result),
    /// otherwise the online result, otherwise the lookup state.
    private func publish() {
        guard let song else {
            current = nil
            return
        }
        let view = online?.songId == song.id ? online : nil
        let fileTiming = Self.timing(embedded)
        let fileUsable = fileTiming != .none
        let permitsPlain = view?.lookup == .idle || view?.lookup == .notFound
        if let view, let candidate = view.candidate, let text = candidate.bestText,
           (candidate.timing >= .line || permitsPlain || view.userChosen),
           (view.userChosen || candidate.timing > fileTiming || !fileUsable) {
            current = SongLyrics(songId: song.id, text: text, origin: view.fromCache ? .onlineSaved : .online, provider: candidate.provider,
                                 timing: candidate.timing, lookup: view.lookup, hasFileLyrics: fileUsable, search: manual)
        } else if fileUsable, fileTiming >= .line || permitsPlain {
            current = SongLyrics(songId: song.id, text: embedded, origin: .file, timing: fileTiming,
                                 lookup: view?.lookup ?? .idle, hasFileLyrics: true, search: manual)
        } else {
            current = SongLyrics(songId: song.id, text: nil, origin: .file, lookup: view?.lookup ?? .idle, hasFileLyrics: fileUsable, search: manual)
        }
    }
}
