import AVFoundation
import Foundation
import Observation
import SpeakerrAudio

public protocol MicrophonePermissionProviding: Sendable {
    func requestPermission() async -> Bool
}

public struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    public init() {}

    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

@MainActor
@Observable
public final class SpeakerrPreferences {
    public var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) } }
    public var selectedSpeakerUIDs: [String] { didSet { defaults.set(selectedSpeakerUIDs, forKey: Keys.speakers) } }
    public var routingMode: SpeakerRoutingMode { didSet { defaults.set(routingMode.rawValue, forKey: Keys.routingMode) } }
    public var preferredMicrophoneUID: String? { didSet { defaults.set(preferredMicrophoneUID, forKey: Keys.microphone) } }
    public var programmeInputUID: String? { didSet { defaults.set(programmeInputUID, forKey: Keys.programmeInput) } }
    public var calibrationVolume: Double { didSet { defaults.set(calibrationVolume, forKey: Keys.volume) } }
    public var measurementsPerSpeaker: Int { didSet { defaults.set(measurementsPerSpeaker, forKey: Keys.measurements) } }
    public var showDetailedTiming: Bool { didSet { defaults.set(showDetailedTiming, forKey: Keys.detailedTiming) } }
    public var saveDiagnosticRecordings: Bool { didSet { defaults.set(saveDiagnosticRecordings, forKey: Keys.saveRecordings) } }
    public var openWindowOnCalibrationFailure: Bool { didSet { defaults.set(openWindowOnCalibrationFailure, forKey: Keys.openOnFailure) } }
    public var suggestRecalibrationAfterReconnect: Bool { didSet { defaults.set(suggestRecalibrationAfterReconnect, forKey: Keys.suggestRecalibration) } }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        selectedSpeakerUIDs = defaults.stringArray(forKey: Keys.speakers) ?? []
        routingMode = SpeakerRoutingMode(rawValue: defaults.string(forKey: Keys.routingMode) ?? "") ?? .stereo
        preferredMicrophoneUID = defaults.string(forKey: Keys.microphone)
        programmeInputUID = defaults.string(forKey: Keys.programmeInput)
        calibrationVolume = defaults.object(forKey: Keys.volume) as? Double ?? 0.12
        measurementsPerSpeaker = defaults.object(forKey: Keys.measurements) as? Int ?? 3
        showDetailedTiming = defaults.bool(forKey: Keys.detailedTiming)
        saveDiagnosticRecordings = defaults.bool(forKey: Keys.saveRecordings)
        openWindowOnCalibrationFailure = defaults.object(forKey: Keys.openOnFailure) as? Bool ?? true
        suggestRecalibrationAfterReconnect = defaults.object(forKey: Keys.suggestRecalibration) as? Bool ?? true
    }

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let speakers = "selectedSpeakerUIDs"
        static let routingMode = "speakerRoutingMode"
        static let microphone = "preferredMicrophoneUID"
        static let programmeInput = "programmeInputUID"
        static let volume = "calibrationVolume"
        static let measurements = "measurementsPerSpeaker"
        static let detailedTiming = "showDetailedTiming"
        static let saveRecordings = "saveDiagnosticRecordings"
        static let openOnFailure = "openWindowOnCalibrationFailure"
        static let suggestRecalibration = "suggestRecalibrationAfterReconnect"
    }
}

@MainActor
@Observable
public final class SpeakerrViewModel {
    public private(set) var presentation = SpeakerrPresentationState()
    public private(set) var availableOutputs: [OutputDevice] = []
    public private(set) var availableInputs: [InputDevice] = []
    public private(set) var calibrationProgress: CalibrationProgressUpdate?
    public private(set) var calibrationOutcome: CalibrationOutcome = .none
    public private(set) var isBusy = false
    public private(set) var microphonePermissionDenied = false
    public var isSpeakerSelectionPresented = false
    public var isCalibrationPresented = false
    public var isDiagnosticsPresented = false

    public let preferences: SpeakerrPreferences
    private let controller: any SpeakerSessionControlling
    private let microphonePermissionProvider: any MicrophonePermissionProviding
    private var pollingTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var latestRecheckResidual: Double?
    private var isPaused = false
    private var attemptedSavedSessionStart = false

    public init(controller: any SpeakerSessionControlling = CoreAudioSpeakerSessionController(), preferences: SpeakerrPreferences? = nil, microphonePermissionProvider: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider(), initialPresentation: SpeakerrPresentationState = .init(), initialCalibrationOutcome: CalibrationOutcome = .none, microphonePermissionDenied: Bool = false) {
        self.controller = controller
        self.microphonePermissionProvider = microphonePermissionProvider
        self.preferences = preferences ?? SpeakerrPreferences()
        presentation = initialPresentation
        calibrationOutcome = initialCalibrationOutcome
        self.microphonePermissionDenied = microphonePermissionDenied
    }

