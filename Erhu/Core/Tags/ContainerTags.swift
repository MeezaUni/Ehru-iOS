import Foundation

/// iTunes-style metadata in MP4/M4A files: moov › udta › meta › ilst.
enum MP4Tags {
    struct Result {
        var tags = FileTags()
        var artwork: Data?
    }

    static func read(_ source: ByteSource, wantArtwork: Bool = false) -> Result {
        guard let moov = findAtom("moov", in: source, from: 0, to: source.size) else { return Result() }
        guard let udta = findAtom("udta", in: source, from: moov.bodyStart, to: moov.end),
              let meta = findAtom("meta", in: source, from: udta.bodyStart, to: udta.end)
        else { return Result() }
        // "meta" is a full atom: 4 bytes of version and flags before its children.
        guard let ilst = findAtom("ilst", in: source, from: meta.bodyStart + 4, to: meta.end) else { return Result() }
        var result = Result()
        var year: String?
        var offset = ilst.bodyStart
        while offset + 8 <= ilst.end {
            let header = source.read(8, at: offset)
            let size = UInt64(header.uint32BE(0))
            guard size >= 8, offset + size <= ilst.end else { break }
            let name = header.slice(4, 4)
            let key = String(decoding: name.map { $0 == 0xA9 ? UInt8(ascii: "@") : $0 }, as: UTF8.self)
            let isArtwork = key == "covr"
            do {
                // Artwork can be megabytes: only read it when asked for.
                let item = isArtwork && !wantArtwork ? Data() : source.read(Int(size - 8), at: offset + 8)
                switch key {
                case "@nam": result.tags.title = dataString(item)
                case "@ART": result.tags.artist = dataString(item)
                case "aART": result.tags.albumArtist = dataString(item)
                case "@alb": result.tags.album = dataString(item)
                case "@day": year = dataString(item)
                case "@gen": result.tags.genres = Genres.parse(dataString(item))
                case "gnre":
                    if let payload = dataPayload(item), payload.count >= 2 {
                        let index = Int(payload.uint16BE(0)) - 1
                        if index >= 0, index < ID3.genreNames.count { result.tags.genres = [ID3.genreNames[index]] }
                    }
                case "@wrt": result.tags.composer = dataString(item)
                case "@lyr": result.tags.lyrics = dataString(item)
                case "trkn": if let payload = dataPayload(item), payload.count >= 4 { result.tags.trackNumber = Int(payload.uint16BE(2)).nonZero }
                case "disk": if let payload = dataPayload(item), payload.count >= 4 { result.tags.discNumber = Int(payload.uint16BE(2)).nonZero }
                case "tmpo": if let payload = dataPayload(item), payload.count >= 2 { result.tags.bpmText = String(payload.uint16BE(0)) }
                case "cpil": if let payload = dataPayload(item), !payload.isEmpty { result.tags.isCompilation = payload.byte(0) != 0 }
                case "covr":
                    result.tags.hasArtwork = true
                    if wantArtwork, result.artwork == nil { result.artwork = dataPayload(item) }
                default: break
                }
            }
            offset += size
        }
        result.tags.year = TagReader.year(year)
        result.tags.dateText = year
        return result
    }

    struct Atom {
        let bodyStart: UInt64
        let end: UInt64
    }

    /// The first child atom called [name] between [from] and [to].
    static func findAtom(_ name: String, in source: ByteSource, from: UInt64, to: UInt64) -> Atom? {
        var offset = from
        while offset + 8 <= to {
            let header = source.read(16, at: offset)
            var size = UInt64(header.uint32BE(0))
            var headerSize: UInt64 = 8
            if size == 1 {
                size = header.uint64BE(8)
                headerSize = 16
            } else if size == 0 {
                size = to - offset
            }
            guard size >= headerSize else { return nil }
            if header.ascii(4, 4) == name {
                return Atom(bodyStart: offset + headerSize, end: min(offset + size, to))
            }
            offset += size
        }
        return nil
    }

