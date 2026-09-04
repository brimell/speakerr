import AudioToolbox
import CoreAudio
import Foundation
import os
import Synchronization

public struct RoutingStatus: Sendable {
    public let isRunning: Bool
    public let sampleRate: Double?
    public let clockDeviceUID: String?
    public let driftCompensatedDeviceUIDs: [String]
    public let outputs: [OutputDevice]
    public let lastRenderError: OSStatus?
}

private final class AggregateRenderState {
    static let maximumFrames: UInt32 = 4096

    private let generator: TransientSignalGenerator
    private let delays: [FractionalDelayLine]
    private let assignments: [OutputChannelAssignment]
    private let sourceLeft: UnsafeMutablePointer<Float>
    private let sourceRight: UnsafeMutablePointer<Float>
    private let delayedLeft: [UnsafeMutablePointer<Float>]
    private let delayedRight: [UnsafeMutablePointer<Float>]

    init(sampleRate: Double, channelCounts: [Int], initialDelays: [Double]) throws {
        generator = TransientSignalGenerator(sampleRate: sampleRate)
        delays = try initialDelays.map { try FractionalDelayLine(sampleRate: sampleRate, initialDelayMilliseconds: $0) }
        assignments = OutputChannelMap.assignments(channelCounts: channelCounts)
        let capacity = Int(Self.maximumFrames)
        sourceLeft = .allocate(capacity: capacity)
        sourceRight = .allocate(capacity: capacity)
        delayedLeft = channelCounts.map { _ in .allocate(capacity: capacity) }
        delayedRight = channelCounts.map { _ in .allocate(capacity: capacity) }
    }

    deinit {
        sourceLeft.deallocate()
        sourceRight.deallocate()
        delayedLeft.forEach { $0.deallocate() }
        delayedRight.forEach { $0.deallocate() }
    }

    func setDelay(index: Int, milliseconds: Double) throws {
        try delays[index].setDelay(milliseconds: milliseconds)
    }

    func render(ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> OSStatus {
        guard frameCount <= Self.maximumFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        let count = Int(frameCount)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)

        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard OutputChannelMap.channelCount(in: buffers) >= assignments.reduce(0, { $0 + $1.count }) else { return kAudio_ParamError }

        generator.render(left: sourceLeft, right: sourceRight, frameCount: count)
        for routeIndex in assignments.indices {
            delays[routeIndex].process(
                left: UnsafePointer(sourceLeft),
                right: UnsafePointer(sourceRight),
                outputLeft: delayedLeft[routeIndex],
                outputRight: delayedRight[routeIndex],
                frameCount: count
            )
            let assignment = assignments[routeIndex]
            for localChannel in 0..<assignment.count {
                switch assignment.source(forLocalChannel: localChannel) {
                case .mono:
                    for frame in 0..<count {
                        delayedLeft[routeIndex][frame] = (delayedLeft[routeIndex][frame] + delayedRight[routeIndex][frame]) * 0.5
                    }
                    OutputChannelMap.write(UnsafePointer(delayedLeft[routeIndex]), to: buffers, channel: assignment.offset + localChannel, frameCount: count)
                case .left:
                    OutputChannelMap.write(UnsafePointer(delayedLeft[routeIndex]), to: buffers, channel: assignment.offset + localChannel, frameCount: count)
                case .right:
                    OutputChannelMap.write(UnsafePointer(delayedRight[routeIndex]), to: buffers, channel: assignment.offset + localChannel, frameCount: count)
                case .silence:
                    break
                }
            }
        }
        return noErr
    }
}

