import Foundation

/// A word of a line with its own timestamp (enhanced LRC `<mm:ss.xx>`).
struct LyricWord: Equatable, Sendable {
    let timeMs: Int64
    let text: String
}

/// A timed lyric line; [words] only when the file times every word of it.
struct LyricLine: Equatable, Sendable {
    let timeMs: Int64
    let text: String
    var words: [LyricWord]?
}

/// Lyrics as the file provides them: timed (LRC) or plain text.
enum Lyrics: Equatable, Sendable {
    case synced([LyricLine])
    case plain([String])

    /// Whether any line carries word timestamps.
    var hasWordTiming: Bool {
        if case .synced(let lines) = self { return lines.contains { $0.words != nil } }
        return false
    }

    /// The line playing at [positionMs] (the last one started), -1 before the first.
    func lineAt(_ positionMs: Int64) -> Int {
        guard case .synced(let lines) = self else { return -1 }
        return lastStarted(lines.map(\.timeMs), positionMs)
    }

    /// The word of [line] playing at [positionMs], -1 before its first word or without word timing.
    func wordAt(line: Int, _ positionMs: Int64) -> Int {
        guard case .synced(let lines) = self, lines.indices.contains(line), let words = lines[line].words else { return -1 }
        return lastStarted(words.map(\.timeMs), positionMs)
    }
}

private func lastStarted(_ times: [Int64], _ positionMs: Int64) -> Int {
    var low = 0
    var high = times.count - 1
    var found = -1
    while low <= high {
        let mid = (low + high) / 2
        if times[mid] <= positionMs {
            found = mid
            low = mid + 1
        } else {
            high = mid - 1
        }
    }
    return found
}

/// Reads lyrics text from a file's tags (or an online result). LRC is recognised by its line
/// timestamps (`[mm:ss]`, `[mm:ss.xx]`, several per line for repeated lines) with optional
/// enhanced-LRC word timestamps (`<mm:ss.xx>`) and an `[offset:±ms]` tag; other `[tag:value]` lines
/// are dropped. Text without any valid line timestamp is plain lyrics. Malformed stamps are ignored.
enum LyricsParser {
    private static let lineTime = Regex16(#"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?]"#)
    private static let wordTime = Regex16(#"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)
    private static let offsetTag = Regex16(#"\[offset:\s*([+-]?\d+)\s*]"#, ignoreCase: true)
    private static let meta = Regex16(#"^\[[a-zA-Z#]+:.*]$"#)

    static func parse(_ text: String?) -> Lyrics? {
        guard let text, !text.isBlank else { return nil }
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        // LRC offset: positive means the lyrics come earlier.
        var offset: Int64 = 0
        for raw in rawLines {
            if let match = offsetTag.firstMatch(in: raw), let value = Int64(match.group(1, in: raw)) {
                offset = value
                break
            }
        }
        var synced: [LyricLine] = []
        for raw in rawLines {
            var rest = raw.trimmed
            var stamps: [Int64] = []
            while let match = lineTime.firstMatch(in: rest) {
                if let ms = toMs(match, in: rest) { stamps.append(ms) }
                rest = rest.substring16(from: match.range.location + match.range.length)
            }
            if stamps.isEmpty { continue }
            let words = parseWords(rest, offset: offset)
            let content = words.map { $0.map(\.text).joined().trimmed } ?? rest.trimmed
            for stamp in stamps { synced.append(LyricLine(timeMs: max(stamp - offset, 0), text: content, words: words)) }
        }
        if !synced.isEmpty { return .synced(stableSorted(synced) { $0.timeMs < $1.timeMs }) }
        var plain = rawLines.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .filter { !meta.matchesEntirely($0.trimmed) }
        while let first = plain.first, first.isBlank { plain.removeFirst() }
        while let last = plain.last, last.isBlank { plain.removeLast() }
        return plain.isEmpty ? nil : .plain(plain)
    }

    /// Words of a line with `<mm:ss.xx>` stamps before them; nil if the line has no word timing.
    private static func parseWords(_ content: String, offset: Int64) -> [LyricWord]? {
        let stamps = wordTime.matches(in: content)
        if stamps.isEmpty { return nil }
        var words: [LyricWord] = []
        for (index, match) in stamps.enumerated() {
            guard let time = toMs(match, in: content) else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < stamps.count ? stamps[index + 1].range.location : content.utf16Length
            let word = content.substring16(start, end)
            if !word.isBlank { words.append(LyricWord(timeMs: max(time - offset, 0), text: word)) }
        }
        return words.isEmpty ? nil : stableSorted(words) { $0.timeMs < $1.timeMs }
    }

    /// Milliseconds of a `mm:ss(.fff)` stamp; nil when the seconds are 60 or more.
    private static func toMs(_ match: NSTextCheckingResult, in text: String) -> Int64? {
        guard let minutes = Int64(match.group(1, in: text)), let seconds = Int64(match.group(2, in: text)), seconds < 60 else { return nil }
        let fraction = match.group(3, in: text)
        let fractionMs: Int64
        switch fraction.count {
        case 0: fractionMs = 0
        case 1: fractionMs = (Int64(fraction) ?? 0) * 100
        case 2: fractionMs = (Int64(fraction) ?? 0) * 10
        default: fractionMs = Int64(fraction.prefix(3)) ?? 0
        }
        return (minutes * 60 + seconds) * 1000 + fractionMs
    }

    /// Kotlin's sortedBy: stable.
    private static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in less(a.element, b.element) || (!less(b.element, a.element) && a.offset < b.offset) }.map(\.element)
    }
}
