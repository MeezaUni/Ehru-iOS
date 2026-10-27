import Foundation

/// What a radio starts from. [key] keeps tie-breaking stable per seed.
enum RadioSeed: Hashable, Sendable {
    case song(Int64)
    case album(Int64)
    case artist(Int64)

    var key: String {
        switch self {
        case .song(let id): "song:\(id)"
        case .album(let id): "album:\(id)"
        case .artist(let id): "artist:\(id)"
        }
    }
}

/// A signal that actually shaped at least one picked song (only these are named to the user).
enum RadioSignal: CaseIterable, Sendable {
    case sound, genre, tempo, sameArtist, listening

    var label: String {
        switch self {
        case .sound: "VYBE sound match"
        case .genre: "shared genres"
        case .tempo: "similar tempo"
        case .sameArtist: "the same artist"
        case .listening: "your listening"
        }
    }
}

/// A built radio: [startSongId] plays first (the seed song, or the album's / artist's most played
/// track), then [songIds] in order. [basedOn]: the signals that shaped the picks, nothing assumed.
struct RadioPlan: Equatable, Sendable {
    let seed: RadioSeed
    let name: String
    let startSongId: Int64
    let songIds: [Int64]
    let basedOn: [RadioSignal]
}

/// Smart Radio: a queue from one song, album or artist, built from the listener's own library.
///
/// Each other song is scored only by what is known about it: VYBE's similarity to the seed songs
/// (when there is an index), genre overlap, tempo closeness (only trusted BPM tags), being by the
/// seed's artist or on its album, and familiarity balanced by a small bonus for songs never played.
/// Missing data scores nothing. The order is then spread out: a few songs per artist and album at
/// most, and never the same artist twice in a row while another fits. Deterministic.
enum RadioEngine {
    static let length = 30

    private static let wSound: Float = 1
    private static let wGenre: Float = 0.6
    private static let wTempo: Float = 0.2
    private static let wFamiliar: Float = 0.25
    private static let wLikedArtist: Float = 0.15
    private static let wUnheard: Float = 0.1
    private static let favouriteFamiliarity: Float = 0.5
    /// BPM difference at which tempo stops counting.
    private static let tempoSpan: Float = 30
    /// Fewest unsuggested songs a refresh draws from before earlier picks may return.
    private static let refreshMin = 10
    private static let perArtist = 3
    private static let perAlbum = 2
    /// An artist radio is mostly that artist's world: their own songs may fill a third of it.
    private static let seedArtistShare = 3
    private static let sameArtist: Float = 0.35
    private static let sameAlbum: Float = 0.15
    private static let seedArtist: Float = 0.8
    /// Cap multipliers: the strict caps first, then looser ones only if the radio is still short.
    private static let capSteps = [1, 2, 1_000]

    /// The seed's own songs (one for a song seed), in a fixed order; empty when the seed is unknown.
    static func anchors(_ profile: ListeningProfile, _ seed: RadioSeed) -> [TrackFacts] {
        let found: [TrackFacts]
        switch seed {
        case .song(let id): found = profile.tracks[id].map { [$0] } ?? []
        case .album(let id): found = profile.tracks.values.filter { $0.albumId == id }
        case .artist(let id): found = profile.tracks.values.filter { $0.artistId == id }
        }
        return found.sorted { $0.songId < $1.songId }
    }

