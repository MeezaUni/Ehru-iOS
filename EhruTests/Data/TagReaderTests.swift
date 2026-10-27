import XCTest
@testable import Ehru

/// Builds small tagged files byte by byte, so the readers are tested without real music.
enum TagFixtures {
    static func be32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    static func le32(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
    static func syncsafe(_ v: Int) -> Data { Data([UInt8(v >> 21 & 0x7F), UInt8(v >> 14 & 0x7F), UInt8(v >> 7 & 0x7F), UInt8(v & 0x7F)]) }

    static func id3Frame(_ id: String, _ payload: Data, v4: Bool) -> Data {
        Data(id.utf8) + (v4 ? syncsafe(payload.count) : be32(payload.count)) + Data([0, 0]) + payload
    }

    static func textFrame(_ id: String, _ text: String, v4: Bool) -> Data {
        // v2.4: UTF-8 (3); v2.3: UTF-16 with BOM (1).
        let payload = v4 ? Data([3]) + Data(text.utf8) : Data([1, 0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        return id3Frame(id, payload, v4: v4)
    }

    static func id3Tag(_ frames: [Data], v4: Bool) -> Data {
        let body = frames.reduce(Data(), +)
        return Data("ID3".utf8) + Data([v4 ? 4 : 3, 0, 0]) + syncsafe(body.count) + body
    }

    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])

    static func mp3(v4: Bool) -> Data {
        id3Tag([
            textFrame("TIT2", "IGOR’S THEME", v4: v4),
            textFrame("TPE1", "Tyler/ The Creator", v4: v4),
            textFrame("TPE2", "Tyler, The Creator", v4: v4),
            textFrame("TALB", "IGOR", v4: v4),
            textFrame("TRCK", "3/12", v4: v4),
            textFrame("TPOS", "1/1", v4: v4),
            textFrame(v4 ? "TDRC" : "TYER", "2019", v4: v4),
            textFrame("TCON", "(7)Hip Hop/Rap", v4: v4),
            textFrame("TBPM", "128", v4: v4),
            id3Frame("USLT", Data([3]) + Data("eng".utf8) + Data([0]) + Data("la la la".utf8), v4: v4),
            id3Frame("APIC", Data([0]) + Data("image/jpeg".utf8) + Data([0, 3]) + Data([0]) + jpeg, v4: v4),
        ], v4: v4) + Data(repeating: 0, count: 64)
    }

    static func atom(_ name: String, _ body: Data) -> Data { be32(body.count + 8) + Data(name.utf8) + body }

    static func ilstItem(_ name: [UInt8], type: Int, _ payload: Data) -> Data {
        let data = atom("data", be32(type) + be32(0) + payload)
        return be32(data.count + 8) + Data(name) + data
    }

    static func m4a() -> Data {
        let copyright: UInt8 = 0xA9
        let ilst = atom("ilst",
            ilstItem([copyright] + Array("nam".utf8), type: 1, Data("Rich Flex".utf8))
            + ilstItem([copyright] + Array("ART".utf8), type: 1, Data("Drake/21 Savage".utf8))
            + ilstItem(Array("aART".utf8), type: 1, Data("Drake & 21 Savage".utf8))
            + ilstItem([copyright] + Array("alb".utf8), type: 1, Data("Her Loss".utf8))
            + ilstItem([copyright] + Array("day".utf8), type: 1, Data("2022-11-04T12:00:00Z".utf8))
            + ilstItem(Array("trkn".utf8), type: 0, Data([0, 0, 0, 1, 0, 16, 0, 0]))
            + ilstItem(Array("disk".utf8), type: 0, Data([0, 0, 0, 1, 0, 1]))
            + ilstItem(Array("tmpo".utf8), type: 21, Data([0, 153]))
            + ilstItem(Array("cpil".utf8), type: 21, Data([1]))
            + ilstItem(Array("covr".utf8), type: 13, jpeg))
        let meta = atom("meta", Data([0, 0, 0, 0]) + atom("hdlr", Data(repeating: 0, count: 25)) + ilst)
        return atom("ftyp", Data("M4A ".utf8) + be32(0)) + atom("moov", atom("udta", meta))
    }

    static func flac() -> Data {
        var streamInfo = Data(repeating: 0, count: 34)
        // 44100 Hz, 2 channels, 16 bits, 441000 samples (10 s)
        streamInfo[10] = 0x0A; streamInfo[11] = 0xC4; streamInfo[12] = 0x42; streamInfo[13] = 0xF0
        streamInfo.replaceSubrange(14..<18, with: be32(441_000))
        let comments = ["TITLE=Nightmare", "ARTIST=Offset/Metro Boomin", "ALBUM=Without Warning", "TRACKNUMBER=4",
                        "DATE=2017-10-31", "GENRE=Hip Hop", "GENRE=Trap", "LYRICS=words"]
        var vorbis = le32(6) + Data("vendor".utf8) + le32(comments.count)
        for comment in comments { vorbis += le32(comment.utf8.count) + Data(comment.utf8) }
        let picture = be32(3) + be32(10) + Data("image/jpeg".utf8) + be32(0) + Data(repeating: 0, count: 16) + be32(jpeg.count) + jpeg
        func block(_ type: UInt8, last: Bool, _ body: Data) -> Data {
            Data([last ? type | 0x80 : type, UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)]) + body
        }
        return Data("fLaC".utf8) + block(0, last: false, streamInfo) + block(4, last: false, vorbis) + block(6, last: true, picture)
    }

