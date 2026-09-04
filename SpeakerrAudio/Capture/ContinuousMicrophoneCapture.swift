import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

public struct CaptureTimestampAnchor: Sendable, Equatable, Codable {
    public let sampleIndex: Int
    public let hostTime: UInt64
    public let sampleTime: Double?
}

public struct CapturedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let anchors: [CaptureTimestampAnchor]

    public func sampleIndex(atHostTime requested: UInt64) throws -> Double {
        guard !anchors.isEmpty else { throw CalibrationSessionError.timestampUnavailable("Microphone input") }
        let targetNanos = AudioConvertHostTimeToNanos(requested)
        let anchor = anchors.min { lhs, rhs in
            abs(Int64(AudioConvertHostTimeToNanos(lhs.hostTime)) - Int64(targetNanos)) < abs(Int64(AudioConvertHostTimeToNanos(rhs.hostTime)) - Int64(targetNanos))
        }!
        let deltaNanos = Int64(targetNanos) - Int64(AudioConvertHostTimeToNanos(anchor.hostTime))
        return Double(anchor.sampleIndex) + Double(deltaNanos) * sampleRate / 1_000_000_000
    }

    public func hostTime(atSampleIndex requested: Double) throws -> UInt64 {
        guard !anchors.isEmpty else { throw CalibrationSessionError.timestampUnavailable("Microphone input") }
        let anchor = anchors.min { abs(Double($0.sampleIndex) - requested) < abs(Double($1.sampleIndex) - requested) }!
        let deltaNanos = (requested - Double(anchor.sampleIndex)) * 1_000_000_000 / sampleRate
        let anchorNanos = Double(AudioConvertHostTimeToNanos(anchor.hostTime))
        return AudioConvertNanosToHostTime(UInt64(max(0, anchorNanos + deltaNanos)))
    }
}

final class InputCaptureState: @unchecked Sendable {
    static let maximumFrames: UInt32 = 4096
    private let capacity: Int
    private let channelCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let channelBuffers: [UnsafeMutablePointer<Float>]
    private let audioBufferList: UnsafeMutableAudioBufferListPointer
    private let anchorCapacity: Int
    private let anchorIndices: UnsafeMutablePointer<Int>
    private let anchorHostTimes: UnsafeMutablePointer<UInt64>
    private let anchorSampleTimes: UnsafeMutablePointer<Double>
    private let publishedSampleCount = Atomic<Int>(0)
    private let publishedAnchorCount = Atomic<Int>(0)
    private let callbackStatus = Atomic<OSStatus>(noErr)
    private let didOverflow = Atomic<Bool>(false)
    private var writeIndex = 0
    private var anchorIndex = 0

