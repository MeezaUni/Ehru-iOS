import Foundation

/// A tag a metadata fix can change.
enum FixField: String, CaseIterable, Sendable {
    case title, artist, album, year, genre, artwork, bpm
}

/// The fields offered in Fix Tags. Artwork is managed by the Artwork Fetcher, as on Android.
enum MetadataField: String, CaseIterable, Identifiable, Sendable {
    case title = "TITLE"
    case artist = "ARTIST"
    case album = "ALBUM"
    case year = "YEAR"
    case genre = "GENRE"
    case bpm = "BPM"
    case filename = "FILENAME"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .year: "Year"
        case .genre: "Genre"
        case .bpm: "BPM"
        case .filename: "Filename"
        }
    }

    /// Selecting all of these is "All fields" (fill missing values only). BPM is left out so that
    /// switching it on or off never changes whether the other fields are filled or replaced.
    static let fillOnlyTags: Set<MetadataField> = [.title, .artist, .album, .year, .genre]
    static let all = Set(allCases)
}

/// The tag fields a selection may change, whether it is "All fields" (fill missing values only),
/// and whether the file is renamed after its title.
struct FieldSelection: Equatable, Sendable {
    let fields: Set<FixField>
    let fillOnly: Bool
    let rename: Bool

    init(_ selected: Set<MetadataField>) {
        var fields = Set<FixField>()
        for field in selected {
            switch field {
            case .title: fields.insert(.title)
            case .artist: fields.insert(.artist)
            case .album: fields.insert(.album)
            case .year: fields.insert(.year)
            case .genre: fields.insert(.genre)
            case .bpm: fields.insert(.bpm)
            case .filename: break
            }
        }
        self.fields = fields
        fillOnly = selected.isSuperset(of: MetadataField.fillOnlyTags)
        rename = selected.contains(.filename)
    }
}

/// What the file has now. [tagsReadable] is false when the embedded tags could not be read: then
/// year, genre and artwork are unknown and "All fields" never fills them (it could overwrite).
struct LocalTrackTags: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var genre: String?
    var hasArtwork = false
    var tagsReadable = true
    var year: String?
    /// False for tag formats that need a day with a month (never the case for what this app writes).
    var canStoreYearMonth = true
    /// The file's BPM tag as stored ("128"), if any.
    var bpm: String?
}

/// A tempo found for a track: [estimated] values never replace a BPM the file already has.
struct FoundBpm: Equatable, Sendable {
    let bpm: Int
    let source: String
    let estimated: Bool
}

/// A planned fix: [request] is nil when nothing should be written; [notes] say why a field was
/// left alone; [unfilled] are the reasons a selected field the file needs could not be found.
struct FieldFixPlan: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        let field: FixField
        let oldValue: String?
        let newValue: String
    }

    var request: TagWriteRequest?
    var changes: [Change]
    var notes: [String]
    var unfilled: [String] = []
}

/// Turns a confident match into the tag edit for a field selection, and nothing more (a port of
/// Android's planFieldFix):
/// - only the selected fields are considered, and a missing or placeholder value is never written;
/// - an artist credit that already contains the match's artist (e.g. with "feat.") is kept;
/// - "All fields" replaces the title (unless it differs only in case or punctuation) but fills
///   artist, album, genre and year only where the file has none, so the library's grouping is never
///   changed; single fields replace;
/// - a found BPM only fills a missing one: an estimate never replaces a BPM the file has.
enum FieldFixPlanner {

    static func plan(fields: Set<FixField>, fillOnly: Bool, local: LocalTrackTags, match: MetadataCandidate,
                     genre: String?, artwork: Data?, releaseDate: ReleaseDate?, bpm: FoundBpm?) -> FieldFixPlan {
        // The file's "(feat. …)" note is kept when the online title has none.
        let matchTitle = withLocalFeaturing(match.title, local: local.title)
        var changes: [FieldFixPlan.Change] = []
        var notes: [String] = []

        func text(_ field: FixField, _ label: String, current: String, found: String?, keepValidLocal: Bool) -> String? {
            guard fields.contains(field) else { return nil }
            guard let value = found?.trimmed, isUsableTag(value) else {
                notes.append("No \(label) found online")
                return nil
            }
            if value == current.trimmed { return nil }
            if keepValidLocal && isUsableTag(current) {
                notes.append("Kept the existing \(label) \"\(current.trimmed)\"")
                return nil
            }
            changes.append(.init(field: field, oldValue: isUsableTag(current) ? current : nil, newValue: value))
            return value
        }

        let sameTitleSpelling = isUsableTag(local.title) && foldForMatch(local.title) == foldForMatch(matchTitle)
        var title: String?
        if fillOnly && fields.contains(.title) && sameTitleSpelling {
            // Same title apart from case or punctuation: the file's spelling stays.
            if local.title.trimmed != matchTitle.trimmed { notes.append("Kept the existing title \"\(local.title.trimmed)\"") }
        } else {
            title = text(.title, "title", current: local.title, found: matchTitle, keepValidLocal: false)
        }
        var artist: String?
        if fields.contains(.artist) && isUsableTag(local.artist) && creditContains(local.artist, match.artist) {
            if local.artist.trimmed.lowercased() != match.artist.trimmed.lowercased() {
                notes.append("Kept the existing artist credit \"\(local.artist.trimmed)\"")
            }
        } else {
            artist = text(.artist, "artist", current: local.artist, found: match.artist, keepValidLocal: fillOnly)
        }
        let album = text(.album, "album", current: local.album, found: match.album, keepValidLocal: fillOnly)
        let year = fields.contains(.year) ? planYear(local, releaseDate, fillOnly, &changes, &notes) : nil
        var newGenre: String?
        if fields.contains(.genre) {
            if fillOnly && !local.tagsReadable {
                notes.append("Genre not filled: the file's tags couldn't be read")
            } else {
                newGenre = planGenres(local.genre, genre, fillOnly, &changes, &notes)
            }
        }
        let newBpm = fields.contains(.bpm) ? planBpm(local, bpm, fillOnly, &changes, &notes) : nil
        var newArtwork: Data?
        if fields.contains(.artwork) {
            if artwork == nil || artwork!.isEmpty {
                notes.append("No artwork found online")
            } else if fillOnly && (local.hasArtwork || !local.tagsReadable) {
                notes.append("Kept the existing artwork")
            } else {
                newArtwork = artwork
                changes.append(.init(field: .artwork, oldValue: local.hasArtwork ? "embedded" : nil, newValue: "from \(match.sourceName)"))
            }
        }
        var request = TagWriteRequest()
        request.title = title
        request.artist = artist
        request.album = album
        request.releaseDate = year
        request.genre = newGenre
        request.bpm = newBpm
        request.artwork = newArtwork
        return FieldFixPlan(request: request.hasChanges ? request : nil, changes: changes, notes: notes)
    }

