import Foundation

/// ID3v2.2, 2.3 and 2.4 tags (and ID3v1 as a last resort).
enum ID3 {
    struct Result {
        var tags = FileTags()
        var artwork: Data?
    }

    /// Reads an ID3v2 tag at [offset] of [source] (0 for MP3; inside a chunk for WAV/AIFF).
    static func read(_ source: ByteSource, at offset: UInt64 = 0, wantArtwork: Bool = false) -> Result {
        let header = source.read(10, at: offset)
        guard header.count == 10, header.ascii(0, 3) == "ID3" else { return Result() }
        let major = Int(header.byte(3))
        let flags = header.byte(5)
        let size = syncsafe(header, 6)
        guard (2...4).contains(major), size > 0 else { return Result() }
        var body = source.read(min(size, TagReader.maxBytes()), at: offset + 10)
        // v2.2/2.3 unsynchronise the whole tag; v2.4 does it per frame.
        if flags & 0x80 != 0 && major < 4 { body = deunsynchronise(body) }
        var position = 0
        if flags & 0x40 != 0 && major >= 3 {
            // Extended header: v2.3 size excludes itself, v2.4 is syncsafe and includes itself.
            position = major == 3 ? Int(body.uint32BE(0)) + 4 : syncsafe(body, 0)
        }
        return parseFrames(body, from: position, major: major, wantArtwork: wantArtwork)
    }

    /// The last 128 bytes "TAG…" of an MP3.
    static func readV1(_ source: ByteSource) -> FileTags? {
        guard source.size >= 128 else { return nil }
        let tag = source.read(128, at: source.size - 128)
        guard tag.ascii(0, 3) == "TAG" else { return nil }
        func field(_ from: Int, _ length: Int) -> String? {
            let bytes = tag.slice(from, length).prefix { $0 != 0 }
            return String(data: bytes, encoding: .isoLatin1)?.trimmed.nonBlank
        }
        var tags = FileTags()
        tags.title = field(3, 30)
        tags.artist = field(33, 30)
        tags.album = field(63, 30)
        tags.year = TagReader.year(field(93, 4))
        if tag.byte(125) == 0, tag.byte(126) != 0 { tags.trackNumber = Int(tag.byte(126)) }
        let genre = Int(tag.byte(127))
        if genre < genreNames.count { tags.genres = [genreNames[genre]] }
        return tags
    }

