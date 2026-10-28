import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A tag edit for one audio file. Nil fields are left exactly as they are in the file; only
/// non-nil fields are written, and the clear flags remove a field.
struct TagWriteRequest: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var year: Int?
    /// A full or partial release date ("2010-11-19", "2010-11", "2010") written as the date tag;
    /// takes the place of [year].
    var releaseDate: String?
    /// One or more genres ("Electronic; Synth-pop"), kept as separate values where the format allows it.
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var bpm: Int?
    var lyrics: String?
    var artwork: Data?
    var clearTitle = false
    var clearArtist = false
    var clearAlbum = false
    var clearYear = false
    var clearGenre = false
    var clearArtwork = false

    var hasChanges: Bool {
        title != nil || artist != nil || album != nil || year != nil || releaseDate != nil || genre != nil
            || trackNumber != nil || discNumber != nil || bpm != nil || lyrics != nil || artwork != nil
            || clearTitle || clearArtist || clearAlbum || clearYear || clearGenre || clearArtwork
    }

    /// The date tag value to write, if any.
    var dateValue: String? { releaseDate ?? year.map(String.init) }

    /// The genres to write, or nil when the request sets none.
    var genres: [String]? {
        let parsed = Genres.parse(genre)
        return parsed.isEmpty ? nil : parsed
    }

    /// What happens to a text field: kept, set, or removed (a blank value removes it too).
    func change(_ value: String?, cleared: Bool) -> TextChange {
        if cleared || value?.trimmed.isEmpty == true { return .remove }
        return value.map { .set($0) } ?? .keep
    }

    enum TextChange: Equatable {
        case keep
        case set(String)
        case remove
    }
}

enum TagWriteError: LocalizedError, Equatable {
    case nothingToWrite
    case unsupportedFormat(String)
    case unreadable(String)
    case verificationFailed(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .nothingToWrite: "Nothing to write."
        case .unsupportedFormat(let detail): "This file's format can't be tagged (\(detail))."
        case .unreadable(let detail): "The file couldn't be read (\(detail))."
        case .verificationFailed(let detail): "Tags couldn't be written: \(detail). The file was not changed."
        case .io(let detail): "The file couldn't be saved (\(detail))."
        }
    }
}

/// Writes tags into MP3 (ID3v2.4), MP4/M4A (iTunes atoms) and FLAC (Vorbis comments, PICTURE).
/// The original is never touched until a verified edited copy exists:
///  1. the file is rewritten into a temporary copy next to it, with only the requested changes;
///  2. the copy is read back with [TagReader] and every requested field checked;
///  3. the copy replaces the original in one atomic swap.
/// Audio data is copied byte for byte; tags the request doesn't name are kept.
enum TagWriter {
    /// Embedded artwork is scaled to fit this many pixels and saved as JPEG (as on Android).
    static let maxArtworkPixels = 1440