    /// The payload of the first "data" atom inside an ilst item (after its type and locale).
    private static func dataPayload(_ item: Data) -> Data? {
        var offset = 0
        while offset + 16 <= item.count {
            let size = Int(item.uint32BE(offset))
            guard size >= 16, offset + size <= item.count else { return nil }
            if item.ascii(offset + 4, 4) == "data" {
                return item.slice(offset + 16, size - 16)
            }
            offset += size
        }
        return nil
    }

    private static func dataString(_ item: Data) -> String? {
        dataPayload(item).flatMap { String(data: $0, encoding: .utf8) }?.trimmed.nonBlank
    }
}

/// FLAC: STREAMINFO, Vorbis comments and PICTURE blocks.
enum FLACTags {
    struct Result {
        var tags = FileTags()
        var artwork: Data?
        var sampleRate = 0
        var channels = 0
        var totalSamples: UInt64 = 0
    }

    static func read(_ source: ByteSource, wantArtwork: Bool = false) -> Result {
        var offset: UInt64 = 0
        // FLAC files may start with an ID3v2 tag.
        let head = source.read(10, at: 0)
        if head.ascii(0, 3) == "ID3" { offset = UInt64(ID3.syncsafe(head, 6)) + 10 }
        guard source.read(4, at: offset).ascii(0, 4) == "fLaC" else { return Result() }
        offset += 4
        var result = Result()
        var last = false
        while !last && offset + 4 <= source.size {
            let header = source.read(4, at: offset)
            last = header.byte(0) & 0x80 != 0
            let type = header.byte(0) & 0x7F
            let length = Int(header.uint24BE(1))
            let bodyOffset = offset + 4
            switch type {
            case 0:
                let info = source.read(length, at: bodyOffset)
                if info.count >= 18 {
                    result.sampleRate = Int(info.uint24BE(10) >> 4)
                    result.channels = Int((info.byte(12) >> 1) & 0x07) + 1
                    result.totalSamples = (UInt64(info.byte(13) & 0x0F) << 32) | UInt64(info.uint32BE(14))
                }
            case 4:
                result.tags = vorbisComments(source.read(min(length, TagReader.maxBytes()), at: bodyOffset), into: result.tags)
            case 6:
                result.tags.hasArtwork = true
                if wantArtwork {
                    let picture = source.read(min(length, TagReader.maxBytes()), at: bodyOffset)
                    if let parsed = pictureBlock(picture), result.artwork == nil || parsed.front { result.artwork = parsed.data }
                }
            default: break
            }
            offset = bodyOffset + UInt64(length)
        }
        return result
    }

    /// Vorbis comments (little-endian lengths): vendor, then KEY=value pairs.
    static func vorbisComments(_ data: Data, into initial: FileTags) -> FileTags {
        var tags = initial
        var position = 0
        let vendorLength = Int(data.uint32LE(position))
        position += 4 + vendorLength
        let count = Int(data.uint32LE(position))
        position += 4
        var genres: [String] = []
        var date: String?
        var lyrics: String?
        for _ in 0..<min(count, 10_000) {
            guard position + 4 <= data.count else { break }
            let length = Int(data.uint32LE(position))
            position += 4
            guard length >= 0, position + length <= data.count else { break }
            let comment = String(decoding: data.slice(position, length), as: UTF8.self)
            position += length
            guard let equals = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<equals].uppercased()
            let value = String(comment[comment.index(after: equals)...]).trimmed
            guard !value.isEmpty else { continue }
            switch key {
            case "TITLE": tags.title = tags.title ?? value
            case "ARTIST": tags.artist = tags.artist ?? value
            case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": tags.albumArtist = tags.albumArtist ?? value
            case "ALBUM": tags.album = tags.album ?? value
            case "TRACKNUMBER": tags.trackNumber = tags.trackNumber ?? TagReader.leadingNumber(value)
            case "DISCNUMBER": tags.discNumber = tags.discNumber ?? TagReader.leadingNumber(value)
            case "DATE", "YEAR", "ORIGINALDATE": date = date ?? value
            case "GENRE": genres.append(value)
            case "BPM", "TEMPO": tags.bpmText = tags.bpmText ?? value
            case "COMPOSER": tags.composer = tags.composer ?? value
            case "LYRICS", "UNSYNCEDLYRICS": lyrics = lyrics ?? value
            case "COMPILATION": tags.isCompilation = value == "1"
            case "METADATA_BLOCK_PICTURE": tags.hasArtwork = true
            default: break
            }
        }
        if !genres.isEmpty { tags.genres = Genres.normalize(genres.flatMap { Genres.parse($0) }.map { Optional($0) }) }
        tags.year = tags.year ?? TagReader.year(date)
        tags.dateText = tags.dateText ?? date
        tags.lyrics = tags.lyrics ?? lyrics
        return tags
    }

    /// A FLAC PICTURE block: type, MIME, description, size, then the image.
    static func pictureBlock(_ data: Data) -> (data: Data, front: Bool)? {
        var position = 0
        let type = data.uint32BE(position)
        position += 4
        let mimeLength = Int(data.uint32BE(position))
        position += 4 + mimeLength
        let descriptionLength = Int(data.uint32BE(position))
        position += 4 + descriptionLength + 16
        let length = Int(data.uint32BE(position))
        position += 4
        guard length > 0, position + length <= data.count else { return nil }
        return (data.slice(position, length), type == 3)
    }
}

