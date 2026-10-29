import AVFoundation
import XCTest
@testable import Ehru

final class AudioEngineTests: XCTestCase {
    @MainActor
    func testPairPreviewSchedulesOnlyTheRealCueWindowsAndStopsBothDecks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let incomingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: incomingURL)
        }
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
        let incomingFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let incomingBuffer = AVAudioPCMBuffer(pcmFormat: incomingFormat, frameCapacity: 144_000)!
        incomingBuffer.frameLength = incomingBuffer.frameCapacity
        for frame in 0..<Int(incomingBuffer.frameLength) { incomingBuffer.floatChannelData![0][frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: incomingURL, settings: incomingFormat.settings)
            try file.write(from: incomingBuffer)
        }
        var spec = TransitionSpec.preset(.bassSwap)
        spec.durationMs = 500
        spec.outgoingCutMs = 500
        spec.incomingStartMs = 500
        let timing = try XCTUnwrap(PairTransitionTiming(spec: spec, outgoingMs: 3000, incomingMs: 3000))
        let engine = AudioEngine()
        await engine.setUp()
        defer { engine.stopAll() }
        try engine.previewTransition(outgoing: url, incoming: incomingURL, timing: timing)
        let out = try XCTUnwrap(engine.other.segments.first)
        let inc = try XCTUnwrap(engine.active.segments.first)
        XCTAssertEqual(out.fileStartFrame, 22_050)
        XCTAssertEqual(out.frameCount, 88_200)
        XCTAssertEqual(inc.fileStartFrame, 24_000)
        XCTAssertEqual(inc.frameCount, 96_000)
        XCTAssertTrue(engine.isRunning)
        var rendered: Double?
        for _ in 0..<40 {
            rendered = engine.previewPositionMs()
            if rendered != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let position = try XCTUnwrap(rendered, "The preview playhead must expose the actual render clock")
        XCTAssertGreaterThanOrEqual(position, -Double(timing.leadMs))
        XCTAssertLessThanOrEqual(position, Double(timing.plan.durationMs) + Double(timing.tailMs))
        engine.stopAll()
        XCTAssertNil(engine.previewPositionMs())
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(engine.active.segments.isEmpty)
        XCTAssertTrue(engine.other.segments.isEmpty)

        let cut = try XCTUnwrap(PairTransitionTiming(spec: nil, outgoingMs: 3000, incomingMs: 3000))
        try engine.previewTransition(outgoing: url, incoming: incomingURL, timing: cut)
        XCTAssertFalse(engine.other.stage.isEngaged)
        XCTAssertFalse(engine.active.stage.isEngaged)
        XCTAssertEqual(try XCTUnwrap(engine.other.segments.first).fileStartFrame, 66_150)
        XCTAssertEqual(try XCTUnwrap(engine.other.segments.first).frameCount, 66_150)
        XCTAssertEqual(try XCTUnwrap(engine.active.segments.first).fileStartFrame, 0)
        XCTAssertEqual(try XCTUnwrap(engine.active.segments.first).frameCount, 72_000)
    }

    @MainActor
    func testManualTrackSwitchPreparesTheOtherDeckBeforeReleasingAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0.1 }
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let engine = AudioEngine()
        await engine.setUp()
        defer { engine.stopAll() }
        let firstID = UUID(), secondID = UUID()
        try engine.play(entryId: firstID, url: url, positionMs: 0, startPlaying: true)
        try await Task.sleep(for: .milliseconds(100))
        let outgoing = engine.active
        try engine.play(entryId: secondID, url: url, positionMs: 0, startPlaying: true)
        XCTAssertTrue(engine.isRunning)
        XCTAssertFalse(engine.active === outgoing)
        XCTAssertTrue(engine.other === outgoing)
        XCTAssertEqual(engine.currentPosition()?.entryId, secondID)
        XCTAssertEqual(outgoing.segments.first?.entryId, firstID)
        XCTAssertTrue(outgoing.player.isPlaying)
        XCTAssertTrue(outgoing.stage.isEngaged)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(try XCTUnwrap(engine.currentPosition()).positionMs, 0)
        engine.releaseFinishedOutgoing()
        XCTAssertTrue(engine.other.segments.isEmpty)
    }

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