    static func write(_ request: TagWriteRequest, to url: URL) throws {
        guard request.hasChanges else { throw TagWriteError.nothingToWrite }
        var request = request
        if let artwork = request.artwork { request.artwork = ArtworkEncoder.prepare(artwork) }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let input = try? FileHandle(forReadingFrom: url) else { throw TagWriteError.unreadable("can't open") }
        defer { try? input.close() }
        let source = ByteSource(file: input)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let output = try? FileHandle(forWritingTo: temp)
        else { throw TagWriteError.io("can't create a temporary copy") }
        do {
            defer { try? output.close() }
            switch format(of: url, source) {
            case .mp3: try ID3Writer.rewrite(source, request, into: output)
            case .mp4: try MP4Writer.rewrite(source, request, into: output)
            case .flac: try FLACWriter.rewrite(source, request, into: output)
            case .other(let ext): throw TagWriteError.unsupportedFormat(ext.isEmpty ? "unknown" : ext)
            }
        }
        try verify(temp, request)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            throw TagWriteError.io(error.localizedDescription)
        }
    }

    enum Format: Equatable {
        case mp3, mp4, flac
        case other(String)
    }

    static func format(of url: URL, _ source: ByteSource) -> Format {
        let ext = url.pathExtension.lowercased()
        let head = source.read(12, at: 0)
        switch ext {
        case "mp3": return .mp3
        case "m4a", "mp4", "aac", "alac", "m4b": return head.ascii(4, 4) == "ftyp" ? .mp4 : .other(ext)
        case "flac": return .flac
        default: return .other(ext)
        }
    }

    /// Re-reads the edited copy so a silently broken write never reaches the original.
    static func verify(_ url: URL, _ request: TagWriteRequest) throws {
        let tags = TagReader.read(url)
        func check(_ name: String, _ actual: String?, _ change: TagWriteRequest.TextChange) throws {
            switch change {
            case .keep: return
            case .remove:
                if let actual, !actual.isEmpty { throw TagWriteError.verificationFailed("\(name) still reads '\(actual)' after removing it") }
            case .set(let value):
                if actual != value.trimmed { throw TagWriteError.verificationFailed("wrote \(name) '\(value)', the file reads '\(actual ?? "")'") }
            }
        }
        try check("title", tags.title, request.change(request.title, cleared: request.clearTitle))
        try check("artist", tags.artist, request.change(request.artist, cleared: request.clearArtist))
        try check("album", tags.album, request.change(request.album, cleared: request.clearAlbum))
        if request.clearYear {
            if tags.dateText != nil { throw TagWriteError.verificationFailed("the date still reads '\(tags.dateText!)' after removing it") }
        } else if let date = request.dateValue, tags.dateText != date {
            // A format that changes the date would store one nobody gave: refuse instead.
            throw TagWriteError.verificationFailed("wrote the date '\(date)', the file reads '\(tags.dateText ?? "")'")
        }
        if request.clearGenre {
            if !tags.genres.isEmpty { throw TagWriteError.verificationFailed("genres remain after removing them") }
        } else if let genres = request.genres, tags.genres != genres {
            throw TagWriteError.verificationFailed("wrote genres \(genres), the file reads \(tags.genres)")
        }
        if let bpm = request.bpm, usableBpm(tags.bpmText) != bpm {
            throw TagWriteError.verificationFailed("wrote BPM \(bpm), the file reads '\(tags.bpmText ?? "")'")
        }
        if let track = request.trackNumber, tags.trackNumber != track {
            throw TagWriteError.verificationFailed("wrote track \(track), the file reads \(tags.trackNumber.map(String.init) ?? "none")")
        }
        if let disc = request.discNumber, tags.discNumber != disc {
            throw TagWriteError.verificationFailed("wrote disc \(disc), the file reads \(tags.discNumber.map(String.init) ?? "none")")
        }
        if let lyrics = request.lyrics, !lyrics.trimmed.isEmpty, tags.lyrics?.trimmed != lyrics.trimmed {
            throw TagWriteError.verificationFailed("the lyrics didn't read back")
        }
        if request.clearArtwork, tags.hasArtwork { throw TagWriteError.verificationFailed("artwork remains after removing it") }
        if let artwork = request.artwork, TagReader.artwork(url) != artwork {
            throw TagWriteError.verificationFailed("the artwork didn't read back")
        }
    }

    /// Copies [source] from [offset] to its end into [output], in chunks.
    static func copyRest(_ source: ByteSource, from offset: UInt64, to end: UInt64? = nil, into output: FileHandle) throws {
        let stop = end ?? source.size
        var position = offset
        let chunk = 4 * 1024 * 1024
        while position < stop {
            let data = source.read(Int(min(UInt64(chunk), stop - position)), at: position)
            guard !data.isEmpty else { throw TagWriteError.unreadable("the audio data ended early") }
            try output.write(contentsOf: data)
            position += UInt64(data.count)
        }
    }
}

/// Artwork as it is embedded: scaled to fit [TagWriter.maxArtworkPixels], JPEG.
enum ArtworkEncoder {
    static func prepare(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: TagWriter.maxArtworkPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : data
    }

    static func mimeType(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}

// MARK: - Byte helpers

extension Data {
    static func be32(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    static func be64(_ value: UInt64) -> Data {
        be32(Int(value >> 32)) + be32(Int(value & 0xFFFF_FFFF))
    }

    static func le32(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
              UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }

    static func be24(_ value: Int) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    static func syncsafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }
}

// MARK: - ID3v2.4

/// Rewrites an MP3's ID3v2 tag as ID3v2.4, keeping every frame the request doesn't touch.
enum ID3Writer {
    struct Frame: Equatable {
        let id: String
        var data: Data
    }

