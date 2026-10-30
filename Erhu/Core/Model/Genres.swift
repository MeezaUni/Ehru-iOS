import Foundation

/// A track's genres as one stored string, and back. Stored joined with [separator]
/// ("Electronic; Synth-pop"). Reading splits on ';' and NUL; '/' and '&' are never split.
enum Genres {
    static let separator = "; "
    /// Longer than this is not a genre name but junk.
    private static let maxLength = 64
    private static let split = Regex16("[;\\u0000]")
    private static let whitespace = Regex16("\\s+")
    private static let placeholders: Set<String> = ["unknown", "unknown genre", "<unknown>", "genre", "none", "n/a"]

    /// Usable, distinct genres in their original order.
    static func normalize<S: Sequence>(_ values: S) -> [String] where S.Element == String? {
        var seen = Set<String>()
        return values.compactMap { $0 }
            .map { whitespace.replacing(in: $0, with: " ").trimmed }
            .filter(isUsable)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// The genres in a stored or tag value; empty when there are none.
    static func parse(_ stored: String?) -> [String] {
        guard let stored else { return [] }
        let parts = split.regex.stringByReplacingMatches(
            in: stored, range: NSRange(location: 0, length: stored.utf16Length), withTemplate: ";"
        ).components(separatedBy: ";")
        return normalize(parts.map { Optional($0) })
    }

    /// The stored form of [genres], or nil when none is usable.
    static func join<S: Sequence>(_ genres: S) -> String? where S.Element == String? {
        let list = normalize(genres)
        return list.isEmpty ? nil : list.joined(separator: separator)
    }

    static func join(_ genres: [String]) -> String? {
        join(genres.map { Optional($0) })
    }

    /// True when [a] and [b] hold the same genres in the same order (ignoring case and spacing).
    static func same(_ a: String?, _ b: String?) -> Bool {
        parse(a).map { $0.lowercased() } == parse(b).map { $0.lowercased() }
    }

    private static func isUsable(_ genre: String) -> Bool {
        !genre.isEmpty
            && genre.utf16Length <= maxLength
            && !placeholders.contains(genre.lowercased())
            && !genre.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
            && genre.contains { $0.isLetter }
    }
}

/// Tempos accepted as a valid tag. Outside this a value is a broken tag (0, a year, a track number).
let plausibleBpm = 20...400

private let bpmNumber = Regex16("^\\s*(\\d{1,4}(?:[.,]\\d+)?)\\s*(?:bpm)?\\s*$", ignoreCase: true)

/// A BPM tag value ("128", "127.9", "128 BPM") as a whole number, or nil when it isn't one.
func parseBpmTag(_ text: String?) -> Int? {
    guard let text, let match = bpmNumber.firstMatch(in: text),
          let value = Double(match.group(1, in: text).replacingOccurrences(of: ",", with: "."))
    else { return nil }
    return Int(value.rounded())
}

/// The file's BPM if it is a plausible tempo, else nil.
func usableBpm(_ text: String?) -> Int? {
    parseBpmTag(text).flatMap { plausibleBpm.contains($0) ? $0 : nil }
}

/// A manual tempo correction for a BPM read at the wrong octave.
enum BpmCorrection: CaseIterable {
    case halfTime
    case doubleTime

    var label: String { self == .halfTime ? "Half time" : "Double time" }
    private var factor: Double { self == .halfTime ? 0.5 : 2.0 }

    /// [bpm] corrected (rounded: 155 → 78), or nil when the result isn't a plausible tempo.
    func applyTo(_ bpm: Int) -> Int? {
        let corrected = Int((Double(bpm) * factor).rounded())
        return plausibleBpm.contains(corrected) ? corrected : nil
    }
}
