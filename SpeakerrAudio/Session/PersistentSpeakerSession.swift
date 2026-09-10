import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

private final class RouteVolume: @unchecked Sendable {
    let value: Atomic<UInt32>
    init(_ volume: Float = 1) { value = Atomic(volume.bitPattern) }
}

enum PersistentRenderMode: UInt32 {
    case muted = 0
    case programme = 1
    case calibration = 2
}

final class PersistentRenderState: @unchecked Sendable {
    static let maximumFrames: UInt32 = 4096
    let renderedFrames = Atomic<Int64>(0)
    let callbackCount = Atomic<UInt64>(0)
    let callbackStatus = Atomic<OSStatus>(noErr)
    let requestedEmission = Atomic<UInt64>(0)
    let emissionSpeaker = Atomic<Int>(0)
    let emissionStartFrame = Atomic<Int64>(-1)
    let emissionHostTime = Atomic<UInt64>(0)

    private let sampleRate: Double
    private let chirp: [Float]
    private let transport: StereoRingBuffer
    private let delays: [FractionalDelayLine]
    private let assignments: [OutputChannelAssignment]
    private let masterEQ: ParametricEQ
    private let routeEQs: [ParametricEQ]
    private let routeVolumes: [RouteVolume]
    private let mode = Atomic<UInt32>(PersistentRenderMode.muted.rawValue)
    private let sourceLeft: UnsafeMutablePointer<Float>
    private let sourceRight: UnsafeMutablePointer<Float>
    private let routeLeft: [UnsafeMutablePointer<Float>]
    private let routeRight: [UnsafeMutablePointer<Float>]
    private let delayedLeft: [UnsafeMutablePointer<Float>]
    private let delayedRight: [UnsafeMutablePointer<Float>]
    private var framePosition: Int64 = 0
    private var observedEmission: UInt64 = 0
    private var activeEmissionStart: Int64 = -1
    private var activeEmissionSpeaker = 0
    private var programmePrimed = false
    private var previousMode = PersistentRenderMode.muted

    private let routingMode: SpeakerRoutingMode

    init(sampleRate: Double, chirp: [Float], transport: StereoRingBuffer, channelCounts: [Int], delays initialDelays: [Double], routingMode: SpeakerRoutingMode) throws {
        self.sampleRate = sampleRate
        self.chirp = chirp
        self.transport = transport
        self.routingMode = routingMode
        delays = try initialDelays.map { try FractionalDelayLine(sampleRate: sampleRate, initialDelayMilliseconds: $0) }
        assignments = OutputChannelMap.assignments(channelCounts: channelCounts)
        masterEQ = ParametricEQ(sampleRate: sampleRate)
        routeEQs = channelCounts.map { _ in ParametricEQ(sampleRate: sampleRate) }
        routeVolumes = channelCounts.map { _ in RouteVolume() }
        let capacity = Int(Self.maximumFrames)
        sourceLeft = .allocate(capacity: capacity)
        sourceRight = .allocate(capacity: capacity)
        routeLeft = channelCounts.map { _ in .allocate(capacity: capacity) }
        routeRight = channelCounts.map { _ in .allocate(capacity: capacity) }
        delayedLeft = channelCounts.map { _ in .allocate(capacity: capacity) }
        delayedRight = channelCounts.map { _ in .allocate(capacity: capacity) }
    }

    deinit {
        sourceLeft.deallocate(); sourceRight.deallocate()
        (routeLeft + routeRight + delayedLeft + delayedRight).forEach { $0.deallocate() }
    }

    func setMode(_ value: PersistentRenderMode) {
        mode.store(value.rawValue, ordering: .releasing)
    }

    func setDelay(index: Int, milliseconds: Double) throws { try delays[index].setDelay(milliseconds: milliseconds) }

    func setMasterEQBands(_ bands: [EQBand]) {
        masterEQ.setBands(bands)
    }

    func setMasterEQBypass(_ bypass: Bool) {
        masterEQ.bypass = bypass
    }

    func setRouteEQBands(route: Int, bands: [EQBand]) {
        guard routeEQs.indices.contains(route) else { return }
        routeEQs[route].setBands(bands)
    }

    func setRouteEQBypass(route: Int, bypass: Bool) {
        guard routeEQs.indices.contains(route) else { return }
        routeEQs[route].bypass = bypass
    }

