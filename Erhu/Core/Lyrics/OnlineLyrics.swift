import Foundation

/// The track to find lyrics for: only this metadata ever leaves the device.
struct LyricsQuery: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    /// 0 when unknown.
    var durationMs: Int64 = 0
}

/// How well a result is timed; higher is better.
enum LyricsTiming: Int, Comparable, Sendable {
    case none, plain, line, word

    static func < (a: LyricsTiming, b: LyricsTiming) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .word: "word-synced"
        case .line: "line-synced"
        case .plain: "plain text"
        case .none: "no text"
        }
    }
}

/// One online result, as the provider describes it. [wordSyncedLrc] is enhanced LRC built from the
/// provider's genuine word timing (nil without it); [syncedLyrics] is line-timed LRC.
struct LyricsCandidate: Codable, Equatable, Sendable, Identifiable {
    var provider: String
    var providerId: Int64
    var trackName: String
    var artistName: String
    var albumName: String?
    /// Seconds; nil when unknown.
    var durationSec: Double?
    var instrumental = false
    var plainLyrics: String?
    var syncedLyrics: String?
    var wordSyncedLrc: String?

    var id: String { "\(provider):\(providerId)" }

    private var usableTexts: [(text: String, timing: LyricsTiming)] {
        [wordSyncedLrc, syncedLyrics, plainLyrics].compactMap { text in
            guard let text = text?.nonBlank, let parsed = LyricsParser.parse(text) else { return nil }
            switch parsed {
            case .plain: return (text, .plain)
            case .synced: return (text, parsed.hasWordTiming ? .word : .line)
            }
        }
    }

    var timing: LyricsTiming { usableTexts.map { $0.timing }.max() ?? .none }

    /// Rank the text's real timestamps, not just the API field it arrived in. Never label a
    /// malformed or plain string synchronized simply because it was called syncedLyrics.
    var bestText: String? {
        var best: (text: String, timing: LyricsTiming)?
        for item in usableTexts where best == nil || item.timing > best!.timing { best = item }
        return best?.text
    }

}

/// What a provider answered for one request.
enum ProviderResponse<T: Sendable>: Sendable {
    case success(T)
    /// The provider has nothing for this request.
    case notFound
    /// Rate limited: no request until [retryAtMs] (wall clock).
    case rateLimited(retryAtMs: Int64)
    /// No connection.
    case offline
    case failed(String)
}

/// A legitimate online lyrics source; the repository asks them in order.
protocol OnlineLyricsProvider: Sendable {
    var name: String { get }
    var supportsSyncedLyrics: Bool { get }
    /// The provider's best record for exactly this track (title, artist, album, duration).
    func exact(_ query: LyricsQuery) async -> ProviderResponse<LyricsCandidate>
    /// Records that may match [query]; [freeText] searches by text instead (manual search).
    func search(_ query: LyricsQuery, freeText: String?) async -> ProviderResponse<[LyricsCandidate]>
}

extension OnlineLyricsProvider {
    var supportsSyncedLyrics: Bool { true }
}

/// A manual search can offer real plain-text options while clearly reporting that synchronized
/// availability could not be checked. It does not turn an outage into a missing-lyrics claim.
struct LyricsSearchResults: Equatable, Sendable {
    var candidates: [LyricsCandidate]
    var syncedServiceNotice: String?
}

/// How a result compares to the track. [rejected] results are a different recording.
struct MatchScore: Equatable {
    let score: Double
    let confident: Bool
    let rejected: Bool
    var reason: String?
}

