import Foundation

/// A track as one online source describes it.
struct MetadataCandidate: Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var year = 0
    var genre: String?
    var trackNumber = 0
    var bpm: Int?
    var durationMs: Int64?
    var coverArtUrl: String?
    var confidenceScore: Float = 0
    var sourceName = ""
    /// MusicBrainz release group of the chosen release: genre and Cover Art Archive lookups.
    var releaseGroupId: String?
    /// Deezer album id: genre lookup (Deezer gives genres per album only).
    var deezerAlbumId: Int64?
    /// Version note kept out of the title, e.g. MusicBrainz "live, 2011-04-17: Coachella".
    var versionNote: String?
    /// Validated original release date as precise as the source gives it ("2010-11-19", "2010-11"
    /// or "2010"); nil when the source has none it can vouch for, with the reason in [releaseDateIssue].
    var releaseDate: String?
    var releaseDateIssue: String?
}

/// What happened when a provider was (or was not) asked about a track. Skipped and not configured
/// mean no request was sent; every failure status means one was sent and failed, and none of them
/// is ever reported as "no results".
enum ProviderStatus: String, Sendable {
    case inProgress = "Searching…"
    case noResults = "No results found"
    case candidatesFound = "Candidates found"
    case lowConfidence = "Low confidence candidates"
    case success = "Selected candidate contributed"
    case skipped = "Not queried"
    case notConfigured = "Not configured"
    case authFailed = "Credentials rejected"
    case networkError = "Network unavailable"
    case timedOut = "Request timed out"
    case rateLimited = "Rate limited"
    case unavailable = "Not available here"
    case failed = "Provider error"

    var label: String { rawValue }

    /// A failure worth retrying later: the connection or the provider's load, not the request itself.
    var isTransient: Bool { self == .networkError || self == .timedOut || self == .rateLimited }

    /// Statuses of a provider that was asked and answered (with or without results).
    var answered: Bool { [.noResults, .candidatesFound, .lowConfidence, .success].contains(self) }
}

struct ProviderOutcome: Equatable, Sendable {
    var providerName: String
    var candidateCount = 0
    var status: ProviderStatus = .noResults
    var errorMessage: String?
}

/// One query sent for a track: its parts, where the title came from, and each provider's answer.
struct QueryAttempt: Equatable, Sendable {
    let title: String
    let artist: String?
    let album: String?
    let source: String
    let outcomes: [ProviderOutcome]
}

/// A match needs this score to be written (Settings can change it).
let highConfidenceThreshold: Float = 0.85
/// Below this a candidate is no match at all.
let uncertainThreshold: Float = 0.60

/// A release date exactly as precise as its source. Only [parse] creates one, so every instance is a
/// real, plausible calendar date.
struct ReleaseDate: Equatable, Hashable, Sendable {
    let year: Int
    let month: Int?
    let day: Int?

    /// Before this a "release date" is noise for a music library.
    static let minYear = 1900

    /// The tag value: "2010", "2010-11" or "2010-11-19".
    var tagValue: String {
        var text = String(format: "%04d", year)
        if let month { text += String(format: "-%02d", month) }
        if let day { text += String(format: "-%02d", day) }
        return text
    }

    var hasMonthOnly: Bool { month != nil && day == nil }

    func yearOnly() -> ReleaseDate { ReleaseDate(year: year, month: nil, day: nil) }

    private var precision: Int { day != nil ? 2 : month != nil ? 1 : 0 }

    /// True when [other] is strictly earlier at the first component both dates know.
    func isLaterThan(_ other: ReleaseDate) -> Bool {
        if year != other.year { return year > other.year }
        if month == nil || other.month == nil || month == other.month {
            guard let day, let otherDay = other.day, month == other.month else { return false }
            return day > otherDay
        }
        return month! > other.month!
    }

    private static let format = Regex16("^(\\d{4})(?:-(\\d{2})(?:-(\\d{2}))?)?$")

