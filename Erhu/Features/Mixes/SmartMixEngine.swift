import Foundation

/// The kinds of smart mix. [personal] mixes come from the listener's own play history and are only
/// offered once there is enough of it. Shelf order is declaration order.
enum MixKind: String, CaseIterable, Sendable {
    case rotation = "rotation"
    case yourSound = "your-sound"
    case forgotten = "forgotten"
    case deepCuts = "deep-cuts"
    case highEnergy = "high-energy"
    case chill = "chill"
    case lateNight = "late-night"
    case aLittleDifferent = "a-little-different"
    case spotlight = "spotlight"
    case throwbacks = "throwbacks"
    case quickHits = "quick-hits"
    case longListens = "long-listens"
    case yetToHear = "yet-to-hear"
    case favourites = "favourites"
    case fresh = "fresh"

    var key: String { rawValue }
    var ordinal: Int { Self.allCases.firstIndex(of: self)! }

    var title: String {
        switch self {
        case .rotation: "In Your Rotation"
        case .yourSound: "Your Kind of Sound"
        case .forgotten: "Forgotten Favourites"
        case .deepCuts: "Deep Cuts"
        case .highEnergy: "High Energy"
        case .chill: "Chill"
        case .lateNight: "Late Night"
        case .aLittleDifferent: "A Little Different"
        case .spotlight: "Spotlight"
        case .throwbacks: "Throwbacks"
        case .quickHits: "Quick Hits"
        case .longListens: "Long Listens"
        case .yetToHear: "Yet to Be Heard"
        case .favourites: "Favourites"
        case .fresh: "Fresh in Your Library"
        }
    }

    var personal: Bool {
        switch self {
        case .rotation, .yourSound, .forgotten, .deepCuts, .aLittleDifferent: true
        default: false
        }
    }

    static func fromKey(_ key: String) -> MixKind? { MixKind(rawValue: key) }
}

/// One built mix: its songs in play order, a truthful line about how it was made, and its title.
struct SmartMix: Equatable, Sendable {
    let kind: MixKind
    let songIds: [Int64]
    let description: String
    var title: String

    init(kind: MixKind, songIds: [Int64], description: String, title: String? = nil) {
        self.kind = kind
        self.songIds = songIds
        self.description = description
        self.title = title ?? kind.title
    }
}

/// Every mix worth showing right now. [needsMoreListening]: the history is too short for personal mixes.
struct SmartMixes: Equatable, Sendable {
    let mixes: [SmartMix]
    let needsMoreListening: Bool

    func mix(_ kind: MixKind) -> SmartMix? { mixes.first { $0.kind == kind } }
}

/// A song's play history: total counted plays, latest play, and plays weighted by how recent they are.
struct SongHistory: Equatable, Sendable {
    let plays: Int
    let lastPlayedAt: Int64
    /// Plays decayed with a short half-life: what is being played now.
    let recent: Float
    /// Plays decayed with a long half-life: lasting taste.
    let lasting: Float

    static let none = SongHistory(plays: 0, lastPlayedAt: 0, recent: 0, lasting: 0)
}

/// What the listening history says about each song, artist, album and genre.
struct ListeningProfile: Sendable {
    static let minPlayedSongs = 5
    static let minTotalPlays = 10

    let tracks: [Int64: TrackFacts]
    let songs: [Int64: SongHistory]
    let artistAffinity: [Int64: Float]
    let albumAffinity: [Int64: Float]
    let genreWeight: [String: Float]
    /// Artists by affinity, strongest first.
    let artistRanking: [Int64]
    let now: Int64
    /// Songs hidden from Smart Playlists: never offered, though their plays still shape the taste.
    var hidden: Set<Int64> = []

    /// Enough history for mixes that claim to know the listener.
    var isPersonal: Bool {
        songs.values.filter { $0.plays > 0 }.count >= Self.minPlayedSongs && songs.values.reduce(0) { $0 + $1.plays } >= Self.minTotalPlays
    }

    func history(_ songId: Int64) -> SongHistory { songs[songId] ?? .none }
    func artist(_ track: TrackFacts) -> Float { artistAffinity[track.artistId] ?? 0 }
    func album(_ track: TrackFacts) -> Float { albumAffinity[track.albumId] ?? 0 }

