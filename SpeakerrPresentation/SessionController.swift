import CoreAudio
import Foundation
import SpeakerrAudio

public struct SessionControllerSnapshot: Sendable, Equatable {
    public let status: PersistentSessionStatus?
    public let selectedOutputs: [OutputDevice]
    public let availableOutputs: [OutputDevice]
    public let availableInputs: [InputDevice]
    public let programmeInputUID: String?
    public let isProgrammeAttached: Bool

    public init(status: PersistentSessionStatus?, selectedOutputs: [OutputDevice], availableOutputs: [OutputDevice], availableInputs: [InputDevice], programmeInputUID: String?, isProgrammeAttached: Bool) {
        self.status = status
        self.selectedOutputs = selectedOutputs
        self.availableOutputs = availableOutputs
        self.availableInputs = availableInputs
        self.programmeInputUID = programmeInputUID
        self.isProgrammeAttached = isProgrammeAttached
    }
}

public protocol SpeakerSessionControlling: Sendable {
    func snapshot() async throws -> SessionControllerSnapshot
    func start(outputUIDs: [String], programmeInputUID: String?, calibrationLevel: Double) async throws
    func stop() async
    func calibrate(inputUID: String, configuration: CalibrationExperimentConfiguration, progress: @escaping @Sendable (CalibrationProgressUpdate) -> Void) async throws -> [CalibrationPassMeasurements]
    func recheck(inputUID: String, configuration: CalibrationExperimentConfiguration) async throws -> CalibrationPassMeasurements
    func applyDynamicCorrection(residualMilliseconds: Double) async throws
    func setManualDelay(outputUID: String, milliseconds: Double) async throws
}

public enum SessionControllerError: LocalizedError, Sendable, Equatable {
    case requiresExactlyTwoOutputs
    case outputUnavailable(String)
    case inputUnavailable(String)
    case sessionNotRunning
    case programmeInputHasNoOutput(String)

    public var errorDescription: String? {
        switch self {
        case .requiresExactlyTwoOutputs: "Select exactly two output devices."
        case .outputUnavailable(let uid): "A selected speaker is unavailable (\(uid))."
        case .inputUnavailable(let uid): "The selected audio input is unavailable (\(uid))."
        case .sessionNotRunning: "Speakerr is not active."
        case .programmeInputHasNoOutput(let uid): "The system-audio device cannot be used as a Mac output (\(uid))."
        }
    }
}

