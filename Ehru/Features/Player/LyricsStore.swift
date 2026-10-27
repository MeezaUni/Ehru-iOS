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
    /// Possible matches, none certain: the user picks one (or none).
    case needsChoice([LyricsCandidate])
}

/// A manual online search started from the lyrics page.
enum ManualLyricsSearch: Equatable {
    case idle, searching
    case results([LyricsCandidate])
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
}

/// The playing song's lyrics (Android's LibraryViewModel lyrics part): the file's own lyrics when it
/// has readable ones, otherwise what was found online. Lookups start when the lyrics are shown,
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
        manual = .searching
        publish()
        let repository = repository
        Task {
            let response = await repository.search(song.lyricsTrack, freeText: text)
            guard self.song?.id == song.id else { return }
            switch response {
            case .success(let candidates): manual = .results(candidates)
            case .notFound: manual = .results([])
            case .offline: manual = .error("You are offline.")
            case .rateLimited: manual = .error("LRCLIB asked to wait a moment. Try again shortly.")
            case .failed(let reason): manual = .error("The search failed (\(reason)).")
            }
            publish()
        }
    }

    /// The user picked a result: it is shown, kept, and preferred for this song (the file is never changed).
    func choose(_ candidate: LyricsCandidate) {
        guard let song else { return }
        lookupTask?.cancel()
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
        let repository = repository
        Task {
            await repository.forget(song.lyricsTrack)
            online = OnlineView(songId: song.id, lookup: .idle)
            publish()
        }
    }

    func closeSearch() {
        manual = .idle
        publish()
    }

    private func startLookup(refresh: Bool) {
        guard let song else { return }
        lookupTask?.cancel()
        manual = .idle
        let track = song.lyricsTrack
        let repository = repository
        let fileUsable = LyricsParser.parse(embedded) != nil
        lookupTask = Task {
            let previous = online?.songId == song.id ? online : nil
            if !refresh {
                let chosen = await repository.cached(track)?.userChosen == true
                if fileUsable && !chosen {
                    online = OnlineView(songId: song.id, lookup: .idle)
                    publish()
                    return
                }
            }
            online = OnlineView(songId: song.id, lookup: .searching, candidate: previous?.candidate,
                                fromCache: previous?.fromCache == true, userChosen: previous?.userChosen == true)
            publish()
            let result = await repository.lookup(track, refresh: refresh)
            guard self.song?.id == song.id else { return }
            online = view(of: result, songId: song.id, previous: previous?.candidate)
            publish()
        }
    }

    private func view(of result: OnlineLyricsResult, songId: Int64, previous: LyricsCandidate?) -> OnlineView {
        switch result {
        case .found(let candidate, let fromCache, let userChosen, _):
            return OnlineView(songId: songId, lookup: .idle, candidate: candidate, fromCache: fromCache, userChosen: userChosen)
        case .notFound: return OnlineView(songId: songId, lookup: .notFound, candidate: previous)
        case .instrumental: return OnlineView(songId: songId, lookup: .instrumental)
        case .offline: return OnlineView(songId: songId, lookup: .offline, candidate: previous)
        case .rateLimited(let at): return OnlineView(songId: songId, lookup: .rateLimited(retryAtMs: at), candidate: previous)
        case .failed(let reason): return OnlineView(songId: songId, lookup: .failed(reason), candidate: previous)
        case .needsChoice(let candidates): return OnlineView(songId: songId, lookup: .needsChoice(candidates), candidate: previous)
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
        let fileUsable = LyricsParser.parse(embedded) != nil
        if let view, let candidate = view.candidate, let text = candidate.bestText, view.userChosen || !fileUsable {
            current = SongLyrics(songId: song.id, text: text, origin: view.fromCache ? .onlineSaved : .online, provider: candidate.provider,
                                 timing: candidate.timing, lookup: view.lookup, hasFileLyrics: fileUsable, search: manual)
        } else if fileUsable {
            current = SongLyrics(songId: song.id, text: embedded, origin: .file, lookup: view?.lookup ?? .idle, hasFileLyrics: true, search: manual)
        } else {
            current = SongLyrics(songId: song.id, text: nil, origin: .file, lookup: view?.lookup ?? .idle, search: manual)
        }
    }
}