    /// The radio for [seed], or nil when the seed has no songs. [similarity]: VYBE's cosine of each
    /// song to the anchors' centroid (nil without an index). [exclude]: songs not to pick (earlier
    /// picks, when refreshing); they come back only if too few other songs are left.
    static func build(_ profile: ListeningProfile, seed: RadioSeed, similarity: [Int64: Float]?, exclude: Set<Int64> = [],
                      startSongId: Int64? = nil, length: Int = RadioEngine.length) -> RadioPlan? {
        let seedSongs = anchors(profile, seed)
        guard let first = seedSongs.first else { return nil }
        let start = startSongId.flatMap { profile.tracks[$0] != nil ? $0 : nil } ?? startOf(profile, seed, seedSongs)
        let reference = Reference(profile, seed, seedSongs)
        let open = profile.tracks.values.filter { $0.songId != start && !profile.hidden.contains($0.songId) }
        let fresh = open.filter { !exclude.contains($0.songId) }
        // Fresh picks while a fair number remain (a refresh may come out a little shorter).
        let pool = fresh.count >= min(length, refreshMin) || fresh.count == open.count ? fresh : open
        let poolIds = Set(pool.map(\.songId))
        let sound = similarity.map { all in rankNormalised(all.filter { poolIds.contains($0.key) }) } ?? [:]
        let scored = pool.map { score(profile, reference, sound, $0) }
        let picked = spread(scored, seed, reference, length)
        let name: String
        switch seed {
        case .song: name = first.title
        case .album: name = first.album
        case .artist: name = first.artist
        }
        return RadioPlan(
            seed: seed, name: name, startSongId: start, songIds: picked.map(\.track.songId),
            basedOn: RadioSignal.allCases.filter { signal in picked.contains { $0.signals.contains(signal) } }
        )
    }

    /// The seed song; else the most-played (then first) song of the album or artist.
    private static func startOf(_ profile: ListeningProfile, _ seed: RadioSeed, _ anchors: [TrackFacts]) -> Int64 {
        if case .song(let id) = seed { return id }
        return anchors.min { a, b in
            let la = profile.history(a.songId).lasting
            let lb = profile.history(b.songId).lasting
            return la != lb ? la > lb : a.songId < b.songId
        }!.songId
    }

    /// What the seed stands for: its genres, typical trusted tempo, artists and albums.
    private struct Reference {
        let genres: Set<String>
        let tempo: Int?
        let artists: Set<Int64>
        let albums: Set<Int64>
        /// Weight of being by the seed's artist: strong for an artist radio, moderate otherwise.
        let artistWeight: Float
        let maxLasting: Float

        init(_ profile: ListeningProfile, _ seed: RadioSeed, _ anchors: [TrackFacts]) {
            let tempos = anchors.compactMap(Moods.tempo).sorted()
            genres = Set(anchors.flatMap(genresOf))
            tempo = tempos.isEmpty ? nil : tempos[tempos.count / 2]
            artists = Set(anchors.map(\.artistId))
            // An album radio looks beyond the album; its own songs only through the artist.
            if case .album = seed { albums = [] } else { albums = Set(anchors.map(\.albumId)) }
            if case .artist = seed { artistWeight = RadioEngine.seedArtist } else { artistWeight = RadioEngine.sameArtist }
            let most = profile.songs.values.map(\.lasting).max() ?? 0
            maxLasting = most > 0 ? most : 1
        }
    }

    private struct Scored {
        let track: TrackFacts
        let score: Float
        let signals: Set<RadioSignal>
    }

    private static func score(_ profile: ListeningProfile, _ reference: Reference, _ sound: [Int64: Float], _ track: TrackFacts) -> Scored {
        var signals = Set<RadioSignal>()
        var total: Float = 0
        if let similarity = sound[track.songId] {
            total += wSound * similarity
            if similarity > 0 { signals.insert(.sound) }
        }
        if let match = genreMatch(track, reference) {
            total += wGenre * match
            signals.insert(.genre)
        }
        if let match = tempoMatch(track, reference) {
            total += wTempo * match
            signals.insert(.tempo)
        }
        if reference.artists.contains(track.artistId) {
            total += reference.artistWeight
            signals.insert(.sameArtist)
        }
        if reference.albums.contains(track.albumId) { total += sameAlbum }

        let history = profile.history(track.songId)
        let favourite: Float = track.isFavorite ? favouriteFamiliarity : 0
        let familiar = min(history.lasting / reference.maxLasting + favourite, 1)
        let liked = profile.artist(track)
        if familiar > 0 || liked > 0 {
            total += wFamiliar * familiar + wLikedArtist * liked
            signals.insert(.listening)
        }
        if history.plays == 0 { total += wUnheard }
        return Scored(track: track, score: total, signals: signals)
    }