public actor CoreAudioSpeakerSessionController: SpeakerSessionControlling {
    private var session: PersistentSpeakerSession?
    private var selectedOutputs: [OutputDevice] = []
    private var programmeInputUID: String?
    private var isProgrammeAttached = false
    private var systemRoute: SystemOutputRoute?

    public init() {}

    public func snapshot() throws -> SessionControllerSnapshot {
        let discovery = AudioDeviceDiscovery()
        return SessionControllerSnapshot(
            status: session?.status(),
            selectedOutputs: selectedOutputs,
            availableOutputs: try discovery.outputDevices().filter { !$0.isAggregate },
            availableInputs: try discovery.inputDevices(),
            programmeInputUID: programmeInputUID,
            isProgrammeAttached: isProgrammeAttached
        )
    }

    public func start(outputUIDs: [String], programmeInputUID: String?, calibrationLevel: Double) throws {
        guard outputUIDs.count == 2, outputUIDs[0] != outputUIDs[1] else { throw SessionControllerError.requiresExactlyTwoOutputs }
        stop()
        let discovery = AudioDeviceDiscovery()
        let outputs = try discovery.outputDevices()
        selectedOutputs = try outputUIDs.map { uid in
            guard let output = outputs.first(where: { $0.id == uid }) else { throw SessionControllerError.outputUnavailable(uid) }
            return output
        }
        let created = try PersistentSpeakerSession(outputs: selectedOutputs)
        do {
            try created.start(calibrationLevel: calibrationLevel)
            try created.startLifecycleMonitoring()
            if let programmeInputUID {
                let inputs = try discovery.inputDevices()
                guard let input = inputs.first(where: { $0.id == programmeInputUID }) else { throw SessionControllerError.inputUnavailable(programmeInputUID) }
                _ = try created.attachProgrammeInput(input)
                systemRoute = try SystemOutputRoute.activate(deviceUID: programmeInputUID, availableOutputs: outputs)
                self.programmeInputUID = programmeInputUID
                isProgrammeAttached = true
            }
            session = created
        } catch {
            created.stop()
            systemRoute?.restore()
            systemRoute = nil
            selectedOutputs = []
            throw error
        }
    }

    public func stop() {
        session?.stopLifecycleMonitoring()
        session?.stop()
        session = nil
        systemRoute?.restore()
        systemRoute = nil
        isProgrammeAttached = false
    }

    public func calibrate(inputUID: String, configuration: CalibrationExperimentConfiguration, progress: @escaping @Sendable (CalibrationProgressUpdate) -> Void) async throws -> [CalibrationPassMeasurements] {
        guard let session else { throw SessionControllerError.sessionNotRunning }
        let input = try resolveInput(uid: inputUID)
        return try await session.performCalibration(input: input, configuration: configuration, progress: progress)
    }

    public func recheck(inputUID: String, configuration: CalibrationExperimentConfiguration) async throws -> CalibrationPassMeasurements {
        guard let session else { throw SessionControllerError.sessionNotRunning }
        return try await session.recheck(input: resolveInput(uid: inputUID), configuration: configuration)
    }

    public func applyDynamicCorrection(residualMilliseconds: Double) throws {
        guard let session else { throw SessionControllerError.sessionNotRunning }
        try session.applyDynamicCorrection(relativeResidualBMinusA: residualMilliseconds)
    }

    public func setManualDelay(outputUID: String, milliseconds: Double) throws {
        guard let session, let index = session.outputUIDs.firstIndex(of: outputUID) else { throw SessionControllerError.outputUnavailable(outputUID) }
        let old = session.status().delays[index]
        try session.setDelayComponents(index: index, value: DelayComponents(manual: milliseconds, calibration: old.calibration, dynamicCorrection: old.dynamicCorrection))
    }

    private func resolveInput(uid: String) throws -> InputDevice {
        guard let input = try AudioDeviceDiscovery().inputDevices().first(where: { $0.id == uid }) else { throw SessionControllerError.inputUnavailable(uid) }
        return input
    }
}

private final class SystemOutputRoute: @unchecked Sendable {
    private let previousOutputUID: String
    private var restored = false

    private init(previousOutputUID: String) {
        self.previousOutputUID = previousOutputUID
    }

    static func activate(deviceUID: String, availableOutputs: [OutputDevice]) throws -> SystemOutputRoute {
        guard let destination = availableOutputs.first(where: { $0.id == deviceUID }) else { throw SessionControllerError.programmeInputHasNoOutput(deviceUID) }
        let previousID = try defaultOutputDeviceID()
        let previousUID = try outputUID(deviceID: previousID)
        let route = SystemOutputRoute(previousOutputUID: previousUID)
        try setDefaultOutputDeviceID(destination.coreAudioID)
        return route
    }

    func restore() {
        guard !restored else { return }
        restored = true
        guard let device = try? AudioDeviceDiscovery().outputDevices().first(where: { $0.id == previousOutputUID }) else { return }
        try? Self.setDefaultOutputDeviceID(device.coreAudioID)
    }

    deinit { restore() }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError("Read default system output", status: status) }
        return value
    }

    private static func outputUID(deviceID: AudioDeviceID) throws -> String {
        guard let device = try AudioDeviceDiscovery().outputDevices().first(where: { $0.coreAudioID == deviceID }) else { throw SessionControllerError.outputUnavailable("default output") }
        return device.id
    }

    private static func setDefaultOutputDeviceID(_ deviceID: AudioDeviceID) throws {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value = deviceID
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
            guard status == noErr else { throw CoreAudioError("Set default system output", status: status) }
        }
    }
}