    /// Padding left in the new tag, so later edits by other apps can happen in place.
    static let padding = 2048

    static func rewrite(_ source: ByteSource, _ request: TagWriteRequest, into output: FileHandle) throws {
        let existing = try readFrames(source)
        var frames = existing.frames
        if existing.audioStart == 0, let v1 = ID3.readV1(source) { frames = seed(from: v1) }
        frames = apply(request, to: frames)
        try output.write(contentsOf: tag(frames))
        // An ID3v1 tag at the end is dropped: its fields now live in the v2 tag (and an old v1
        // title would otherwise come back after the v2 one is cleared).
        let end = source.size >= 128 && source.read(3, at: source.size - 128).ascii(0, 3) == "TAG" ? source.size - 128 : source.size
        try TagWriter.copyRest(source, from: existing.audioStart, to: end, into: output)
    }

    /// The frames of the file's ID3v2 tag (as v2.4 frames) and where the audio starts.
    static func readFrames(_ source: ByteSource) throws -> (frames: [Frame], audioStart: UInt64) {
        let header = source.read(10, at: 0)
        guard header.count == 10, header.ascii(0, 3) == "ID3" else { return ([], 0) }
        let major = Int(header.byte(3))
        let flags = header.byte(5)
        let size = ID3.syncsafe(header, 6)
        let footer: UInt64 = major == 4 && flags & 0x10 != 0 ? 10 : 0
        let audioStart = 10 + UInt64(size) + footer
        guard major == 3 || major == 4 else {
            throw TagWriteError.unsupportedFormat("ID3v2.\(major) tag; save it as ID3v2.3 or 2.4 in another app first")
        }
        var body = source.read(size, at: 10)
        guard body.count == size else { throw TagWriteError.unreadable("the ID3 tag is cut short") }
        if flags & 0x80 != 0 && major == 3 { body = ID3.deunsynchronise(body) }
        var position = 0
        if flags & 0x40 != 0 { position = major == 3 ? Int(body.uint32BE(0)) + 4 : ID3.syncsafe(body, 0) }
        var frames: [Frame] = []
        var tyer: String?
        var tdat: String?
        while position + 10 <= body.count {
            let id = body.ascii(position, 4)
            guard id.count == 4, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { break }
            let frameSize = major == 3 ? Int(body.uint32BE(position + 4)) : ID3.syncsafe(body, position + 4)
            let frameFlags = body.uint16BE(position + 8)
            let start = position + 10
            guard frameSize >= 0, start + frameSize <= body.count else { break }
            position = start + frameSize
            var data = body.slice(start, frameSize)
            if major == 3 {
                if frameFlags & 0x00C0 != 0 { continue } // compressed or encrypted: can't be carried over
                if frameFlags & 0x0020 != 0 { data = data.slice(1, data.count - 1) } // grouping id
            } else {
                if frameFlags & 0x000C != 0 { continue }
                if frameFlags & 0x0040 != 0 { data = data.slice(1, data.count - 1) }
                if frameFlags & 0x0001 != 0 { data = data.slice(4, data.count - 4) }
                if frameFlags & 0x0002 != 0 { data = ID3.deunsynchronise(data) }
            }
            switch id {
            // ID3v2.3 date frames become one v2.4 TDRC.
            case "TYER": tyer = ID3.text(data)
            case "TDAT": tdat = ID3.text(data)
            case "TIME", "TRDA", "TSIZ": continue
            case "TORY": frames.append(Frame(id: "TDOR", data: data))
            default: frames.append(Frame(id: id, data: data))
            }
        }
        if let tyer, !frames.contains(where: { $0.id == "TDRC" }) {
            var date = tyer
            if let tdat, tdat.count == 4, let day = Int(tdat.prefix(2)), let month = Int(tdat.suffix(2)),
               (1...12).contains(month), (1...31).contains(day) {
                date += String(format: "-%02d-%02d", month, day)
            }
            frames.append(text("TDRC", date))
        }
        return (frames, audioStart)
    }

