import Foundation

/// A piece of raw credit text between candidate separators; [start]/[end] index the owning run's raw text.
struct Segment: Equatable {
    let text: String
    let key: String
    let start: Int
    let end: Int
}

/// Raw credit text on one side of an artist-text feat marker.
struct CreditRun: Equatable {
    let raw: String
    let segments: [Segment]
    let featured: Bool
}

/// Text utilities for artist credits. Separators found here are only CANDIDATE boundaries:
/// nothing in this file decides whether text is one artist or several.
enum CreditText {
    // Java's \s is ASCII whitespace only; spelled out so ICU behaves the same.
    private static let ws = "[ \\t\\n\\x0B\\f\\r]"
    private static let whitespace = Regex16("\(ws)+")
    private static let candidateSeparator = Regex16("\(ws)*[/;,&|+]\(ws)*|\(ws)+(?:and|x)\(ws)+", ignoreCase: true)
    private static let artistFeatMarker = Regex16(
        "\(ws)+(?:feat\\.?|ft\\.|featuring)\(ws)+|\(ws)*[(\\[]\(ws)*(?:feat\\.?|ft\\.|featuring|with)\(ws)+",
        ignoreCase: true
    )
    private static let blockNoise = Regex16("[ \\t\\n\\x0B\\f\\r/;,&|+]+")
    private static let trimChars = Set(" ()[]".utf16)

    static func canonicalKey(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return whitespace.replacing(in: folded, with: " ").trimmed
    }

    /// Key for comparing a whole marker block with credit text: separators are ignored, nothing is split.
    static func blockKey(_ text: String) -> String {
        blockNoise.replacing(in: canonicalKey(text), with: " ").trimmed
    }

    static func runs(_ raw: String) -> [CreditRun] {
        let pieces: [(String, Bool)]
        if let marker = artistFeatMarker.firstMatch(in: raw) {
            pieces = [
                (raw.substring16(0, marker.range.location), false),
                (raw.substring16(from: NSMaxRange(marker.range)), true),
            ]
        } else {
            pieces = [(raw, false)]
        }
        return pieces.compactMap { text, featured in
            let segments = segmentsOf(text)
            return segments.isEmpty ? nil : CreditRun(raw: text, segments: segments, featured: featured)
        }
    }

    static func segmentsOf(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var cursor = 0
        for separator in candidateSeparator.matches(in: text) {
            addSegment(text, from: cursor, to: separator.range.location, into: &out)
            cursor = NSMaxRange(separator.range)
        }
        addSegment(text, from: cursor, to: text.utf16Length, into: &out)
        return out
    }

    private static func addSegment(_ text: String, from: Int, to: Int, into out: inout [Segment]) {
        let ns = text as NSString
        var start = from
        var end = to
        while start < end, trimChars.contains(ns.character(at: start)) { start += 1 }
        while end > start, trimChars.contains(ns.character(at: end - 1)) { end -= 1 }
        if start == end { return }
        let piece = text.substring16(start, end)
        let key = canonicalKey(piece)
        if out.last?.key == key { return } // the same credit repeated back to back
        out.append(Segment(text: piece, key: key, start: start, end: end))
    }
}