/// WAV: an "id3 " chunk, else LIST/INFO text.
enum RIFFTags {
    static func read(_ source: ByteSource, wantArtwork: Bool = false) -> ID3.Result {
        let head = source.read(12, at: 0)
        guard head.ascii(0, 4) == "RIFF", head.ascii(8, 4) == "WAVE" else { return ID3.Result() }
        var offset: UInt64 = 12
        var info = FileTags()
        var id3: ID3.Result?
        while offset + 8 <= source.size {
            let header = source.read(8, at: offset)
            let id = header.ascii(0, 4)
            let size = UInt64(header.uint32LE(4))
            let body = offset + 8
            if id.lowercased() == "id3 " {
                id3 = ID3.read(source, at: body, wantArtwork: wantArtwork)
            } else if id == "LIST", source.read(4, at: body).ascii(0, 4) == "INFO" {
                info = infoChunk(source.read(Int(min(size, 1_000_000)) - 4, at: body + 4))
            }
            offset = body + size + (size % 2)
        }
        guard var result = id3 else { return ID3.Result(tags: info, artwork: nil) }
        result.tags.fillMissing(from: info)
        return result
    }

    private static func infoChunk(_ data: Data) -> FileTags {
        var tags = FileTags()
        var position = 0
        while position + 8 <= data.count {
            let id = data.ascii(position, 4)
            let size = Int(data.uint32LE(position + 4))
            let value = String(data: data.slice(position + 8, size).prefix { $0 != 0 }, encoding: .utf8)?.trimmed.nonBlank
            switch id {
            case "INAM": tags.title = value
            case "IART": tags.artist = value
            case "IPRD": tags.album = value
            case "ICRD": tags.year = TagReader.year(value)
            case "IGNR": tags.genres = Genres.parse(value)
            case "ITRK", "IPRT": tags.trackNumber = TagReader.leadingNumber(value)
            default: break
            }
            position += 8 + size + (size % 2)
        }
        return tags
    }
}

/// AIFF: an "ID3 " chunk.
enum AIFFTags {
    static func read(_ source: ByteSource, wantArtwork: Bool = false) -> ID3.Result {
        let head = source.read(12, at: 0)
        guard head.ascii(0, 4) == "FORM" else { return ID3.Result() }
        var offset: UInt64 = 12
        while offset + 8 <= source.size {
            let header = source.read(8, at: offset)
            let size = UInt64(header.uint32BE(4))
            if header.ascii(0, 4).uppercased() == "ID3 " {
                return ID3.read(source, at: offset + 8, wantArtwork: wantArtwork)
            }
            offset += 8 + size + (size % 2)
        }
        return ID3.Result()
    }
}

extension Int {
    /// nil for 0 (an unset track or disc number).
    var nonZero: Int? { self == 0 ? nil : self }
}
