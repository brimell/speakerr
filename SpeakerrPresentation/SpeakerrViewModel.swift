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
    public var calibrationVolume: Double {
        get { storedCalibrationVolume }
        set {
            storedCalibrationVolume = min(max(newValue, 0.03), 0.5)
            defaults.set(storedCalibrationVolume, forKey: Keys.volume)
        }
    }
    public var measurementsPerSpeaker: Int { didSet { defaults.set(measurementsPerSpeaker, forKey: Keys.measurements) } }
    public var showDetailedTiming: Bool { didSet { defaults.set(showDetailedTiming, forKey: Keys.detailedTiming) } }
    public var saveDiagnosticRecordings: Bool { didSet { defaults.set(saveDiagnosticRecordings, forKey: Keys.saveRecordings) } }
    public var openWindowOnCalibrationFailure: Bool { didSet { defaults.set(openWindowOnCalibrationFailure, forKey: Keys.openOnFailure) } }
    public var suggestRecalibrationAfterReconnect: Bool { didSet { defaults.set(suggestRecalibrationAfterReconnect, forKey: Keys.suggestRecalibration) } }

    private let defaults: UserDefaults
    private var storedCalibrationVolume: Double

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        selectedSpeakerUIDs = defaults.stringArray(forKey: Keys.speakers) ?? []
        routingMode = SpeakerRoutingMode(rawValue: defaults.string(forKey: Keys.routingMode) ?? "") ?? .stereo
        preferredMicrophoneUID = defaults.string(forKey: Keys.microphone)
        programmeInputUID = defaults.string(forKey: Keys.programmeInput)
        storedCalibrationVolume = min(max(defaults.object(forKey: Keys.volume) as? Double ?? 0.12, 0.03), 0.5)
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
    public private(set) var calibrationSpeakerResults: [CalibrationSpeakerResult] = []
    public private(set) var calibrationOutcome: CalibrationOutcome = .none
        public private(set) var calibrationAttempts: [CalibrationAttemptDiagnostic] = []
        public private(set) var calibrationCompletion: CalibrationCompletionDiagnostics?
    public private(set) var isBusy = false
    public private(set) var microphonePermissionDenied = false
    public var isSpeakerSelectionPresented = false
    public var isCalibrationPresented = false
    public var isDiagnosticsPresented = false

    public let preferences: SpeakerrPreferences
    @ObservationIgnored public weak var playbackCoordinator: PlaybackCoordinator?
    private let controller: any SpeakerSessionControlling
    private let microphonePermissionProvider: any MicrophonePermissionProviding
    private var pollingTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var calibrationRunID: UInt64 = 0
    private var latestRecheckResidual: Double?
    private var latestRecheckResiduals: [Double] = []
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
            if playbackCoordinator == nil, preferences.programmeInputUID == nil {
                preferences.programmeInputUID = snapshot.availableInputs.first(where: { input in
                    input.name.localizedCaseInsensitiveContains("BlackHole") && snapshot.availableOutputs.contains(where: { $0.id == input.id })
                })?.id
            }
            map(snapshot)
            if let message = playbackCoordinator?.errorMessage {
                presentPlaybackError(NSError(domain: "SpeakerrPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        } catch {
            presentation.status = .audioError
            presentation.statusDetail = "Speakerr could not read the current audio devices."
            presentation.technicalError = error.localizedDescription
        }
    }

    public func startSavedSessionIfNeeded() {
        guard !attemptedSavedSessionStart else { return }
        attemptedSavedSessionStart = true
        if preferences.selectedSpeakerUIDs.count >= 2 { start() }
    }

    public func useSelectedSpeakers(_ uids: [String]) {
        guard uids.count >= 2, Set(uids).count == uids.count else { return }
        isSpeakerSelectionPresented = false
        if let playbackCoordinator {
            playbackCoordinator.selectOutputs(uids)
            return
        }
        preferences.selectedSpeakerUIDs = uids
        start()
    }

    public func selectProgrammeInput(_ uid: String?) {
        if let playbackCoordinator {
            playbackCoordinator.selectInput(uid)
        } else {
            preferences.programmeInputUID = uid
            if presentation.playback.isActive { start() }
        }
    }

    public func setRoutingMode(_ mode: SpeakerRoutingMode) {
        guard preferences.routingMode != mode else { return }
        preferences.routingMode = mode
        if preferences.selectedSpeakerUIDs.count >= 2 {
            start()
        }
    }

    public func start() {
        if let playbackCoordinator {
            playbackCoordinator.start()
            return
        }
        guard preferences.selectedSpeakerUIDs.count >= 2 else {
            isSpeakerSelectionPresented = true
            return
        }
        let outputs = preferences.selectedSpeakerUIDs
        let input = preferences.programmeInputUID
        #if DEBUG
        let level = 0.25
        #else
        let level = preferences.calibrationVolume
        #endif
        let mode = preferences.routingMode
        Task {
            do {
                try await startSession(outputUIDs: outputs, inputUID: input, calibrationLevel: level, routingMode: mode)
            } catch {
                present(error)
            }
        }
    }

    public func pause() {
        if let playbackCoordinator {
            playbackCoordinator.stop()
            return
        }
        Task { await pauseSession() }
    }

    func startSession(outputUIDs: [String], inputUID: String?, calibrationLevel: Double, routingMode: SpeakerRoutingMode) async throws {
        isPaused = false
        isBusy = true
        defer { isBusy = false }
        try await controller.start(outputUIDs: outputUIDs, programmeInputUID: inputUID, calibrationLevel: calibrationLevel, routingMode: routingMode)
        calibrationOutcome = .none
        await refresh()
    }

    func pauseSession() async {
        let activeCalibration = calibrationTask
        activeCalibration?.cancel()
        isPaused = true
        isBusy = true
        await activeCalibration?.value
        await controller.stop()
        isBusy = false
        await refresh()
    }

    public func calibrate() {
        guard let inputUID = resolvedCalibrationInputUID else {
            presentation.statusDetail = "Choose a microphone before calibrating."
            presentCalibration()
            return
        }
        preferences.preferredMicrophoneUID = inputUID
        calibrationTask?.cancel()
        calibrationRunID &+= 1
        let runID = calibrationRunID
        calibrationOutcome = .none
        calibrationProgress = nil
        calibrationAttempts = []
        calibrationCompletion = nil
        calibrationSpeakerResults = []
        latestRecheckResidual = nil
        latestRecheckResiduals = []
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
                #if DEBUG
                configuration.level = 0.12
                #else
                configuration.level = preferences.calibrationVolume
                #endif
                let passes = try await controller.calibrate(inputUID: inputUID, configuration: configuration) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.calibrationRunID == runID else { return }
                        self.calibrationProgress = update
                    }
                }
                guard calibrationRunID == runID else { return }
                let finalPass = passes.last
                let snapshot = try? await controller.snapshot()
                if let pass = finalPass {
                    let applied = pass.canApplyCompensation && snapshot?.status?.state == .aligned
                    let estimationPass = applied ? (passes.first ?? pass) : pass
                    calibrationSpeakerResults = estimationPass.speakerEstimates.enumerated().map { index, estimate in
                        let speaker = snapshot?.selectedOutputs.indices.contains(index) == true ? snapshot?.selectedOutputs[index] : nil
                        return CalibrationSpeakerResult(id: speaker?.id ?? "speaker-\(index + 1)", speakerName: speaker?.name ?? "Speaker \(index + 1)", detectedLatencyMilliseconds: estimate.delayMilliseconds, confidence: estimate.confidence, quality: estimate.quality, measurementCount: estimate.measurementCount, acceptedMeasurementCount: estimate.acceptedMeasurementCount, spreadMilliseconds: estimate.summary?.spreadMilliseconds, evidenceCount: estimate.clusterMembers.count)
                    }
                    // Recheck arrivals already contain the applied delay. Do not add it a second time.
                    let arrivals = pass.speakerEstimates.compactMap(\.delayMilliseconds)
                    if applied, arrivals.count == pass.speakerEstimates.count {
                        let center = (try? RobustMeasurementSummary(values: arrivals).medianMilliseconds) ?? 0
                        let rows = arrivals.indices.map { index in
                            CalibrationCompletionDiagnostic(speakerIndex: index, speakerName: calibrationSpeakerResults[index].speakerName, arrivalMilliseconds: arrivals[index], appliedDelayMilliseconds: snapshot?.status?.delays[index].calibration ?? 0, residualMilliseconds: arrivals[index] - center)
                        }
                        calibrationCompletion = CalibrationCompletionDiagnostics(speakers: rows, residualSpreadMilliseconds: pass.residualSpreadMilliseconds ?? 0)
                    }
                    if applied && passes.allSatisfy({ $0.quality == .high }) {
                        calibrationOutcome = .success(residualMilliseconds: pass.residualSpreadMilliseconds ?? 0)
                    } else {
                        calibrationOutcome = .estimated(residualMilliseconds: applied ? pass.residualSpreadMilliseconds : nil, applied: applied, residualQuality: pass.quality)
                    }
                }
                calibrationAttempts = passes.flatMap(\.attempts)
            } catch is CancellationError {
                guard calibrationRunID == runID else { return }
                calibrationOutcome = .cancelled
            } catch let error as CalibrationSessionError {
                guard calibrationRunID == runID else { return }
                switch error {
                case .didNotConverge(let residual): calibrationOutcome = .nonConverged(residualMilliseconds: abs(residual), canKeepCurrentAlignment: false)
                default: calibrationOutcome = .lowConfidence(message: userMessage(for: error))
                }
            } catch {
                guard calibrationRunID == runID else { return }
                present(error)
            }
            guard calibrationRunID == runID else { return }
            isBusy = false
            await refresh()
        }
    }

    public private(set) var latestRecheckQuality: CalibrationQuality?
    public private(set) var canApplyLatestCorrection = false
    #if DEBUG
    public private(set) var diagnosticMessage: String?
    public func runMiddletonDiagnostic() {
        guard !isBusy, let inputUID = resolvedCalibrationInputUID else { return }
        isBusy = true
        diagnosticMessage = "MIDDLETON diagnostic: 0 / 20"
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false }
            guard await microphonePermissionProvider.requestPermission() else {
                microphonePermissionDenied = true
                return
            }
            do {
                let path = try await controller.runMiddletonDiagnostic(inputUID: inputUID) { [weak self] count in
                    Task { @MainActor in self?.diagnosticMessage = "MIDDLETON diagnostic: \(count) / 20" }
                }
                diagnosticMessage = "20 measurements complete. Delays retained. Artifacts: \(path)"
            } catch is CancellationError { diagnosticMessage = "Diagnostic cancelled. Delays retained." }
            catch { diagnosticMessage = error.localizedDescription }
        }
    }

    public func runThreeSpeakerDiagnostic(passesPerSpeaker: Int = 20) {
        guard !isBusy, let inputUID = resolvedCalibrationInputUID else { return }
        isBusy = true
        diagnosticMessage = "Three-speaker diagnostic starting..."
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            defer { isBusy = false }
            guard await microphonePermissionProvider.requestPermission() else {
                microphonePermissionDenied = true
                return
            }
            do {
                let path = try await controller.runThreeSpeakerDiagnostic(inputUID: inputUID, passesPerSpeaker: passesPerSpeaker) { [weak self] completed, total, currentSpeaker in
                    Task { @MainActor in
                        self?.diagnosticMessage = "Three-speaker diagnostic: \(completed) / \(total) (\(currentSpeaker))"
                    }
                }
                diagnosticMessage = "Multi-speaker diagnostic complete (\(passesPerSpeaker) passes/speaker). Delays retained. Artifacts: \(path)"
            } catch is CancellationError {
                diagnosticMessage = "Diagnostic cancelled. Delays retained."
            } catch {
                diagnosticMessage = error.localizedDescription
            }
        }
    }
    #endif

    public func presentCalibration() {
        isCalibrationPresented = true
    }

    private var resolvedCalibrationInputUID: String? {
        if let preferred = preferences.preferredMicrophoneUID,
           availableInputs.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return availableInputs.first?.id
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
                latestRecheckResiduals = result.relativeArrivalsToReferenceMilliseconds
                latestRecheckResidual = result.residualSpreadMilliseconds
                latestRecheckQuality = result.quality
                canApplyLatestCorrection = result.canApplyCompensation
            } catch { present(error) }
            isBusy = false
            await refresh()
        }
    }

    public func applyLatestCorrection() {
        guard canApplyLatestCorrection, let residual = latestRecheckResidual else { return }
        Task {
            do {
                try await controller.applyDynamicCorrections(residuals: latestRecheckResiduals.isEmpty ? [0, residual] : latestRecheckResiduals)
                latestRecheckResidual = nil
                latestRecheckResiduals = []
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

    public func updateRouteVolume(route: Int, volume: Float) {
        Task { await controller.setRouteVolume(route: route, volume: volume) }
    }

    public func shutdown() async {
        pollingTask?.cancel()
        if let playbackCoordinator {
            playbackCoordinator.stop()
            await playbackCoordinator.waitForTransition()
        } else {
            await pauseSession()
        }
    }

    private func map(_ snapshot: SessionControllerSnapshot) {
        guard let status = snapshot.status else {
            presentation = SpeakerrPresentationState(
                status: isPaused ? .paused : .inactive,
                statusDetail: preferences.selectedSpeakerUIDs.count >= 2 ? nil : "Select at least two speakers to create a Speakerr group.",
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
            playback: .init(isActive: !isPaused && speakers.allSatisfy(\.isConnected) && status.renderError == nil && status.state != .idle && status.state != .rebuilding, isProgrammeAttached: snapshot.isProgrammeAttached, statusText: snapshot.isProgrammeAttached ? "Active" : "Ready"),
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

    func presentPlaybackError(_ error: Error) {
        present(error)
        presentation.playback = .init(isActive: false, isProgrammeAttached: false, statusText: "Stopped")
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
