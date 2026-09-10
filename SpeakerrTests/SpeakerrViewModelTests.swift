import XCTest
@testable import SpeakerrAudio
@testable import SpeakerrPresentation

private struct GrantedMicrophonePermission: MicrophonePermissionProviding {
    func requestPermission() async -> Bool { true }
}

private actor MockSpeakerSessionController: SpeakerSessionControlling {
    var currentSnapshot: SessionControllerSnapshot
    var startCount = 0
    var stopCount = 0
    var calibrationCancelled = false
    var returnedPasses: [CalibrationPassMeasurements]?
    func setCalibrationResponse(_ passes: [CalibrationPassMeasurements]) { returnedPasses = passes }

    init(snapshot: SessionControllerSnapshot) {
        currentSnapshot = snapshot
    }

    func snapshot() -> SessionControllerSnapshot { currentSnapshot }
    func start(outputUIDs: [String], programmeInputUID: String?, calibrationLevel: Double, routingMode: SpeakerRoutingMode) { startCount += 1 }
    func stop() { stopCount += 1 }

    func calibrate(inputUID: String, configuration: CalibrationExperimentConfiguration, progress: @escaping @Sendable (CalibrationProgressUpdate) -> Void) async throws -> [CalibrationPassMeasurements] {
        if let returnedPasses { return returnedPasses }
        progress(.init(phase: .measuring(speakerIndex: 0, speakerName: "Bose", pass: 1, totalPasses: 3, measurement: 1, totalMeasurements: 3)))
        do {
            try await Task.sleep(for: .seconds(30))
            return []
        } catch is CancellationError {
            calibrationCancelled = true
            throw CancellationError()
        }
    }

    func recheck(inputUID: String, configuration: CalibrationExperimentConfiguration) async throws -> CalibrationPassMeasurements { throw CancellationError() }
    func applyDynamicCorrection(residualMilliseconds: Double) {}
    func setManualDelay(outputUID: String, milliseconds: Double) {}
    func setMasterEQBands(_ bands: [EQBand]) {}
    func setMasterEQBypass(_ bypass: Bool) {}
    func setRouteEQBands(route: Int, bands: [EQBand]) {}
    func setRouteEQBypass(route: Int, bypass: Bool) {}
    func setRouteVolume(route: Int, volume: Float) {}
    func applyDynamicCorrections(residuals: [Double]) {}
}

@MainActor
final class SpeakerrViewModelTests: XCTestCase {
    func testCalibrationVolumeClampsSavedAndAssignedValuesToSignalRange() {
        let defaults = UserDefaults(suiteName: "SpeakerrCalibrationVolumeTests-\(UUID().uuidString)")!
        defaults.set(0.8, forKey: "calibrationVolume")

        let preferences = SpeakerrPreferences(defaults: defaults)
        XCTAssertEqual(preferences.calibrationVolume, 0.5)

        preferences.calibrationVolume = 0.7
        XCTAssertEqual(preferences.calibrationVolume, 0.5)
    }

    func testViewModelMapsValidEngineCalibrationToAligned() async throws {
        let fixture = try makeFixture(state: .aligned, validCalibration: true)
        let model = fixture.model
        await model.refresh()
        XCTAssertEqual(model.presentation.status, .aligned)
        guard case .valid(let residual, _, _) = model.presentation.calibration else {
            return XCTFail("Expected valid calibration presentation")
        }
        XCTAssertEqual(residual, 0.47, accuracy: 0.001)
    }

