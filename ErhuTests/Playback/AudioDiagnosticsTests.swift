import AVFoundation
@testable import Erhu
import XCTest

final class AudioDiagnosticsTests: XCTestCase {
    private var written: [URL] = []

    override func tearDown() {
        written.forEach { try? FileManager.default.removeItem(at: $0) }
        written = []
        super.tearDown()
    }

    /// A one-second 16-bit stereo WAV in the music folder, and its library song.
    private func wavSong() throws -> Song {
        let name = "diagnostics-\(UUID().uuidString).wav"
        let url = LibraryPaths.musicFolder.appendingPathComponent(name)
        written.append(url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for i in 0..<44_100 { buffer.floatChannelData![channel][i] = 0.25 * sin(Float(i) * 0.05) }
            }
            try file.write(from: buffer)
        }
        return Song(id: 1, title: "Tone", artist: "Test", album: "Diagnostics", durationMs: 1_000, path: name)
    }

    func testAWavFileIsReadFromItsHeader() throws {
        let diagnostics = SourceInspector.inspect(try wavSong())
        XCTAssertNil(diagnostics.problem)
        XCTAssertEqual(diagnostics.codec, Fact("PCM", .fileHeader))
        XCTAssertEqual(diagnostics.sampleRate, Fact("44.1 kHz", .fileHeader))
        XCTAssertEqual(diagnostics.channels, Fact("2 (Stereo)", .fileHeader))
        XCTAssertEqual(diagnostics.bitDepth, Fact("16-bit", .fileHeader))
        XCTAssertNil(diagnostics.bitDepthNote)
        XCTAssertEqual(diagnostics.container, Fact("WAV (RIFF)", .container))
        XCTAssertEqual(diagnostics.duration?.value, "0:01")
        XCTAssertEqual(diagnostics.fileSize?.provenance, .platform)
    }

    func testAMissingFileFallsBackToTheLibraryAndSaysSo() {
        var song = Song(id: 2, title: "Gone", artist: "A", album: "B", durationMs: 185_000, path: "missing-\(UUID().uuidString).flac")
        song.sampleRate = 96_000
        song.channels = 2
        song.bitrate = 2_116_000
        song.codec = "flac"
        let diagnostics = SourceInspector.inspect(song)
        XCTAssertNotNil(diagnostics.problem)
        XCTAssertEqual(diagnostics.sampleRate, Fact("96 kHz", .library))
        XCTAssertEqual(diagnostics.bitrate, Fact("2116 kbps", .library))
        XCTAssertEqual(diagnostics.codec, Fact("FLAC", .library))
        XCTAssertEqual(diagnostics.duration, Fact("3:05", .library))
        XCTAssertNil(diagnostics.bitDepth) // never guessed
        XCTAssertNil(diagnostics.fileSize)
    }

    func testFormatTexts() {
        XCTAssertEqual(MediaFormats.sampleRateText(48_000), "48 kHz")
        XCTAssertEqual(MediaFormats.sampleRateText(44_100), "44.1 kHz")
        XCTAssertEqual(MediaFormats.bitrateText(320_000), "320 kbps")
        XCTAssertEqual(MediaFormats.bitrateText(127_600), "128 kbps")
        XCTAssertEqual(MediaFormats.channelsText(1), "1 (Mono)")
        XCTAssertEqual(MediaFormats.channelsText(3), "3")
        XCTAssertEqual(MediaFormats.codecName(kAudioFormatFLAC), "FLAC")
        XCTAssertEqual(MediaFormats.codecName(kAudioFormatMPEGLayer3), "MP3")
        XCTAssertEqual(MediaFormats.fourCC(0x6C70_636D), "lpcm")
        XCTAssertEqual(MediaFormats.containerName(kAudioFileM4AType), "MPEG-4 (M4A)")
        XCTAssertEqual(MediaFormats.formatSize(5 * 1024 * 1024 + 512 * 1024), "5.5 MB")
    }

    func testBitDepthOnlyForLosslessFormatsThatStateIt() {
        let alac24 = AudioFormatFlags(kAppleLosslessFormatFlag_24BitSourceData)
        XCTAssertEqual(MediaFormats.bitDepth(formatID: kAudioFormatAppleLossless, flags: alac24, bitsPerChannel: 0), 24)
        XCTAssertEqual(MediaFormats.bitDepth(formatID: kAudioFormatLinearPCM, flags: 0, bitsPerChannel: 16), 16)
        XCTAssertNil(MediaFormats.bitDepth(formatID: kAudioFormatFLAC, flags: 0, bitsPerChannel: 0))
        XCTAssertNil(MediaFormats.bitDepth(formatID: kAudioFormatMPEG4AAC, flags: 0, bitsPerChannel: 16))
    }

    func testTheReportSaysUnavailableNeverZeroAndLeavesOutDeviceNames() {
        let stage = EqStage(status: .off, reason: "Turned off in Audio & Equalizer", activeBands: [])
        let output = OutputDiagnostics(route: [OutputPort(typeName: "Bluetooth (A2DP)", name: "Sam's AirPods", spatialAudio: true)],
                                       sampleRateHz: 48_000, channels: 2, bufferMs: 10.7, latencyMs: nil)
        let source = SourceDiagnostics(title: "Song\nwith a break", artist: "A", album: "B", container: nil,
                                       codec: Fact("FLAC", .fileHeader), sampleRate: Fact("44.1 kHz", .fileHeader), channels: nil,
                                       bitDepth: nil, bitDepthNote: "Not stated in the file", bitrate: nil, duration: nil,
                                       fileSize: nil, problem: nil)
        let report = DiagnosticsReport.build(DiagnosticsSnapshot(
            source: source, state: "playing", decoderInput: nil, sentToSystem: "32-bit float, 48 kHz, 2 (Stereo)",
            eq: stage, headroom: DspDiagnostics.headroom(stage, sampleRateHz: 48_000), peak: nil, output: output, transitionFading: false
        ))
        XCTAssertTrue(report.hasPrefix("Erhu audio details"))
        XCTAssertTrue(report.contains("Title: Song with a break"))
        XCTAssertTrue(report.contains("Codec: FLAC (File header)"))
        XCTAssertTrue(report.contains("Channels: unavailable"))
        XCTAssertTrue(report.contains("Bit depth: Not stated in the file"))
        XCTAssertTrue(report.contains("Decoder output: unavailable"))
        XCTAssertTrue(report.contains("Route: Bluetooth (A2DP)"))
        XCTAssertTrue(report.contains("Spatial audio: on"))
        XCTAssertTrue(report.contains("Output latency: unavailable"))
        XCTAssertTrue(report.contains("Transition: unity gain (no change)"))
        XCTAssertFalse(report.contains("AirPods"))
        XCTAssertFalse(report.contains("Measured sample peak"))
    }
}
