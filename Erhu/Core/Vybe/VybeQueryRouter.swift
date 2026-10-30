import Foundation

/// What a name in a query was found as in the library.
enum EntityKind: Sendable { case artist, album, title }

/// How VYBE answers a query.
enum VybeRoute: Equatable, Sendable {
    /// The query names a library artist, album or title: [songIds] are the songs it names, found
    /// exactly from metadata. [wantsSimilar] is true for "like …" queries.
    case named(kind: EntityKind, name: String, songIds: [Int64], wantsSimilar: Bool)
    /// A "like …" / "from …" query whose name matches nothing in the library.
    case unknownName(name: String, query: String)
    /// Not about a name: a mood / activity description for semantic search.
    case describe(query: String)
}

/// Sends explicit artist / album / title queries to exact metadata matching instead of embeddings.
/// Names are compared as word sequences, so "Tyler, the Creator" finds the credit "Tyler/ The
/// Creator", and an artist inside a credit ("A feat. B") counts. No similarity is inferred.
enum VybeQueryRouter {
    private static let patterns: [(Regex16, Bool)] = [
        (Regex16(#"^(?:play\s+)?(?:some\s+)?(?:songs?|music|tracks?|stuff|albums?)\s+(?:like|similar to)\s+(.+)$"#), true),
        (Regex16(#"^(?:more\s+)?(?:like|similar to)\s+(.+)$"#), true),
        (Regex16(#"^(?:play\s+)?(?:more\s+)?(?:songs?|music|tracks?)?\s*(?:from|by)\s+(.+)$"#), false),
    ]
    private static let nonWord = Regex16(#"[^\p{L}\p{N}$]+"#)
    /// Names shorter than this (in letters and digits) are too ambiguous to match inside credits.
    private static let minNameChars = 3

    static func route(_ query: String, songs: [SongText]) -> VybeRoute {
        let original = query.trimmed
        let text = original.lowercased()
        var found: (String, Bool)?
        for (regex, similar) in patterns {
            guard let match = regex.firstMatch(in: text) else { continue }
            // The name as the user typed it ("Drake", not "drake"), when lower-casing kept the length.
            let range = match.range(at: 1)
            let typed = original.utf16Length == text.utf16Length
                ? (original as NSString).substring(with: range) : match.group(1, in: text)
            found = (typed.trimmed, similar)
            break
        }
        guard let (name, wantsSimilar) = found else { return .describe(query: original) }
        let nameWords = words(name)
        if nameWords.joined().utf16Length < minNameChars { return .unknownName(name: name, query: original) }

        let byArtist = songs.filter { containsSequence(words($0.artist), nameWords) }
        let byAlbum = songs.filter { words($0.album) == nameWords }
        let byTitle = songs.filter { words($0.title) == nameWords }
        // Artist wins, then album, then title.
        if !byArtist.isEmpty { return .named(kind: .artist, name: name, songIds: ids(byArtist), wantsSimilar: wantsSimilar) }
        if !byAlbum.isEmpty { return .named(kind: .album, name: name, songIds: ids(byAlbum), wantsSimilar: wantsSimilar) }
        if !byTitle.isEmpty { return .named(kind: .title, name: name, songIds: ids(byTitle), wantsSimilar: wantsSimilar) }
        return .unknownName(name: name, query: original)
    }

    private static func ids(_ songs: [SongText]) -> [Int64] { songs.map(\.songId).sorted() }

    private static func words(_ text: String) -> [String] { nonWord.split(text.lowercased()).filter { !$0.isEmpty } }
}

/// The needle's words appear in order, back to back, somewhere in the haystack.
func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return false }
    return (0...(haystack.count - needle.count)).contains { start in Array(haystack[start..<(start + needle.count)]) == needle }
}