    func testStaleCalibrationNeverRendersAligned() async throws {
        let fixture = try makeFixture(state: .calibrationStale(.deviceReconnected), validCalibration: false)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.presentation.status, .calibrationStale)
        guard case .required(let reason) = fixture.model.presentation.calibration else {
            return XCTFail("Expected required calibration presentation")
        }
        XCTAssertTrue(reason.contains("reconnected"))
    }

    func testUnavailableSpeakerMapsToWaiting() async throws {
        let fixture = try makeFixture(state: .unavailable("missing"), validCalibration: false, availableBoth: false)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.presentation.status, .waitingForSpeaker)
        XCTAssertFalse(fixture.model.presentation.speakers[1].isConnected)
    }

    func testCalibrationCancellationRestoresAuthoritativeAlignedState() async throws {
        let fixture = try makeFixture(state: .aligned, validCalibration: true)
        await fixture.model.refresh()
        fixture.model.calibrate()
        try await Task.sleep(for: .milliseconds(50))
        fixture.model.cancelCalibration()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(fixture.model.calibrationOutcome, .cancelled)
        XCTAssertEqual(fixture.model.presentation.status, .aligned)
        let calibrationCancelled = await fixture.controller.calibrationCancelled
        XCTAssertTrue(calibrationCancelled)
    }

    func testCalibrationFallsBackToAvailableMicrophoneWhenPreferenceIsMissing() async throws {
        let fixture = try makeFixture(state: .ready, validCalibration: false)
        fixture.model.preferences.preferredMicrophoneUID = nil
        await fixture.model.refresh()

        fixture.model.calibrate()
        try await Task.sleep(for: .milliseconds(50))
        fixture.model.cancelCalibration()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(fixture.model.preferences.preferredMicrophoneUID, "mic")
    }

    func testPresentCalibrationSetsAuthoritativePresentationState() throws {
        let fixture = try makeFixture(state: .ready, validCalibration: false)

        XCTAssertFalse(fixture.model.isCalibrationPresented)
        fixture.model.presentCalibration()
        XCTAssertTrue(fixture.model.isCalibrationPresented)
    }

    func testPassiveRefreshEquivalentToWindowCloseReopenDoesNotMutateSession() async throws {
        let fixture = try makeFixture(state: .aligned, validCalibration: true)
        await fixture.model.refresh()
        await fixture.model.refresh()
        await fixture.model.refresh()
        let startCount = await fixture.controller.startCount
        let stopCount = await fixture.controller.stopCount
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(fixture.model.presentation.status, .aligned)
    }

    func testProvisionalUIRetainsInitialEstimateAndDoesNotDoubleCountResidualDelay() async throws {
        let fixture = try makeFixture(state: .aligned, validCalibration: true)
        func measurement(_ latency: Double, accepted: Bool) -> AcousticMeasurement {
            AcousticMeasurement(emission: CalibrationEmission(pass: 0, sequence: 0, speakerIndex: 0, scheduledOutputFrame: 0, scheduledOutputHostTime: 1), arrivalHostTime: 2, acousticLatencyMilliseconds: latency, estimate: DelayEstimate(sampleOffset: latency, sampleRate: 1_000, confidence: accepted ? 0.7 : 0.32, peakValue: 0.22, secondBestPeak: 0.05, peakProminence: 4.4, accepted: accepted))
        }
        let initial = try CalibrationPassMeasurements(pass: 0, measurementsBySpeaker: [
            [100.0, 100.1, 99.9].map { measurement($0, accepted: true) },
            [42.0, 42.2, 42.4].map { measurement($0, accepted: false) }
        ], failures: [])
        let final = try CalibrationPassMeasurements(pass: 1, measurementsBySpeaker: [
            [100.0, 100.1, 99.9].map { measurement($0, accepted: true) },
            [99.8, 100.0, 100.2].map { measurement($0, accepted: false) }
        ], failures: [])
        await fixture.controller.setCalibrationResponse([initial, final])
        await fixture.model.refresh()
        fixture.model.calibrate()
        for _ in 0..<100 where fixture.model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.calibrationOutcome, .estimated(residualMilliseconds: 0, applied: true, residualQuality: .provisional))
        XCTAssertEqual(fixture.model.calibrationSpeakerResults[1].detectedLatencyMilliseconds, 42.2)
        XCTAssertEqual(fixture.model.calibrationSpeakerResults[1].quality, .provisional)
        XCTAssertEqual(fixture.model.calibrationCompletion?.residualSpreadMilliseconds, 0)
        XCTAssertEqual(fixture.model.calibrationCompletion?.speakers[1].appliedDelayMilliseconds, 57.77)
    }

    func testPoorUIShowsCandidateWithoutClaimingAppliedAlignment() async throws {
        let fixture = try makeFixture(state: .ready, validCalibration: false)
        func measurement(_ latency: Double) -> AcousticMeasurement {
            AcousticMeasurement(emission: CalibrationEmission(pass: 0, sequence: 0, speakerIndex: 0, scheduledOutputFrame: 0, scheduledOutputHostTime: 1), arrivalHostTime: 2, acousticLatencyMilliseconds: latency, estimate: DelayEstimate(sampleOffset: latency, sampleRate: 1_000, confidence: 0.2, peakValue: 0.1, secondBestPeak: 0.09, peakProminence: 1.1, accepted: false))
        }
        let pass = try CalibrationPassMeasurements(pass: 0, measurementsBySpeaker: [[measurement(100)], []], failures: ["no estimate"])
        await fixture.controller.setCalibrationResponse([pass])
        await fixture.model.refresh()
        fixture.model.calibrate()
        for _ in 0..<100 where fixture.model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.calibrationOutcome, .estimated(residualMilliseconds: nil, applied: false, residualQuality: .unavailable))
        XCTAssertEqual(fixture.model.calibrationSpeakerResults[0].detectedLatencyMilliseconds, 100)
        XCTAssertNil(fixture.model.calibrationSpeakerResults[1].detectedLatencyMilliseconds)
        XCTAssertNil(fixture.model.calibrationCompletion)
    }

    private func makeFixture(state: SpeakerSessionState, validCalibration: Bool, availableBoth: Bool = true) throws -> (model: SpeakerrViewModel, controller: MockSpeakerSessionController) {
        let bose = OutputDevice(id: "bose", coreAudioID: 10, name: "Bose", transport: .bluetooth, sampleRate: 44_100, channelCount: 2)
        let middleton = OutputDevice(id: "middleton", coreAudioID: 11, name: "MIDDLETON", transport: .bluetooth, sampleRate: 44_100, channelCount: 2)
        let mic = InputDevice(id: "mic", coreAudioID: 12, name: "MacBook Microphone", transport: .builtIn, sampleRate: 44_100, channelCount: 1)
        let calibration = validCalibration ? CalibrationSnapshot(outputUIDs: ["bose", "middleton"], sampleRate: 44_100, compensationByUID: ["middleton": 57.77], residualMilliseconds: 0.47, confidence: 0.95, sessionGeneration: 4) : nil
        let status = PersistentSessionStatus(generation: 4, sampleRate: 44_100, state: state, delays: [try DelayComponents(), try DelayComponents(calibration: 57.77)], calibration: calibration)
        let controller = MockSpeakerSessionController(snapshot: .init(status: status, selectedOutputs: [bose, middleton], availableOutputs: availableBoth ? [bose, middleton] : [bose], availableInputs: [mic], programmeInputUID: "blackhole", isProgrammeAttached: true))
        let defaults = UserDefaults(suiteName: "SpeakerrViewModelTests-\(UUID().uuidString)")!
        let preferences = SpeakerrPreferences(defaults: defaults)
        preferences.selectedSpeakerUIDs = [bose.id, middleton.id]
        preferences.preferredMicrophoneUID = mic.id
        return (SpeakerrViewModel(controller: controller, preferences: preferences, microphonePermissionProvider: GrantedMicrophonePermission()), controller)
    }
}
