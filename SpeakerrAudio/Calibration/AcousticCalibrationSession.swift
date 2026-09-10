import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

private final class ScheduledEmissionState: @unchecked Sendable {
    let pass: Int
    let sequence: Int
    let speakerIndex: Int
    let startFrame: Int64
    let hostTime = Atomic<UInt64>(0)

    init(pass: Int, sequence: Int, speakerIndex: Int, startFrame: Int64) {
        self.pass = pass
        self.sequence = sequence
        self.speakerIndex = speakerIndex
        self.startFrame = startFrame
    }
}

private final class CalibrationOutputRenderState: @unchecked Sendable {
    static let maximumFrames: UInt32 = 4096
    let renderedFrames = Atomic<Int64>(0)
    let callbackStatus = Atomic<OSStatus>(noErr)

    private let sampleRate: Double
    private let chirp: [Float]
    private let events: [ScheduledEmissionState]
    private let delays: [FractionalDelayLine]
    private let assignments: [OutputChannelAssignment]
    private let sourceLeft: [UnsafeMutablePointer<Float>]
    private let sourceRight: [UnsafeMutablePointer<Float>]
    private let delayedLeft: [UnsafeMutablePointer<Float>]
    private let delayedRight: [UnsafeMutablePointer<Float>]
    private var framePosition: Int64 = 0

    init(sampleRate: Double, chirp: [Float], channelCounts: [Int], initialDelays: [Double], events: [ScheduledEmissionState]) throws {
        self.sampleRate = sampleRate
        self.chirp = chirp
        self.events = events
        delays = try initialDelays.map { try FractionalDelayLine(sampleRate: sampleRate, initialDelayMilliseconds: $0) }
        assignments = OutputChannelMap.assignments(channelCounts: channelCounts)
        let capacity = Int(Self.maximumFrames)
        sourceLeft = channelCounts.map { _ in .allocate(capacity: capacity) }
        sourceRight = channelCounts.map { _ in .allocate(capacity: capacity) }
        delayedLeft = channelCounts.map { _ in .allocate(capacity: capacity) }
        delayedRight = channelCounts.map { _ in .allocate(capacity: capacity) }
    }

    deinit {
        (sourceLeft + sourceRight + delayedLeft + delayedRight).forEach { $0.deallocate() }
    }

    func setDelay(index: Int, milliseconds: Double) throws { try delays[index].setDelay(milliseconds: milliseconds) }

