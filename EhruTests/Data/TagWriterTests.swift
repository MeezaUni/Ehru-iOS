import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Ehru
import XCTest

final class TagWriterTests: XCTestCase {
    private let audio = Data((0..<256).map { UInt8($0) })

    /// A real 64 × 48 PNG, so the artwork is decoded and re-encoded like a real cover.
    private func png() -> Data {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    func testMp3EditsOnlyWhatWasAskedAndKeepsTheAudio() throws {
        for v4 in [false, true] {
            let url = TagFixtures.write(TagFixtures.mp3(v4: v4) + audio, name: "song.mp3")
            var request = TagWriteRequest()
            request.title = "Earfquake"
            request.clearArtist = true
            request.releaseDate = "2019-05"
            request.genre = "Hip Hop; Neo Soul"
            request.bpm = 80
            request.trackNumber = 5
            try TagWriter.write(request, to: url)

            let tags = TagReader.read(url)
            XCTAssertEqual(tags.title, "Earfquake")
            XCTAssertNil(tags.artist)
            XCTAssertEqual(tags.dateText, "2019-05")
            XCTAssertEqual(tags.year, 2019)
            XCTAssertEqual(tags.genres, ["Hip Hop", "Neo Soul"])
            XCTAssertEqual(usableBpm(tags.bpmText), 80)
            XCTAssertEqual(tags.trackNumber, 5)
            // Untouched frames stay.
            XCTAssertEqual(tags.albumArtist, "Tyler, The Creator")
            XCTAssertEqual(tags.album, "IGOR")
            XCTAssertEqual(tags.discNumber, 1)
            XCTAssertEqual(tags.lyrics, "la la la")
            XCTAssertEqual(TagReader.artwork(url), TagFixtures.jpeg)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.suffix(audio.count), audio)
            XCTAssertEqual(data.byte(3), 4) // now ID3v2.4
        }
    }

    func testMp3TrackNumberKeepsTheTotal() throws {
        let url = TagFixtures.write(TagFixtures.mp3(v4: true) + audio, name: "song.mp3")
        var request = TagWriteRequest()
        request.trackNumber = 7
        try TagWriter.write(request, to: url)
        let header = try Data(contentsOf: url)
        XCTAssertNotNil(header.range(of: Data("7/12".utf8)))
    }

    func testTrackAndDiscRepairsRoundTripInEveryWritableFormat() throws {
        let fixtures: [(String, Data)] = [("mp3", TagFixtures.mp3(v4: true) + audio),
                                          ("m4a", TagFixtures.m4a()), ("flac", TagFixtures.flac() + audio)]
        for (ext, data) in fixtures {
            let url = TagFixtures.write(data, name: "ordering.\(ext)")
            let before = TagReader.read(url)
            var request = TagWriteRequest()
            request.trackNumber = 7
            request.discNumber = 2
            try TagWriter.write(request, to: url)
            let after = TagReader.read(url)
            XCTAssertEqual(after.trackNumber, 7, ext)
            XCTAssertEqual(after.discNumber, 2, ext)
            XCTAssertEqual(after.title, before.title, ext)
            XCTAssertEqual(after.artist, before.artist, ext)
            XCTAssertEqual(after.album, before.album, ext)
            if ext != "m4a" { XCTAssertEqual(try Data(contentsOf: url).suffix(audio.count), audio, ext) }
        }
    }

    func testMp3ArtworkIsScaledToJpegAndCanBeRemoved() throws {
        let url = TagFixtures.write(TagFixtures.mp3(v4: true) + audio, name: "song.mp3")
        var request = TagWriteRequest()
        request.artwork = png()
        try TagWriter.write(request, to: url)
        let art = try XCTUnwrap(TagReader.artwork(url))
        XCTAssertEqual(Array(art.prefix(2)), [0xFF, 0xD8])

        var clear = TagWriteRequest()
        clear.clearArtwork = true
        try TagWriter.write(clear, to: url)
        XCTAssertFalse(TagReader.read(url).hasArtwork)
        XCTAssertEqual(try Data(contentsOf: url).suffix(audio.count), audio)
    }

    func testMp3WithOnlyAnId3v1TagKeepsItsValues() throws {
        var v1 = Data("TAG".utf8)
        func field(_ text: String, _ length: Int) -> Data { Data(text.utf8) + Data(repeating: 0, count: length - text.utf8.count) }
        v1 += field("Old Title", 30) + field("Old Artist", 30) + field("Old Album", 30) + field("1999", 4)
        v1 += Data(repeating: 0, count: 28) + Data([0, 3, 17])
        let url = TagFixtures.write(audio + v1, name: "old.mp3")
        var request = TagWriteRequest()
        request.title = "New Title"
        try TagWriter.write(request, to: url)
        let tags = TagReader.read(url)
        XCTAssertEqual(tags.title, "New Title")
        XCTAssertEqual(tags.artist, "Old Artist")
        XCTAssertEqual(tags.album, "Old Album")
        XCTAssertEqual(tags.year, 1999)
        XCTAssertEqual(tags.trackNumber, 3)
        XCTAssertEqual(try Data(contentsOf: url).suffix(audio.count), audio) // the v1 tag is gone, the audio isn't
    }