    /// A strictly formatted ("YYYY", "YYYY-MM" or "YYYY-MM-DD"), real calendar date from [minYear] up
    /// to [today]; anything else (blank, malformed, impossible or in the future) is nil.
    static func parse(_ raw: String?, today: Date = Date()) -> ReleaseDate? {
        guard let text = raw?.trimmed, let match = format.firstMatch(in: text), match.range.length == text.utf16Length else { return nil }
        guard let year = Int(match.group(1, in: text)) else { return nil }
        let month = Int(match.group(2, in: text))
        let day = Int(match.group(3, in: text))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents(year: year, month: month ?? 1, day: day ?? 1)
        components.calendar = calendar
        guard (1...12).contains(month ?? 1), components.isValidDate, let date = calendar.date(from: components) else { return nil }
        guard year >= minYear, date <= today else { return nil }
        return ReleaseDate(year: year, month: month, day: day)
    }

    /// The original release among [dates]: the earliest, as precise as the data allows.
    static func earliest(_ dates: [ReleaseDate]) -> ReleaseDate? {
        let candidates = dates.filter { date in !dates.contains { date.isLaterThan($0) } }
        var best: ReleaseDate?
        for date in candidates where best == nil || date.precision > best!.precision { best = date }
        return best
    }
}

/// Is [value] (a file's year tag) a real year to keep? Blank, unparseable and the 1970 some
/// downloaders write (the Unix epoch, not a release year) all count as missing.
func isUsableYearTag(_ value: String?) -> Bool {
    guard let text = value?.trimmed, text.count >= 4, let year = Int(text.prefix(4)) else { return false }
    return year >= ReleaseDate.minYear && year != 1970
}

enum ReleaseDateDecision: Equatable {
    case found(ReleaseDate)
    case rejected(String)
}

/// Matches within this score of the best are treated as equally good.
let tieMargin: Float = 0.02

/// The release date to write for [match], or why there is none: the match must carry a validated
/// date, and no other equally good confident match may name a different year.
func releaseDateFor(_ match: MetadataCandidate, candidates: [MetadataCandidate], today: Date = Date(), confidentScore: Float) -> ReleaseDateDecision {
    let date = ReleaseDate.parse(match.releaseDate, today: today)
    var otherYears: [Int] = []
    for candidate in candidates where candidate.id != match.id
        && candidate.confidenceScore >= confidentScore
        && match.confidenceScore - candidate.confidenceScore <= tieMargin {
        if let year = ReleaseDate.parse(candidate.releaseDate, today: today)?.year, year != date?.year, !otherYears.contains(year) {
            otherYears.append(year)
        }
    }
    guard let date else {
        return .rejected(match.releaseDateIssue ?? "\(match.sourceName) gives no release date for this match")
    }
    if !otherYears.isEmpty {
        let years = ([date.year] + otherYears).sorted().map(String.init).joined(separator: ", ")
        return .rejected("Equally good matches disagree on the year (\(years))")
    }
    return .found(date)
}

private let tagPlaceholders: Set<String> = ["unknown", "unknown artist", "unknown album", "unknown title", "<unknown>", "unknown genre"]

/// A value worth writing: not blank and not a placeholder some app or provider uses for "no value".
func isUsableTag(_ value: String?) -> Bool {
    guard let value, !value.isBlank else { return false }
    return !tagPlaceholders.contains(value.trimmed.lowercased())
}

/// UTF-8 text that was decoded as Windows-1252 ("IGORâ€™S THEME").
enum MojibakeText {
    /// A UTF-8 lead byte (Â–ï as Windows-1252) followed by a continuation byte, as Windows-1252 shows them.
    private static let signature = Regex16("[Â-ï][\\u0080-¿ŒœŠšŸŽžƒˆ˜–—‘-„†-•…‰‹›€™]")

    static func looksMisread(_ text: String?) -> Bool {
        guard let text else { return false }
        return signature.containsMatch(in: text)
    }
}
