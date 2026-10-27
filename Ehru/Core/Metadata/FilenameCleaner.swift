import Foundation

/// A file name turned into a title (and an artist, from "Artist - Title").
struct CleanedFilename: Equatable {
    var title: String
    var artistGuess: String?
}

/// Strips what downloaders add to file names: track numbers, site watermarks, bitrates, bracketed
/// noise ("[Official Video]"). A port of Android's FilenameCleaner.
enum FilenameCleaner {
    static let defaultBlocklist = [
        "pagalworld", "songsmpk", "pagalnew", "djpunjab", "downloadming", "mr-jatt", "riskyjatt", "pendujatt",
        "www.", ".com", ".in", ".net", "[320kbps]", "[128kbps]", "320kbps", "128kbps",
    ]
    private static let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "ogg", "opus", "wav", "aac", "wma", "alac", "aiff", "aif"]
    private static let leadingTrackNumber = Regex16("^[0-9]{1,3}[\\s._-]+")
    private static let whitespace = Regex16("\\s+")
    private static let emptyBrackets = Regex16("\\(\\s*\\)|\\[\\s*]")
    private static let domainWatermark = Regex16("(?i)[a-zA-Z0-9-]+\\.(com|in|org|net|co|site|xyz|cc|io|club|mobi|audio|mp3)")
    private static let bitrate = Regex16("(?i)\\[?\\d{2,3}\\s*kbps]?|\\(128kbps\\)|\\(320kbps\\)|320kbps|128kbps|vbr|flac\\s*hd")
    private static let bracketNoise = Regex16("(?i)\\[(official|video|audio|lyric|hd|4k|clean|remastered|mp3|download|single)]")
    private static let attribution = Regex16("(?i)[_\\s-]+(tagged|downloaded|uploaded|ripped)[_\\s]+(by|from)[_\\s]+[a-zA-Z0-9._-]+$")

    static func clean(_ rawFilename: String, blocklist custom: [String] = []) -> CleanedFilename {
        var text = stripAudioExtension(rawFilename)
        text = leadingTrackNumber.replacing(in: text, with: "")
        text = attribution.replacing(in: text, with: "")
        var tokens: [String] = []
        for token in defaultBlocklist + custom where !token.isBlank && !tokens.contains(token) { tokens.append(token) }
        for token in tokens {
            let escaped = NSRegularExpression.escapedPattern(for: token)
            let pattern = token.hasPrefix(".") ? Regex16("(?i)\(escaped)\\b") : Regex16("(?i)\\b\(escaped)\\b")
            text = pattern.replacing(in: text, with: "")
        }
        text = domainWatermark.replacing(in: text, with: "")
        text = bitrate.replacing(in: text, with: "")
        text = text.replacingOccurrences(of: "_", with: " ")
        text = bracketNoise.replacing(in: text, with: "")
        // Brackets emptied by the removals above ("[320kbps]" -> "[]") go too.
        text = emptyBrackets.replacing(in: text, with: "")
        text = trimUnmatchedBrackets(trim(whitespace.replacing(in: text, with: " "), " -_"))
        let parts = text.components(separatedBy: " - ")
        if parts.count == 2 { return CleanedFilename(title: parts[1].trimmed, artistGuess: parts[0].trimmed) }
        return CleanedFilename(title: text)
    }

    /// [name] without its audio file extension; a title without one is returned whole.
    static func stripAudioExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), audioExtensions.contains(name[name.index(after: dot)...].lowercased()) else { return name }
        return String(name[..<dot])
    }

    /// Strips brackets left dangling at either end, but keeps a balanced one.
    static func trimUnmatchedBrackets(_ text: String) -> String {
        var result = text.trimmed
        while true {
            let before = result
            func count(_ c: Character) -> Int { result.filter { $0 == c }.count }
            if result.hasSuffix(")") && count(")") > count("(") { result.removeLast() }
            if result.hasSuffix("]") && count("]") > count("[") { result.removeLast() }
            if result.hasPrefix("(") && count("(") > count(")") { result.removeFirst() }
            if result.hasPrefix("[") && count("[") > count("]") { result.removeFirst() }
            // An opener at the very end (or a closer at the very start) never encloses anything.
            if result.hasSuffix("(") || result.hasSuffix("[") { result.removeLast() }
            if result.hasPrefix(")") || result.hasPrefix("]") { result.removeFirst() }
            result = trim(result, " -_")
            if result == before { return result }
        }
    }

    /// Kotlin's trim(chars): removes any of [characters] from both ends.
    static func trim(_ text: String, _ characters: String) -> String {
        let set = Set(characters)
        var slice = Substring(text)
        while let first = slice.first, set.contains(first) { slice.removeFirst() }
        while let last = slice.last, set.contains(last) { slice.removeLast() }
        return String(slice)
    }
}

/// Title guesses from a file name, best first: the whole name, the part before a dash, without a
/// featured-artist clause, without a version tag, and the watermark-cleaned name. At most three.
enum TitleCandidates {
    private static let enclosures = Regex16("\\[.*?\\]|\\(.*?\\)")
    private static let whitespace = Regex16("\\s+")
    private static let featuring = Regex16("(?i)\\s*[(\\[]?(feat|ft|featuring|with)\\.?\\s+[^)\\]]+[)\\]]?")
    private static let version = Regex16("(?i)\\s*[(\\[](remix|radio edit|live|remastered|extended mix|acoustic)[^)]*[)\\]]")
    private static let extensions: Set<String> = ["mp3", "flac", "m4a", "ogg", "opus", "wav", "aac", "wma", "alac", "aiff"]
    private static let noise = " -_[]()"

    static func generate(_ rawFilenameOrTitle: String, blocklist: [String] = []) -> [String] {
        var raw = rawFilenameOrTitle
        if let dot = raw.lastIndex(of: "."), extensions.contains(raw[raw.index(after: dot)...].lowercased()) {
            raw = String(raw[..<dot])
        }
        let title = autoCompleteEnclosures(raw.replacingOccurrences(of: "_", with: " ").trimmed)
        var candidates: [String] = []
        if !title.isBlank { candidates.append(title) }
        if let dash = title.firstIndex(of: "-") {
            let head = FilenameCleaner.trim(whitespace.replacing(in: enclosures.replacing(in: String(title[..<dash]).trimmed, with: ""), with: " "), noise)
            if !head.isBlank, head.count >= 2, head != title { candidates.append(head) }
        }
        if featuring.containsMatch(in: title) {
            let plain = FilenameCleaner.trim(featuring.replacing(in: title, with: ""), noise)
            if plain.count >= 2, plain != title { candidates.append(plain) }
        }
        if version.containsMatch(in: title) {
            let plain = FilenameCleaner.trim(version.replacing(in: title, with: ""), noise)
            if plain.count >= 2, plain != title { candidates.append(plain) }
        }
        let cleaned = FilenameCleaner.clean(title, blocklist: blocklist).title.trimmed
        if !cleaned.isBlank, cleaned.count >= 2 { candidates.append(cleaned) }
        var seen = Set<String>()
        return Array(candidates.filter { !$0.isBlank && $0.count >= 2 && seen.insert($0).inserted }.prefix(3))
    }

    private static func autoCompleteEnclosures(_ title: String) -> String {
        var result = title
        let parens = result.filter { $0 == "(" }.count - result.filter { $0 == ")" }.count
        if parens > 0 { result += String(repeating: ")", count: parens) }
        let brackets = result.filter { $0 == "[" }.count - result.filter { $0 == "]" }.count
        if brackets > 0 { result += String(repeating: "]", count: brackets) }
        return result
    }
}