    public func beginMonitoring() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    public func refresh() async {
        do {
            let snapshot = try await controller.snapshot()
            availableOutputs = snapshot.availableOutputs
            availableInputs = snapshot.availableInputs
            if preferences.preferredMicrophoneUID == nil {
                preferences.preferredMicrophoneUID = snapshot.availableInputs.first(where: { $0.transport == .builtIn })?.id
            }
            if preferences.programmeInputUID == nil {
                preferences.programmeInputUID = snapshot.availableInputs.first(where: { input in
                    input.transport == .virtual && snapshot.availableOutputs.contains(where: { $0.id == input.id })
                })?.id
            }
            map(snapshot)
        } catch {
            presentation.status = .audioError
            presentation.statusDetail = "Speakerr could not read the current audio devices."
            presentation.technicalError = error.localizedDescription
        }
    }

    public func startSavedSessionIfNeeded() {
        guard !attemptedSavedSessionStart else { return }
        attemptedSavedSessionStart = true
        if preferences.selectedSpeakerUIDs.count == 2 { start() }
    }

    public func useSelectedSpeakers(_ uids: [String]) {
        guard uids.count == 2 else { return }
        preferences.selectedSpeakerUIDs = uids
        isSpeakerSelectionPresented = false
        start()
    }

    public func setRoutingMode(_ mode: SpeakerRoutingMode) {
        guard preferences.routingMode != mode else { return }
        preferences.routingMode = mode
        if preferences.selectedSpeakerUIDs.count == 2 {
            start()
        }
    }

    public func start() {
        guard preferences.selectedSpeakerUIDs.count == 2 else {
            isSpeakerSelectionPresented = true
            return
        }
        isPaused = false
        isBusy = true
        Task {
            do {
                try await controller.start(outputUIDs: preferences.selectedSpeakerUIDs, programmeInputUID: preferences.programmeInputUID, calibrationLevel: preferences.calibrationVolume, routingMode: preferences.routingMode)
                calibrationOutcome = .none
            } catch {
                present(error)
            }
            isBusy = false
            await refresh()
        }
    }

    public func pause() {
        let activeCalibration = calibrationTask
        activeCalibration?.cancel()
        isPaused = true
        isBusy = true
        Task {
            await activeCalibration?.value
            await controller.stop()
            isBusy = false
            await refresh()
        }
    }

