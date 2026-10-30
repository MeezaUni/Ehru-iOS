import Foundation

/// Tags read from an audio file's own metadata, as written (nothing resolved or guessed).
struct FileTags: Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    /// The date tag exactly as stored ("2010-11-19", "2010"), for checking a write.
    var dateText: String?
    var genres: [String] = []
    var bpmText: String?
    var lyrics: String?
    var composer: String?
    var isCompilation = false
    var hasArtwork = false

    /// Fills the fields this one is missing from [other].
    mutating func fillMissing(from other: FileTags) {
        title = title ?? other.title
        artist = artist ?? other.artist
        albumArtist = albumArtist ?? other.albumArtist
        album = album ?? other.album
        trackNumber = trackNumber ?? other.trackNumber
        discNumber = discNumber ?? other.discNumber
        year = year ?? other.year
        dateText = dateText ?? other.dateText
        if genres.isEmpty { genres = other.genres }
        bpmText = bpmText ?? other.bpmText
        lyrics = lyrics ?? other.lyrics
        composer = composer ?? other.composer
        isCompilation = isCompilation || other.isCompilation
        hasArtwork = hasArtwork || other.hasArtwork
    }
}

/// Reads tags and embedded artwork from MP3 (ID3v2.2–2.4, ID3v1), MP4/M4A/ALAC, FLAC, WAV and AIFF.
/// Only the metadata regions are read, never the audio. Android used MediaStore + jaudiotagger;
/// this reader replaces both on iOS.
enum TagReader {
    /// Reads at most this much of a file's head looking for tags (artwork can be large).
    private static let maxTagBytes = 16 * 1024 * 1024

    static func read(_ url: URL) -> FileTags {
        guard let file = try? FileHandle(forReadingFrom: url) else { return FileTags() }
        defer { try? file.close() }
        let reader = ByteSource(file: file)
        let ext = url.pathExtension.lowercased()
        var tags = FileTags()
        switch ext {
        case "m4a", "mp4", "aac", "alac", "m4b":
            if reader.peek(4, at: 4) == Data("ftyp".utf8) { tags = MP4Tags.read(reader).tags }
            else { tags = ID3.read(reader).tags }
        case "flac":
            tags = FLACTags.read(reader).tags
        case "wav", "wave":
            tags = RIFFTags.read(reader).tags
        case "aif", "aiff", "aifc":
            tags = AIFFTags.read(reader).tags
        default:
            tags = ID3.read(reader).tags
            if tags.title == nil, tags.artist == nil, let v1 = ID3.readV1(reader) { tags.fillMissing(from: v1) }
        }
        return tags
    }

    /// The first embedded picture (front cover preferred), or nil.
    static func artwork(_ url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let reader = ByteSource(file: file)
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "aac", "alac", "m4b":
            if reader.peek(4, at: 4) == Data("ftyp".utf8) { return MP4Tags.read(reader, wantArtwork: true).artwork }
            return ID3.read(reader, wantArtwork: true).artwork
        case "flac":
            return FLACTags.read(reader, wantArtwork: true).artwork
        case "wav", "wave":
            return RIFFTags.read(reader, wantArtwork: true).artwork
        case "aif", "aiff", "aifc":
            return AIFFTags.read(reader, wantArtwork: true).artwork
        default:
            return ID3.read(reader, wantArtwork: true).artwork
        }
    }

    /// "1/12" or "3" → 1 or 3.
    static func leadingNumber(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.trimmed.prefix { $0.isNumber }
        return Int(digits)
    }

    /// The first plausible 4-digit year in a date tag ("2010-11-19", "2010").
    static func year(_ text: String?) -> Int? {
        guard let text, let match = Regex16("\\b(19\\d{2}|20\\d{2})\\b").firstMatch(in: text) else { return nil }
        return Int(match.group(1, in: text))
    }

    static func maxBytes() -> Int { maxTagBytes }
}

/// Random access to the start (and end) of a file without reading the audio.
final class ByteSource {
    private let file: FileHandle
    let size: UInt64

    init(file: FileHandle) {
        self.file = file
        size = (try? file.seekToEnd()) ?? 0
    }

    func read(_ count: Int, at offset: UInt64) -> Data {
        guard count > 0, offset < size else { return Data() }
        do {
            try file.seek(toOffset: offset)
            return try file.read(upToCount: min(count, Int(size - offset))) ?? Data()
        } catch {
            return Data()
        }
    }

    func peek(_ count: Int, at offset: UInt64) -> Data { read(count, at: offset) }
}

extension Data {
    /// The byte at [at] (0 past the end), counting from the start of this Data.
    func byte(_ at: Int) -> UInt8 {
        guard at >= 0, at < count else { return 0 }
        return self[index(startIndex, offsetBy: at)]
    }

    func uint32BE(_ at: Int) -> UInt32 {
        guard at + 4 <= count else { return 0 }
        let b0 = UInt32(byte(at)) << 24
        let b1 = UInt32(byte(at + 1)) << 16
        let b2 = UInt32(byte(at + 2)) << 8
        let b3 = UInt32(byte(at + 3))
        return b0 | b1 | b2 | b3
    }

    func uint32LE(_ at: Int) -> UInt32 {
        guard at + 4 <= count else { return 0 }
        let b0 = UInt32(byte(at))
        let b1 = UInt32(byte(at + 1)) << 8
        let b2 = UInt32(byte(at + 2)) << 16
        let b3 = UInt32(byte(at + 3)) << 24
        return b0 | b1 | b2 | b3
    }

    func uint24BE(_ at: Int) -> UInt32 {
        guard at + 3 <= count else { return 0 }
        let b0 = UInt32(byte(at)) << 16
        let b1 = UInt32(byte(at + 1)) << 8
        let b2 = UInt32(byte(at + 2))
        return b0 | b1 | b2
    }

    func uint16BE(_ at: Int) -> UInt16 {
        guard at + 2 <= count else { return 0 }
        let high = UInt16(byte(at)) << 8
        let low = UInt16(byte(at + 1))
        return high | low
    }

    func uint64BE(_ at: Int) -> UInt64 {
        let high = UInt64(uint32BE(at)) << 32
        let low = UInt64(uint32BE(at + 4))
        return high | low
    }

    func slice(_ from: Int, _ length: Int) -> Data {
        let start = Swift.max(0, Swift.min(from, count))
        let end = Swift.max(start, Swift.min(from + length, count))
        return Data(self[(startIndex + start)..<(startIndex + end)])
    }

    func ascii(_ from: Int, _ length: Int) -> String {
        String(decoding: slice(from, length), as: UTF8.self)
    }
}