    func setRouteVolume(route: Int, volume: Float) {
        let bits = max(0, min(1, volume)).bitPattern
        guard routeVolumes.indices.contains(route) else { return }
        routeVolumes[route].value.store(bits, ordering: .relaxed)
    }

    func requestEmission(speaker: Int) -> UInt64 {
        emissionSpeaker.store(speaker, ordering: .relaxed)
        emissionStartFrame.store(-1, ordering: .relaxed)
        emissionHostTime.store(0, ordering: .relaxed)
        let generation = requestedEmission.wrappingAdd(1, ordering: .releasing).newValue
        return generation
    }

    func render(timestamp: UnsafePointer<AudioTimeStamp>, ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> OSStatus {
        guard frameCount <= Self.maximumFrames else { return record(kAudioUnitErr_TooManyFramesToProcess) }
        guard timestamp.pointee.mFlags.contains(.hostTimeValid) else { return record(kAudio_ParamError) }
        let count = Int(frameCount)
        let blockStart = framePosition
        let blockEnd = blockStart + Int64(count)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        guard OutputChannelMap.channelCount(in: buffers) >= assignments.reduce(0, { $0 + $1.count }) else { return record(kAudio_ParamError) }

        sourceLeft.initialize(repeating: 0, count: count)
        sourceRight.initialize(repeating: 0, count: count)
        let currentMode = PersistentRenderMode(rawValue: mode.load(ordering: .acquiring)) ?? .muted
        if currentMode != previousMode {
            programmePrimed = false
            previousMode = currentMode
        }
        if currentMode == .programme {
            let prefill = count * 4
            if !programmePrimed, transport.availableFrames >= prefill { programmePrimed = true }
            if programmePrimed {
                let fetched = transport.read(left: sourceLeft, right: sourceRight, frameCount: count)
                if fetched < count { programmePrimed = false }
                if routingMode == .mono {
                    for frame in 0..<count {
                        let mono = (sourceLeft[frame] + sourceRight[frame]) * 0.5
                        sourceLeft[frame] = mono
                        sourceRight[frame] = mono
                    }
                }
                masterEQ.process(buffer: sourceLeft, frameCount: count, channel: 0)
                masterEQ.process(buffer: sourceRight, frameCount: count, channel: 1)
            }
        } else if currentMode == .calibration {
            renderCalibration(timestamp: timestamp, blockStart: blockStart, blockEnd: blockEnd, count: count)
        }

        for route in assignments.indices {
            memcpy(routeLeft[route], sourceLeft, count * MemoryLayout<Float>.size)
            memcpy(routeRight[route], sourceRight, count * MemoryLayout<Float>.size)
            if currentMode == .calibration, route != activeEmissionSpeaker {
                routeLeft[route].initialize(repeating: 0, count: count)
                routeRight[route].initialize(repeating: 0, count: count)
            } else if currentMode == .programme {
                routeEQs[route].process(buffer: routeLeft[route], frameCount: count, channel: 0)
                routeEQs[route].process(buffer: routeRight[route], frameCount: count, channel: 1)
                let volumeBits = routeVolumes[route].value.load(ordering: .relaxed)
                let volume = Float(bitPattern: volumeBits)
                if volume < 1 {
                    for frame in 0..<count {
                        routeLeft[route][frame] *= volume
                        routeRight[route][frame] *= volume
                    }
                }
            }
            delays[route].process(left: UnsafePointer(routeLeft[route]), right: UnsafePointer(routeRight[route]), outputLeft: delayedLeft[route], outputRight: delayedRight[route], frameCount: count)
            let assignment = assignments[route]
            for channel in 0..<assignment.count {
                switch assignment.source(forLocalChannel: channel) {
                case .mono:
                    for frame in 0..<count {
                        delayedLeft[route][frame] = (delayedLeft[route][frame] + delayedRight[route][frame]) * 0.5
                    }
                    OutputChannelMap.write(UnsafePointer(delayedLeft[route]), to: buffers, channel: assignment.offset + channel, frameCount: count)
                case .left:
                    OutputChannelMap.write(UnsafePointer(delayedLeft[route]), to: buffers, channel: assignment.offset + channel, frameCount: count)
                case .right:
                    OutputChannelMap.write(UnsafePointer(delayedRight[route]), to: buffers, channel: assignment.offset + channel, frameCount: count)
                case .silence: break
                }
            }
        }
        framePosition = blockEnd
        renderedFrames.store(blockEnd, ordering: .releasing)
        callbackCount.wrappingAdd(1, ordering: .relaxed)
        return noErr
    }

    private func renderCalibration(timestamp: UnsafePointer<AudioTimeStamp>, blockStart: Int64, blockEnd: Int64, count: Int) {
        let request = requestedEmission.load(ordering: .acquiring)
        if request != observedEmission {
            observedEmission = request
            activeEmissionSpeaker = emissionSpeaker.load(ordering: .relaxed)
            activeEmissionStart = blockEnd + 512
            emissionStartFrame.store(activeEmissionStart, ordering: .releasing)
        }
        guard activeEmissionStart >= 0,
              activeEmissionStart < blockEnd,
              activeEmissionStart + Int64(chirp.count) > blockStart else { return }
        if emissionHostTime.load(ordering: .relaxed) == 0, activeEmissionStart >= blockStart {
            let offset = activeEmissionStart - blockStart
            let nanos = UInt64((Double(offset) * 1_000_000_000 / sampleRate).rounded())
            emissionHostTime.store(timestamp.pointee.mHostTime + AudioConvertNanosToHostTime(nanos), ordering: .releasing)
        }
        let destinationStart = max(Int64(0), activeEmissionStart - blockStart)
        let sourceStart = max(Int64(0), blockStart - activeEmissionStart)
        let copyCount = min(Int64(chirp.count) - sourceStart, Int64(count) - destinationStart)
        guard copyCount > 0 else { return }
        for offset in 0..<Int(copyCount) {
            let sample = chirp[Int(sourceStart) + offset]
            sourceLeft[Int(destinationStart) + offset] = sample
            sourceRight[Int(destinationStart) + offset] = sample
        }
    }

    private func record(_ status: OSStatus) -> OSStatus {
        callbackStatus.store(status, ordering: .releasing)
        return status
    }
}

public struct PersistentSessionStatus: Sendable {
    public let generation: UInt64
    public let sampleRate: Double
    public let state: SpeakerSessionState
    public let delays: [DelayComponents]
    public let calibration: CalibrationSnapshot?
    public let transport: AudioTransportCounters
    public let renderCallbacks: UInt64
    public let renderError: OSStatus?