    /// Share of genres in common (0..1]; nil when either side has no genre tag or none is shared.
    private static func genreMatch(_ track: TrackFacts, _ reference: Reference) -> Float? {
        let genres = genresOf(track)
        let shared = genres.filter { reference.genres.contains($0) }.count
        return shared > 0 ? Float(shared) / Float(min(genres.count, reference.genres.count)) : nil
    }

    /// Closeness of trusted tempos (0..1]; nil when either is unknown or they are too far apart.
    private static func tempoMatch(_ track: TrackFacts, _ reference: Reference) -> Float? {
        guard let tempo = Moods.tempo(track), let target = reference.tempo else { return nil }
        let match = 1 - Float(abs(tempo - target)) / tempoSpan
        return match > 0 ? match : nil
    }

    /// Best first within caps (a few per artist and album; the seed artist may fill a third of an
    /// artist radio), never the same artist twice in a row while another song fits. When the caps
    /// leave the radio short, they are relaxed step by step to fill it.
    private static func spread(_ scored: [Scored], _ seed: RadioSeed, _ reference: Reference, _ length: Int) -> [Scored] {
        var remaining = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let ha = mixHash(a.track.songId, seed.key)
            let hb = mixHash(b.track.songId, seed.key)
            return ha != hb ? ha < hb : a.track.songId < b.track.songId
        }
        let isArtistSeed: Bool
        if case .artist = seed { isArtistSeed = true } else { isArtistSeed = false }
        let seedArtistCap = isArtistSeed ? max(length / seedArtistShare, perArtist) : perArtist
        var artists: [Int64: Int] = [:]
        var albums: [Int64: Int] = [:]
        var picked: [Scored] = []
        for relax in capSteps {
            while picked.count < length {
                let previous = picked.last?.track.artistId
                let fits = remaining.indices.filter { index in
                    let track = remaining[index].track
                    return artists[track.artistId, default: 0] < artistCap(track, seed, reference, seedArtistCap, relax)
                        && albums[track.albumId, default: 0] < albumCap(track, seed, relax)
                }
                // A repeat of the previous artist only once even the loosest caps offer nothing else.
                guard let index = fits.first(where: { remaining[$0].track.artistId != previous })
                    ?? (relax == capSteps.last ? fits.first : nil)
                else { break }
                let next = remaining.remove(at: index)
                picked.append(next)
                artists[next.track.artistId, default: 0] += 1
                albums[next.track.albumId, default: 0] += 1
            }
        }
        return picked
    }

    private static func artistCap(_ track: TrackFacts, _ seed: RadioSeed, _ reference: Reference, _ seedArtistCap: Int, _ relax: Int) -> Int {
        let isSeedArtist = reference.artists.contains(track.artistId)
        // An artist radio stays at most a third that artist, even when short.
        if case .artist = seed, isSeedArtist { return seedArtistCap }
        return isSeedArtist ? seedArtistCap * relax : perArtist * relax
    }

    /// An album radio keeps at most two more of that album, even when short.
    private static func albumCap(_ track: TrackFacts, _ seed: RadioSeed, _ relax: Int) -> Int {
        if case .album(let id) = seed, track.albumId == id { return perAlbum }
        return perAlbum * relax
    }

    /// Scales similarities to 0..1 across the candidates (the closest is 1).
    private static func rankNormalised(_ similarity: [Int64: Float]) -> [Int64: Float] {
        let finite = similarity.filter { $0.value.isFinite }
        let low = finite.values.min() ?? 0
        let span = (finite.values.max() ?? 0) - low
        return finite.mapValues { span > 0 ? ($0 - low) / span : 1 }
    }
}
