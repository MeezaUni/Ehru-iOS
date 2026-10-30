import AudioToolbox
import AVFoundation
import Foundation

/// Where a value comes from, shown next to it so nothing reads as more certain than it is.
enum Provenance: String, Sendable {
    /// Parsed from the file's own audio header by Core Audio.
    case fileHeader = "File header"
    /// Reported by Core Audio for the file's container (estimates for some formats).
    case container = "Container"
    /// Recorded in the library when the file was scanned.
    case library = "Library index"
    /// Reported by the app's audio engine for what it is doing now.
    case player = "Player"
    /// Reported by iOS for the audio session and output devices.
    case platform = "iOS"
}

/// A value and where it comes from.
struct Fact: Equatable, Sendable {
    let value: String
    let provenance: Provenance

    init(_ value: String, _ provenance: Provenance) {
        self.value = value
        self.provenance = provenance
    }
}

/// What the playing file is, read without decoding it.
struct SourceDiagnostics: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let container: Fact?
    let codec: Fact?
    let sampleRate: Fact?
    let channels: Fact?
    /// Only for lossless formats that store one; nil otherwise, with [bitDepthNote] saying why.
    let bitDepth: Fact?
    let bitDepthNote: String?
    let bitrate: Fact?
    let duration: Fact?
    let fileSize: Fact?
    /// Why some values are missing (the file cannot be read), or nil.
    let problem: String?
}

/// Readable names for Core Audio constants. Unknown values stay unknown.
enum MediaFormats {
    static func sampleRateText(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000)
    }

    static func bitrateText(_ bitsPerSecond: Int) -> String { "\((bitsPerSecond + 500) / 1000) kbps" }

    static func channelsText(_ count: Int) -> String {
        channelLayout(count).map { "\(count) (\($0))" } ?? "\(count)"
    }

    /// Common names for channel counts; nil for counts without a standard layout name.
    static func channelLayout(_ count: Int?) -> String? {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: nil
        }
    }

    static func formatSize(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }

    /// Codec name of a Core Audio format id, e.g. 'fLaC' to FLAC.
    static func codecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: "AAC"
        case kAudioFormatMPEG4AAC_HE: "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: "HE-AAC v2"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        default: fourCC(formatID)
        }
    }

    /// The four characters of a Core Audio code, e.g. "lpcm".
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(code)
    }

    /// Container name of a Core Audio file type.
    static func containerName(_ type: AudioFileTypeID) -> String? {
        switch type {
        case kAudioFileFLACType: "FLAC"
        case kAudioFileMP3Type: "MPEG audio (MP3)"
        case kAudioFileM4AType, kAudioFileMPEG4Type: "MPEG-4 (M4A)"
        case kAudioFileAAC_ADTSType: "ADTS AAC"
        case kAudioFileWAVEType, kAudioFileRF64Type: "WAV (RIFF)"
        case kAudioFileAIFFType, kAudioFileAIFCType: "AIFF"
        case kAudioFileCAFType: "Core Audio (CAF)"
        default: nil
        }
    }

    /// Whether a codec is lossless (so its stored bit depth is meaningful).
    static func isLossless(_ codec: String?) -> Bool { ["FLAC", "ALAC", "PCM"].contains(codec ?? "") }

    /// The bit depth a lossless stream stores: PCM's sample size, or the source bit depth FLAC and
    /// ALAC record in their format flags. Nil when the format does not say.
    static func bitDepth(formatID: AudioFormatID, flags: AudioFormatFlags, bitsPerChannel: UInt32) -> Int? {
        switch formatID {
        case kAudioFormatLinearPCM:
            return bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            let sources: [(AudioFormatFlags, Int)] = [
                (AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData), 16),
                (AudioFormatFlags(kAppleLosslessFormatFlag_20BitSourceData), 20),
                (AudioFormatFlags(kAppleLosslessFormatFlag_24BitSourceData), 24),
                (AudioFormatFlags(kAppleLosslessFormatFlag_32BitSourceData), 32),
            ]
            if let match = sources.first(where: { $0.0 == flags }) { return match.1 }
            return bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
        default:
            return nil
        }
    }
}