    /// How well [track]'s genres match the listener's (0..1); 0 without genre tags.
    func genre(_ track: TrackFacts) -> Float {
        genresOf(track).map { genreWeight[$0] ?? 0 }.max() ?? 0
    }
}

/// A track's genres, lower-cased (a tag may hold several: "Hip-Hop; R&B").
func genresOf(_ track: TrackFacts) -> [String] {
    guard let genre = track.genre else { return [] }
    return genre.split(whereSeparator: { ";,/|".contains($0) })
        .map { String($0).trimmed.lowercased() }
        .filter { !$0.isEmpty }
}

/// Java's String.hashCode (UTF-16, 32-bit wrapping), for tie-breaks identical to Android's.
func javaHashCode(_ text: String) -> Int32 {
    text.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32(bitPattern: UInt32($1)) }
}

/// A fixed scramble of a song and a key (SplitMix64 finaliser), as on Android.
func mixHash(_ songId: Int64, _ key: String) -> Int64 {
    let goldenGamma = Int64(bitPattern: 0x9E37_79B9_7F4A_7C15)
    let multiplier = Int64(bitPattern: 0xFF51_AFD7_ED55_8CCD)
    var h = songId &* goldenGamma &+ Int64(javaHashCode(key))
    h = (h ^ Int64(bitPattern: UInt64(bitPattern: h) >> 33)) &* multiplier
    return h ^ Int64(bitPattern: UInt64(bitPattern: h) >> 33)
}

/// Conservative mood matching. A song's genre tag decides; its BPM only supports or vetoes a
/// genre, never places a song on its own. BPM tags outside 70–175 count as unknown (half/double time).
enum Moods {
    private static let trustedRange = 70...175
    private static let fastMin = 125
    private static let upbeatMin = 118
    private static let slowMax = 110

    private static let energy = [
        "metal", "punk", "hardcore", "drum and bass", "drum & bass", "dnb", "edm", "dance", "house", "techno", "trance",
        "dubstep", "hardstyle", "electro house", "trap", "drill", "grime", "rock", "hyperpop", "phonk", "jungle", "breakbeat",
        "garage", "workout", "rage",
    ]
    private static let calm = [
        "ambient", "chill", "lo-fi", "lofi", "acoustic", "folk", "bossa", "downtempo", "easy listening", "lounge", "new age",
        "dream pop", "bedroom pop", "soft rock", "piano", "classical", "singer-songwriter", "meditation", "sleep", "jazz",
    ]
    private static let explicitlyCalm = ["ambient", "chill", "lo-fi", "lofi", "sleep", "meditation"]
    private static let night = [
        "r&b", "rnb", "soul", "jazz", "trip hop", "trip-hop", "downtempo", "ambient", "synthwave", "darkwave", "chillwave",
        "lo-fi", "lofi", "dream pop", "slowcore", "blues", "neo soul", "alternative r&b", "shoegaze", "nocturn",
    ]

    private static func any(_ genres: [String], _ keywords: [String]) -> Bool {
        genres.contains { genre in keywords.contains { genre.contains($0) } }
    }

    static func isHighEnergy(_ track: TrackFacts) -> Bool {
        let genres = genresOf(track)
        let tempo = self.tempo(track)
        if genres.isEmpty || any(genres, calm) { return false }
        if any(genres, energy) { return tempo == nil || tempo! >= upbeatMin }
        // A known genre that is neither: only a clearly fast, trusted tempo makes it upbeat.
        return tempo != nil && tempo! >= fastMin && !any(genres, night)
    }

    static func isChill(_ track: TrackFacts) -> Bool {
        let genres = genresOf(track)
        let tempo = self.tempo(track)
        if !any(genres, calm) { return false }
        if genres.contains(where: { g in energy.contains { g.contains($0) } && !g.contains("soft rock") }) { return false }
        if any(genres, explicitlyCalm) { return true }
        return tempo == nil || tempo! < upbeatMin
    }

    static func isLateNight(_ track: TrackFacts) -> Bool {
        let genres = genresOf(track)
        let tempo = self.tempo(track)
        return any(genres, night) && !any(genres, energy) && (tempo == nil || tempo! <= slowMax)
    }

    /// The BPM when it can be trusted as the song's tempo.
    static func tempo(_ track: TrackFacts) -> Int? {
        track.bpm.flatMap { trustedRange.contains($0) ? $0 : nil }
    }
}