    /// Frames for a file that only has an ID3v1 tag, so its values aren't lost.
    static func seed(from v1: FileTags) -> [Frame] {
        var frames: [Frame] = []
        if let title = v1.title { frames.append(text("TIT2", title)) }
        if let artist = v1.artist { frames.append(text("TPE1", artist)) }
        if let album = v1.album { frames.append(text("TALB", album)) }
        if let year = v1.year { frames.append(text("TDRC", String(year))) }
        if let track = v1.trackNumber { frames.append(text("TRCK", String(track))) }
        if !v1.genres.isEmpty { frames.append(texts("TCON", v1.genres)) }
        return frames
    }

    static func apply(_ request: TagWriteRequest, to original: [Frame]) -> [Frame] {
        var frames = original
        func replace(_ id: String, with frame: Frame) {
            // The new frame takes the place of the first old one; any duplicates go.
            if let index = frames.firstIndex(where: { $0.id == id }) {
                frames.removeAll { $0.id == id }
                frames.insert(frame, at: min(index, frames.count))
            } else {
                frames.append(frame)
            }
        }
        func setText(_ id: String, _ change: TagWriteRequest.TextChange) {
            switch change {
            case .keep: return
            case .remove: frames.removeAll { $0.id == id }
            case .set(let value): replace(id, with: text(id, value.trimmed))
            }
        }
        setText("TIT2", request.change(request.title, cleared: request.clearTitle))
        setText("TPE1", request.change(request.artist, cleared: request.clearArtist))
        setText("TALB", request.change(request.album, cleared: request.clearAlbum))
        if request.clearYear {
            frames.removeAll { ["TDRC", "TYER", "TDAT", "TDOR", "TORY"].contains($0.id) }
        } else if let date = request.dateValue {
            replace("TDRC", with: text("TDRC", date))
        }
        if request.clearGenre {
            frames.removeAll { $0.id == "TCON" }
        } else if let genres = request.genres {
            replace("TCON", with: texts("TCON", genres))
        }
        if let track = request.trackNumber {
            // Keeps a "/total" the file already has.
            let total = frames.first { $0.id == "TRCK" }.flatMap { ID3.text($0.data) }?.split(separator: "/").dropFirst().first
                .flatMap { Int($0).flatMap { $0 >= track ? String($0) : nil } }
            replace("TRCK", with: text("TRCK", total.map { "\(track)/\($0)" } ?? String(track)))
        }
        if let bpm = request.bpm { replace("TBPM", with: text("TBPM", String(bpm))) }
        if let disc = request.discNumber {
            let total = frames.first { $0.id == "TPOS" }.flatMap { ID3.text($0.data) }?.split(separator: "/").dropFirst().first
                .flatMap { Int($0).flatMap { $0 >= disc ? String($0) : nil } }
            replace("TPOS", with: text("TPOS", total.map { "\(disc)/\($0)" } ?? String(disc)))
        }
        if let lyrics = request.lyrics, !lyrics.trimmed.isEmpty {
            frames.removeAll { $0.id == "USLT" }
            frames.append(Frame(id: "USLT", data: Data([3]) + Data("eng".utf8) + Data([0]) + Data(lyrics.utf8)))
        }
        if request.clearArtwork {
            frames.removeAll { $0.id == "APIC" }
        } else if let artwork = request.artwork {
            frames.removeAll { $0.id == "APIC" }
            let mime = Data(ArtworkEncoder.mimeType(artwork).utf8)
            frames.append(Frame(id: "APIC", data: Data([3]) + mime + Data([0, 3, 0]) + artwork))
        }
        return frames
    }

    static func text(_ id: String, _ value: String) -> Frame { Frame(id: id, data: Data([3]) + Data(value.utf8)) }

    /// A v2.4 text frame with several values (NUL-separated).
    static func texts(_ id: String, _ values: [String]) -> Frame {
        Frame(id: id, data: Data([3]) + Data(values.joined(separator: "\u{0}").utf8))
    }