    public init(generation: UInt64, sampleRate: Double, state: SpeakerSessionState, delays: [DelayComponents], calibration: CalibrationSnapshot?, transport: AudioTransportCounters = .init(), renderCallbacks: UInt64 = 0, renderError: OSStatus? = nil) {
        self.generation = generation
        self.sampleRate = sampleRate
        self.state = state
        self.delays = delays
        self.calibration = calibration
        self.transport = transport
        self.renderCallbacks = renderCallbacks
        self.renderError = renderError
    }
}

public final class PersistentSpeakerSession: @unchecked Sendable {
    public let outputUIDs: [String]
    public private(set) var outputs: [OutputDevice]
    public private(set) var generation: UInt64
    public private(set) var sampleRate: Double = 0
    public private(set) var calibrationSnapshot: CalibrationSnapshot?

    private let aggregateManager = AggregateDeviceManager()
    private let transport: StereoRingBuffer
    private let estimator: NormalizedCrossCorrelationEstimator
    private var stateMachine = SpeakerSessionStateMachine()
    private var delayComponents: [DelayComponents]
    private var aggregate: AggregateDeviceManager.Session?
    private var outputUnit: AudioUnit?
    private var renderState: PersistentRenderState?
    private var programmeCapture: SystemAudioCapture?
    private var microphoneCapture: ContinuousMicrophoneCapture?
    private var reference: CalibrationSignal?
    private var emissionSequence = 0
    private var running = false
    private var rebuilding = false
    private var lifecycleMonitor: CoreAudioDeviceMonitor?
    private let routingMode: SpeakerRoutingMode

    private var pendingMasterBands: [EQBand]?
    private var pendingMasterBypass: Bool = false
    private var pendingRouteBands: [Int: [EQBand]] = [:]
    private var pendingRouteBypass: [Int: Bool] = [:]
    private var pendingRouteVolumes: [Int: Float] = [:]

