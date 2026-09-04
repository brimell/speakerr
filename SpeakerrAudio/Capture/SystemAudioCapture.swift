import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

public struct SampleRateConversionPlan: Sendable, Equatable {
    public let captureRate: Double
    public let renderRate: Double
    public var ratio: Double { renderRate / captureRate }
    public var requiresConversion: Bool { abs(captureRate - renderRate) >= 0.01 }

    public init(captureRate: Double, renderRate: Double) {
        self.captureRate = captureRate
        self.renderRate = renderRate
    }
}

public enum SystemAudioCaptureError: LocalizedError, Equatable {
    case requiresStereo(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .requiresStereo(let name): "System-audio input \(name) does not expose two channels."
        case .unavailable(let name): "System-audio input \(name) is unavailable."
        }
    }
}

private final class SystemAudioCaptureState: @unchecked Sendable {
    static let maximumFrames: UInt32 = 4096
    private let transport: StereoRingBuffer
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let callbackStatus = Atomic<OSStatus>(noErr)

    init(transport: StereoRingBuffer) {
        self.transport = transport
        let count = Int(Self.maximumFrames)
        left = .allocate(capacity: count)
        right = .allocate(capacity: count)
        left.initialize(repeating: 0, count: count)
        right.initialize(repeating: 0, count: count)
        buffers = AudioBufferList.allocate(maximumBuffers: 2)
        buffers.count = 2
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: Self.maximumFrames * 4, mData: left)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: Self.maximumFrames * 4, mData: right)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        free(buffers.unsafeMutablePointer)
    }

    func capture(unit: AudioUnit, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32) -> OSStatus {
        guard frameCount <= Self.maximumFrames else { return record(kAudioUnitErr_TooManyFramesToProcess) }
        buffers[0].mDataByteSize = frameCount * 4
        buffers[1].mDataByteSize = frameCount * 4
        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, buffers.unsafeMutablePointer)
        guard status == noErr else { return record(status) }
        transport.write(left: UnsafePointer(left), right: UnsafePointer(right), frameCount: Int(frameCount))
        return noErr
    }

    var lastError: OSStatus? {
        let status = callbackStatus.load(ordering: .acquiring)
        return status == noErr ? nil : status
    }

    private func record(_ status: OSStatus) -> OSStatus {
        callbackStatus.store(status, ordering: .releasing)
        return status
    }
}

/// Raw AUHAL capture for a virtual stereo device such as BlackHole. Setting the
/// AUHAL client-side format to the renderer rate delegates bounded, native sample
/// rate conversion to the AudioUnit when the device and aggregate rates differ.
public final class SystemAudioCapture: @unchecked Sendable {
    public let device: InputDevice
    public let conversion: SampleRateConversionPlan
    private let state: SystemAudioCaptureState
    private var unit: AudioUnit?
    private var running = false

    public init(device: InputDevice, renderSampleRate: Double, transport: StereoRingBuffer) throws {
        guard device.channelCount >= 2 else { throw SystemAudioCaptureError.requiresStereo(device.name) }
        self.device = device
        conversion = SampleRateConversionPlan(captureRate: device.sampleRate, renderRate: renderSampleRate)
        state = SystemAudioCaptureState(transport: transport)
        unit = try createUnit(clientSampleRate: renderSampleRate)
    }

    deinit { stop() }

    public func start() throws {
        guard !running, let unit else { return }
        try CoreAudioProperty.check(AudioOutputUnitStart(unit), "Start system-audio capture")
        running = true
    }

    public func pause() {
        guard running, let unit else { return }
        AudioOutputUnitStop(unit)
        running = false
    }

    public func stop() {
        guard let unit else { return }
        pause()
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        running = false
    }

    public var lastError: OSStatus? { state.lastError }

    fileprivate func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32) -> OSStatus {
        guard let unit else { return kAudio_ParamError }
        return state.capture(unit: unit, flags: flags, timestamp: timestamp, frameCount: frameCount)
    }

    private func createUnit(clientSampleRate: Double) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw SystemAudioCaptureError.unavailable(device.name) }
        var optionalUnit: AudioUnit?
        try CoreAudioProperty.check(AudioComponentInstanceNew(component, &optionalUnit), "Create system-audio capture unit")
        guard let unit = optionalUnit else { throw SystemAudioCaptureError.unavailable(device.name) }
        do {
            var enabled: UInt32 = 1
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4), "Enable system-audio input")
            var disabled: UInt32 = 0
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, 4), "Disable system-audio capture output")
            var deviceID = device.coreAudioID
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Bind system-audio input")
            var format = AudioStreamBasicDescription(
                mSampleRate: clientSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
            )
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set system-audio client format")
            var maximumFrames = SystemAudioCaptureState.maximumFrames
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, 4), "Set system-audio maximum callback size")
            var callback = AURenderCallbackStruct(inputProc: speakerrSystemAudioInputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install system-audio callback")
            try CoreAudioProperty.check(AudioUnitInitialize(unit), "Initialize system-audio capture unit")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }
}

private let speakerrSystemAudioInputCallback: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
    Unmanaged<SystemAudioCapture>.fromOpaque(refCon).takeUnretainedValue().capture(flags: flags, timestamp: timestamp, frameCount: frames)
}