    static func tag(_ frames: [Frame]) -> Data {
        var body = Data()
        for frame in frames where !frame.data.isEmpty {
            body += Data(frame.id.utf8) + Data.syncsafe(frame.data.count) + Data([0, 0]) + frame.data
        }
        body += Data(repeating: 0, count: padding)
        return Data("ID3".utf8) + Data([4, 0, 0]) + Data.syncsafe(body.count) + body
    }
}

// MARK: - MP4

/// Rewrites an MP4's moov › udta › meta › ilst, moving chunk offsets when moov sits before the media data.
enum MP4Writer {
    struct Box {
        let type: String
        let offset: UInt64
        let size: UInt64
        let headerSize: UInt64
        var end: UInt64 { offset + size }
    }

    /// Top-level boxes of the file.
    static func topLevel(_ source: ByteSource) throws -> [Box] {
        var boxes: [Box] = []
        var offset: UInt64 = 0
        while offset + 8 <= source.size {
            let header = source.read(16, at: offset)
            var size = UInt64(header.uint32BE(0))
            var headerSize: UInt64 = 8
            if size == 1 {
                size = header.uint64BE(8)
                headerSize = 16
            } else if size == 0 {
                size = source.size - offset
            }
            guard size >= headerSize, offset + size <= source.size else { throw TagWriteError.unreadable("a broken MP4 box") }
            boxes.append(Box(type: header.ascii(4, 4), offset: offset, size: size, headerSize: headerSize))
            offset += size
        }
        return boxes
    }

    static func rewrite(_ source: ByteSource, _ request: TagWriteRequest, into output: FileHandle) throws {
        let boxes = try topLevel(source)
        guard let moov = boxes.first(where: { $0.type == "moov" }) else { throw TagWriteError.unreadable("no moov box") }
        guard !boxes.contains(where: { $0.type == "moof" }) else { throw TagWriteError.unsupportedFormat("fragmented MP4") }
        guard moov.size < 64 * 1024 * 1024 else { throw TagWriteError.unsupportedFormat("a very large moov box") }
        let oldBody = source.read(Int(moov.size - moov.headerSize), at: moov.offset + moov.headerSize)
        var newBody = try rebuildMoov(oldBody, request)
        let mediaAfter = boxes.contains { $0.type == "mdat" && $0.offset > moov.offset }
        let delta = Int64(newBody.count + 8) - Int64(moov.size)
        if mediaAfter && delta != 0 { newBody = try shiftChunkOffsets(newBody, by: delta) }
        try TagWriter.copyRest(source, from: 0, to: moov.offset, into: output)
        try output.write(contentsOf: Data.be32(newBody.count + 8) + Data("moov".utf8) + newBody)
        try TagWriter.copyRest(source, from: moov.end, into: output)
    }

    /// Children of a container body: (type, full box bytes).
    static func children(_ body: Data) throws -> [(type: String, box: Data)] {
        var out: [(type: String, box: Data)] = []
        var position = 0
        while position + 8 <= body.count {
            var size = Int(body.uint32BE(position))
            if size == 1 { size = Int(body.uint64BE(position + 8)) } else if size == 0 { size = body.count - position }
            guard size >= 8, position + size <= body.count else { throw TagWriteError.unreadable("a broken MP4 box") }
            out.append((type: body.ascii(position + 4, 4), box: body.slice(position, size)))
            position += size
        }
        return out
    }

    static func box(_ type: String, _ body: Data) -> Data { Data.be32(body.count + 8) + Data(type.utf8) + body }

    /// The body of a plain 32-bit box (its bytes after the 8-byte header).
    static func body(_ box: Data) -> Data { box.slice(8, box.count - 8) }

    static func rebuildMoov(_ moov: Data, _ request: TagWriteRequest) throws -> Data {
        var items = try children(moov)
        var udtaBody = Data()
        if let index = items.firstIndex(where: { $0.type == "udta" }) {
            udtaBody = body(items[index].box)
            items.remove(at: index)
        }
        var udtaChildren = try children(udtaBody)
        var metaBody = Data([0, 0, 0, 0]) + box("hdlr", Data(repeating: 0, count: 8) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9))
        var metaIndex: Int?
        if let index = udtaChildren.firstIndex(where: { $0.type == "meta" }) {
            metaBody = body(udtaChildren[index].box)
            metaIndex = index
        }
        let versionFlags = metaBody.slice(0, 4)
        var metaChildren = try children(metaBody.slice(4, metaBody.count - 4))
        var ilstBody = Data()
        var ilstIndex: Int?
        if let index = metaChildren.firstIndex(where: { $0.type == "ilst" }) {
            ilstBody = body(metaChildren[index].box)
            ilstIndex = index
        }
        let newIlst = box("ilst", try apply(request, to: ilstBody))
        if let ilstIndex { metaChildren[ilstIndex].box = newIlst } else { metaChildren.append((type: "ilst", box: newIlst)) }
        let newMeta = box("meta", versionFlags + metaChildren.map(\.box).reduce(Data(), +))
        if let metaIndex { udtaChildren[metaIndex].box = newMeta } else { udtaChildren.append((type: "meta", box: newMeta)) }
        let newUdta = box("udta", udtaChildren.map(\.box).reduce(Data(), +))
        return items.map(\.box).reduce(Data(), +) + newUdta
    }