    public init(outputs: [OutputDevice], generation: UInt64 = 1, transportCapacityFrames: Int = 44_100, routingMode: SpeakerRoutingMode = .stereo) throws {
        guard outputs.count >= 2 else { throw AudioRoutingError.requiresAtLeastTwoOutputs }
        guard Set(outputs.map(\.id)).count == outputs.count else { throw AudioRoutingError.duplicateOutput }
        self.outputs = outputs
        outputUIDs = outputs.map(\.id)
        self.generation = generation
        self.routingMode = routingMode
        transport = StereoRingBuffer(capacityFrames: transportCapacityFrames)
        estimator = NormalizedCrossCorrelationEstimator()
        delayComponents = try outputs.map { try DelayComponents(manual: $0.delayMilliseconds) }
    }

    deinit { stopSynchronously() }

    public func setMasterEQBands(_ bands: [EQBand]) {
        pendingMasterBands = bands
        renderState?.setMasterEQBands(bands)
    }

    public func setMasterEQBypass(_ bypass: Bool) {
        pendingMasterBypass = bypass
        renderState?.setMasterEQBypass(bypass)
    }

    public func setRouteEQBands(route: Int, bands: [EQBand]) {
        pendingRouteBands[route] = bands
        renderState?.setRouteEQBands(route: route, bands: bands)
    }

    public func setRouteEQBypass(route: Int, bypass: Bool) {
        pendingRouteBypass[route] = bypass
        renderState?.setRouteEQBypass(route: route, bypass: bypass)
    }

    public func setRouteVolume(route: Int, volume: Float) {
        let clamped = max(0, min(1, volume))
        pendingRouteVolumes[route] = clamped
        renderState?.setRouteVolume(route: route, volume: clamped)
    }

    public func start(calibrationLevel: Double = 0.12) throws {
        guard !running else { return }
        _ = try stateMachine.handle(.prepare)
        do {
            let aggregate = try aggregateManager.create(outputs: outputs)
            sampleRate = aggregate.sampleRate
            let chirp = try LogarithmicChirpGenerator(level: calibrationLevel).generate(sampleRate: sampleRate)
            let state = try PersistentRenderState(sampleRate: sampleRate, chirp: chirp.samples, transport: transport, channelCounts: aggregate.channelCounts, delays: delayComponents.map(\.effectiveMilliseconds), routingMode: routingMode)
            if let master = pendingMasterBands { state.setMasterEQBands(master) }
            state.setMasterEQBypass(pendingMasterBypass)
            for (route, bands) in pendingRouteBands { state.setRouteEQBands(route: route, bands: bands) }
            for (route, bypass) in pendingRouteBypass { state.setRouteEQBypass(route: route, bypass: bypass) }
            for (route, volume) in pendingRouteVolumes { state.setRouteVolume(route: route, volume: volume) }
            let unit = try createOutputUnit(aggregate: aggregate)
            self.aggregate = aggregate
            reference = chirp
            renderState = state
            outputUnit = unit
            try CoreAudioProperty.check(AudioOutputUnitStart(unit), "Start persistent speaker output")
            running = true
            _ = try stateMachine.handle(.prepared)
        } catch {
            stopSynchronously()
            throw error
        }
    }

    public func attachProgrammeInput(_ input: InputDevice) throws -> SampleRateConversionPlan {
        guard running else { throw AudioRoutingError.notConfigured }
        programmeCapture?.stop()
        let capture = try SystemAudioCapture(device: input, renderSampleRate: sampleRate, transport: transport)
        try capture.start()
        programmeCapture = capture
        renderState?.setMode(.programme)
        return capture.conversion
    }

    public func setDelayComponents(index: Int, value: DelayComponents) throws {
        guard delayComponents.indices.contains(index) else { throw AudioRoutingError.outputNotConfigured("index \(index)") }
        try renderState?.setDelay(index: index, milliseconds: value.effectiveMilliseconds)
        delayComponents[index] = value
    }