    init(sampleRate: Double, durationSeconds: Double, channelCount: Int) {
        capacity = Int((sampleRate * durationSeconds).rounded(.up))
        self.channelCount = channelCount
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
        channelBuffers = (0..<channelCount).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: Int(Self.maximumFrames))
            pointer.initialize(repeating: 0, count: Int(Self.maximumFrames))
            return pointer
        }
        audioBufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        audioBufferList.count = channelCount
        for index in 0..<channelCount {
            audioBufferList[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: Self.maximumFrames * UInt32(MemoryLayout<Float>.size),
                mData: channelBuffers[index]
            )
        }
        anchorCapacity = max(1_024, Int(durationSeconds * sampleRate / 16))
        anchorIndices = .allocate(capacity: anchorCapacity)
        anchorHostTimes = .allocate(capacity: anchorCapacity)
        anchorSampleTimes = .allocate(capacity: anchorCapacity)
    }

    deinit {
        samples.deinitialize(count: capacity)
        samples.deallocate()
        for pointer in channelBuffers {
            pointer.deinitialize(count: Int(Self.maximumFrames))
            pointer.deallocate()
        }
        free(audioBufferList.unsafeMutablePointer)
        anchorIndices.deallocate()
        anchorHostTimes.deallocate()
        anchorSampleTimes.deallocate()
    }

    func capture(unit: AudioUnit, actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32) -> OSStatus {
        guard frameCount <= Self.maximumFrames else { return record(kAudioUnitErr_TooManyFramesToProcess) }
        guard timestamp.pointee.mFlags.contains(.hostTimeValid) else { return record(kAudio_ParamError) }
        let count = Int(frameCount)
        guard writeIndex + count <= capacity, anchorIndex < anchorCapacity else {
            didOverflow.store(true, ordering: .releasing)
            return noErr
        }
        for index in 0..<channelCount { audioBufferList[index].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size) }
        let status = AudioUnitRender(unit, actionFlags, timestamp, 1, frameCount, audioBufferList.unsafeMutablePointer)
        guard status == noErr else { return record(status) }

        anchorIndices[anchorIndex] = writeIndex
        anchorHostTimes[anchorIndex] = timestamp.pointee.mHostTime
        anchorSampleTimes[anchorIndex] = timestamp.pointee.mFlags.contains(.sampleTimeValid) ? timestamp.pointee.mSampleTime : .nan
        anchorIndex += 1
        publishedAnchorCount.store(anchorIndex, ordering: .releasing)

        let first = channelBuffers[0]
        if channelCount == 1 {
            memcpy(samples.advanced(by: writeIndex), first, count * MemoryLayout<Float>.size)
        } else {
            let scale = 1 / Float(channelCount)
            for frame in 0..<count {
                var mono: Float = 0
                for channel in 0..<channelCount { mono += channelBuffers[channel][frame] }
                samples[writeIndex + frame] = mono * scale
            }
        }
        writeIndex += count
        publishedSampleCount.store(writeIndex, ordering: .releasing)
        return noErr
    }

    func snapshot(sampleRate: Double) throws -> CapturedAudio {
        if didOverflow.load(ordering: .acquiring) { throw CalibrationSessionError.captureOverflow }
        let status = callbackStatus.load(ordering: .acquiring)
        if status != noErr { throw CalibrationSessionError.renderFailed(status) }
        let sampleCount = publishedSampleCount.load(ordering: .acquiring)
        let count = publishedAnchorCount.load(ordering: .acquiring)
        let copiedSamples = Array(UnsafeBufferPointer(start: samples, count: sampleCount))
        let anchors = (0..<count).map {
            CaptureTimestampAnchor(
                sampleIndex: anchorIndices[$0],
                hostTime: anchorHostTimes[$0],
                sampleTime: anchorSampleTimes[$0].isFinite ? anchorSampleTimes[$0] : nil
            )
        }
        return CapturedAudio(samples: copiedSamples, sampleRate: sampleRate, anchors: anchors)
    }

    private func record(_ status: OSStatus) -> OSStatus {
        callbackStatus.store(status, ordering: .releasing)
        return status
    }
}

final class ContinuousMicrophoneCapture {
    private let device: InputDevice
    private let sampleRate: Double
    private let state: InputCaptureState
    private var unit: AudioUnit?

    init(device: InputDevice, sampleRate: Double, maximumDurationSeconds: Double) throws {
        guard device.channelCount > 0 else { throw CalibrationSessionError.inputUnavailable(device.name) }
        self.device = device
        self.sampleRate = sampleRate
        state = InputCaptureState(sampleRate: sampleRate, durationSeconds: maximumDurationSeconds, channelCount: device.channelCount)
        unit = try createUnit()
    }

    deinit { stop() }

    func start() throws {
        guard let unit else { throw CalibrationSessionError.inputUnavailable(device.name) }
        try CoreAudioProperty.check(AudioOutputUnitStart(unit), "Start microphone capture")
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
    }

    func snapshot() throws -> CapturedAudio { try state.snapshot(sampleRate: sampleRate) }

    fileprivate func capture(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32) -> OSStatus {
        guard let unit else { return kAudio_ParamError }
        return state.capture(unit: unit, actionFlags: actionFlags, timestamp: timestamp, frameCount: frameCount)
    }

    private func createUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError("Find microphone HAL component", status: kAudioHardwareUnsupportedOperationError)
        }
        var optionalUnit: AudioUnit?
        try CoreAudioProperty.check(AudioComponentInstanceNew(component, &optionalUnit), "Create microphone Audio Unit")
        guard let unit = optionalUnit else { throw CalibrationSessionError.inputUnavailable(device.name) }
        do {
            var enableInput: UInt32 = 1
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size)), "Enable microphone input")
            var disableOutput: UInt32 = 0
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size)), "Disable microphone output")
            var deviceID = device.coreAudioID
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Bind microphone device")
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: UInt32(device.channelCount),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set raw microphone capture format")
            var maximumFrames = InputCaptureState.maximumFrames
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, UInt32(MemoryLayout<UInt32>.size)), "Set microphone maximum callback size")
            var callback = AURenderCallbackStruct(inputProc: speakerrMicrophoneInputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install microphone callback")
            try CoreAudioProperty.check(AudioUnitInitialize(unit), "Initialize microphone Audio Unit")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }
}

private let speakerrMicrophoneInputCallback: AURenderCallback = { refCon, flags, timestamp, _, frameCount, _ in
    Unmanaged<ContinuousMicrophoneCapture>.fromOpaque(refCon).takeUnretainedValue().capture(actionFlags: flags, timestamp: timestamp, frameCount: frameCount)
}
