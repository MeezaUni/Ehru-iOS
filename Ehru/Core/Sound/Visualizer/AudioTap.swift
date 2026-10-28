import AVFoundation
import Foundation
import os

/// Read-only tap on the audio the engine sends to the output (after the equaliser), for the
/// visualizer and the audio inspector's peak meter. It never changes the audio. Samples are only
/// collected while at least one reader holds the tap.
final class AudioTap: @unchecked Sendable {
    /// About 2.7 s at 48 kHz.
    static let capacity = 1 << 17
    private static let mask = capacity - 1

    private struct State {
        var ring = [Float](repeating: 0, count: AudioTap.capacity)
        var users = 0
        var writtenFrames: Int64 = 0
        var collectFrom = Int64.max
        var sampleRate = 0
        var lastWrite: TimeInterval = 0
        var meterPeak: Float = 0
        var meterFullScale: Int64 = 0
        var meterFrames: Int64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isCollecting: Bool { state.withLock { $0.users > 0 } }
    var currentSampleRate: Int { state.withLock { $0.sampleRate } }
    var framesWritten: Int64 { state.withLock { $0.writtenFrames } }
    var lastWriteTime: TimeInterval { state.withLock { $0.lastWrite } }

    func acquire() {
        state.withLock {
            $0.users += 1
            if $0.users == 1 { $0.collectFrom = $0.writtenFrames }
        }
    }

    func release() {
        state.withLock {
            $0.users = max(0, $0.users - 1)
            if $0.users == 0 { $0.collectFrom = .max }
        }
    }

    /// Called from the engine's tap with each buffer heard.
    func write(_ buffer: AVAudioPCMBuffer, time: TimeInterval) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        let rate = Int(buffer.format.sampleRate)
        // A diagnostic reader must never block the audio callback. Skipping a visualizer buffer
        // under contention is preferable to stalling playback; music samples are untouched.
        _ = state.withLockIfAvailable { s in
            s.sampleRate = rate
            let first = s.writtenFrames
            if s.users > 0 {
                var peak: Float = 0
                var fullScale: Int64 = 0
                for frame in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<count {
                        let sample = channels[c][frame]
                        let magnitude = abs(sample)
                        if magnitude > peak { peak = magnitude }
                        if magnitude >= Float(32_767.0 / 32_768.0) { fullScale += 1 }
                        sum += sample
                    }
                    s.ring[Int((first + Int64(frame)) & Int64(Self.mask))] = sum / Float(max(count, 1))
                }
                s.meterPeak = max(s.meterPeak, peak)
                s.meterFullScale += fullScale
                s.meterFrames += Int64(frames)
            }
            s.writtenFrames = first + Int64(frames)
            s.lastWrite = time
        }
    }

    /// Copies [count] mono samples ending [framesBeforeNewest] frames before the newest one.
    func read(into dest: inout [Float], count: Int, framesBeforeNewest: Int64) -> Bool {
        state.withLock { s in
            let newest = s.writtenFrames
            let from = s.collectFrom
            guard s.users > 0, newest > from else { return false }
            let end = newest - framesBeforeNewest.clamped(0, Int64(Self.capacity - count))
            let start = end - Int64(count)
            let oldestKept = max(from, newest - Int64(Self.capacity))
            for i in 0..<count {
                let frame = start + Int64(i)
                dest[i] = frame < oldestKept || frame >= newest ? 0 : s.ring[Int(frame & Int64(Self.mask))]
            }
            return end > oldestKept
        }
    }

    func meterReading() -> PeakReading {
        state.withLock { PeakReading(peak: $0.meterPeak, fullScaleSamples: $0.meterFullScale, frames: $0.meterFrames, sampleRateHz: $0.sampleRate) }
    }

    func resetMeter() {
        state.withLock {
            $0.meterPeak = 0
            $0.meterFullScale = 0
            $0.meterFrames = 0
        }
    }
}

/// What the peak meter saw: the largest sample magnitude (0..1), samples at full scale, frames measured.
struct PeakReading: Equatable {
    let peak: Float
    let fullScaleSamples: Int64
    let frames: Int64
    let sampleRateHz: Int

    var peakDbfs: Float? { frames == 0 || peak <= 0 ? nil : 20 * log10(peak) }
    var secondsMeasured: Float { sampleRateHz > 0 ? Float(frames) / Float(sampleRateHz) : 0 }
}