    public func performCalibration(input: InputDevice, configuration: CalibrationExperimentConfiguration = .init(), progress: (@Sendable (CalibrationProgressUpdate) -> Void)? = nil) async throws -> [CalibrationPassMeasurements] {
        var configuration = configuration
        configuration.selectedSpeakerCount = outputs.count
        try configuration.validate()
        guard running, let reference, let renderState else { throw AudioRoutingError.notConfigured }
        guard abs(input.sampleRate - sampleRate) < 0.01 else { throw CalibrationSessionError.requiresMatchingSampleRates(output: sampleRate, input: input.sampleRate) }
        let priorState = stateMachine.state
        let priorDelays = delayComponents
        programmeCapture?.pause()
        transport.discardAll()
        renderState.setMode(.calibration)
        _ = try stateMachine.handle(.beginCalibration)
        let maximumDuration = max(30, Double(configuration.maximumPasses * configuration.eventsPerPass) * (configuration.chirpDurationSeconds + configuration.maximumAcousticLatencySeconds + 0.25) + 10)
        let microphone = try ContinuousMicrophoneCapture(device: input, sampleRate: sampleRate, maximumDurationSeconds: maximumDuration)
        microphoneCapture = microphone
        try microphone.start()
        defer {
            microphone.stop()
            microphoneCapture = nil
        }
        try await waitForRenderedFrames(renderState.renderedFrames.load(ordering: .acquiring) + Int64(configuration.preRollSeconds * sampleRate))

        var passes: [CalibrationPassMeasurements] = []
        var residuals: [Double] = []
        let convergence = ConvergenceController(targetResidualMilliseconds: configuration.targetResidualMilliseconds, maximumPasses: configuration.maximumPasses)
        do {
            for pass in 0..<configuration.maximumPasses {
                try Task.checkCancellation()
                if pass > 0 { progress?(.init(phase: .verifying(pass: pass + 1))) }
                let measured = try await measurePass(pass: pass, configuration: configuration, microphone: microphone, reference: reference, progress: progress)
                passes.append(measured)
                let residualsForSpeakers = measured.relativeArrivalsToReferenceMilliseconds
                let residual = (residualsForSpeakers.max() ?? 0) - (residualsForSpeakers.min() ?? 0)
                residuals.append(residual)
                if abs(residual) <= configuration.targetResidualMilliseconds {
                    let allMeasurements = measured.measurementsBySpeaker.flatMap { $0 }
                    let confidence = allMeasurements.map(\.estimate.confidence).reduce(0, +) / Double(allMeasurements.count)
                    calibrationSnapshot = CalibrationSnapshot(outputUIDs: outputUIDs, sampleRate: sampleRate, compensationByUID: Dictionary(uniqueKeysWithValues: zip(outputUIDs, delayComponents.map(\.calibration))), residualMilliseconds: abs(residual), confidence: confidence, sessionGeneration: generation)
                    _ = try stateMachine.handle(.calibrationSucceeded)
                    resumeProgramme()
                    return passes
                }
                guard convergence.shouldContinue(residuals: residuals) else { break }
                progress?(.init(phase: .applyingCorrection(residualMilliseconds: residual)))
                try applyResiduals(measured.relativeArrivalsToReferenceMilliseconds)
            }
            let residual = residuals.last ?? .infinity
            _ = try stateMachine.handle(.calibrationFailed("residual \(residual) ms"))
            throw CalibrationSessionError.didNotConverge(residualMilliseconds: residual)
        } catch is CancellationError {
            for index in priorDelays.indices { try? setDelayComponents(index: index, value: priorDelays[index]) }
            if case .calibrating = stateMachine.state { _ = try? stateMachine.handle(.cancelCalibration(priorState)) }
            resumeProgramme()
            throw CancellationError()
        } catch {
            if case .calibrating = stateMachine.state { _ = try? stateMachine.handle(.calibrationFailed(error.localizedDescription)) }
            resumeProgramme()
            throw error
        }
    }

    public func recheck(input: InputDevice, configuration: CalibrationExperimentConfiguration = .init()) async throws -> CalibrationPassMeasurements {
        guard calibrationIsValid else { throw CalibrationSessionError.didNotConverge(residualMilliseconds: .infinity) }
        programmeCapture?.pause(); transport.discardAll(); renderState?.setMode(.calibration)
        let microphone = try ContinuousMicrophoneCapture(device: input, sampleRate: sampleRate, maximumDurationSeconds: 20)
        microphoneCapture = microphone
        try microphone.start()
        defer { microphone.stop(); microphoneCapture = nil; resumeProgramme() }
        if let renderState { try await waitForRenderedFrames(renderState.renderedFrames.load(ordering: .acquiring) + Int64(configuration.preRollSeconds * sampleRate)) }
        return try await measurePass(pass: 0, configuration: configuration, microphone: microphone, reference: reference!, progress: nil)
    }

