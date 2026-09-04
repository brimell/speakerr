import SpeakerrAudio
import SpeakerrPresentation
import SwiftUI

#if DEBUG
private actor PreviewSessionController: SpeakerSessionControlling {
    let value: SessionControllerSnapshot
    init(_ value: SessionControllerSnapshot) { self.value = value }
    func snapshot() -> SessionControllerSnapshot { value }
    func start(outputUIDs: [String], programmeInputUID: String?, calibrationLevel: Double, routingMode: SpeakerRoutingMode) throws {}
    func stop() {}
    func calibrate(inputUID: String, configuration: CalibrationExperimentConfiguration, progress: @escaping @Sendable (CalibrationProgressUpdate) -> Void) async throws -> [CalibrationPassMeasurements] { throw CancellationError() }
    func recheck(inputUID: String, configuration: CalibrationExperimentConfiguration) async throws -> CalibrationPassMeasurements { throw CancellationError() }
    func applyDynamicCorrection(residualMilliseconds: Double) throws {}
    func setManualDelay(outputUID: String, milliseconds: Double) throws {}
    func setMasterEQBands(_ bands: [EQBand]) async {}
    func setMasterEQBypass(_ bypass: Bool) async {}
    func setRouteEQBands(route: Int, bands: [EQBand]) async {}
    func setRouteEQBypass(route: Int, bypass: Bool) async {}
    func setRouteVolume(route: Int, volume: Float) async {}
}

@MainActor
private func previewModel(state: SpeakerSessionState?, snapshot: CalibrationSnapshot? = nil, availableBoth: Bool = true, initialOutcome: CalibrationOutcome = .none, permissionDenied: Bool = false) -> SpeakerrViewModel {
    let bose = OutputDevice(id: "bose", coreAudioID: 10, name: "Bose SoundLink Max", transport: .bluetooth, sampleRate: 44_100, channelCount: 2)
    let middleton = OutputDevice(id: "middleton", coreAudioID: 11, name: "MIDDLETON", transport: .bluetooth, sampleRate: 44_100, channelCount: 2)
    let mic = InputDevice(id: "mic", coreAudioID: 12, name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 44_100, channelCount: 1)
    let delays = [try! DelayComponents(), try! DelayComponents(calibration: 57.77)]
    let status = state.map { PersistentSessionStatus(generation: 4, sampleRate: 44_100, state: $0, delays: delays, calibration: snapshot) }
    let controller = PreviewSessionController(.init(status: status, selectedOutputs: [bose, middleton], availableOutputs: availableBoth ? [bose, middleton] : [bose], availableInputs: [mic], programmeInputUID: nil, isProgrammeAttached: true))
    let defaults = UserDefaults(suiteName: "SpeakerrPreview-\(UUID().uuidString)")!
    let preferences = SpeakerrPreferences(defaults: defaults)
    preferences.selectedSpeakerUIDs = [bose.id, middleton.id]
    preferences.preferredMicrophoneUID = mic.id
    return SpeakerrViewModel(controller: controller, preferences: preferences, initialCalibrationOutcome: initialOutcome, microphonePermissionDenied: permissionDenied)
}

#Preview("No speakers selected") {
    let controller = PreviewSessionController(.init(status: nil, selectedOutputs: [], availableOutputs: [], availableInputs: [], programmeInputUID: nil, isProgrammeAttached: false))
    MainWindowView(model: SpeakerrViewModel(controller: controller))
}

#Preview("Ready to calibrate") {
    MainWindowView(model: previewModel(state: .ready))
}

#Preview("Calibrating") {
    MainWindowView(model: previewModel(state: .calibrating))
}

#Preview("Aligned") {
    let calibration = CalibrationSnapshot(outputUIDs: ["bose", "middleton"], sampleRate: 44_100, compensationByUID: ["middleton": 57.77], residualMilliseconds: 0.47, confidence: 0.95, sessionGeneration: 4)
    MainWindowView(model: previewModel(state: .aligned, snapshot: calibration))
}

#Preview("Stale after reconnect") {
    MainWindowView(model: previewModel(state: .calibrationStale(.deviceReconnected)))
}

#Preview("Speaker disconnected") {
    MainWindowView(model: previewModel(state: .unavailable("speaker missing"), availableBoth: false))
}

#Preview("Audio error") {
    MainWindowView(model: previewModel(state: .failed("Speakerr couldn't create the combined audio output.")))
}

#Preview("Non-convergence") {
    CalibrationSheet(model: previewModel(state: .failed("did not converge"), initialOutcome: .nonConverged(residualMilliseconds: 2.56, canKeepCurrentAlignment: false)))
}

#Preview("Microphone denied") {
    CalibrationSheet(model: previewModel(state: .ready, permissionDenied: true))
}
#endif