    func testM4aEdits() throws {
        let url = TagFixtures.write(TagFixtures.m4a(), name: "song.m4a")
        var request = TagWriteRequest()
        request.title = "Rich Flex (Clean)"
        request.genre = "Hip Hop; Trap"
        request.bpm = 153
        request.trackNumber = 2
        request.clearYear = true
        try TagWriter.write(request, to: url)
        let tags = TagReader.read(url)
        XCTAssertEqual(tags.title, "Rich Flex (Clean)")
        XCTAssertEqual(tags.genres, ["Hip Hop", "Trap"])
        XCTAssertEqual(tags.bpmText, "153")
        XCTAssertEqual(tags.trackNumber, 2)
        XCTAssertNil(tags.year)
        XCTAssertEqual(tags.artist, "Drake/21 Savage")
        XCTAssertTrue(tags.isCompilation)
        XCTAssertEqual(TagReader.artwork(url), TagFixtures.jpeg)
        // The total of 16 tracks is kept.
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(data.range(of: Data([0, 0, 0, 2, 0, 16, 0, 0])))
    }

    func testM4aChunkOffsetsFollowTheMediaData() throws {
        typealias F = TagFixtures
        let samples = Data("SAMPLES!".utf8)
        func file(stco offset: Int) -> Data {
            let stco = F.atom("stco", Data([0, 0, 0, 0]) + F.be32(1) + F.be32(offset))
            let trak = F.atom("trak", F.atom("mdia", F.atom("minf", F.atom("stbl", stco))))
            let ftyp = F.atom("ftyp", Data("M4A ".utf8) + F.be32(0))
            return ftyp + F.atom("moov", trak) + F.atom("mdat", samples)
        }
        // The chunk offset points at the samples inside mdat.
        let draft = file(stco: 0)
        let original = file(stco: draft.count - samples.count)
        let url = F.write(original, name: "song.m4a")
        var request = TagWriteRequest()
        request.title = "A title long enough to grow the moov box"
        try TagWriter.write(request, to: url)

        let data = try Data(contentsOf: url)
        let stco = try XCTUnwrap(data.range(of: Data("stco".utf8)))
        let offset = Int(data.uint32BE(stco.upperBound + 8))
        XCTAssertEqual(data.slice(offset, samples.count), samples)
        XCTAssertEqual(TagReader.read(url).title, "A title long enough to grow the moov box")
    }

    func testFlacEditsKeepStreamInfoAndAudio() throws {
        let url = TagFixtures.write(TagFixtures.flac() + audio, name: "song.flac")
        var request = TagWriteRequest()
        request.artist = "Offset & Metro Boomin"
        request.releaseDate = "2017-10-31"
        request.clearGenre = true
        request.artwork = png()
        try TagWriter.write(request, to: url)
        let tags = TagReader.read(url)
        XCTAssertEqual(tags.artist, "Offset & Metro Boomin")
        XCTAssertEqual(tags.title, "Nightmare")
        XCTAssertEqual(tags.dateText, "2017-10-31")
        XCTAssertEqual(tags.genres, [])
        XCTAssertEqual(tags.lyrics, "words")
        XCTAssertEqual(Array(try XCTUnwrap(TagReader.artwork(url)).prefix(2)), [0xFF, 0xD8])
        let source = ByteSource(file: try FileHandle(forReadingFrom: url))
        let info = FLACTags.read(source)
        XCTAssertEqual(info.sampleRate, 44_100)
        XCTAssertEqual(info.totalSamples, 441_000)
        XCTAssertEqual(try Data(contentsOf: url).suffix(audio.count), audio)
    }

    func testUnsupportedFormatsAndEmptyRequestsAreRefused() {
        let url = TagFixtures.write(Data("RIFF".utf8) + Data(repeating: 0, count: 40), name: "song.wav")
        var request = TagWriteRequest()
        request.title = "x"
        XCTAssertThrowsError(try TagWriter.write(request, to: url)) { error in
            XCTAssertEqual(error as? TagWriteError, .unsupportedFormat("wav"))
        }
        XCTAssertThrowsError(try TagWriter.write(TagWriteRequest(), to: url)) { error in
            XCTAssertEqual(error as? TagWriteError, .nothingToWrite)
        }
    }

    func testRequestChanges() {
        var request = TagWriteRequest()
        XCTAssertFalse(request.hasChanges)
        request.title = "  "
        XCTAssertEqual(request.change(request.title, cleared: false), .remove) // blank removes
        XCTAssertEqual(request.change(nil, cleared: false), .keep)
        request.year = 2001
        XCTAssertEqual(request.dateValue, "2001")
        request.releaseDate = "2001-09"
        XCTAssertEqual(request.dateValue, "2001-09")
        request.genre = "Rock; ; Pop"
        XCTAssertEqual(request.genres, ["Rock", "Pop"])
    }
}