    public func applyDynamicCorrection(relativeResidualBMinusA residual: Double) throws {
        let index = residual >= 0 ? 0 : 1
        let increment = abs(residual)
        let old = delayComponents[index]
        try setDelayComponents(index: index, value: DelayComponents(manual: old.manual, calibration: old.calibration, dynamicCorrection: old.dynamicCorrection + increment))
    }

    public var calibrationIsValid: Bool {
        calibrationSnapshot?.isValid(outputUIDs: outputUIDs, sampleRate: sampleRate, sessionGeneration: generation) == true && stateMachine.state == .aligned
    }

    public var aggregateDeviceID: AudioDeviceID? { aggregate?.deviceID }

    public func invalidate(_ reason: CalibrationStaleReason) {
        generation &+= 1
        calibrationSnapshot = nil
        _ = try? stateMachine.handle(.invalidate(reason))
    }

    public func startLifecycleMonitoring() throws {
        try installLifecycleMonitor()
    }

    public func stopLifecycleMonitoring() {
        lifecycleMonitor?.stop()
        lifecycleMonitor = nil
    }

    public func rebuild(reason: CalibrationStaleReason) throws {
        try performRebuild(reason: reason)
    }

    public func stop() { stopSynchronously() }

    public func status() -> PersistentSessionStatus {
        let error = renderState?.callbackStatus.load(ordering: .acquiring)
        return PersistentSessionStatus(generation: generation, sampleRate: sampleRate, state: stateMachine.state, delays: delayComponents, calibration: calibrationSnapshot, transport: transport.counters(), renderCallbacks: renderState?.callbackCount.load(ordering: .relaxed) ?? 0, renderError: error == noErr ? nil : error)
    }

    private func measurePass(pass: Int, configuration: CalibrationExperimentConfiguration, microphone: ContinuousMicrophoneCapture, reference: CalibrationSignal, progress: (@Sendable (CalibrationProgressUpdate) -> Void)?) async throws -> CalibrationPassMeasurements {
        var values = outputs.map { _ in [AcousticMeasurement]() }
        var failures: [String] = []
        let maximumAttempts = configuration.measurementsPerSpeaker + configuration.maximumRetriesPerSpeaker
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            for speaker in outputs.indices where values[speaker].count < configuration.measurementsPerSpeaker {
                progress?(.init(phase: .measuring(speakerIndex: speaker, speakerName: outputs[speaker].name, pass: pass + 1, totalPasses: configuration.maximumPasses, measurement: values[speaker].count + 1, totalMeasurements: configuration.measurementsPerSpeaker)))
                do { values[speaker].append(try await emitAndMeasure(pass: pass, sequence: attempt * outputs.count + speaker, speaker: speaker, configuration: configuration, microphone: microphone, reference: reference)) }
                catch { failures.append("pass=\(pass + 1) attempt=\(attempt + 1) speaker=\(speaker): \(error.localizedDescription)") }
            }
        }
        for speaker in outputs.indices where values[speaker].count < configuration.measurementsPerSpeaker {
            throw CalibrationSessionError.insufficientValidMeasurements(speaker: outputs[speaker].name, valid: values[speaker].count, required: configuration.measurementsPerSpeaker)
        }
        return try CalibrationPassMeasurements(pass: pass, measurementsBySpeaker: values, failures: failures)
    }

    private func applyResiduals(_ residuals: [Double]) throws {
        guard let maximum = residuals.max() else { return }
        for (index, residual) in residuals.enumerated() where index < delayComponents.count {
            let old = delayComponents[index]
            let delay = maximum - residual
            try setDelayComponents(index: index, value: DelayComponents(manual: old.manual, calibration: old.calibration + delay, dynamicCorrection: old.dynamicCorrection))
        }
    }

