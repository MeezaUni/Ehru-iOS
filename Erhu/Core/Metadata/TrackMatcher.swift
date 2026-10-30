import Foundation

/// What is known about a local track. [title], [artist] and [album] come from the file's own tags
/// (nil when missing, a placeholder or unreadable); [fileTitles] are titles read from the file
/// name, a fallback only: downloaders shorten names ("THANK YOU.mp3" for "GONE, GONE / THANK YOU").
struct TrackIdentity: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var durationMs: Int64?
    var fileTitles: [String] = []
    var fileArtist: String?
}

/// One search sent to the providers, as separate values: a title, and the artist credit or the
/// album to narrow it, plus where the title came from.
struct TrackQuery: Equatable, Sendable {
    enum Source: String, Sendable {
        case tag = "file tags"
        case fileName = "file name"
    }

    let title: String
    let artist: String?
    let source: Source
    var album: String?
}

/// Every provider's answer to one query.
struct SearchResponse: Sendable {
    var candidates: [MetadataCandidate]
    var outcomes: [ProviderOutcome]
}

enum MatchDecision: Equatable, Sendable {
    case confident(MetadataCandidate)
    /// Equally good matches would write different tags: nothing is chosen.
    case ambiguous([MetadataCandidate], reason: String)
    case lowConfidence(MetadataCandidate, reason: String)
    case noMatch(reason: String?)
}

struct MatchResult: Sendable {
    let decision: MatchDecision
    /// Every candidate found, once each, scored against the track itself, best first.
    let candidates: [MetadataCandidate]
    let outcomes: [ProviderOutcome]
    let queries: [TrackQuery]
    /// Each query actually sent, with every provider's answer to it, in order.
    let attempts: [QueryAttempt]
}

/// Finds the online record of a local track. Searches start from the file's own tags and fall back
/// to the file name; every candidate is scored against the track's best-known identity, so a short
/// file name can widen the search but never lowers a correct candidate's score. A tie between
/// matches that would write different tags is reported, never resolved silently.
enum TrackMatcher {
    private static let maxQueries = 6
    /// A file-name title is weaker evidence than the tag title.
    private static let alternateTitleFactor: Float = 0.97

    static func match(_ identity: TrackIdentity, acceptAt: Float = highConfidenceThreshold,
                      search: (TrackQuery) async -> SearchResponse) async -> MatchResult {
        let queries = planQueries(identity)
        var found: [String: MetadataCandidate] = [:]
        var order: [String] = []
        var responses: [SearchResponse] = []
        var attempts: [QueryAttempt] = []
        for query in queries {
            let response = await search(query)
            responses.append(response)
            attempts.append(QueryAttempt(title: query.title, artist: query.artist, album: query.album,
                                         source: query.source.rawValue, outcomes: response.outcomes))
            for candidate in response.candidates {
                let scored = rescore(candidate, identity, query)
                if let previous = found[candidate.id] {
                    if scored.confidenceScore > previous.confidenceScore { found[candidate.id] = scored }
                } else {
                    found[candidate.id] = scored
                    order.append(candidate.id)
                }
            }
            if case .confident = decide(ranked(order, found), identity, acceptAt: acceptAt) { break }
        }
        let best = ranked(order, found)
        return MatchResult(decision: decide(best, identity, acceptAt: acceptAt), candidates: best,
                           outcomes: mergeOutcomes(responses, best), queries: Array(queries.prefix(attempts.count)), attempts: attempts)
    }

    /// Best first; equal scores keep the order they were found in.
    private static func ranked(_ order: [String], _ found: [String: MetadataCandidate]) -> [MetadataCandidate] {
        let list = order.compactMap { found[$0] }
        return list.enumerated().sorted { a, b in
            a.element.confidenceScore != b.element.confidenceScore ? a.element.confidenceScore > b.element.confidenceScore : a.offset < b.offset
        }.map(\.element)
    }

    /// Scores [candidate] against the track itself, not the query text. File-name titles count as
    /// alternates (a little below the tag title), so they can only add evidence.
    static func rescore(_ candidate: MetadataCandidate, _ identity: TrackIdentity, _ query: TrackQuery) -> MetadataCandidate {
        let artist = identity.artist ?? identity.fileArtist ?? query.artist
        func against(_ title: String) -> MetadataCandidate {
            MetadataScorer.score(candidate, title: title, artist: artist, album: identity.album, durationMs: identity.durationMs)
        }
        let primary = against(identity.title ?? query.title)
        var alternate: MetadataCandidate?
        for title in identity.fileTitles {
            let scored = against(title)
            if alternate == nil || scored.confidenceScore > alternate!.confidenceScore { alternate = scored }
        }
        if var alternate {
            alternate.confidenceScore *= alternateTitleFactor
            if alternate.confidenceScore > primary.confidenceScore { return alternate }
        }
        return primary
    }