    private static let copyright: UInt8 = 0xA9

    static func key(_ name: String) -> Data {
        Data(name.utf8.map { $0 == UInt8(ascii: "@") ? copyright : $0 })
    }

    /// An ilst item holding one data atom of [type] (1 UTF-8, 0 binary, 21 integer, 13 JPEG, 14 PNG).
    static func item(_ name: String, type: Int, _ payload: Data) -> Data {
        let data = box("data", Data.be32(type) + Data.be32(0) + payload)
        return Data.be32(data.count + 8) + key(name) + data
    }

    static func apply(_ request: TagWriteRequest, to ilst: Data) throws -> Data {
        var items = try children(ilst).map { (name: String(decoding: $0.box.slice(4, 4).map { $0 == copyright ? UInt8(ascii: "@") : $0 }, as: UTF8.self), box: $0.box) }
        func set(_ name: String, _ box: Data?) {
            let index = items.firstIndex { $0.name == name }
            items.removeAll { $0.name == name }
            guard let box else { return }
            items.insert((name: name, box: box), at: min(index ?? items.count, items.count))
        }
        func setText(_ name: String, _ change: TagWriteRequest.TextChange) {
            switch change {
            case .keep: return
            case .remove: set(name, nil)
            case .set(let value): set(name, item(name, type: 1, Data(value.trimmed.utf8)))
            }
        }
        setText("@nam", request.change(request.title, cleared: request.clearTitle))
        setText("@ART", request.change(request.artist, cleared: request.clearArtist))
        setText("@alb", request.change(request.album, cleared: request.clearAlbum))
        if request.clearYear { set("@day", nil) } else if let date = request.dateValue { set("@day", item("@day", type: 1, Data(date.utf8))) }
        if request.clearGenre {
            set("@gen", nil)
            set("gnre", nil)
        } else if let genres = request.genres {
            set("gnre", nil)
            set("@gen", item("@gen", type: 1, Data(genres.joined(separator: Genres.separator).utf8)))
        }
        if let track = request.trackNumber {
            // Keeps the total the file already has.
            // The item's data atom: size, "data", type, locale, then [0, 0, track, total, 0, 0].
            let old = items.first { $0.name == "trkn" }.map { body($0.box) }
            let storedTotal = old.flatMap { $0.count >= 22 ? $0.uint16BE(20) : nil } ?? 0
            let total = Int(storedTotal) >= track ? storedTotal : 0
            let payload = Data([0, 0, UInt8(track >> 8 & 0xFF), UInt8(track & 0xFF), UInt8(total >> 8), UInt8(total & 0xFF), 0, 0])
            set("trkn", item("trkn", type: 0, payload))
        }
        if let bpm = request.bpm { set("tmpo", item("tmpo", type: 21, Data([UInt8(bpm >> 8 & 0xFF), UInt8(bpm & 0xFF)]))) }
        if let disc = request.discNumber {
            let old = items.first { $0.name == "disk" }.map { body($0.box) }
            let storedTotal = old.flatMap { $0.count >= 22 ? $0.uint16BE(20) : nil } ?? 0
            let total = Int(storedTotal) >= disc ? storedTotal : 0
            let payload = Data([0, 0, UInt8(disc >> 8 & 0xFF), UInt8(disc & 0xFF), UInt8(total >> 8), UInt8(total & 0xFF)])
            set("disk", item("disk", type: 0, payload))
        }
        if let lyrics = request.lyrics, !lyrics.trimmed.isEmpty { set("@lyr", item("@lyr", type: 1, Data(lyrics.utf8))) }
        if request.clearArtwork {
            set("covr", nil)
        } else if let artwork = request.artwork {
            set("covr", item("covr", type: ArtworkEncoder.mimeType(artwork) == "image/png" ? 14 : 13, artwork))
        }
        return items.map(\.box).reduce(Data(), +)
    }