/// Decides whether an online result is the lyrics of this track. Harmless differences are ignored
/// (case, accents, punctuation, "feat." credits, "Remastered" notes, "&" vs "and"); version markers
/// that change the recording (live, remix, acoustic, cover, sped up…) must agree, and a duration
/// more than 10 s away is a different recording. Only a confident match is used automatically.
enum LyricsMatcher {
    private static let strictTags: [(String, Regex16)] = [
        ("live", Regex16(#"\blive\b"#)),
        ("remix", Regex16(#"\b(remix|rmx|bootleg|edit mix)\b"#)),
        ("acoustic", Regex16(#"\b(acoustic|unplugged)\b"#)),
        ("instrumental", Regex16(#"\binstrumental\b"#)),
        ("karaoke", Regex16(#"\bkaraoke\b"#)),
        ("cover", Regex16(#"\bcover\b"#)),
        ("demo", Regex16(#"\bdemo\b"#)),
        ("sped up", Regex16(#"\b(sped up|speed up|nightcore)\b"#)),
        ("slowed", Regex16(#"\b(slowed|reverb)\b"#)),
        ("reprise", Regex16(#"\breprise\b"#)),
    ]
    private static let softTags: [(String, Regex16)] = [
        ("clean", Regex16(#"\b(clean|radio edit|censored)\b"#)),
        ("explicit", Regex16(#"\bexplicit\b"#)),
        ("extended", Regex16(#"\bextended\b"#)),
    ]
    private static let bracketed = Regex16(#"[(\[][^)\]]*[)\]]"#)
    private static let dashSuffix = Regex16(#"\s+-\s+.*$"#)
    private static let featuring = Regex16(#"\b(feat|ft|featuring)\b.*$"#)
    private static let artistSplit = Regex16(#"\s*(,|&|;|/|\bfeat\.?|\bft\.?|\bfeaturing\b|\band\b|\bx\b)\s*"#)
    private static let nonWord = Regex16(#"[^\p{L}\p{N}]+"#)
    private static let accents = Regex16(#"\p{Mn}+"#)

    static let confidentScore = 0.85
    static let plausibleScore = 0.5
    static let rejectDurationSec = 10.0

    static func score(_ query: LyricsQuery, _ candidate: LyricsCandidate) -> MatchScore {
        let queryTags = tags(query.title, query.album)
        let candidateTags = tags(candidate.trackName, candidate.albumName)
        if let different = strictTags.map(\.0).first(where: { queryTags.contains($0) != candidateTags.contains($0) }) {
            return MatchScore(score: 0, confident: false, rejected: true, reason: "different version (\(different))")
        }
        let queryDuration = query.durationMs > 0 ? Double(query.durationMs) / 1000 : nil
        let durationDiff = queryDuration.flatMap { q in candidate.durationSec.map { abs(q - $0) } }
        if let durationDiff, durationDiff > rejectDurationSec {
            return MatchScore(score: 0, confident: false, rejected: true, reason: "different length")
        }
        let title = textSimilarity(baseTitle(query.title), baseTitle(candidate.trackName))
        let artist = artistSimilarity(query.artist, candidate.artistName)
        let duration = durationScore(durationDiff)
        let album = albumScore(query.album, candidate.albumName)
        let softPenalty = Double(softTags.map(\.0).filter { queryTags.contains($0) != candidateTags.contains($0) }.count) * 0.1
        let raw = 0.45 * title + 0.35 * artist + 0.15 * duration + 0.05 * album - softPenalty
        let total = min(max(raw, 0), 1)
        // Without a known duration, only an exact title and artist are trusted on their own.
        let durationOk = durationDiff == nil ? (title == 1 && artist == 1) : duration >= 0.6
        let confident = total >= confidentScore && title >= 0.8 && artist >= 0.8 && durationOk
        return MatchScore(score: total, confident: confident, rejected: false)
    }

    private static func durationScore(_ diff: Double?) -> Double {
        guard let diff else { return 0.5 }
        if diff <= 2 { return 1 }
        if diff <= 5 { return 0.6 }
        if diff <= 10 { return 0.2 }
        return 0
    }

    private static func albumScore(_ query: String?, _ candidate: String?) -> Double {
        guard let query, let candidate, !query.isBlank, !candidate.isBlank else { return 0.5 }
        return baseTitle(query) == baseTitle(candidate) ? 1 : 0
    }

    /// Version markers found in a title and album, normalised.
    static func tags(_ title: String, _ album: String?) -> Set<String> {
        let text = fold("\(title) \(album ?? "")")
        return Set((strictTags + softTags).filter { $0.1.containsMatch(in: text) }.map(\.0))
    }

    /// Markers of a different recording (live, remix, acoustic, …) found in [text], normalised.
    static func strictTagsIn(_ text: String) -> Set<String> {
        let folded = fold(text)
        return Set(strictTags.filter { $0.1.containsMatch(in: folded) }.map(\.0))
    }

    /// The title without bracketed notes, " - …" suffixes or credits, folded for comparison.
    static func baseTitle(_ title: String) -> String {
        let withoutNotes = dashSuffix.replacing(in: bracketed.replacing(in: title, with: " "), with: "")
        return normalize(featuring.replacing(in: fold(withoutNotes), with: ""))
    }

    private static func artistSimilarity(_ query: String, _ candidate: String) -> Double {
        let a = artists(query)
        let b = artists(candidate)
        if !a.isEmpty && !Set(a).isDisjoint(with: b) { return 1 }
        // A name inside another ("Someone" in "Someone Else") is a different artist: never confident.
        return min(textSimilarity(a.joined(separator: " "), b.joined(separator: " ")), 0.6)
    }

    /// Kotlin's toSet keeps first-seen order; the joined form above relies on it.
    private static func artists(_ text: String) -> [String] {
        var seen: [String] = []
        for part in artistSplit.split(fold(text)) {
            var name = normalize(part)
            if name.hasPrefix("the ") { name.removeFirst(4) }
            if name == "ye" { name = "kanye west" }
            if !name.isEmpty && !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    private static func textSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        if min(a.utf16Length, b.utf16Length) >= 4 && (a.contains(b) || b.contains(a)) { return 0.8 }
        let ta = Set(a.split(separator: " ", omittingEmptySubsequences: false).map(String.init))
        let tb = Set(b.split(separator: " ", omittingEmptySubsequences: false).map(String.init))
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    /// Lower case, no accents, "&" as "and".
    private static func fold(_ text: String) -> String {
        let decomposed = text.lowercased().decomposedStringWithCompatibilityMapping
        return accents.replacing(in: decomposed, with: "").replacingOccurrences(of: "&", with: " and ")
    }

    private static func normalize(_ text: String) -> String { nonWord.replacing(in: text, with: " ").trimmed }

    /// Verified artist alias for lookup/matching only; never rewrites local metadata.
    static func alternativeArtistName(_ artist: String) -> String? {
        switch normalize(fold(artist)) {
        case "ye": return "Kanye West"
        case "kanye west": return "Ye"
        default: return nil
        }
    }

    /// The result to use automatically: among confident matches, word timing first, then line,
    /// then plain; ties by score (the first of equals). Nil when no result is confident.
    static func best(_ query: LyricsQuery, _ candidates: [LyricsCandidate], minimumTiming: LyricsTiming = .none) -> LyricsCandidate? {
        var best: (LyricsCandidate, MatchScore)?
        for candidate in candidates {
            guard candidate.instrumental || (candidate.bestText != nil && candidate.timing >= minimumTiming) else { continue }
            let match = score(query, candidate)
            guard match.confident else { continue }
            if let current = best {
                let better = candidate.timing != current.0.timing ? candidate.timing > current.0.timing : match.score > current.1.score
                if better { best = (candidate, match) }
            } else {
                best = (candidate, match)
            }
        }
        return best?.0
    }

    /// Results worth offering when nothing is confident: not rejected, plausible, best first.
    static func plausible(_ query: LyricsQuery, _ candidates: [LyricsCandidate], limit: Int = 8) -> [LyricsCandidate] {
        let scored = candidates.map { ($0, score(query, $0)) }.filter {
            ($0.0.instrumental || $0.0.bestText != nil) && !$0.1.rejected && $0.1.score >= plausibleScore
        }
        let ordered = scored.enumerated().sorted { a, b in
            a.element.1.score != b.element.1.score ? a.element.1.score > b.element.1.score : a.offset < b.offset
        }
        return ordered.prefix(limit).map(\.element.0)
    }
}

/// LRCLIB's Lyricsfile: YAML with `lines` (`text`, `start_ms`, `end_ms`) and, for word-synced
/// lyrics, `words` per line (`text`, `start_ms`). Converted to enhanced LRC so genuine word timing
/// reaches the karaoke highlight unchanged. A line whose words are not all timed (in order) keeps
/// only its line time; nothing is estimated.
enum Lyricsfile {
    /// Enhanced LRC with the file's word timing, or nil when it has none (or cannot be read).
    static func toEnhancedLrc(_ yaml: String?) -> String? {
        guard let document = load(yaml) else { return nil }
        let lines = (document["lines"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let written = lines.compactMap(lineToLrc)
        if !written.contains(where: \.timedWords) { return nil }
        var header: [String] = []
        if let offset = number((document["metadata"] as? [String: Any])?["offset_ms"]), offset != 0 { header.append("[offset:\(offset)]") }
        return (header + written.map(\.text)).joined(separator: "\n")
    }

    /// Whether the Lyricsfile says the track is instrumental.
    static func isInstrumental(_ yaml: String?) -> Bool {
        ((load(yaml)?["metadata"] as? [String: Any])?["instrumental"] as? Bool) == true
    }

    private static func lineToLrc(_ line: [String: Any]) -> (text: String, timedWords: Bool)? {
        guard let start = number(line["start_ms"]) else { return nil }
        let words = (line["words"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let pairs = words.map { (number($0["start_ms"]), text($0["text"]) ?? "") }
        if !pairs.isEmpty, pairs.allSatisfy({ $0.0 != nil }) {
            let timed = pairs.map { ($0.0!, $0.1) }
            if zip(timed, timed.dropFirst()).allSatisfy({ $0.0 <= $1.0 }) {
                return ("[\(stamp(start))]" + timed.map { "<\(stamp($0.0))>\($0.1)" }.joined(), true)
            }
        }
        let content = text(line["text"]) ?? words.map { text($0["text"]) ?? "" }.joined()
        return ("[\(stamp(start))]\(content)", false)
    }

    private static func load(_ yaml: String?) -> [String: Any]? {
        guard let yaml, !yaml.isBlank else { return nil }
        return (try? MiniYAML.parse(yaml)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Int64? {
        switch value {
        case let v as Int64: v
        case let v as Double: Int64(v)
        default: nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: nil
        case let v as String: v
        case let v as Int64: String(v)
        case let v as Double: String(v)
        case let v as Bool: String(v)
        default: nil
        }
    }

    /// `mm:ss.mmm` (milliseconds kept exactly).
    static func stamp(_ ms: Int64) -> String {
        let safe = max(ms, 0)
        return String(format: "%02d:%02d.%03d", safe / 60_000, safe % 60_000 / 1000, safe % 1000)
    }
}

/// The block-style YAML that Lyricsfiles use: mappings, sequences (also at their key's indent),
/// plain and quoted scalars, block scalars (`|`, `>`), and empty flow collections. Anything else
/// throws, and the caller falls back to line timing.
enum MiniYAML {
    struct Invalid: Error {}

    private struct Line {
        let indent: Int
        let text: String
    }

    static func parse(_ source: String) throws -> Any {
        var lines: [Line] = []
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { lines.append(Line(indent: -1, text: raw)); continue }
            let indent = raw.prefix { $0 == " " }.count
            lines.append(Line(indent: indent, text: String(raw.dropFirst(indent))))
        }
        var parser = Parser(lines: lines)
        parser.skipBlank()
        guard parser.index < lines.count else { return NSNull() }
        let value = try parser.node(indent: lines[parser.index].indent)
        parser.skipBlank()
        if parser.index < lines.count { throw Invalid() }
        return value
    }

    private struct Parser {
        var lines: [Line]
        var index = 0

        mutating func skipBlank() {
            while index < lines.count && lines[index].indent < 0 { index += 1 }
        }

        mutating func node(indent: Int) throws -> Any {
            skipBlank()
            guard index < lines.count else { return NSNull() }
            let line = lines[index]
            if line.text == "-" || line.text.hasPrefix("- ") { return try sequence(indent: line.indent) }
            if keyValue(line.text) != nil { return try mapping(indent: line.indent) }
            index += 1
            return try scalar(line.text)
        }

        mutating func mapping(indent: Int) throws -> [String: Any] {
            var map: [String: Any] = [:]
            while true {
                skipBlank()
                guard index < lines.count, lines[index].indent == indent else { break }
                let line = lines[index]
                if line.text.hasPrefix("- ") || line.text == "-" { break }
                guard let (key, rest) = keyValue(line.text) else { throw Invalid() }
                index += 1
                if rest.isEmpty {
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        map[key] = try node(indent: lines[index].indent)
                    } else if index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("-") {
                        map[key] = try sequence(indent: indent)
                    } else {
                        map[key] = NSNull()
                    }
                } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                    map[key] = blockScalar(parentIndent: indent, folded: rest.hasPrefix(">"), keep: rest.contains("+"), strip: rest.contains("-"))
                } else {
                    map[key] = try scalar(rest)
                }
            }
            return map
        }

        mutating func sequence(indent: Int) throws -> [Any] {
            var items: [Any] = []
            while true {
                skipBlank()
                guard index < lines.count, lines[index].indent == indent else { break }
                let line = lines[index]
                guard line.text == "-" || line.text.hasPrefix("- ") else { break }
                let content = line.text == "-" ? "" : String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    index += 1
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        items.append(try node(indent: lines[index].indent))
                    } else {
                        items.append(NSNull())
                    }
                } else if keyValue(content) != nil || content.hasPrefix("- ") {
                    // The item's first line sits after the dash: read it as if indented there.
                    let itemIndent = indent + (line.text.count - content.count)
                    lines[index] = Line(indent: itemIndent, text: content)
                    items.append(try node(indent: itemIndent))
                } else {
                    index += 1
                    items.append(try scalar(content))
                }
            }
            return items
        }

        mutating func blockScalar(parentIndent: Int, folded: Bool, keep: Bool, strip: Bool) -> String {
            var collected: [String] = []
            var blockIndent: Int?
            while index < lines.count {
                let line = lines[index]
                if line.indent < 0 {
                    collected.append("")
                    index += 1
                    continue
                }
                if line.indent <= parentIndent { break }
                let base = blockIndent ?? line.indent
                blockIndent = base
                collected.append(String(repeating: " ", count: max(line.indent - base, 0)) + line.text)
                index += 1
            }
            while !keep, let last = collected.last, last.isEmpty { collected.removeLast() }
            let body = folded ? collected.joined(separator: " ") : collected.joined(separator: "\n")
            return strip || keep ? body : body + "\n"
        }

        /// "key: value" → (key, value); nil when the line is not a mapping entry.
        func keyValue(_ text: String) -> (String, String)? {
            if text.hasPrefix("\"") || text.hasPrefix("'") {
                guard let close = closingQuote(text), let after = text[close...].dropFirst().firstIndex(of: ":") else { return nil }
                guard let key = try? scalar(String(text[...close])) as? String else { return nil }
                let rest = text[text.index(after: after)...]
                guard rest.isEmpty || rest.first == " " else { return nil }
                return (key, rest.trimmingCharacters(in: .whitespaces))
            }
            guard let colon = text.range(of: ": ")?.lowerBound ?? (text.hasSuffix(":") ? text.index(before: text.endIndex) : nil) else { return nil }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces)
            if key.isEmpty || key.hasPrefix("[") || key.hasPrefix("{") { return nil }
            let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (key, rest)
        }

        func closingQuote(_ text: String) -> String.Index? {
            guard let quote = text.first else { return nil }
            var i = text.index(after: text.startIndex)
            while i < text.endIndex {
                if text[i] == quote {
                    let next = text.index(after: i)
                    if quote == "'" && next < text.endIndex && text[next] == "'" {
                        i = text.index(after: next)
                        continue
                    }
                    return i
                }
                if quote == "\"" && text[i] == "\\" { i = text.index(after: i) }
                if i < text.endIndex { i = text.index(after: i) }
            }
            return nil
        }

        func scalar(_ raw: String) throws -> Any {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("'") {
                guard let close = closingQuote(text), text.index(after: close) == text.endIndex else { throw Invalid() }
                return String(text[text.index(after: text.startIndex)..<close]).replacingOccurrences(of: "''", with: "'")
            }
            if text.hasPrefix("\"") {
                guard let close = closingQuote(text), text.index(after: close) == text.endIndex else { throw Invalid() }
                return unescape(String(text[text.index(after: text.startIndex)..<close]))
            }
            if text.hasPrefix("[") || text.hasPrefix("{") {
                let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if text == "[]" || (text.hasPrefix("[") && text.hasSuffix("]") && inner.isEmpty) { return [Any]() }
                if text == "{}" || (text.hasPrefix("{") && text.hasSuffix("}") && inner.isEmpty) { return [String: Any]() }
                guard text.hasPrefix("[") && text.hasSuffix("]") else { throw Invalid() }
                return try inner.split(separator: ",").map { try scalar(String($0)) }
            }
            var plain = text
            if let comment = plain.range(of: " #") { plain = String(plain[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            switch plain {
            case "", "~", "null", "Null", "NULL": return NSNull()
            case "true", "True", "TRUE": return true
            case "false", "False", "FALSE": return false
            default: break
            }
            if let int = Int64(plain) { return int }
            if plain.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let double = Double(plain) { return double }
            return plain
        }

        func unescape(_ text: String) -> String {
            var out = ""
            var escaping = false
            for ch in text {
                if escaping {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    default: out.append(ch)
                    }
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
    }
}

/// Lyrics can still be found in a browser when all in-app providers are unavailable. Opening
/// this URL is an explicit user action; it neither scrapes a site nor claims a cached result.
enum LyricsWebSearch {
    static func url(for text: String) -> URL? {
        guard let query = text.nonBlank else { return nil }
        var parts = URLComponents(string: "https://www.google.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: query + " lyrics")]
        return parts.url
    }
}

enum LyricsFailureMessage {
    static func text(_ reason: String) -> String {
        if reason.contains("LRCLIB") { return reason + "." }
        if reason.contains("HTTP 5") || reason.contains("timed out") {
            return "Online lyrics are temporarily unavailable. You can search the web instead."
        }
        return "Could not load online lyrics (\(reason))."
    }
}
