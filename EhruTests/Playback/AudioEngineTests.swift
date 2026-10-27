import AVFoundation
import XCTest
@testable import Ehru

final class AudioEngineTests: XCTestCase {
    @MainActor
    func testPauseKeepsPositionAndStopsRenderingUntilResume() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0 }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let engine = AudioEngine()
        await engine.setUp()
        defer { engine.stopAll() }
        let id = UUID()
        try engine.play(entryId: id, url: url, positionMs: 1_000, startPlaying: true)
        try await Task.sleep(for: .milliseconds(250))
        engine.pause()
        let paused = try XCTUnwrap(engine.currentPosition())
        XCTAssertEqual(paused.entryId, id)
        XCTAssertGreaterThan(paused.positionMs, 1_000)
        XCTAssertFalse(engine.isRunning)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.currentPosition()?.positionMs, paused.positionMs)
        try engine.resume()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(engine.isRunning)
        XCTAssertGreaterThan(try XCTUnwrap(engine.currentPosition()).positionMs, paused.positionMs)
    }
}