public final class CoreAudioAggregateRoutingBackend: AudioRoutingBackend, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.brimell.speakerr", category: "Routing")
    private let aggregateManager = AggregateDeviceManager()
    private let callbackStatus = Atomic<OSStatus>(noErr)
    private var configuredOutputs: [OutputDevice] = []
    private var aggregateSession: AggregateDeviceManager.Session?
    private var outputUnit: AudioUnit?
    private var renderState: AggregateRenderState?
    private var running = false

    public init() {}
    deinit { stopSynchronously() }

    public func configureOutputs(_ outputs: [OutputDevice]) async throws {
        guard !running else { throw AudioRoutingError.alreadyRunning }
        let enabled = outputs.filter(\.enabled)
        guard enabled.count == 2 else { throw AudioRoutingError.requiresExactlyTwoOutputs }
        guard enabled[0].id != enabled[1].id else { throw AudioRoutingError.duplicateOutput }
        for output in enabled where output.isAggregate {
            throw AudioRoutingError.aggregateOutputUnsupported(output.name)
        }
        configuredOutputs = enabled
        logger.info("Configured A id=\(enabled[0].coreAudioID, privacy: .public) uid=\(enabled[0].id, privacy: .public) name=\(enabled[0].name, privacy: .public) rate=\(enabled[0].sampleRate, privacy: .public) channels=\(enabled[0].channelCount, privacy: .public)")
        logger.info("Configured B id=\(enabled[1].coreAudioID, privacy: .public) uid=\(enabled[1].id, privacy: .public) name=\(enabled[1].name, privacy: .public) rate=\(enabled[1].sampleRate, privacy: .public) channels=\(enabled[1].channelCount, privacy: .public)")
    }

    public func setDelay(deviceID: String, milliseconds: Double) async throws {
        guard (0...FractionalDelayLine.maximumDelayMilliseconds).contains(milliseconds) else {
            throw AudioRoutingError.delayOutOfRange(milliseconds)
        }
        guard let index = configuredOutputs.firstIndex(where: { $0.id == deviceID }) else {
            throw AudioRoutingError.outputNotConfigured(deviceID)
        }
        configuredOutputs[index].delayMilliseconds = milliseconds
        try renderState?.setDelay(index: index, milliseconds: milliseconds)
        logger.info("Set delay uid=\(deviceID, privacy: .public) milliseconds=\(milliseconds, privacy: .public)")
    }

    public func start() async throws {
        guard !running else { throw AudioRoutingError.alreadyRunning }
        guard configuredOutputs.count == 2 else { throw AudioRoutingError.notConfigured }
        do {
            let session = try aggregateManager.create(outputs: configuredOutputs)
            let state = try AggregateRenderState(
                sampleRate: session.sampleRate,
                channelCounts: session.channelCounts,
                initialDelays: configuredOutputs.map(\.delayMilliseconds)
            )
            let unit = try createOutputUnit(session: session)
            aggregateSession = session
            renderState = state
            outputUnit = unit
            callbackStatus.store(noErr, ordering: .relaxed)
            try CoreAudioProperty.check(AudioOutputUnitStart(unit), "Start aggregate output")
            running = true
            logger.info("Playback started aggregate=\(session.deviceID, privacy: .public) rate=\(session.sampleRate, privacy: .public) channelCounts=\(String(describing: session.channelCounts), privacy: .public)")
        } catch {
            stopSynchronously()
            throw error
        }
    }

    public func stop() async {
        stopSynchronously()
    }

    public func status() -> RoutingStatus {
        RoutingStatus(
            isRunning: running,
            sampleRate: aggregateSession?.sampleRate,
            clockDeviceUID: aggregateSession?.mainDeviceUID,
            driftCompensatedDeviceUIDs: aggregateSession?.driftCompensatedUIDs ?? [],
            outputs: configuredOutputs,
            lastRenderError: callbackStatus.load(ordering: .relaxed) == noErr ? nil : callbackStatus.load(ordering: .relaxed)
        )
    }

    fileprivate func render(ioData: UnsafeMutablePointer<AudioBufferList>?, frameCount: UInt32) -> OSStatus {
        guard let ioData, let renderState else { return kAudio_ParamError }
        let status = renderState.render(ioData: ioData, frameCount: frameCount)
        if status != noErr { callbackStatus.store(status, ordering: .relaxed) }
        return status
    }

    private func createOutputUnit(session: AggregateDeviceManager.Session) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError("Find HAL output component", status: kAudioHardwareUnsupportedOperationError)
        }
        var optionalUnit: AudioUnit?
        try CoreAudioProperty.check(AudioComponentInstanceNew(component, &optionalUnit), "Create aggregate output Audio Unit")
        guard let unit = optionalUnit else { throw CoreAudioError("Create aggregate output Audio Unit", status: kAudioHardwareUnspecifiedError) }

        do {
            var disableInput: UInt32 = 0
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableInput, UInt32(MemoryLayout<UInt32>.size)), "Disable aggregate input")
            var deviceID = session.deviceID
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Bind aggregate output device")

            let totalChannels = session.channelCounts.reduce(0, +)
            var format = AudioStreamBasicDescription(
                mSampleRate: session.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: UInt32(totalChannels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set aggregate output format")
            var maximumFrames = AggregateRenderState.maximumFrames
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, UInt32(MemoryLayout<UInt32>.size)), "Set maximum output callback size")
            var callback = AURenderCallbackStruct(inputProc: speakerrAggregateRenderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install aggregate render callback")
            try CoreAudioProperty.check(AudioUnitInitialize(unit), "Initialize aggregate output Audio Unit")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func stopSynchronously() {
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }
        renderState = nil
        aggregateSession = nil
        aggregateManager.destroy()
        if running { logger.info("Playback stopped") }
        running = false
    }
}

private let speakerrAggregateRenderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    return Unmanaged<CoreAudioAggregateRoutingBackend>.fromOpaque(refCon).takeUnretainedValue().render(ioData: ioData, frameCount: frameCount)
}
