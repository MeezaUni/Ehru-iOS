import Foundation

// Text handling for searching and matching tracks, from what MusicBrainz actually does with
// queries: a featured-artist note in a title makes a phrase search miss, and a multi-artist credit
// flattened by a downloader ("Tyler/ The Creator/Frank Ocean/ Steve Lacy") never matches as a
// phrase while its words do.

private let featuringNote = Regex16("\\s*[(\\[]\\s*(?:feat\\.?|ft\\.?|featuring)\\s[^)\\]]*[)\\]]?", ignoreCase: true)
private let trailingFeaturing = Regex16("\\s+(?:feat\\.?|ft\\.?|featuring)\\s.*$", ignoreCase: true)

/// [title] without its featured-artist note: "911 / Mr. Lonely (feat. Frank Ocean & Steve Lacy)" -> "911 / Mr. Lonely".
func stripFeaturing(_ title: String) -> String {
    trailingFeaturing.replacing(in: featuringNote.replacing(in: title, with: ""), with: "").trimmed
}

/// Words that join names in a credit rather than being part of one.
private let creditConnectors: Set<String> = ["feat", "ft", "featuring", "and", "with", "x", "vs"]

/// The words of an artist credit, joiners dropped.
func creditWords(_ credit: String) -> Set<String> {
    Set(foldForMatch(credit).split(separator: " ").map(String.init).filter { !$0.isEmpty && !creditConnectors.contains($0) })
}

/// How alike two artist credits are by the names they contain, ignoring how they are joined
/// (Jaccard similarity of the words).
func creditSimilarity(_ a: String, _ b: String) -> Float {
    let x = creditWords(a)
    let y = creditWords(b)
    if x.isEmpty || y.isEmpty { return 0 }
    return Float(x.intersection(y).count) / Float(x.union(y).count)
}

/// The parts of a two-sided title: "911 / Mr. Lonely" -> ["911", "Mr. Lonely"].
func titleSides(_ title: String) -> [String] {
    title.components(separatedBy: " / ").map(\.trimmed).filter { !$0.isEmpty }
}

private let specialMix = Regex16("\\b(dolby atmos|atmos|spatial audio|360 reality audio|binaural|surround)\\b", ignoreCase: true)

/// Marks of a special mix of the same recording: not wrong, but not the plain version a file usually holds.
func isSpecialMix(_ text: String?) -> Bool {
    guard let text else { return false }
    return specialMix.containsMatch(in: text)
}

/// An artist credit as search words for MusicBrainz's `artist:(…)`: no joiners, no punctuation.
func artistSearchTerms(_ credit: String?) -> String? {
    guard let credit else { return nil }
    // In the credit's own word order, each word once.
    var words: [String] = []
    for word in foldForMatch(credit).split(separator: " ").map(String.init) where !creditConnectors.contains(word) && !words.contains(word) {
        words.append(word)
    }
    return words.isEmpty ? nil : words.joined(separator: " ")
}