    private func emitAndMeasure(pass: Int, sequence: Int, speaker: Int, configuration: CalibrationExperimentConfiguration, microphone: ContinuousMicrophoneCapture, reference: CalibrationSignal) async throws -> AcousticMeasurement {
        guard let renderState else { throw AudioRoutingError.notConfigured }
        let request = renderState.requestEmission(speaker: speaker)
        while renderState.emissionHostTime.load(ordering: .acquiring) == 0 || renderState.requestedEmission.load(ordering: .acquiring) != request {
            try checkRenderStatus()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let host = renderState.emissionHostTime.load(ordering: .acquiring)
        let startFrame = renderState.emissionStartFrame.load(ordering: .acquiring)
        let durationSeconds = Double(reference.samples.count) / sampleRate
        let waitSeconds = durationSeconds + configuration.maximumAcousticLatencySeconds + 0.1
        try await Task.sleep(nanoseconds: UInt64(max(0, waitSeconds) * 1_000_000_000))
        let captured = try microphone.snapshot()
        let scheduledInput = try captured.sampleIndex(atHostTime: host)
        let preSearch = Int((0.005 * sampleRate).rounded())
        let sliceStart = max(0, Int(floor(scheduledInput)) - preSearch)
        let searchEnd = min(captured.samples.count, Int(ceil(scheduledInput + (configuration.maximumAcousticLatencySeconds + durationSeconds) * sampleRate)))
        let sliceEnd = min(captured.samples.count, searchEnd + reference.samples.count)
        guard sliceEnd - sliceStart >= reference.samples.count else { throw DelayEstimatorError.insufficientRecording }
        let recording = Array(captured.samples[sliceStart..<sliceEnd])
        let lower = max(0, Int(floor(scheduledInput)) - sliceStart - preSearch)
        let upper = min(recording.count - reference.samples.count + 1, searchEnd - sliceStart)
        let estimate = try estimator.estimateDelay(reference: reference.samples, recording: recording, sampleRate: sampleRate, searchRange: lower..<upper)
        let arrivalHost = try captured.hostTime(atSampleIndex: Double(sliceStart) + estimate.sampleOffset)
        let latency = Double(Int64(AudioConvertHostTimeToNanos(arrivalHost)) - Int64(AudioConvertHostTimeToNanos(host))) / 1_000_000
        emissionSequence += 1
        return AcousticMeasurement(emission: CalibrationEmission(pass: pass, sequence: emissionSequence, speakerIndex: speaker, scheduledOutputFrame: startFrame, scheduledOutputHostTime: host), arrivalHostTime: arrivalHost, acousticLatencyMilliseconds: latency, estimate: estimate)
    }

    private func applyResidual(_ residual: Double) throws {
        let index = residual >= 0 ? 0 : 1
        let old = delayComponents[index]
        try setDelayComponents(index: index, value: DelayComponents(manual: old.manual, calibration: old.calibration + abs(residual), dynamicCorrection: old.dynamicCorrection))
    }

    private func resumeProgramme() {
        transport.discardAll()
        if let programmeCapture {
            try? programmeCapture.start()
            renderState?.setMode(.programme)
        } else {
            renderState?.setMode(.muted)
        }
    }

    private func waitForRenderedFrames(_ target: Int64) async throws {
        while (renderState?.renderedFrames.load(ordering: .acquiring) ?? target) < target {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func checkRenderStatus() throws {
        let status = renderState?.callbackStatus.load(ordering: .acquiring) ?? kAudio_ParamError
        if status != noErr { throw CalibrationSessionError.renderFailed(status) }
    }

    private func createOutputUnit(aggregate: AggregateDeviceManager.Session) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw CoreAudioError("Find persistent HAL component", status: kAudioHardwareUnsupportedOperationError) }
        var optional: AudioUnit?
        try CoreAudioProperty.check(AudioComponentInstanceNew(component, &optional), "Create persistent output unit")
        guard let unit = optional else { throw CoreAudioError("Create persistent output unit", status: kAudioHardwareUnspecifiedError) }
        do {
            var deviceID = aggregate.deviceID
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Bind persistent aggregate")
            var format = AudioStreamBasicDescription(mSampleRate: aggregate.sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(aggregate.channelCounts.reduce(0, +)), mBitsPerChannel: 32, mReserved: 0)
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set persistent output format")
            var maximum = PersistentRenderState.maximumFrames
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, 4), "Set persistent output maximum callback")
            var callback = AURenderCallbackStruct(inputProc: speakerrPersistentOutputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try CoreAudioProperty.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Install persistent output callback")
            try CoreAudioProperty.check(AudioUnitInitialize(unit), "Initialize persistent output unit")
            return unit
        } catch { AudioComponentInstanceDispose(unit); throw error }
    }