    /// Adds [delta] to every stco / co64 entry under moov › trak › mdia › minf › stbl.
    static func shiftChunkOffsets(_ moov: Data, by delta: Int64) throws -> Data {
        try transform(moov, path: ["trak", "mdia", "minf", "stbl"]) { type, box in
            switch type {
            case "stco":
                var out = box
                let count = Int(box.uint32BE(12))
                guard 16 + count * 4 <= box.count else { throw TagWriteError.unreadable("a broken stco box") }
                for i in 0..<count {
                    let at = 16 + i * 4
                    let moved = Int64(box.uint32BE(at)) + delta
                    guard moved >= 0, moved <= Int64(UInt32.max) else { throw TagWriteError.unsupportedFormat("chunk offsets past 4 GB") }
                    out.replaceSubrange(at..<(at + 4), with: Data.be32(Int(moved)))
                }
                return out
            case "co64":
                var out = box
                let count = Int(box.uint32BE(12))
                guard 16 + count * 8 <= box.count else { throw TagWriteError.unreadable("a broken co64 box") }
                for i in 0..<count {
                    let at = 16 + i * 8
                    out.replaceSubrange(at..<(at + 8), with: Data.be64(UInt64(Int64(box.uint64BE(at)) + delta)))
                }
                return out
            default:
                return box
            }
        }
    }

    /// Rebuilds [body] with [change] applied to the leaf boxes found by following [path].
    private static func transform(_ body: Data, path: [String], _ change: (String, Data) throws -> Data) throws -> Data {
        var out = Data()
        for child in try children(body) {
            if let next = path.first {
                if child.type == next {
                    out += box(child.type, try transform(Self.body(child.box), path: Array(path.dropFirst()), change))
                } else {
                    out += child.box
                }
            } else {
                out += try change(child.type, child.box)
            }
        }
        return out
    }
}

// MARK: - FLAC

/// Rewrites a FLAC file's metadata blocks: Vorbis comments and pictures change, the rest is kept.
enum FLACWriter {
    static let padding = 4096

    static func rewrite(_ source: ByteSource, _ request: TagWriteRequest, into output: FileHandle) throws {
        var offset: UInt64 = 0
        let head = source.read(10, at: 0)
        if head.ascii(0, 3) == "ID3" { offset = UInt64(ID3.syncsafe(head, 6)) + 10 }
        guard source.read(4, at: offset).ascii(0, 4) == "fLaC" else { throw TagWriteError.unreadable("no FLAC stream marker") }
        let prefix = offset
        offset += 4
        var blocks: [(type: UInt8, body: Data)] = []
        var last = false
        while !last {
            let header = source.read(4, at: offset)
            guard header.count == 4 else { throw TagWriteError.unreadable("the metadata ends early") }
            last = header.byte(0) & 0x80 != 0
            let type = header.byte(0) & 0x7F
            let length = Int(header.uint24BE(1))
            let body = source.read(length, at: offset + 4)
            guard body.count == length else { throw TagWriteError.unreadable("a metadata block is cut short") }
            blocks.append((type: type, body: body))
            offset += 4 + UInt64(length)
        }
        guard blocks.first?.type == 0 else { throw TagWriteError.unreadable("no STREAMINFO block") }
        let existingComments = blocks.first { $0.type == 4 }.map { parseComments($0.body) }
        let comments: (vendor: String, comments: [String]) = existingComments ?? (vendor: "empee3", comments: [])
        let newComments = apply(request, to: comments.comments)
        var kept = blocks.filter { $0.type != 4 && $0.type != 1 && !(($0.type == 6) && (request.artwork != nil || request.clearArtwork)) }
        kept.insert((type: 4, body: commentsBlock(vendor: comments.vendor, newComments)), at: 1)
        if let artwork = request.artwork, !request.clearArtwork { kept.append((type: 6, body: pictureBlock(artwork))) }
        kept.append((type: 1, body: Data(repeating: 0, count: padding)))
        try TagWriter.copyRest(source, from: 0, to: prefix, into: output)
        var metadata = Data("fLaC".utf8)
        for (index, block) in kept.enumerated() {
            guard block.body.count < 1 << 24 else { throw TagWriteError.unsupportedFormat("a metadata block over 16 MB") }
            let flag: UInt8 = index == kept.count - 1 ? 0x80 : 0
            metadata += Data([block.type | flag]) + Data.be24(block.body.count) + block.body
        }
        try output.write(contentsOf: metadata)
        try TagWriter.copyRest(source, from: offset, into: output)
    }