    static func write(_ data: Data, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
        return url
    }
}

final class TagReaderTests: XCTestCase {
    func testId3v23AndV24() {
        for v4 in [false, true] {
            let url = TagFixtures.write(TagFixtures.mp3(v4: v4), name: "song.mp3")
            let tags = TagReader.read(url)
            XCTAssertEqual("IGOR’S THEME", tags.title)
            XCTAssertEqual("Tyler/ The Creator", tags.artist)
            XCTAssertEqual("Tyler, The Creator", tags.albumArtist)
            XCTAssertEqual("IGOR", tags.album)
            XCTAssertEqual(3, tags.trackNumber)
            XCTAssertEqual(1, tags.discNumber)
            XCTAssertEqual(2019, tags.year)
            XCTAssertEqual(["Hip-Hop", "Hip Hop/Rap"], tags.genres)
            XCTAssertEqual(128, usableBpm(tags.bpmText))
            XCTAssertEqual("la la la", tags.lyrics)
            XCTAssertTrue(tags.hasArtwork)
            XCTAssertEqual(TagFixtures.jpeg, TagReader.artwork(url))
        }
    }

    func testMp4Atoms() {
        let url = TagFixtures.write(TagFixtures.m4a(), name: "song.m4a")
        let tags = TagReader.read(url)
        XCTAssertEqual("Rich Flex", tags.title)
        XCTAssertEqual("Drake/21 Savage", tags.artist)
        XCTAssertEqual("Drake & 21 Savage", tags.albumArtist)
        XCTAssertEqual("Her Loss", tags.album)
        XCTAssertEqual(2022, tags.year)
        XCTAssertEqual(1, tags.trackNumber)
        XCTAssertEqual(1, tags.discNumber)
        XCTAssertEqual("153", tags.bpmText)
        XCTAssertTrue(tags.isCompilation)
        XCTAssertEqual(TagFixtures.jpeg, TagReader.artwork(url))
    }

    func testFlacVorbisCommentsAndPicture() {
        let url = TagFixtures.write(TagFixtures.flac(), name: "song.flac")
        let tags = TagReader.read(url)
        XCTAssertEqual("Nightmare", tags.title)
        XCTAssertEqual("Offset/Metro Boomin", tags.artist)
        XCTAssertEqual("Without Warning", tags.album)
        XCTAssertEqual(4, tags.trackNumber)
        XCTAssertEqual(2017, tags.year)
        XCTAssertEqual(["Hip Hop", "Trap"], tags.genres)
        XCTAssertEqual("words", tags.lyrics)
        XCTAssertEqual(TagFixtures.jpeg, TagReader.artwork(url))
        let source = ByteSource(file: try! FileHandle(forReadingFrom: url))
        let info = FLACTags.read(source)
        XCTAssertEqual(44_100, info.sampleRate)
        XCTAssertEqual(2, info.channels)
        XCTAssertEqual(441_000, info.totalSamples)
    }

    func testUntaggedFileReadsNothing() {
        let url = TagFixtures.write(Data(repeating: 7, count: 500), name: "noise.mp3")
        XCTAssertEqual(FileTags(), TagReader.read(url))
        XCTAssertNil(TagReader.artwork(url))
    }

    func testId3Genres() {
        XCTAssertEqual(["Rock"], ID3.genres(["(17)"]))
        XCTAssertEqual(["Rock"], ID3.genres(["17"]))
        XCTAssertEqual(["Rock", "Pop"], ID3.genres(["Rock", "Pop"]))
        XCTAssertEqual(["Remix"], ID3.genres(["(RX)"]))
    }
}
