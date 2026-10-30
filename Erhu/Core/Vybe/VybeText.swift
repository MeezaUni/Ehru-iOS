import Foundation

/// The text VYBE knows about a song, taken from the library as it is (no fetching): blank or
/// unknown fields are left out of its description. [genre] is the stored value: one genre or
/// several ("Electronic; Synth-pop; Alternative", see [Genres]).
struct SongText: Equatable, Sendable {
    let songId: Int64
    let title: String
    let artist: String
    let album: String
    var genre: String? = nil
    var year: Int = 0
    /// Lyrics already stored for the song (embedded tags), if any; only an excerpt is used.
    var lyrics: String? = nil
    /// The library's BPM (the file's tag), if it has a plausible one.
    var bpm: Int? = nil

    /// Each genre on its own: "Electronic; Synth-pop" is two genres, not one.
    var genres: [String] { Genres.parse(genre) }
}

/// Builds the one-paragraph description of a song. Pure and deterministic. The album name is left
/// out on purpose: its words dominated mood queries ("late night music" found *Late Registration*).
enum SongDescriber {
    /// Lyrics beyond this many characters are cut (at a word boundary).
    static let lyricsExcerptChars = 240

    /// LRC line / word timestamps and `[tag:value]` lines: timing, not words.
    private static let lrcMarkup = Regex16(#"\[[^\]]*]|<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)
    /// Java's `\s`: ASCII whitespace only.
    private static let whitespace = Regex16(#"[ \t\n\x0B\f\r]+"#)
    private static let unknown: Set<String> = ["<unknown>", "unknown", "unknown artist", "unknown album"]

    static func describe(_ song: SongText) -> String {
        [
            field("Title", song.title),
            field("Artist", song.artist),
            genreField(song.genres),
            (1900...2100).contains(song.year) ? "Year: \(song.year)" : nil,
            song.bpm.flatMap { (20...400).contains($0) ? "Tempo: \($0) BPM" : nil },
            lyricsExcerpt(song.lyrics).map { "Lyrics: \($0)" },
        ].compactMap { $0 }.joined(separator: ". ")
    }

    /// The first words of the lyrics, timestamps removed, on one line; nil when there are none.
    static func lyricsExcerpt(_ lyrics: String?) -> String? {
        guard let lyrics else { return nil }
        let words = whitespace.replacing(in: lrcMarkup.replacing(in: lyrics, with: " "), with: " ").trimmed
        if words.isEmpty { return nil }
        if words.utf16Length <= lyricsExcerptChars { return words }
        let units = Array(words.utf16)
        var cut = -1
        for i in stride(from: min(lyricsExcerptChars, units.count - 1), through: 0, by: -1) where units[i] == 0x20 {
            cut = i
            break
        }
        return words.substring16(0, cut > 0 ? cut : lyricsExcerptChars)
    }

    /// "Genre: Hip-Hop", or "Genres: Electronic, Synth-pop, Alternative" for several.
    private static func genreField(_ genres: [String]) -> String? {
        let known = genres.filter { !unknown.contains($0.lowercased()) }
        if known.isEmpty { return nil }
        return (known.count == 1 ? "Genre: " : "Genres: ") + known.joined(separator: ", ")
    }

    private static func field(_ label: String, _ value: String?) -> String? {
        guard let value = value?.trimmed, !value.isEmpty, !unknown.contains(value.lowercased()) else { return nil }
        return "\(label): \(value)"
    }
}

/// What VYBE embeds for a song in discovery, and how a library row becomes a [SongText].
enum VybeText {
    /// A BPM tag outside this is junk, not a tempo.
    static let plausibleBpm = 20...400
    /// Bumped whenever [describe] changes, so the index re-embeds every song.
    static let documentVersion = 1

    private static let nothingKnown = "A song with no artist, genre or tempo information"
    private static let unknown: Set<String> = ["<unknown>", "unknown", "unknown artist"]

    /// Artist, every genre, tempo and a short lyrics excerpt: whatever is known. Titles and album
    /// names are left out: their words matched mood queries by accident.
    static func describe(_ song: SongText) -> String {
        let genres = song.genres
        let parts: [String?] = [
            !song.artist.isBlank && !unknown.contains(song.artist.lowercased()) ? "Artist: \(song.artist.trimmed)" : nil,
            genres.isEmpty ? nil : (genres.count == 1 ? "Genre: " : "Genres: ") + genres.joined(separator: ", "),
            song.bpm.flatMap { plausibleBpm.contains($0) ? "Tempo: \($0) BPM" : nil },
            SongDescriber.lyricsExcerpt(song.lyrics).map { "Lyrics: \($0)" },
        ]
        let text = parts.compactMap { $0 }.joined(separator: ". ")
        return text.isEmpty ? nothingKnown : text
    }

    static func fromTags(_ tags: SongTags) -> SongText {
        SongText(songId: tags.songId, title: tags.title, artist: tags.artist, album: tags.album, genre: tags.genre,
                 year: tags.year, lyrics: tags.lyricsExcerpt, bpm: tags.bpm)
    }
}

/// A stable 64-bit hash of a description (FNV-1a over UTF-16 units): changes whenever the text does.
func textHash(_ text: String) -> Int64 { IdentityHash.of(text) }