    fileprivate func render(timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData, let renderState else { return kAudio_ParamError }
        return renderState.render(timestamp: timestamp, ioData: ioData, frameCount: frameCount)
    }

    private func installLifecycleMonitor() throws {
        guard lifecycleMonitor == nil else { return }
        let monitor = try CoreAudioDeviceMonitor(selectedUIDs: outputUIDs) { [weak self] event in
            self?.handleLifecycleEvent(event)
        }
        try monitor.start()
        if let deviceID = aggregateDeviceID { try? monitor.watchAggregate(deviceID: deviceID) }
        lifecycleMonitor = monitor
    }

    private func handleLifecycleEvent(_ event: AudioLifecycleEvent) {
        switch event {
        case .devicesChanged(let changes, _):
            for change in changes { applyLifecycleChange(change) }
        case .aggregateDestroyed:
            try? performRebuild(reason: .routeRebuilt)
        case .systemSleep:
            invalidate(.systemWoke)
        case .systemWake:
            try? performRebuild(reason: .systemWoke)
        case .defaultOutputChanged:
            break
        }
    }

    private func applyLifecycleChange(_ change: DeviceLifecycleChange) {
        switch change {
        case .unchanged:
            break
        case .disconnected:
            markOutputsUnavailable(reason: .deviceReconnected)
        case .reconnected:
            try? performRebuild(reason: .deviceReconnected)
        case .sampleRateChanged:
            try? performRebuild(reason: .sampleRateChanged)
        case .channelLayoutChanged:
            try? performRebuild(reason: .deviceSetChanged)
        }
    }

    private func markOutputsUnavailable(reason: CalibrationStaleReason) {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        tearDownRunningResources()
        generation &+= 1
        calibrationSnapshot = nil
        _ = try? stateMachine.handle(.outputUnavailable("selected output disconnected"))
        _ = reason
    }

    private func tearDownRunningResources() {
        programmeCapture?.stop()
        microphoneCapture?.stop(); microphoneCapture = nil
        if let outputUnit {
            AudioOutputUnitStop(outputUnit); AudioUnitUninitialize(outputUnit); AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }
        renderState = nil; reference = nil
        aggregateManager.destroy(); aggregate = nil
        running = false
    }

    /// Idempotent: repeated device notifications for the same underlying event
    /// are safe to coalesce into a single rebuild because this always tears
    /// down first and resolves fresh AudioObjectIDs from stable UIDs.
    private func performRebuild(reason: CalibrationStaleReason) throws {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }

        let previousProgrammeInput = programmeCapture?.device
        let priorState = stateMachine.state
        tearDownRunningResources()

        let discovered = try AudioDeviceDiscovery().outputDevices()
        let byUID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        guard outputUIDs.allSatisfy({ byUID[$0] != nil }) else {
            generation &+= 1
            calibrationSnapshot = nil
            _ = try? stateMachine.handle(.outputUnavailable("one or more selected outputs are not currently connected"))
            return
        }
        outputs = outputUIDs.map { byUID[$0]! }
        generation &+= 1
        calibrationSnapshot = nil

        if case .rebuilding = priorState {} else { _ = try? stateMachine.handle(.beginRebuild) }
        do {
            try start()
        } catch {
            _ = try? stateMachine.handle(.outputUnavailable("rebuild failed: \(error.localizedDescription)"))
            throw error
        }
        for (index, component) in delayComponents.enumerated() {
            try? renderState?.setDelay(index: index, milliseconds: component.effectiveMilliseconds)
        }
        if let previousProgrammeInput {
            do {
                _ = try attachProgrammeInput(previousProgrammeInput)
            } catch {
                _ = try? stateMachine.handle(.outputUnavailable("programme attach failed: \(error.localizedDescription)"))
            }
        }
    }

    private func stopSynchronously() {
        stopLifecycleMonitoring()
        tearDownRunningResources()
        _ = try? stateMachine.handle(.stop)
    }
}

private func speakerrPersistentOutputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<PersistentSpeakerSession>.fromOpaque(inRefCon).takeUnretainedValue().render(
        timestamp: inTimeStamp,
        frameCount: inNumberFrames,
        ioData: ioData
    )
}
