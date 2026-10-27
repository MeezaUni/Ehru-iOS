import AudioToolbox
import AVFoundation
import Foundation

/// DSP that runs inside the audio engine's render thread.
protocol RenderKernel: AnyObject {
    func prepare(sampleRate: Double, channels: Int)
    /// Processes deinterleaved float audio in place.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, timestamp: UnsafePointer<AudioTimeStamp>)
}

/// A tiny in-process audio effect that hands its audio to a [RenderKernel]. This is how the app's
/// own DSP (ported from the Android app) sits in AVAudioEngine's graph.
final class KernelAudioUnit: AUAudioUnit {
    final class Holder: @unchecked Sendable {
        var kernel: RenderKernel?
        var buffer: AVAudioPCMBuffer?
    }

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("ehrk"),
        componentManufacturer: fourCharCode("Ehru"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(KernelAudioUnit.self, as: componentDescription, name: "Ehru: Kernel", version: 1)
    }()

    /// An AVAudioUnit node running [kernel], ready to attach to an engine.
    static func make(kernel: RenderKernel) async throws -> AVAudioUnit {
        _ = registration
        let unit = try await AVAudioUnit.instantiate(with: componentDescription, options: [.loadInProcess])
        (unit.auAudioUnit as? KernelAudioUnit)?.holder.kernel = kernel
        return unit
    }

    let holder = Holder()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 8
        outputBus.maximumChannelCount = 8
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = inputBus.format
        holder.buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesToRender)
        holder.kernel?.prepare(sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }

    override func deallocateRenderResources() {
        holder.buffer = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let holder = self.holder
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock, let buffer = holder.buffer else { return kAudioUnitErr_NoConnection }
            guard frameCount <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let inputList = buffer.mutableAudioBufferList
            let input = UnsafeMutableAudioBufferListPointer(inputList)
            let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
            for i in 0..<input.count {
                input[i].mDataByteSize = byteSize
            }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, inputList)
            if status != noErr { return status }

            let output = UnsafeMutableAudioBufferListPointer(outputData)
            for i in 0..<min(output.count, input.count) {
                if output[i].mData == nil {
                    output[i].mData = input[i].mData
                } else if output[i].mData != input[i].mData, let destination = output[i].mData, let source = input[i].mData {
                    memcpy(destination, source, Int(byteSize))
                }
                output[i].mDataByteSize = byteSize
            }
            holder.kernel?.process(output, frames: Int(frameCount), timestamp: timestamp)
            return noErr
        }
    }
}

func fourCharCode(_ text: String) -> FourCharCode {
    text.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}