/// Reads what a file is from its own header (through Core Audio's file reader, without decoding),
/// falling back to what the library recorded. Blocking: call off the main thread.
enum SourceInspector {
    static func inspect(_ song: Song) -> SourceDiagnostics {
        let url = song.url
        let onDisk = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let sizeFact = onDisk.map { Fact(MediaFormats.formatSize($0), .platform) }
            ?? (song.fileSize > 0 ? Fact(MediaFormats.formatSize(song.fileSize), .library) : nil)
        guard let file = AudioFileReader(url) else {
            return fromLibrary(song, sizeFact: sizeFact, problem: "The file could not be opened, so these values come from the library index.")
        }
        let format = file.dataFormat
        let codec = format.map { MediaFormats.codecName($0.mFormatID) }
        let depth = format.flatMap { MediaFormats.bitDepth(formatID: $0.mFormatID, flags: $0.mFormatFlags, bitsPerChannel: $0.mBitsPerChannel) }
        let depthNote: String?
        if depth != nil {
            depthNote = nil
        } else if let codec, !MediaFormats.isLossless(codec) {
            depthNote = "\(codec) is lossy: it stores no bit depth"
        } else {
            depthNote = "Not stated in the file"
        }
        let rate = format.map { Int($0.mSampleRate) }.flatMap { $0 > 0 ? $0 : nil }
        let channels = format.map { Int($0.mChannelsPerFrame) }.flatMap { $0 > 0 ? $0 : nil }
        let durationSeconds = file.estimatedDuration.flatMap { $0 > 0 ? $0 : nil }
        let bitrate = file.bitRate.flatMap { $0 > 0 ? $0 : nil }
        return SourceDiagnostics(
            title: song.title, artist: song.artist, album: song.album,
            container: (file.fileType.flatMap(MediaFormats.containerName)).map { Fact($0, .container) },
            codec: codec.map { Fact($0, .fileHeader) },
            sampleRate: rate.map { Fact(MediaFormats.sampleRateText($0), .fileHeader) },
            channels: channels.map { Fact(MediaFormats.channelsText($0), .fileHeader) },
            bitDepth: depth.map { Fact("\($0)-bit", .fileHeader) },
            bitDepthNote: depthNote,
            bitrate: bitrate.map { Fact(MediaFormats.bitrateText($0), .container) },
            duration: durationSeconds.map { Fact(formatDuration(Int64($0 * 1000)), .container) },
            fileSize: sizeFact,
            problem: nil
        )
    }

    private static func fromLibrary(_ song: Song, sizeFact: Fact?, problem: String) -> SourceDiagnostics {
        SourceDiagnostics(
            title: song.title, artist: song.artist, album: song.album,
            container: nil,
            codec: song.codec.flatMap { $0.isEmpty ? nil : Fact($0.uppercased(), .library) },
            sampleRate: song.sampleRate > 0 ? Fact(MediaFormats.sampleRateText(song.sampleRate), .library) : nil,
            channels: song.channels > 0 ? Fact(MediaFormats.channelsText(song.channels), .library) : nil,
            bitDepth: nil,
            bitDepthNote: "Unknown: the file could not be read",
            bitrate: song.bitrate > 0 ? Fact(MediaFormats.bitrateText(song.bitrate), .library) : nil,
            duration: song.durationMs > 0 ? Fact(formatDuration(song.durationMs), .library) : nil,
            fileSize: sizeFact,
            problem: problem
        )
    }
}

/// The few Core Audio file properties the inspector reads.
private final class AudioFileReader {
    private let id: AudioFileID

    init?(_ url: URL) {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        id = file
    }

    deinit { AudioFileClose(id) }

    var dataFormat: AudioStreamBasicDescription? { property(kAudioFilePropertyDataFormat, AudioStreamBasicDescription()) }
    var fileType: AudioFileTypeID? { property(kAudioFilePropertyFileFormat, AudioFileTypeID(0)) }
    var bitRate: Int? { property(kAudioFilePropertyBitRate, UInt32(0)).map(Int.init) }
    var estimatedDuration: Double? { property(kAudioFilePropertyEstimatedDuration, Float64(0)) }

    private func property<T>(_ key: AudioFilePropertyID, _ initial: T) -> T? {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioFileGetProperty(id, key, &size, &value) == noErr ? value : nil
    }
}