    static func parseComments(_ data: Data) -> (vendor: String, comments: [String]) {
        var position = 0
        let vendorLength = Int(data.uint32LE(position))
        position += 4
        let vendor = String(decoding: data.slice(position, vendorLength), as: UTF8.self)
        position += vendorLength
        let count = Int(data.uint32LE(position))
        position += 4
        var comments: [String] = []
        for _ in 0..<min(count, 100_000) {
            guard position + 4 <= data.count else { break }
            let length = Int(data.uint32LE(position))
            position += 4
            guard position + length <= data.count else { break }
            comments.append(String(decoding: data.slice(position, length), as: UTF8.self))
            position += length
        }
        return (vendor, comments)
    }

    /// Changed fields first (so a new DATE is read before an ORIGINALDATE), then everything kept.
    static func apply(_ request: TagWriteRequest, to comments: [String]) -> [String] {
        var removed = Set<String>()
        var added: [String] = []
        func setText(_ keys: [String], _ change: TagWriteRequest.TextChange) {
            guard change != .keep else { return }
            removed.formUnion(keys)
            if case .set(let value) = change { added.append("\(keys[0])=\(value.trimmed)") }
        }
        setText(["TITLE"], request.change(request.title, cleared: request.clearTitle))
        setText(["ARTIST"], request.change(request.artist, cleared: request.clearArtist))
        setText(["ALBUM"], request.change(request.album, cleared: request.clearAlbum))
        if request.clearYear {
            removed.formUnion(["DATE", "YEAR", "ORIGINALDATE"])
        } else if let date = request.dateValue {
            removed.formUnion(["DATE", "YEAR"])
            added.append("DATE=\(date)")
        }
        if request.clearGenre {
            removed.insert("GENRE")
        } else if let genres = request.genres {
            removed.insert("GENRE")
            added += genres.map { "GENRE=\($0)" }
        }
        if let track = request.trackNumber {
            removed.insert("TRACKNUMBER")
            added.append("TRACKNUMBER=\(track)")
        }
        if let disc = request.discNumber {
            removed.insert("DISCNUMBER")
            added.append("DISCNUMBER=\(disc)")
        }
        if let bpm = request.bpm {
            removed.formUnion(["BPM", "TEMPO"])
            added.append("BPM=\(bpm)")
        }
        if let lyrics = request.lyrics, !lyrics.trimmed.isEmpty {
            removed.formUnion(["LYRICS", "UNSYNCEDLYRICS"])
            added.append("LYRICS=\(lyrics)")
        }
        if request.clearArtwork || request.artwork != nil { removed.insert("METADATA_BLOCK_PICTURE") }
        let kept = comments.filter { comment in
            let key = comment.split(separator: "=", maxSplits: 1).first.map { $0.uppercased() } ?? ""
            return !removed.contains(key)
        }
        return added + kept
    }

    static func commentsBlock(vendor: String, _ comments: [String]) -> Data {
        var data = Data.le32(vendor.utf8.count) + Data(vendor.utf8) + Data.le32(comments.count)
        for comment in comments { data += Data.le32(comment.utf8.count) + Data(comment.utf8) }
        return data
    }

    static func pictureBlock(_ image: Data) -> Data {
        let mime = Data(ArtworkEncoder.mimeType(image).utf8)
        let size = ArtworkEncoder.pixelSize(image)
        return Data.be32(3) + Data.be32(mime.count) + mime + Data.be32(0)
            + Data.be32(size.width) + Data.be32(size.height) + Data.be32(24) + Data.be32(0)
            + Data.be32(image.count) + image
    }
}
