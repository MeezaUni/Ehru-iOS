import Foundation

/// NSRegularExpression with Kotlin-style string offsets: every position is a UTF-16 index, the
/// same unit Kotlin's String uses, so code ported from the Android app keeps its exact offsets.
struct Regex16: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false, multiline: Bool = false) {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if multiline { options.insert(.anchorsMatchLines) }
        // Patterns are compile-time constants; a bad one is a programming error.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16Length))
    }

    func matches(in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(location: 0, length: text.utf16Length))
    }

    func containsMatch(in text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    /// Kotlin's `replace(regex, literal)`: [replacement] is inserted as is.
    func replacing(in text: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: text.utf16Length),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    /// The whole text matches (Kotlin's `matches`).
    func matchesEntirely(_ text: String) -> Bool {
        guard let match = firstMatch(in: text) else { return false }
        return match.range.location == 0 && match.range.length == text.utf16Length
    }
}

extension NSTextCheckingResult {
    /// Group [index]'s text in [text], or "" when the group did not take part (Kotlin's groupValues).
    func group(_ index: Int, in text: String) -> String {
        let range = range(at: index)
        guard range.location != NSNotFound else { return "" }
        return (text as NSString).substring(with: range)
    }
}

extension String {
    var utf16Length: Int { (self as NSString).length }

    /// Kotlin `substring(from, to)` in UTF-16 offsets.
    func substring16(_ from: Int, _ to: Int) -> String {
        (self as NSString).substring(with: NSRange(location: from, length: to - from))
    }

    func substring16(from: Int) -> String {
        (self as NSString).substring(from: from)
    }

    /// Kotlin `isBlank()`.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Kotlin `trim()`.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kotlin `ifBlank { other }`.
    func ifBlank(_ other: String) -> String {
        isBlank ? other : self
    }

    /// nil when blank, else self (Kotlin `takeIf { it.isNotBlank() }`).
    var nonBlank: String? {
        isBlank ? nil : self
    }
}

/// Kotlin's String ordering (UTF-16 code units), so ties break exactly as on Android.
func utf16Less(_ a: String, _ b: String) -> Bool {
    a.utf16.lexicographicallyPrecedes(b.utf16)
}

/// Kotlin's `contains`: every string contains the empty string (Foundation's says no).
func kotlinContains(_ text: String, _ part: String) -> Bool {
    part.isEmpty || text.contains(part)
}