/// Builds the smart mixes from local data only. Deterministic: the same library, history, time and
/// taste always give the same mixes in the same order.
enum SmartMixEngine {
    private static let dayMs: Int64 = 86_400_000
    private static let recentHalfLifeDays = 21.0
    private static let lastingHalfLifeDays = 120.0
    private static let favouriteWeight: Float = 2
    static let mixLimit = 40
    private static let looseArtistCap = 8
    private static let tasteSeedCount = 15
    private static let minPersonalBeforeFallbacks = 3

    static func profile(tracks: [TrackFacts], plays: [MonthlyPlays], now: Int64, hidden: Set<Int64> = []) -> ListeningProfile {
        let byId = Dictionary(tracks.map { ($0.songId, $0) }, uniquingKeysWith: { first, _ in first })
        var songs: [Int64: SongHistory] = [:]
        for (songId, rows) in Dictionary(grouping: plays.filter { $0.plays > 0 && byId[$0.songId] != nil }, by: \.songId) {
            var recent = 0.0
            var lasting = 0.0
            for row in rows {
                let ageDays = Double(max(now - row.lastPlayedAt, 0)) / Double(dayMs)
                recent += Double(row.plays) * pow(0.5, ageDays / recentHalfLifeDays)
                lasting += Double(row.plays) * pow(0.5, ageDays / lastingHalfLifeDays)
            }
            songs[songId] = SongHistory(
                plays: rows.reduce(0) { $0 + $1.plays }, lastPlayedAt: rows.map(\.lastPlayedAt).max()!,
                recent: Float(recent), lasting: Float(lasting)
            )
        }
        var artistRaw: [Int64: Float] = [:]
        var albumRaw: [Int64: Float] = [:]
        var genreRaw: [String: Float] = [:]
        for track in tracks {
            let weight = (songs[track.songId]?.lasting ?? 0) + (track.isFavorite ? favouriteWeight : 0)
            if weight <= 0 { continue }
            artistRaw[track.artistId, default: 0] += weight
            albumRaw[track.albumId, default: 0] += weight
            for genre in genresOf(track) { genreRaw[genre, default: 0] += weight }
        }
        return ListeningProfile(
            tracks: byId, songs: songs, artistAffinity: normalised(artistRaw), albumAffinity: normalised(albumRaw),
            genreWeight: normalised(genreRaw),
            artistRanking: artistRaw.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }.map(\.key),
            now: now, hidden: hidden
        )
    }

    /// The songs (with weights) that define the listener's taste, for VYBE's taste neighbours.
    static func tasteSeeds(_ profile: ListeningProfile) -> [Int64: Float] {
        let top = profile.songs.filter { $0.value.lasting > 0 }
            .sorted { a, b in a.value.lasting != b.value.lasting ? a.value.lasting > b.value.lasting : a.key < b.key }
            .prefix(tasteSeedCount)
        return Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value.lasting) })
    }

    /// Every mix with enough songs to be worth offering. [taste]: VYBE's similarity to the listener's taste, if any.
    static func build(_ profile: ListeningProfile, taste: [Int64: Float]?) -> SmartMixes {
        let personal = profile.isPersonal
        var built: [SmartMix] = []
        if personal {
            if let mix = rotation(profile) { built.append(mix) }
            if let mix = yourSound(profile, taste: taste) { built.append(mix) }
            if let mix = forgotten(profile) { built.append(mix) }
        }
        let cuts = personal ? deepCuts(profile) : nil
        if let cuts { built.append(cuts) }
        if let mix = mood(profile, .highEnergy, Moods.isHighEnergy) { built.append(mix) }
        if let mix = mood(profile, .chill, Moods.isChill) { built.append(mix) }
        if let mix = mood(profile, .lateNight, Moods.isLateNight) { built.append(mix) }
        if personal, let mix = aLittleDifferent(profile, taste: taste, exclude: Set(cuts?.songIds ?? [])) { built.append(mix) }
        built += LibraryMixes.build(profile)
        if built.filter({ $0.kind.personal }).count < minPersonalBeforeFallbacks {
            if let mix = favourites(profile) { built.append(mix) }
            if let mix = fresh(profile) { built.append(mix) }
        }
        let ordered = built.enumerated().sorted { a, b in
            a.element.kind.ordinal != b.element.kind.ordinal ? a.element.kind.ordinal < b.element.kind.ordinal : a.offset < b.offset
        }.map(\.element)
        return SmartMixes(mixes: ordered, needsMoreListening: !personal)
    }

    // MARK: In Your Rotation: played often, lately.

    static func rotation(_ profile: ListeningProfile) -> SmartMix? {
        let since = profile.now - 45 * dayMs
        let ranked = profile.songs.filter { $0.value.plays >= 2 && $0.value.lastPlayedAt >= since }
            .map { ($0.key, $0.value.recent + 0.1 * log(1 + Float($0.value.plays))) }
        return finish(profile, .rotation, ranked, minimum: 5, description: "What you've been playing most lately", perArtist: looseArtistCap)
    }

    // MARK: Forgotten Favourites: played meaningfully before, not for a while.

    static func forgotten(_ profile: ListeningProfile) -> SmartMix? {
        let before = profile.now - 60 * dayMs
        let ranked = profile.songs.filter { $0.value.plays >= 3 && $0.value.lastPlayedAt < before }
            .map { id, h in (id, Float(h.plays) + (profile.tracks[id]?.isFavorite == true ? favouriteWeight : 0)) }
        return finish(profile, .forgotten, ranked, minimum: 5, description: "Songs you played a lot, not heard for two months or more",
                      perArtist: looseArtistCap)
    }

    // MARK: Deep Cuts: rarely played songs by the artists the listener enjoys.

    static func deepCuts(_ profile: ListeningProfile) -> SmartMix? {
        let ranked = profile.tracks.values
            .filter { profile.history($0.songId).plays <= 1 && profile.artist($0) >= 0.15 }
            .map { track -> (Int64, Float) in
                let unheard: Float = profile.history(track.songId).plays == 0 ? 0.1 : 0
                return (track.songId, 0.6 * profile.artist(track) + 0.4 * profile.album(track) + unheard)
            }
        return finish(profile, .deepCuts, ranked, minimum: 6, description: "Less-played songs by artists you love", perArtist: 4, perAlbum: 3)
    }

    // MARK: Your Kind of Sound: songs that match the established taste.

    static func yourSound(_ profile: ListeningProfile, taste: [Int64: Float]?) -> SmartMix? {
        let vybe = taste.flatMap { $0.isEmpty ? nil : $0 }
        let hasGenres = !profile.genreWeight.isEmpty
        if vybe == nil && !hasGenres { return nil }
        let restSince = profile.now - 14 * dayMs
        let seeds = Set(tasteSeeds(profile).keys)
        let similarity = vybe.map(rankNormalised) ?? [:]
        let ranked = profile.tracks.values
            .filter { !seeds.contains($0.songId) && profile.history($0.songId).lastPlayedAt < restSince }
            .compactMap { track -> (Int64, Float)? in
                let sound = similarity[track.songId] ?? 0
                let genre = profile.genre(track)
                let artist = profile.artist(track)
                let score = vybe != nil ? 0.55 * sound + 0.25 * genre + 0.2 * artist : 0.6 * genre + 0.4 * artist
                return sound > 0 || genre > 0 ? (track.songId, score) : nil
            }
        let how = vybe != nil ? "Close to the songs you play most, matched by VYBE" : "From the genres and artists you play most"
        return finish(profile, .yourSound, ranked, minimum: 10, description: how, perArtist: 3)
    }

    // MARK: A Little Different: lesser-heard songs just outside the favourites.

    static func aLittleDifferent(_ profile: ListeningProfile, taste: [Int64: Float]?, exclude: Set<Int64>) -> SmartMix? {
        let outerArtists = Set(profile.artistRanking.dropFirst(5).prefix(25))
        let similarity = taste.map(rankNormalised) ?? [:]
        let open = profile.tracks.values.filter { !exclude.contains($0.songId) && profile.history($0.songId).plays <= 1 }
        let familiar = open.filter { outerArtists.contains($0.artistId) }
            .map { ($0.songId, profile.artist($0) + 0.5 * profile.genre($0)) }
        let unfamiliar = open.filter { profile.artist($0) == 0 }.compactMap { track -> (Int64, Float)? in
            let near = similarity[track.songId] ?? 0
            let genre = profile.genre(track)
            return near > 0 || genre >= 0.3 ? (track.songId, near + genre) : nil
        }
        let half = mixLimit / 2
        let a = diverse(profile, .aLittleDifferent, familiar, limit: half, perArtist: 2, perAlbum: 2)
        let b = diverse(profile, .aLittleDifferent, unfamiliar, limit: half, perArtist: 2, perAlbum: 2)
        var interleaved: [Int64] = []
        var seen = Set<Int64>()
        for i in 0..<max(a.count, b.count) {
            if i < a.count, seen.insert(a[i]).inserted { interleaved.append(a[i]) }
            if i < b.count, seen.insert(b[i]).inserted { interleaved.append(b[i]) }
        }
        if a.isEmpty || b.isEmpty || interleaved.count < 8 { return nil }
        return SmartMix(kind: .aLittleDifferent, songIds: interleaved, description: "Lesser-heard songs near your taste")
    }

    // MARK: Moods

    static func mood(_ profile: ListeningProfile, _ kind: MixKind, _ matches: (TrackFacts) -> Bool) -> SmartMix? {
        let ranked = profile.tracks.values.filter(matches).map { track -> (Int64, Float) in
            let plays = min(Float(profile.history(track.songId).plays) / 5, 1)
            return (track.songId, 0.5 * profile.artist(track) + 0.3 * profile.genre(track) + 0.2 * plays)
        }
        let how: String
        switch kind {
        case .highEnergy: how = "Upbeat songs from your library, by genre and tempo"
        case .chill: how = "Easy-going songs from your library, by genre"
        default: how = "After-dark songs from your library, by genre"
        }
        return finish(profile, kind, ranked, minimum: 8, description: how, perArtist: 3)
    }

    // MARK: Fallbacks

    static func favourites(_ profile: ListeningProfile) -> SmartMix? {
        let ranked = profile.tracks.values.filter(\.isFavorite).map { ($0.songId, Float(profile.history($0.songId).plays)) }
        return finish(profile, .favourites, ranked, minimum: 3, description: "Songs you marked with a heart", perArtist: .max)
    }

    static func fresh(_ profile: ListeningProfile) -> SmartMix? {
        if profile.tracks.count < 10 { return nil }
        let ranked = profile.tracks.values.map { ($0.songId, Float($0.addedAt)) }
        return finish(profile, .fresh, ranked, minimum: 3, description: "The newest additions to your library", perArtist: .max)
    }

    // MARK: Ordering and diversity

    static func finish(_ profile: ListeningProfile, _ kind: MixKind, _ ranked: [(Int64, Float)], minimum: Int, description: String,
                       perArtist: Int = 3, perAlbum: Int = .max) -> SmartMix? {
        let picked = diverse(profile, kind, ranked, limit: mixLimit, perArtist: perArtist, perAlbum: perAlbum)
        return picked.count >= minimum ? SmartMix(kind: kind, songIds: picked, description: description) : nil
    }

    /// Best first, at most [perArtist] per artist and [perAlbum] per album, no duplicates. Equal
    /// scores fall back to a fixed hash of song and mix, so ties never reshuffle.
    static func diverse(_ profile: ListeningProfile, _ kind: MixKind, _ ranked: [(Int64, Float)], limit: Int,
                        perArtist: Int, perAlbum: Int) -> [Int64] {
        let ordered = ranked.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let ha = mixHash(a.0, kind.key)
            let hb = mixHash(b.0, kind.key)
            return ha != hb ? ha < hb : a.0 < b.0
        }
        var artists: [Int64: Int] = [:]
        var albums: [Int64: Int] = [:]
        var picked: [Int64] = []
        var seen = Set<Int64>()
        for (id, score) in ordered {
            if picked.count >= limit { break }
            guard score.isFinite, !seen.contains(id), !profile.hidden.contains(id), let track = profile.tracks[id] else { continue }
            guard artists[track.artistId, default: 0] < perArtist, albums[track.albumId, default: 0] < perAlbum else { continue }
            artists[track.artistId, default: 0] += 1
            albums[track.albumId, default: 0] += 1
            picked.append(id)
            seen.insert(id)
        }
        return picked
    }

    private static func normalised<K>(_ raw: [K: Float]) -> [K: Float] {
        guard let max = raw.values.max(), max > 0 else { return [:] }
        return raw.mapValues { $0 / max }
    }

    /// Cosine scores to 0..1 across the returned neighbours (the closest is 1).
    static func rankNormalised(_ similarity: [Int64: Float]) -> [Int64: Float] {
        let max = similarity.values.max() ?? 0
        let min = similarity.values.min() ?? 0
        let span = max - min
        return similarity.mapValues { span > 0 ? ($0 - min) / span : 1 }
    }
}