    private static func parseFrames(_ body: Data, from start: Int, major: Int, wantArtwork: Bool) -> Result {
        var result = Result()
        var position = start
        let idLength = major == 2 ? 3 : 4
        let headerLength = major == 2 ? 6 : 10
        var year: String?
        var originalYear: String?
        while position + headerLength <= body.count {
            let id = body.ascii(position, idLength)
            guard id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }), id.first != "\0", !id.isEmpty else { break }
            let size: Int
            var frameFlags: UInt16 = 0
            switch major {
            case 2: size = Int(body.uint24BE(position + 3))
            case 3: size = Int(body.uint32BE(position + 4)); frameFlags = body.uint16BE(position + 8)
            default: size = syncsafe(body, position + 4); frameFlags = body.uint16BE(position + 8)
            }
            let dataStart = position + headerLength
            guard size > 0, dataStart + size <= body.count else { break }
            var data = body.slice(dataStart, size)
            if major == 4 {
                if frameFlags & 0x0001 != 0 { data = data.slice(4, data.count - 4) } // data length indicator
                if frameFlags & 0x0002 != 0 { data = deunsynchronise(data) }
            }
            // Compressed or encrypted frames are skipped.
            let unusable = major == 3 ? frameFlags & 0x00C0 != 0 : major == 4 ? frameFlags & 0x000C != 0 : false
            if !unusable {
                let key = major == 2 ? v22ToV23[id] ?? id : id
                switch key {
                case "TIT2": result.tags.title = text(data)
                case "TPE1": result.tags.artist = text(data)
                case "TPE2": result.tags.albumArtist = text(data)
                case "TALB": result.tags.album = text(data)
                case "TRCK": result.tags.trackNumber = TagReader.leadingNumber(text(data))
                case "TPOS": result.tags.discNumber = TagReader.leadingNumber(text(data))
                case "TYER", "TDRC": year = year ?? text(data)
                case "TDOR", "TORY": originalYear = originalYear ?? text(data)
                case "TCON": result.tags.genres = genres(texts(data))
                case "TBPM": result.tags.bpmText = text(data)
                case "TCOM": result.tags.composer = text(data)
                case "TCMP": result.tags.isCompilation = text(data) == "1"
                case "USLT": if result.tags.lyrics == nil { result.tags.lyrics = lyrics(data) }
                case "APIC", "PIC":
                    result.tags.hasArtwork = true
                    if wantArtwork, let picture = picture(data, v22: major == 2) {
                        if result.artwork == nil || picture.front { result.artwork = picture.data }
                    }
                default: break
                }
            }
            position = dataStart + size
        }
        result.tags.year = TagReader.year(year) ?? TagReader.year(originalYear)
        return result
    }

    private static let v22ToV23: [String: String] = [
        "TT2": "TIT2", "TP1": "TPE1", "TP2": "TPE2", "TAL": "TALB", "TRK": "TRCK", "TPA": "TPOS",
        "TYE": "TYER", "TOR": "TORY", "TCO": "TCON", "TBP": "TBPM", "TCM": "TCOM", "TCP": "TCMP", "ULT": "USLT", "PIC": "PIC",
    ]

    static func syncsafe(_ data: Data, _ at: Int) -> Int {
        (Int(data.byte(at) & 0x7F) << 21) | (Int(data.byte(at + 1) & 0x7F) << 14)
            | (Int(data.byte(at + 2) & 0x7F) << 7) | Int(data.byte(at + 3) & 0x7F)
    }

    static func deunsynchronise(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var previous: UInt8 = 0
        for byte in data {
            if previous == 0xFF && byte == 0x00 {
                previous = byte
                continue
            }
            out.append(byte)
            previous = byte
        }
        return out
    }

    private static func encoding(_ byte: UInt8) -> String.Encoding {
        switch byte {
        case 1: return .utf16
        case 2: return .utf16BigEndian
        case 3: return .utf8
        default: return .isoLatin1
        }
    }

    /// Splits [data] (text after the encoding byte) at the encoding's terminator.
    private static func decodeStrings(_ data: Data, encoding byte: UInt8) -> [String] {
        let wide = byte == 1 || byte == 2
        var parts: [Data] = []
        var current = Data()
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            if wide {
                if i + 1 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0 {
                    parts.append(current)
                    current = Data()
                    i += 2
                    continue
                }
                current.append(bytes[i])
                if i + 1 < bytes.count { current.append(bytes[i + 1]) }
                i += 2
            } else {
                if bytes[i] == 0 {
                    parts.append(current)
                    current = Data()
                } else {
                    current.append(bytes[i])
                }
                i += 1
            }
        }
        parts.append(current)
        let encodingToUse = encoding(byte)
        return parts.compactMap { part -> String? in
            guard !part.isEmpty else { return nil }
            // UTF-16 with BOM: each string carries its own; without one, assume little endian.
            if byte == 1, part.count >= 2 {
                if part.byte(0) == 0xFF, part.byte(1) == 0xFE { return String(data: part.slice(2, part.count - 2), encoding: .utf16LittleEndian) }
                if part.byte(0) == 0xFE, part.byte(1) == 0xFF { return String(data: part.slice(2, part.count - 2), encoding: .utf16BigEndian) }
                return String(data: part, encoding: .utf16LittleEndian)
            }
            return String(data: part, encoding: encodingToUse) ?? String(data: part, encoding: .isoLatin1)
        }
    }

    static func texts(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        return decodeStrings(data.slice(1, data.count - 1), encoding: data.byte(0)).map(\.trimmed).filter { !$0.isEmpty }
    }

    static func text(_ data: Data) -> String? {
        texts(data).first
    }

    /// TCON values: names, "(17)" / "17" ID3v1 numbers, "(17)Rock" refinements, "RX"/"CR".
    static func genres(_ values: [String]) -> [String] {
        var out: [String] = []
        for value in values {
            var rest = Substring(value)
            while rest.hasPrefix("(") {
                guard let close = rest.firstIndex(of: ")") else { break }
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let number = Int(inner), number < genreNames.count {
                    out.append(genreNames[number])
                } else if inner == "RX" {
                    out.append("Remix")
                } else if inner == "CR" {
                    out.append("Cover")
                }
                rest = rest[rest.index(after: close)...]
            }
            let remainder = String(rest).trimmed
            if !remainder.isEmpty {
                if let number = Int(remainder), number < genreNames.count {
                    out.append(genreNames[number])
                } else {
                    out.append(remainder)
                }
            }
        }
        return Genres.normalize(out.map { Optional($0) })
    }

    private static func lyrics(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        // encoding(1) language(3) descriptor\0 text
        let parts = decodeStrings(data.slice(4, data.count - 4), encoding: data.byte(0))
        guard parts.count >= 2 else { return parts.first?.nonBlank }
        return parts.dropFirst().joined(separator: "\n").nonBlank
    }

    private static func picture(_ data: Data, v22: Bool) -> (data: Data, front: Bool)? {
        guard data.count > 4 else { return nil }
        let encodingByte = data.byte(0)
        var position = 1
        if v22 {
            position += 3 // image format
        } else {
            while position < data.count, data.byte(position) != 0 { position += 1 } // MIME type
            position += 1
        }
        let pictureType = data.byte(position)
        position += 1
        // Description, terminated per encoding.
        if encodingByte == 1 || encodingByte == 2 {
            while position + 1 < data.count, !(data.byte(position) == 0 && data.byte(position + 1) == 0) { position += 2 }
            position += 2
        } else {
            while position < data.count, data.byte(position) != 0 { position += 1 }
            position += 1
        }
        guard position < data.count else { return nil }
        return (data.slice(position, data.count - position), pictureType == 3)
    }

    /// The ID3v1 genre list (with Winamp extensions).
    static let genreNames = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies",
        "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
        "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
        "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
        "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing",
        "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock",
        "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech",
        "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam",
        "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
        "Drum Solo", "A capella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie",
        "BritPop", "Negerpunk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover",
        "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop", "Synthpop",
    ]
}