    func render(timestamp: UnsafePointer<AudioTimeStamp>, ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> OSStatus {
        guard frameCount <= Self.maximumFrames else { return record(kAudioUnitErr_TooManyFramesToProcess) }
        guard timestamp.pointee.mFlags.contains(.hostTimeValid) else { return record(kAudio_ParamError) }
        let count = Int(frameCount)
        let blockStart = framePosition
        let blockEnd = blockStart + Int64(count)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        guard OutputChannelMap.channelCount(in: buffers) >= assignments.reduce(0, { $0 + $1.count }) else { return record(kAudio_ParamError) }

        for route in assignments.indices {
            sourceLeft[route].update(repeating: 0, count: count)
            sourceRight[route].update(repeating: 0, count: count)
        }
        for event in events where event.startFrame < blockEnd && event.startFrame + Int64(chirp.count) > blockStart {
            if event.hostTime.load(ordering: .relaxed) == 0, event.startFrame >= blockStart {
                let frameOffset = event.startFrame - blockStart
                let nanos = UInt64((Double(frameOffset) * 1_000_000_000 / sampleRate).rounded())
                event.hostTime.store(timestamp.pointee.mHostTime + (AudioConvertNanosToHostTime(nanos) - AudioConvertNanosToHostTime(0)), ordering: .releasing)
            }
            let destinationStart = max(Int64(0), event.startFrame - blockStart)
            let sourceStart = max(Int64(0), blockStart - event.startFrame)
            let copyCount = min(Int64(chirp.count) - sourceStart, Int64(count) - destinationStart)
            guard copyCount > 0 else { continue }
            for offset in 0..<Int(copyCount) {
                let sample = chirp[Int(sourceStart) + offset]
                sourceLeft[event.speakerIndex][Int(destinationStart) + offset] = sample
                sourceRight[event.speakerIndex][Int(destinationStart) + offset] = sample
            }
        }

        for route in assignments.indices {
            delays[route].process(
                left: UnsafePointer(sourceLeft[route]), right: UnsafePointer(sourceRight[route]),
                outputLeft: delayedLeft[route], outputRight: delayedRight[route], frameCount: count
            )
            let assignment = assignments[route]
            for localChannel in 0..<assignment.count {
                switch assignment.source(forLocalChannel: localChannel) {
                case .mono:
                    for frame in 0..<count {
                        delayedLeft[route][frame] = (delayedLeft[route][frame] + delayedRight[route][frame]) * 0.5
                    }
                    OutputChannelMap.write(UnsafePointer(delayedLeft[route]), to: buffers, channel: assignment.offset + localChannel, frameCount: count)
                case .left:
                    OutputChannelMap.write(UnsafePointer(delayedLeft[route]), to: buffers, channel: assignment.offset + localChannel, frameCount: count)
                case .right:
                    OutputChannelMap.write(UnsafePointer(delayedRight[route]), to: buffers, channel: assignment.offset + localChannel, frameCount: count)
                case .silence: break
                }
            }
        }
        framePosition = blockEnd
        renderedFrames.store(blockEnd, ordering: .releasing)
        return noErr
    }

    private func record(_ status: OSStatus) -> OSStatus {
        callbackStatus.store(status, ordering: .releasing)
        return status
    }
}

public final class AcousticCalibrationSession: @unchecked Sendable {
    public let outputs: [OutputDevice]
    public let input: InputDevice
    public let configuration: CalibrationExperimentConfiguration
    public private(set) var sampleRate: Double = 0
    public private(set) var manualDelays: [Double]
    public private(set) var calibrationDelays = [0.0, 0.0]

    private let aggregateManager = AggregateDeviceManager()
    private let estimator: NormalizedCrossCorrelationEstimator
    private var aggregateSession: AggregateDeviceManager.Session?
    private var microphoneCapture: ContinuousMicrophoneCapture?
    private var outputUnit: AudioUnit?
    private var renderState: CalibrationOutputRenderState?
    private var events: [ScheduledEmissionState] = []
    private var reference: CalibrationSignal?
    private var running = false

    public init(outputs: [OutputDevice], input: InputDevice, configuration: CalibrationExperimentConfiguration = .init(), estimator: NormalizedCrossCorrelationEstimator = .init()) throws {
        guard outputs.count >= 2 else { throw AudioRoutingError.requiresAtLeastTwoOutputs }
        guard Set(outputs.map(\.id)).count == outputs.count else { throw AudioRoutingError.duplicateOutput }
        var configuration = configuration
        configuration.selectedSpeakerCount = outputs.count
        try configuration.validate()
        self.outputs = outputs
        self.input = input
        self.configuration = configuration
        self.estimator = estimator
        manualDelays = outputs.map(\.delayMilliseconds)
    }

    deinit { stopSynchronously() }

    public func start() async throws {
        guard !running else { throw AudioRoutingError.alreadyRunning }
        do {
            let aggregate = try aggregateManager.create(outputs: outputs)
            sampleRate = aggregate.sampleRate
            guard abs(input.sampleRate - sampleRate) < 0.01 else {
                throw CalibrationSessionError.requiresMatchingSampleRates(output: sampleRate, input: input.sampleRate)
            }
            let generated = try LogarithmicChirpGenerator(durationSeconds: configuration.chirpDurationSeconds, level: configuration.level).generate(sampleRate: sampleRate)
            let plannedEvents = makeEvents(sampleRate: sampleRate)
            let state = try CalibrationOutputRenderState(
                sampleRate: sampleRate,
                chirp: generated.samples,
                channelCounts: aggregate.channelCounts,
                initialDelays: zip(manualDelays, calibrationDelays).map(+),
                events: plannedEvents
            )
            let capture = try ContinuousMicrophoneCapture(device: input, sampleRate: sampleRate, maximumDurationSeconds: configuration.maximumSessionSeconds)
            let unit = try createOutputUnit(aggregate: aggregate, state: state)
            aggregateSession = aggregate
            reference = generated
            events = plannedEvents
            renderState = state
            microphoneCapture = capture
            outputUnit = unit
            try capture.start()
            try CoreAudioProperty.check(AudioOutputUnitStart(unit), "Start calibration output")
            running = true
        } catch {
            stopSynchronously()
            throw error
        }
    }

