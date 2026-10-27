import AudioToolbox
import Foundation
import os

/// One deck's transition stage on the audio thread (Android's TransitionGainProcessor): the volume
/// curve, the bass-swap low shelf and the filter sweep, applied sample by sample in content time.
///
/// An automation is armed with the host time at which it starts. The first buffer after arming
/// converts that into the render timeline's sample time, so the fade lines up exactly with the
/// deck that starts playing at the same host time. Idle (the normal case) it leaves audio untouched.
final class TransitionStageKernel: RenderKernel, @unchecked Sendable {
    private enum Command {
        case arm(TransitionAutomation, startHostTime: UInt64)
        case cancel
    }

    struct Status: Equatable {
        var engaged = false
        var started = false
        var silent = false
    }

    private let commands = OSAllocatedUnfairLock<Command?>(initialState: nil)
    private let status = OSAllocatedUnfairLock(initialState: Status())

    // Audio thread only.
    private var automation: TransitionAutomation?
    private var startHostTime: UInt64 = 0
    private var startSampleTime: Double?
    private var sampleRate = 44_100
    private var shelves: [BiquadFilter] = []
    private var shelfDb = Float.nan
    private var sweeps: [PassFilter] = []
    private var sweepSetting: FilterSetting?

    private static let filterUpdateFrames = 32
    private static let filterStepDb: Float = 0.05
    private static let shelfSlope: Float = 0.707
    private static let cutoffStep: Float = 0.005

    private static let ticksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Host-clock ticks in [seconds] (for scheduling a start a little ahead).
    static func hostTicks(forSeconds seconds: Double) -> UInt64 {
        UInt64((seconds / ticksToSeconds).rounded())
    }

    /// True while an automation is waiting to start or still shaping the audio.
    var isEngaged: Bool { status.withLock { $0.engaged } }
    /// True once the armed automation has reached its start.
    var hasStarted: Bool { status.withLock { $0.started } }
    /// True once an outgoing fade is over: the deck can be stopped.
    var isSilent: Bool { status.withLock { $0.silent } }

    func arm(_ automation: TransitionAutomation, startHostTime: UInt64) {
        commands.withLock { $0 = .arm(automation, startHostTime: startHostTime) }
        status.withLock { $0 = Status(engaged: true, started: false, silent: false) }
    }

    /// Back to unity gain at once.
    func cancel() {
        commands.withLock { $0 = .cancel }
        status.withLock { $0 = Status() }
    }

    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = Int(sampleRate)
        shelves = Array(repeating: BiquadFilter(), count: channels)
        sweeps = Array(repeating: PassFilter(), count: channels)
        shelfDb = .nan
        sweepSetting = nil
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, timestamp: UnsafePointer<AudioTimeStamp>) {
        if let command = commands.withLockIfAvailable({ value -> Command? in
            defer { value = nil }
            return value
        }) ?? nil {
            switch command {
            case .arm(let next, let host):
                automation = next
                startHostTime = host
                startSampleTime = nil
                resetFilters()
            case .cancel:
                automation = nil
            }
        }
        guard let automation else { return }
        let ts = timestamp.pointee
        if startSampleTime == nil {
            guard ts.mFlags.contains(.sampleTimeValid) else { return }
            if ts.mFlags.contains(.hostTimeValid) {
                let deltaSeconds = (Double(startHostTime) - Double(ts.mHostTime)) * Self.ticksToSeconds
                startSampleTime = ts.mSampleTime + deltaSeconds * Double(sampleRate)
            } else {
                startSampleTime = ts.mSampleTime
            }
        }
        let start = startSampleTime ?? ts.mSampleTime
        let msPerFrame = 1000.0 / Double(sampleRate)
        let bass = automation.spec.bassSwap
        let sweep = automation.spec.filter.affects(automation.role)
        if shelves.count != buffers.count { prepare(sampleRate: Double(sampleRate), channels: buffers.count) }

        for i in 0..<frames {
            let frame = ts.mSampleTime + Double(i) - start
            let ms = frame * msPerFrame
            let gain = automation.gainAt(ms)
            if i % Self.filterUpdateFrames == 0 {
                if bass { updateShelves(automation.bassDbAt(ms)) }
                if sweep { updateSweeps(automation.filterAt(ms)) }
            }
            for channel in 0..<buffers.count {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var x = data[i]
                if sweep { x = sweeps[channel].process(x) }
                if bass { x = shelves[channel].process(x) }
                data[i] = x * gain
            }
        }

        let endMs = (ts.mSampleTime + Double(frames) - start) * msPerFrame
        let begun = endMs > 0
        if automation.isFinished(endMs) {
            self.automation = nil
            _ = status.withLockIfAvailable { $0 = Status() }
        } else {
            let silent = automation.isSilentForGood(endMs)
            _ = status.withLockIfAvailable { $0 = Status(engaged: true, started: begun, silent: silent) }
        }
    }

    private func resetFilters() {
        for i in shelves.indices { shelves[i].reset() }
        for i in sweeps.indices { sweeps[i].reset() }
        shelfDb = .nan
        sweepSetting = nil
    }

    private func updateShelves(_ db: Float) {
        if !shelfDb.isNaN, abs(db - shelfDb) < Self.filterStepDb { return }
        shelfDb = db
        for i in shelves.indices {
            shelves[i].configure(
                centerFrequency: TransitionSpec.bassShelfHz, sampleRate: sampleRate, gainInDb: db,
                q: Self.shelfSlope, type: .lowShelf
            )
        }
    }

    /// Moves the sweep's cutoff in steps under 1 % (inaudible as steps), keeping the filter state.
    private func updateSweeps(_ setting: FilterSetting?) {
        guard let setting else { return }
        if let current = sweepSetting, current.type == setting.type, abs(setting.hz / current.hz - 1) < Self.cutoffStep { return }
        sweepSetting = setting
        for i in sweeps.indices {
            sweeps[i].configure(setting.type, cutoffHz: setting.hz, sampleRate: sampleRate)
        }
    }
}
