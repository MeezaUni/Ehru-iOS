import Foundation

/// Search matching that forgives leetspeak symbols, accents and punctuation.
enum SearchNormalizer {
    private static let marks = Regex16("\\p{M}")
    private static let notAlnum = Regex16("[^a-z0-9]")
    private static let notAlnumOrSpace = Regex16("[^a-z0-9\\s]")
    private static let spaces = Regex16("\\s+")

    private static func base(_ text: String) -> String {
        let leetspeak = text
            .replacingOccurrences(of: "$", with: "s")
            .replacingOccurrences(of: "@", with: "a")
            .replacingOccurrences(of: "!", with: "i")
            .replacingOccurrences(of: "3", with: "e")
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "&", with: "and")
        let decomposed = leetspeak.lowercased().decomposedStringWithCanonicalMapping
        return marks.replacing(in: decomposed, with: "")
    }

    static func normalize(_ text: String) -> String {
        if text.isBlank { return "" }
        return notAlnum.replacing(in: base(text), with: "")
    }

    /// Like [normalize], keeping single spaces between words.
    static func normalizeWords(_ text: String) -> String {
        if text.isBlank { return "" }
        let cleaned = notAlnumOrSpace.replacing(in: base(text), with: " ")
        return spaces.replacing(in: cleaned, with: " ").trimmed
    }

    /// [target] matches [query] as a plain substring, a normalized substring, or with every query word present.
    static func matches(_ target: String, _ query: String) -> Bool {
        if query.isBlank || target.isBlank { return false }
        if target.range(of: query, options: .caseInsensitive) != nil { return true }

        let normTarget = normalize(target)
        let normQuery = normalize(query)
        if kotlinContains(normTarget, normQuery) || kotlinContains(normQuery, normTarget) { return true }

        let wordsTarget = normalizeWords(target)
        let tokens = normalizeWords(query).split(separator: " ").map(String.init).filter { !$0.isBlank }
        if tokens.isEmpty { return false }
        return tokens.allSatisfy { kotlinContains(wordsTarget, $0) || kotlinContains(normTarget, $0) }
    }
}
