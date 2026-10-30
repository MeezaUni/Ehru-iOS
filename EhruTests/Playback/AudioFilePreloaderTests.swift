import AVFoundation
import XCTest
@testable import Ehru

final class AudioFilePreloaderTests: XCTestCase {
    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        buffer.frameLength = 800
        for i in 0..<800 { buffer.floatChannelData![0][i] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @MainActor
    func testBoundedReadAheadConsumesEachReaderOnceAndRejectsReplacedFiles() async throws {
        let a = try file(), b = try file(), c = try file(), d = try file(), e = try file()
        defer { for url in [a, b, c, d, e] { try? FileManager.default.removeItem(at: url) } }
        let loader = AudioFilePreloader()
        await loader.warm([a, a, b, c, d, e])
        XCTAssertNil(loader.take(e))
        XCTAssertNotNil(loader.take(c))
        XCTAssertNotNil(loader.take(d))
        let first = try XCTUnwrap(loader.take(a))
        XCTAssertEqual(first.length, 800)
        XCTAssertEqual(first.framePosition, 0, "Decoder priming must rewind before handing off the reader")
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: first.processingFormat, frameCapacity: 800))
        try first.read(into: samples)
        XCTAssertEqual(samples.frameLength, 800, "No opening samples may be lost during priming")
        XCTAssertNil(loader.take(a), "An active reader must not be reused by another deck")
        XCTAssertNotNil(loader.take(b))
        await loader.warm([a, b])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: a.path)
        XCTAssertNil(loader.take(a))
        try FileManager.default.removeItem(at: b)
        XCTAssertNil(loader.take(b))
        await loader.warm([])
        XCTAssertNil(loader.take(a))
    }
}