    public func calibrate() {
        guard let inputUID = preferences.preferredMicrophoneUID else {
            presentation.statusDetail = "Choose a microphone before calibrating."
            isCalibrationPresented = true
            return
        }
        calibrationTask?.cancel()
        calibrationOutcome = .none
        calibrationProgress = nil
        isBusy = true
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            guard await microphonePermissionProvider.requestPermission() else {
                microphonePermissionDenied = true
                isBusy = false
                return
            }
            microphonePermissionDenied = false
            do {
                var configuration = CalibrationExperimentConfiguration()
                configuration.measurementsPerSpeaker = preferences.measurementsPerSpeaker
                configuration.level = preferences.calibrationVolume
                let passes = try await controller.calibrate(inputUID: inputUID, configuration: configuration) { [weak self] update in
                    Task { @MainActor in self?.calibrationProgress = update }
                }
                let residual = abs(passes.last?.relativeArrivalBMinusAMilliseconds ?? 0)
                calibrationOutcome = .success(residualMilliseconds: residual)
                latestRecheckResidual = nil
            } catch is CancellationError {
                calibrationOutcome = .cancelled
            } catch let error as CalibrationSessionError {
                switch error {
                case .didNotConverge(let residual): calibrationOutcome = .nonConverged(residualMilliseconds: abs(residual), canKeepCurrentAlignment: false)
                default: calibrationOutcome = .lowConfidence(message: userMessage(for: error))
                }
            } catch {
                present(error)
            }
            isBusy = false
            await refresh()
        }
    }

    public func cancelCalibration() {
        calibrationTask?.cancel()
    }

    public func recheck() {
        guard let inputUID = preferences.preferredMicrophoneUID else { return }
        isBusy = true
        Task {
            do {
                var configuration = CalibrationExperimentConfiguration()
                configuration.measurementsPerSpeaker = 1
                let result = try await controller.recheck(inputUID: inputUID, configuration: configuration)
                latestRecheckResidual = result.relativeArrivalBMinusAMilliseconds
            } catch { present(error) }
            isBusy = false
            await refresh()
        }
    }

    public func applyLatestCorrection() {
        guard let residual = latestRecheckResidual else { return }
        Task {
            do {
                try await controller.applyDynamicCorrection(residualMilliseconds: residual)
                latestRecheckResidual = nil
            } catch { present(error) }
            await refresh()
        }
    }

    public func setManualDelay(outputUID: String, milliseconds: Double) {
        Task {
            do { try await controller.setManualDelay(outputUID: outputUID, milliseconds: milliseconds) }
            catch { present(error) }
            await refresh()
        }
    }

    public func updateMasterEQ(bands: [EQBand]) {
        Task { await controller.setMasterEQBands(bands) }
    }

    public func updateMasterEQBypass(_ bypass: Bool) {
        Task { await controller.setMasterEQBypass(bypass) }
    }

    public func updateRouteEQ(route: Int, bands: [EQBand]) {
        Task { await controller.setRouteEQBands(route: route, bands: bands) }
    }

    public func updateRouteEQBypass(route: Int, bypass: Bool) {
        Task { await controller.setRouteEQBypass(route: route, bypass: bypass) }
    }

    public func shutdown() async {
        pollingTask?.cancel()
        calibrationTask?.cancel()
        await controller.stop()
    }

    private func map(_ snapshot: SessionControllerSnapshot) {
        guard let status = snapshot.status else {
            presentation = SpeakerrPresentationState(
                status: isPaused ? .paused : .inactive,
                statusDetail: preferences.selectedSpeakerUIDs.count == 2 ? nil : "Select two speakers to create a Speakerr group.",
                speakers: savedSpeakerStates(from: snapshot),
                calibration: .unavailable,
                playback: .init(isActive: false, isProgrammeAttached: false, statusText: isPaused ? "Paused" : "Inactive")
            )
            return
        }
        let valid = status.calibration?.isValid(outputUIDs: snapshot.selectedOutputs.map(\.id), sampleRate: status.sampleRate, sessionGeneration: status.generation) == true && status.state == .aligned
        let userStatus = PresentationStateMapper.userStatus(for: status.state, calibrationIsValid: valid, latestRecheckResidualMilliseconds: latestRecheckResidual, isPaused: isPaused)
        let speakers = snapshot.selectedOutputs.enumerated().map { index, output in
            SpeakerViewState(id: output.id, name: output.name, transport: output.transport, sampleRate: output.sampleRate, channelCount: output.channelCount, isConnected: snapshot.availableOutputs.contains(where: { $0.id == output.id }), effectiveDelayMilliseconds: status.delays.indices.contains(index) ? status.delays[index].effectiveMilliseconds : 0, delayComponents: status.delays.indices.contains(index) ? status.delays[index] : nil)
        }
        presentation = SpeakerrPresentationState(
            status: userStatus,
            statusDetail: detail(for: status.state, speakers: speakers),
            speakers: speakers,
            calibration: PresentationStateMapper.calibration(for: status.state, snapshot: status.calibration, calibrationIsValid: valid, progress: calibrationProgress, outcome: calibrationOutcome),
            playback: .init(isActive: !isPaused, isProgrammeAttached: snapshot.isProgrammeAttached, statusText: snapshot.isProgrammeAttached ? "Active" : "Ready"),
            generation: status.generation,
            sampleRate: status.sampleRate,
            transport: status.transport,
            renderCallbacks: status.renderCallbacks,
            technicalError: status.renderError.map { "CoreAudio render status \($0)" },
            latestRecheckResidualMilliseconds: latestRecheckResidual
        )
    }

    private func savedSpeakerStates(from snapshot: SessionControllerSnapshot) -> [SpeakerViewState] {
        preferences.selectedSpeakerUIDs.map { uid in
            if let device = snapshot.availableOutputs.first(where: { $0.id == uid }) {
                return SpeakerViewState(id: uid, name: device.name, transport: device.transport, sampleRate: device.sampleRate, channelCount: device.channelCount, isConnected: true, effectiveDelayMilliseconds: 0)
            }
            return SpeakerViewState(id: uid, name: "Saved speaker", transport: .unknown, sampleRate: 0, channelCount: 0, isConnected: false, effectiveDelayMilliseconds: 0)
        }
    }

    private func detail(for state: SpeakerSessionState, speakers: [SpeakerViewState]) -> String? {
        switch state {
        case .calibrationStale(let reason): PresentationStateMapper.staleReason(reason)
        case .unavailable:
            if let missing = speakers.first(where: { !$0.isConnected }) { "Waiting for \(missing.name). Playback is paused." }
            else { "One of the selected speakers is unavailable." }
        case .failed(let message): message
        default: nil
        }
    }

    private func present(_ error: Error) {
        presentation.status = .audioError
        presentation.statusDetail = userMessage(for: error)
        presentation.technicalError = error.localizedDescription
    }

    private func userMessage(for error: Error) -> String {
        if let controllerError = error as? SessionControllerError { return controllerError.localizedDescription }
        if let calibrationError = error as? CalibrationSessionError {
            switch calibrationError {
            case .insufficientValidMeasurements: return "The microphone could not distinguish the calibration signal clearly enough. Reduce background noise or increase calibration volume slightly."
            case .requiresMatchingSampleRates: return "The selected microphone is not using the same sample rate as the speakers."
            default: return calibrationError.localizedDescription
            }
        }
        return "Speakerr could not complete the audio operation."
    }
}