/// [text] safe inside a quoted Lucene phrase (MusicBrainz search syntax).
func escapePhrase(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

private let accents = Regex16("\\p{Mn}+")
private let apostrophes = Regex16("['‘’ʼ`´]")
private let notWord = Regex16("[^\\p{L}\\p{N}]+")
private let featuringCredit = Regex16("\\s+(?:feat\\.?|ft\\.?|featuring)\\s+.*$", ignoreCase: true)

/// Lowercase, accents and apostrophes removed, every other separator a single space.
func foldForMatch(_ text: String) -> String {
    let decomposed = accents.replacing(in: text.decomposedStringWithCompatibilityMapping, with: "").lowercased()
    return notWord.replacing(in: apostrophes.replacing(in: decomposed, with: ""), with: " ").trimmed
}

/// The credit without its "feat." part: "Kanye West feat. Pusha T" -> "Kanye West".
func primaryArtist(_ credit: String) -> String {
    featuringCredit.replacing(in: credit, with: "").trimmed
}

/// Scores a candidate against what is known about the local track (a port of Android's MetadataScorer).
enum MetadataScorer {
    /// Applied when version markers differ; keeps even a perfect name match below the uncertain threshold.
    static let versionMismatchFactor: Float = 0.5
    /// Enough to rank a special mix below the plain recording when everything else is equal.
    static let specialMixFactor: Float = 0.95
    /// "Mr. Lonely" for "911 / Mr. Lonely": strong, but below an exact title.
    static let oneSideOfTitle: Float = 0.95

    static func score(_ candidate: MetadataCandidate, title targetTitle: String, artist targetArtist: String?,
                      album targetAlbum: String? = nil, durationMs targetDurationMs: Int64? = nil) -> MetadataCandidate {
        let titleSim = titleSimilarity(candidate.title, targetTitle)
        var artistSim: Float?
        if let targetArtist, !targetArtist.isBlank, targetArtist.lowercased() != "unknown artist",
           !candidate.artist.isBlank, candidate.artist.lowercased() != "unknown artist" {
            // "A feat. B" against "A": the credited artist is the same; and the same names joined
            // differently ("A/ B/C" against "A ft. B & C") are the same credit.
            artistSim = max(textSimilarity(candidate.artist, targetArtist),
                            textSimilarity(primaryArtist(candidate.artist), primaryArtist(targetArtist)),
                            creditSimilarity(candidate.artist, targetArtist))
        }
        var albumSim: Float?
        if let targetAlbum, !targetAlbum.isBlank, targetAlbum.lowercased() != "unknown album",
           !candidate.album.isBlank, candidate.album.lowercased() != "unknown album" {
            albumSim = textSimilarity(candidate.album, targetAlbum)
        }
        var total: Float
        switch (artistSim, albumSim) {
        case let (artist?, album?): total = titleSim * 0.5 + artist * 0.3 + album * 0.2
        case let (artist?, nil): total = titleSim * 0.625 + artist * 0.375
        case let (nil, album?): total = titleSim * 0.714 + album * 0.286
        case (nil, nil):
            // Without artist or album confirmation an unverified title match stays below 0.85.
            total = titleSim >= 1 ? 0.80 : titleSim * 0.80
        }
        if let targetDurationMs, targetDurationMs > 0, let duration = candidate.durationMs, duration > 0 {
            let deltaSeconds = abs(targetDurationMs - duration) / 1000
            if deltaSeconds > 30 { total *= 0.7 } else if deltaSeconds > 15 { total *= 0.9 }
        }
        // A live / remix / acoustic … recording is a different version, however similar the names.
        let candidateVersion = LyricsMatcher.strictTagsIn("\(candidate.title) \(candidate.versionNote ?? "")")
        if candidateVersion != LyricsMatcher.strictTagsIn(targetTitle) { total *= versionMismatchFactor }
        // A Dolby Atmos / spatial mix of the same song ranks just below the plain recording.
        if (isSpecialMix(candidate.title) || isSpecialMix(candidate.versionNote)) && !isSpecialMix(targetTitle) {
            total *= specialMixFactor
        }
        var scored = candidate
        scored.confidenceScore = total.clamped(0, 1)
        return scored
    }

    /// Title similarity that doesn't penalise a featured-artist note on one side only, and accepts
    /// one side of a two-sided title as a near match.
    static func titleSimilarity(_ candidate: String, _ target: String) -> Float {
        let plainCandidate = stripFeaturing(candidate)
        let plainTarget = stripFeaturing(target)
        let sides = titleSides(plainCandidate).map(foldForMatch)
        let oneSide: Float = sides.count > 1 && sides.contains(foldForMatch(plainTarget)) ? oneSideOfTitle : 0
        return max(textSimilarity(candidate, target), textSimilarity(plainCandidate, plainTarget), oneSide)
    }

    /// Similarity that ignores spelling noise (case, accents, typographic quotes, separators); the
    /// plain comparison is kept as a floor.
    static func textSimilarity(_ a: String, _ b: String) -> Float {
        max(jaroWinkler(a.lowercased().trimmed, b.lowercased().trimmed), jaroWinkler(foldForMatch(a), foldForMatch(b)))
    }

    /// Jaro-Winkler similarity over UTF-16 code units (as Kotlin strings index them).
    static func jaroWinkler(_ first: String, _ second: String) -> Float {
        if first == second { return 1 }
        let s1 = Array(first.utf16)
        let s2 = Array(second.utf16)
        if s1.isEmpty || s2.isEmpty { return 0 }
        let matchDistance = max(s1.count, s2.count) / 2 - 1
        var s1Matches = [Bool](repeating: false, count: s1.count)
        var s2Matches = [Bool](repeating: false, count: s2.count)
        var matches = 0
        for i in s1.indices {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, s2.count)
            guard start < end else { continue }
            for j in start..<end where !s2Matches[j] && s1[i] == s2[j] {
                s1Matches[i] = true
                s2Matches[j] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0 }
        var transpositions = 0
        var k = 0
        for i in s1.indices where s1Matches[i] {
            while !s2Matches[k] { k += 1 }
            if s1[i] != s2[k] { transpositions += 1 }
            k += 1
        }
        let m = Float(matches)
        let jaro = (m / Float(s1.count) + m / Float(s2.count) + (m - Float(transpositions) / 2) / m) / 3
        var prefix = 0
        for i in 0..<min(4, min(s1.count, s2.count)) {
            if s1[i] == s2[i] { prefix += 1 } else { break }
        }
        return jaro + Float(prefix) * 0.1 * (1 - jaro)
    }
}