    /// The searches to run, best evidence first: the tagged title, then file-name titles, each without
    /// its featured-artist note, first with the artist credit, then with the album; last, the best
    /// title alone. Duplicates are dropped.
    static func planQueries(_ identity: TrackIdentity) -> [TrackQuery] {
        let artist = identity.artist ?? identity.fileArtist
        var titles: [(String, TrackQuery.Source)] = []
        var seenTitles = Set<String>()
        let raw = (identity.title.map { [($0, TrackQuery.Source.tag)] } ?? []) + identity.fileTitles.map { ($0, TrackQuery.Source.fileName) }
        for (title, source) in raw {
            let plain = stripFeaturing(title)
            guard !plain.isBlank, seenTitles.insert(foldForMatch(plain)).inserted else { continue }
            titles.append((plain, source))
        }
        var narrowed: [TrackQuery] = []
        for (title, source) in titles {
            if let artist { narrowed.append(TrackQuery(title: title, artist: artist, source: source)) }
            if let album = identity.album { narrowed.append(TrackQuery(title: title, artist: nil, source: source, album: album)) }
        }
        var queries = Array(narrowed.prefix(maxQueries - 1))
        if let first = titles.first { queries.append(TrackQuery(title: first.0, artist: nil, source: first.1)) }
        var seen = Set<String>()
        return queries.filter { query in
            seen.insert([foldForMatch(query.title), foldForMatch(query.artist ?? ""), foldForMatch(query.album ?? "")].joined(separator: "\u{1}")).inserted
        }
    }

    /// The decision for [ranked] candidates (best first), with a reason a person can act on.
    static func decide(_ ranked: [MetadataCandidate], _ identity: TrackIdentity, acceptAt: Float = highConfidenceThreshold) -> MatchDecision {
        guard let best = ranked.first else { return .noMatch(reason: nil) }
        let rivals = ranked.dropFirst().filter {
            $0.confidenceScore >= acceptAt && best.confidenceScore - $0.confidenceScore <= tieMargin && !sameSong($0, best)
        }
        if best.confidenceScore < min(uncertainThreshold, acceptAt) {
            return .noMatch(reason: "No close match. Best: \(describe(best, identity))")
        }
        if best.confidenceScore < acceptAt {
            return .lowConfidence(best, reason: "Not confident enough to write. Best: \(describe(best, identity))")
        }
        if !rivals.isEmpty {
            let all = [best] + rivals
            return .ambiguous(all, reason: "Equally good matches disagree: " + all.map { describe($0, identity) }.joined(separator: " / "))
        }
        return .confident(best)
    }

    /// Whether two candidates are the same underlying song (spelling and "feat." formatting aside).
    private static func sameSong(_ a: MetadataCandidate, _ b: MetadataCandidate) -> Bool {
        let sameTitle = foldForMatch(a.title) == foldForMatch(b.title)
        let sameAlbum = foldForMatch(a.album) == foldForMatch(b.album) || a.album.isBlank || b.album.isBlank
        let sameArtist = foldForMatch(primaryArtist(a.artist)) == foldForMatch(primaryArtist(b.artist))
            || creditSimilarity(a.artist, b.artist) >= 0.80
        return sameTitle && sameAlbum && sameArtist
    }

    /// e.g. "GONE, GONE / THANK YOU" by Tyler, The Creator (IGOR), 4:32 vs file 6:15, 69% [MusicBrainz]
    static func describe(_ candidate: MetadataCandidate, _ identity: TrackIdentity) -> String {
        let album = candidate.album.isBlank ? "" : " (\(candidate.album))"
        let fileLength = identity.durationMs.map { " vs file \(clock($0))" } ?? ""
        let duration = candidate.durationMs.map { ", \(clock($0))\(fileLength)" } ?? ""
        let version = candidate.versionNote.map { " [\($0)]" } ?? ""
        let percent = Int(candidate.confidenceScore * 100)
        return "\"\(candidate.title)\" by \(candidate.artist)\(album)\(version)\(duration), \(percent)% [\(candidate.sourceName)]"
    }

    private static func clock(_ ms: Int64) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// One outcome per provider across all queries: failed only if every query failed, else
    /// counted from the merged candidates.
    static func mergeOutcomes(_ responses: [SearchResponse], _ ranked: [MetadataCandidate]) -> [ProviderOutcome] {
        var names: [String] = []
        var byName: [String: [ProviderOutcome]] = [:]
        for outcome in responses.flatMap(\.outcomes) {
            if byName[outcome.providerName] == nil { names.append(outcome.providerName) }
            byName[outcome.providerName, default: []].append(outcome)
        }
        return names.map { name in
            let outcomes = byName[name] ?? []
            let mine = ranked.filter { $0.sourceName == name }
            if let top = mine.map(\.confidenceScore).max() {
                return ProviderOutcome(providerName: name, candidateCount: mine.count,
                                       status: top >= highConfidenceThreshold ? .success : .lowConfidence)
            }
            if outcomes.contains(where: { $0.status == .noResults }) { return ProviderOutcome(providerName: name, status: .noResults) }
            return outcomes.last ?? ProviderOutcome(providerName: name)
        }
    }
}

private let watermark = Regex16("(?i)\\.(com|net|org|mp3|m4a)\\b|\\b(www|download(ed)?|ripped)\\b")

/// A tag value worth searching and matching with: present, not a placeholder, not misread text,
/// not a downloader watermark.
func usableIdentityText(_ value: String?) -> String? {
    guard let text = value?.trimmed, isUsableTag(text), !MojibakeText.looksMisread(text), !watermark.containsMatch(in: text) else { return nil }
    return text
}