/// Mixes built from what the library itself says, each only when enough songs really fit.
enum LibraryMixes {
    static func build(_ profile: ListeningProfile, calendar: Calendar = .current) -> [SmartMix] {
        [spotlight(profile), throwbacks(profile, calendar: calendar), quickHits(profile), longListens(profile), yetToHear(profile)].compactMap { $0 }
    }

    /// One artist's songs: the artist played most (with enough songs here), else the one with the most songs.
    static func spotlight(_ profile: ListeningProfile) -> SmartMix? {
        let byArtist = Dictionary(grouping: profile.tracks.values.filter { !profile.hidden.contains($0.songId) }, by: \.artistId)
        let played = profile.artistRanking.first { (byArtist[$0]?.count ?? 0) >= 6 }
        let artistId = played ?? byArtist.filter { $0.value.count >= 6 }
            .max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : -a.key < -b.key }?.key
        guard let artistId, let songs = byArtist[artistId] else { return nil }
        let name = songs.sorted { $0.songId < $1.songId }.first!.artist
        let how = played != nil ? "The artist you play most, every song of theirs you have" : "The artist with the most songs in your library"
        let ranked = songs.map { ($0.songId, Float(profile.history($0.songId).plays)) }
        guard var mix = SmartMixEngine.finish(profile, .spotlight, ranked, minimum: 6, description: how, perArtist: .max, perAlbum: .max)
        else { return nil }
        mix.title = "Spotlight: \(name)"
        return mix
    }

    /// Songs whose year tag says they are ten years old or more (placeholder and implausible years ignored).
    static func throwbacks(_ profile: ListeningProfile, calendar: Calendar = .current) -> SmartMix? {
        let thisYear = calendar.component(.year, from: Date(timeIntervalSince1970: Double(profile.now) / 1000))
        let ranked = profile.tracks.values.filter { track in
            guard let year = track.year else { return false }
            return year >= 1950 && year != 1970 && year <= thisYear - 10
        }.map { ($0.songId, profile.artist($0) + Float(min(profile.history($0.songId).plays, 1))) }
        return SmartMixEngine.finish(profile, .throwbacks, ranked, minimum: 8, description: "Songs from ten or more years ago, by their year tags")
    }

    static func quickHits(_ profile: ListeningProfile) -> SmartMix? {
        byLength(profile, .quickHits, 60_000...160_000, "Short songs from your library, all under 2:40")
    }

    static func longListens(_ profile: ListeningProfile) -> SmartMix? {
        byLength(profile, .longListens, 300_000...1_200_000, "Songs from your library that run five minutes or more")
    }

    private static func byLength(_ profile: ListeningProfile, _ kind: MixKind, _ range: ClosedRange<Int64>, _ how: String) -> SmartMix? {
        let ranked = profile.tracks.values.filter { range.contains($0.durationMs) }.map { ($0.songId, profile.artist($0)) }
        return SmartMixEngine.finish(profile, kind, ranked, minimum: 8, description: how)
    }

    /// Songs never played, liked artists first, newest next. Only once there is real history.
    static func yetToHear(_ profile: ListeningProfile) -> SmartMix? {
        let totalPlays = profile.songs.values.reduce(0) { $0 + $1.plays }
        if totalPlays < ListeningProfile.minTotalPlays { return nil }
        let newestAdded = profile.tracks.values.map(\.addedAt).max() ?? 0
        let newest = newestAdded > 0 ? newestAdded : 1
        let ranked = profile.tracks.values.filter { profile.history($0.songId).plays == 0 }
            .map { ($0.songId, 2 * profile.artist($0) + Float($0.addedAt) / Float(newest)) }
        return SmartMixEngine.finish(profile, .yetToHear, ranked, minimum: 8, description: "Songs in your library you haven't played yet")
    }
}