    public func setCalibrationDelays(_ delays: DelayCompensation) throws {
        let values = [delays.calibrationDelayA, delays.calibrationDelayB]
        for index in outputs.indices {
            guard index < values.count else { continue }
            let effective = manualDelays[index] + values[index]
            guard effective <= FractionalDelayLine.maximumDelayMilliseconds else { throw CalibrationMathError.compensationExceedsMaximum(effective) }
            try renderState?.setDelay(index: index, milliseconds: effective)
        }
        calibrationDelays = values
    }

    public func waitForPass(_ pass: Int) async throws -> CalibrationPassMeasurements {
        let passEvents = events.filter { $0.pass == pass }
        guard let final = passEvents.last, let renderState, let reference else { throw CalibrationSessionError.invalidConfiguration }
        let completionFrame = final.startFrame + Int64(reference.samples.count) + Int64((configuration.postRollSeconds * sampleRate).rounded())
        while renderState.renderedFrames.load(ordering: .acquiring) < completionFrame {
            let status = renderState.callbackStatus.load(ordering: .acquiring)
            if status != noErr { throw CalibrationSessionError.renderFailed(status) }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let captured = try microphoneCapture?.snapshot() else { throw CalibrationSessionError.inputUnavailable(input.name) }
        var bySpeaker = outputs.map { _ in [AcousticMeasurement]() }
        var failures: [String] = []
        for event in passEvents {
            guard bySpeaker[event.speakerIndex].count < configuration.measurementsPerSpeaker else { continue }
            do {
                bySpeaker[event.speakerIndex].append(try measure(event: event, captured: captured, reference: reference))
            } catch {
                failures.append("pass=\(pass + 1) sequence=\(event.sequence + 1) speaker=\(outputs[event.speakerIndex].name): \(error.localizedDescription)")
            }
        }
        for index in outputs.indices where bySpeaker[index].count < configuration.measurementsPerSpeaker {
            throw CalibrationSessionError.insufficientValidMeasurements(speaker: outputs[index].name, valid: bySpeaker[index].count, required: configuration.measurementsPerSpeaker)
        }
        return try CalibrationPassMeasurements(pass: pass, measurementsBySpeaker: bySpeaker, failures: failures)
    }

    public func capturedAudio() throws -> CapturedAudio {
        guard let microphoneCapture else { throw CalibrationSessionError.inputUnavailable(input.name) }
        return try microphoneCapture.snapshot()
    }

    public func allEmissions() -> [CalibrationEmission] {
        events.map { CalibrationEmission(pass: $0.pass, sequence: $0.sequence, speakerIndex: $0.speakerIndex, scheduledOutputFrame: $0.startFrame, scheduledOutputHostTime: $0.hostTime.load(ordering: .acquiring)) }
    }

    public func stop() async { stopSynchronously() }

    private func measure(event: ScheduledEmissionState, captured: CapturedAudio, reference: CalibrationSignal) throws -> AcousticMeasurement {
        let scheduledHost = event.hostTime.load(ordering: .acquiring)
        guard scheduledHost != 0 else { throw CalibrationSessionError.timestampUnavailable("Calibration output") }
        let scheduledInputIndex = try captured.sampleIndex(atHostTime: scheduledHost)
        let preSearchFrames = Int((0.02 * sampleRate).rounded())
        let sliceStart = max(0, Int(floor(scheduledInputIndex)) - preSearchFrames)
        let searchEnd = Int(ceil(scheduledInputIndex)) + Int((configuration.maximumAcousticLatencySeconds * sampleRate).rounded())
        let sliceEnd = min(captured.samples.count, searchEnd + reference.samples.count)
        guard sliceEnd - sliceStart >= reference.samples.count else { throw DelayEstimatorError.insufficientRecording }
        let recording = Array(captured.samples[sliceStart..<sliceEnd])
        let lower = max(0, Int(floor(scheduledInputIndex)) - sliceStart - preSearchFrames)
        let upper = min(recording.count - reference.samples.count + 1, searchEnd - sliceStart)
        let estimate = try estimator.estimateDelay(reference: reference.samples, recording: recording, sampleRate: sampleRate, searchRange: lower..<upper)
        let globalArrivalIndex = Double(sliceStart) + estimate.sampleOffset
        let arrivalHost = try captured.hostTime(atSampleIndex: globalArrivalIndex)
        let latencyNanos = Int64(AudioConvertHostTimeToNanos(arrivalHost)) - Int64(AudioConvertHostTimeToNanos(scheduledHost))
        let emission = CalibrationEmission(pass: event.pass, sequence: event.sequence, speakerIndex: event.speakerIndex, scheduledOutputFrame: event.startFrame, scheduledOutputHostTime: scheduledHost)
        return AcousticMeasurement(
            emission: emission,
            arrivalHostTime: arrivalHost,
            acousticLatencyMilliseconds: Double(latencyNanos) / 1_000_000,
            estimate: estimate
        )
    }

    private func makeEvents(sampleRate: Double) -> [ScheduledEmissionState] {
        var result: [ScheduledEmissionState] = []
        for pass in 0..<configuration.totalScheduledPasses {
            let start = configuration.passStartSeconds(pass)
            for sequence in 0..<configuration.eventsPerPass {
                result.append(ScheduledEmissionState(
                    pass: pass,
                    sequence: sequence,
                    speakerIndex: sequence % outputs.count,
                    startFrame: Int64(((start + Double(sequence) * configuration.intervalSeconds) * sampleRate).rounded())
                ))
            }
        }
        return result
    }

    private func createOutputUnit(aggregate: AggregateDeviceManager.Session, state: CalibrationOutputRenderState) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw CoreAudioError("Find calibration HAL component", status: kAudioHardwareUnsupportedOperationError) }
        var optionalUnit: AudioUnit?
        try CoreAudioProperty.check(AudioComponentInstanceNew(component, &optionalUnit), "Create calibration output Audio Unit")
        guard let unit = optionalUnit else { throw CoreAudioError("Create calibration output Audio Unit", status: kAudioHardwareUnspecifiedError) }
        do {
            var disableInput: UInt32 = 0
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableInput, UInt32(MemoryLayout<UInt32>.size)), "Disable calibration aggregate input")
            var deviceID = aggregate.deviceID
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Bind calibration aggregate")
            var format = AudioStreamBasicDescription(
                mSampleRate: aggregate.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size), mChannelsPerFrame: UInt32(aggregate.channelCounts.reduce(0, +)),
                mBitsPerChannel: 32, mReserved: 0
            )
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set calibration output format")
            var maximumFrames = CalibrationOutputRenderState.maximumFrames
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, UInt32(MemoryLayout<UInt32>.size)), "Set calibration maximum callback size")
            var callback = AURenderCallbackStruct(inputProc: speakerrCalibrationOutputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install calibration output callback")
            try CoreAudioProperty.check(AudioUnitInitialize(unit), "Initialize calibration output Audio Unit")
            return unit
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    fileprivate func render(timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, let renderState else { return kAudio_ParamError }
        return renderState.render(timestamp: timestamp, ioData: ioData, frameCount: frameCount)
    }

    private func stopSynchronously() {
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }
        microphoneCapture?.stop()
        microphoneCapture = nil
        renderState = nil
        reference = nil
        events = []
        aggregateSession = nil
        aggregateManager.destroy()
        running = false
    }
}

private let speakerrCalibrationOutputCallback: AURenderCallback = { refCon, _, timestamp, _, frameCount, ioData in
    Unmanaged<AcousticCalibrationSession>.fromOpaque(refCon).takeUnretainedValue().render(timestamp: timestamp, frameCount: frameCount, ioData: ioData)
}