    /// The genres to write (stored form), or nil. Compared as genre lists, so "Rock; Pop" and "rock;pop" are the same.
    private static func planGenres(_ current: String?, _ found: String?, _ fillOnly: Bool,
                                   _ changes: inout [FieldFixPlan.Change], _ notes: inout [String]) -> String? {
        let genres = Genres.join(Genres.parse(found))
        let existing = Genres.join(Genres.parse(current))
        guard let genres else {
            notes.append("No genre found online")
            return nil
        }
        if Genres.same(existing, genres) { return nil }
        if fillOnly, let existing {
            notes.append("Kept the existing genre \"\(existing)\"")
            return nil
        }
        changes.append(.init(field: .genre, oldValue: existing, newValue: genres))
        return genres
    }

    private static func planBpm(_ local: LocalTrackTags, _ found: FoundBpm?, _ fillOnly: Bool,
                                _ changes: inout [FieldFixPlan.Change], _ notes: inout [String]) -> Int? {
        let current = usableBpm(local.bpm)
        guard let found else {
            notes.append("No BPM found")
            return nil
        }
        if !plausibleBpm.contains(found.bpm) {
            notes.append("BPM \(found.bpm) from \(found.source) is not a plausible tempo")
            return nil
        }
        if fillOnly && !local.tagsReadable {
            notes.append("BPM not filled: the file's tags couldn't be read")
            return nil
        }
        if current == found.bpm { return nil }
        if let current, fillOnly {
            notes.append("Kept the existing BPM \(current)")
            return nil
        }
        if let current, found.estimated {
            notes.append("Kept the existing BPM \(current): an estimate (\(found.bpm), \(found.source)) doesn't replace it")
            return nil
        }
        changes.append(.init(field: .bpm, oldValue: current.map(String.init), newValue: "\(found.bpm) (\(found.source))"))
        return found.bpm
    }

    /// The date tag value to write, or nil. The date keeps its precision unless the file's tag format
    /// can't hold it.
    private static func planYear(_ local: LocalTrackTags, _ found: ReleaseDate?, _ fillOnly: Bool,
                                 _ changes: inout [FieldFixPlan.Change], _ notes: inout [String]) -> String? {
        let current = local.year?.trimmed ?? ""
        var date: ReleaseDate?
        if found == nil {
            notes.append("No release year found online")
        } else if fillOnly && !local.tagsReadable {
            notes.append("Year not filled: the file's tags couldn't be read")
        } else if fillOnly && isUsableYearTag(current) {
            if !current.hasPrefix(String(found!.year)) { notes.append("Kept the existing year \"\(current)\"") }
        } else if current.count > found!.tagValue.count && current.hasPrefix(found!.tagValue) {
            notes.append("Kept the existing, more precise date \"\(current)\"")
        } else if found!.hasMonthOnly && !local.canStoreYearMonth {
            date = found!.yearOnly()
            notes.append("Saved the year only: this file's tag format can't store a month without a day")
        } else {
            date = found
        }
        guard let date, date.tagValue != current else { return nil }
        changes.append(.init(field: .year, oldValue: current.isEmpty ? nil : current, newValue: date.tagValue))
        return date.tagValue
    }

    /// True when [credit] already names [artist] as a whole word sequence, e.g. "A feat. B" contains "A".
    static func creditContains(_ credit: String, _ artist: String) -> Bool {
        let split = Regex16("[^\\p{L}\\p{N}$]+")
        func words(_ text: String) -> [String] { split.split(text.lowercased()).filter { !$0.isEmpty } }
        let c = words(credit)
        let a = words(artist)
        guard !a.isEmpty, a.count <= c.count else { return false }
        return (0...(c.count - a.count)).contains { Array(c[$0..<($0 + a.count)]) == a }
    }

    private static let featuringPart = Regex16("(?i)\\s*[(\\[]\\s*(?:feat\\.?|ft\\.?|featuring|with)\\s[^)\\]]+[)\\]]")

    /// [online] with [local]'s featured-artist note added when only the file has one.
    static func withLocalFeaturing(_ online: String, local: String) -> String {
        guard let match = featuringPart.firstMatch(in: local), !featuringPart.containsMatch(in: online) else { return online }
        let note = (local as NSString).substring(with: match.range).trimmed
        return "\(online.trimmed) \(note)"
    }
}
