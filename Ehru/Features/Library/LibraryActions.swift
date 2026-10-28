import Foundation
import Observation

/// What the library screens do with songs (Android's LibraryViewModel actions): play, queue,
/// favourite, Smart Radio. One-line results show as a toast ([message]).
@MainActor
@Observable
final class LibraryActions {
    /// The radio in the queue (for "New radio picks") and what it already suggested.
    struct RadioSession: Equatable {
        let seed: RadioSeed
        let startSongId: Int64
        let suggested: Set<Int64>
    }

    var message: String?
    private(set) var messageID = UUID()
    private(set) var radio: RadioSession?

    private let database: LibraryDatabase
    private let player: PlayerController
    private let mixes: MixStore

    init(database: LibraryDatabase, player: PlayerController, mixes: MixStore) {
        self.database = database
        self.player = player
        self.mixes = mixes
    }

    func show(_ text: String) {
        messageID = UUID()
        message = text
    }

    func dismissMessage(id: UUID) {
        if messageID == id { message = nil }
    }

    /// [slots]: each song's playlist position, when [origin] is a playlist (a song may be in it twice).
    func play(_ songs: [Song], startIndex: Int, origin: CollectionRef? = nil, slots: [Int]? = nil, source: PlaybackSource? = nil) {
        if songs.isEmpty { return }
        player.playCollection(songs, startIndex: min(max(startIndex, 0), songs.count - 1), origin: origin, slots: slots, source: source)
    }

    func playInOrder(_ songs: [Song], origin: CollectionRef? = nil, slots: [Int]? = nil, source: PlaybackSource? = nil) {
        if songs.isEmpty { return }
        player.setShuffleModeEnabled(false)
        player.playCollection(songs, startIndex: 0, origin: origin, slots: slots, source: source)
    }

    /// Plays [songs] shuffled: the same shuffle mode the playlists use.
    func playShuffled(_ songs: [Song], origin: CollectionRef? = nil, slots: [Int]? = nil, source: PlaybackSource? = nil) {
        if songs.isEmpty { return }
        player.setShuffleModeEnabled(true)
        player.playCollection(songs, startIndex: Int.random(in: 0..<songs.count), origin: origin, slots: slots, source: source)
    }

    /// Plays the smart mix [key] in mix order, as its page's Play button does.
    func playMix(_ key: String) {
        guard let mix = mixes.mix(key) else { return }
        playInOrder(songs(mix.songIds), source: .smartPlaylist(key))
    }

    func playNext(_ song: Song, source: PlaybackSource? = nil) {
        player.playNext(song, source: source)
        show("\"\(song.title)\" will play next")
    }

    func addToQueue(_ song: Song, source: PlaybackSource? = nil) {
        player.addToQueue(song, source: source)
        show("Added to queue")
    }

    func toggleFavorite(_ song: Song) {
        do {
            try database.toggleFavorite(songId: song.id)
            // Read the database result rather than trusting a potentially older row snapshot.
            guard let updated = try database.song(id: song.id) else { return }
            show(updated.isFavorite ? "Added to Liked Songs" : "Removed from Liked Songs")
        } catch { show("Couldn't change the favourite: \(error.localizedDescription)") }
    }

    /// The library songs with [ids], in that order (missing ones left out).
    func songs(_ ids: [Int64]) -> [Song] {
        let found = (try? database.songs(ids: ids)) ?? []
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    // MARK: Smart Radio

    /// Starts a new queue: the seed's start song, then the radio's picks, in radio order.
    func startRadio(_ seed: RadioSeed) {
        Task {
            guard let plan = await mixes.radio(seed) else { return report(nil) }
            let queue = songs([plan.startSongId] + plan.songIds)
            if plan.songIds.isEmpty || queue.isEmpty { return report(plan) }
            player.setShuffleModeEnabled(false)
            player.playCollection(queue, startIndex: 0, origin: nil)
            radio = RadioSession(seed: seed, startSongId: plan.startSongId, suggested: Set(plan.songIds))
            report(plan)
        }
    }

    /// A radio from the song playing now: it keeps playing and the radio replaces what comes next.
    func startRadioFromCurrent() {
        guard let current = player.state.currentSong else { return }
        replaceUpcomingWithRadio(.song(current.id), startSongId: current.id, exclude: [])
    }

    /// Fresh picks for the radio in the queue, avoiding the songs it already suggested.
    func refreshRadio() {
        guard let session = radio else { return }
        replaceUpcomingWithRadio(session.seed, startSongId: session.startSongId, exclude: session.suggested)
    }

    private func replaceUpcomingWithRadio(_ seed: RadioSeed, startSongId: Int64, exclude: Set<Int64>) {
        Task {
            guard let plan = await mixes.radio(seed, exclude: exclude, startSongId: startSongId) else { return report(nil) }
            let picks = songs(plan.songIds)
            if picks.isEmpty { return report(plan) }
            player.setShuffleModeEnabled(false)
            player.replaceUpcoming(picks)
            radio = RadioSession(seed: seed, startSongId: startSongId, suggested: exclude.union(plan.songIds))
            report(plan)
        }
    }

    private func report(_ plan: RadioPlan?) {
        guard let plan else { return show("No songs to start a radio from") }
        if plan.songIds.isEmpty { return show("Not enough other songs for a radio from “\(plan.name)”") }
        let basis = plan.basedOn.map(\.label)
        let reasons: String
        switch basis.count {
        case 0: reasons = ""
        case 1: reasons = " · by \(basis[0])"
        default: reasons = " · by \(basis.dropLast().joined(separator: ", ")) and \(basis.last!)"
        }
        show("Radio from “\(plan.name)”: \(plan.songIds.count) songs\(reasons)")
    }

    // MARK: Playlists

    func createPlaylist(_ name: String, songs: [Song] = []) {
        let trimmed = name.trimmed
        if trimmed.isEmpty { return }
        do {
            _ = try database.createPlaylist(name: trimmed, songIds: songs.map(\.id))
            show(songs.isEmpty ? "Created \"\(trimmed)\"" : "Added to \"\(trimmed)\"")
        } catch {
            show("Couldn't create the playlist: \(error.localizedDescription)")
        }
    }

    func add(_ songs: [Song], to playlist: Playlist) {
        do {
            var added = 0
            for song in songs where try database.appendSong(song.id, toPlaylist: playlist.id) { added += 1 }
            show(added == 0 ? "Already in \"\(playlist.name)\"" : "Added \(countLabel(added, "song")) to \"\(playlist.name)\"")
        } catch {
            show("Couldn't add to the playlist: \(error.localizedDescription)")
        }
    }
}
