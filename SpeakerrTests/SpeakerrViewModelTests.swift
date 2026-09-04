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

    init(snapshot: SessionControllerSnapshot) {
        currentSnapshot = snapshot
    }

    func snapshot() -> SessionControllerSnapshot { currentSnapshot }
    func start(outputUIDs: [String], programmeInputUID: String?, calibrationLevel: Double) { startCount += 1 }
    func stop() { stopCount += 1 }

    func calibrate(inputUID: String, configuration: CalibrationExperimentConfiguration, progress: @escaping @Sendable (CalibrationProgressUpdate) -> Void) async throws -> [CalibrationPassMeasurements] {
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
}

@MainActor
final class SpeakerrViewModelTests: XCTestCase {
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
