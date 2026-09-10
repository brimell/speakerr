import XCTest
@testable import SpeakerrAudio
@testable import SpeakerrPresentation

@MainActor
private final class PlaybackTrace {
    var events: [String] = []
    var singleRunning = false
    var pairRunning = false
    var overlappingPlayback = false
}

@MainActor
private final class TestSinglePlayback: SingleSpeakerPlaybackControlling {
    let trace: PlaybackTrace
    init(_ trace: PlaybackTrace) { self.trace = trace }
    var isRunning: Bool { trace.singleRunning }
    func start(outputUID: String, inputUID: String) {
        trace.overlappingPlayback = trace.overlappingPlayback || trace.pairRunning
        trace.singleRunning = true
        trace.events.append("single.start:\(outputUID):\(inputUID)")
    }
    func stop() {
        trace.singleRunning = false
        trace.events.append("single.stop")
    }
}

@MainActor
private final class TestPairPlayback: SpeakerSessionControlling {
    let trace: PlaybackTrace
    var outputs: [String] = []
    var input: String?
    var failStart = false
    var stopGate: CheckedContinuation<Void, Never>?
    var holdNextStop = false
    var onStopWaiting: (() -> Void)?
    var startGate: CheckedContinuation<Void, Never>?
    var holdNextStart = false
    var onStartWaiting: (() -> Void)?
    init(_ trace: PlaybackTrace) { self.trace = trace }

    func snapshot() -> SessionControllerSnapshot {
        let devices = outputs.enumerated().map { index, uid in
            OutputDevice(id: uid, coreAudioID: UInt32(index + 1), name: uid, transport: .builtIn, sampleRate: 44_100, channelCount: 2)
        }
        let status = trace.pairRunning ? PersistentSessionStatus(generation: 1, sampleRate: 44_100, state: .ready, delays: [], calibration: nil) : nil
        return .init(status: status, selectedOutputs: devices, availableOutputs: devices, availableInputs: [], programmeInputUID: input, isProgrammeAttached: trace.pairRunning)
    }

    func start(outputUIDs: [String], programmeInputUID: String?, calibrationLevel: Double, routingMode: SpeakerRoutingMode) async throws {
        if holdNextStart {
            holdNextStart = false
            await withCheckedContinuation { startGate = $0; onStartWaiting?() }
        }
        if failStart { throw SessionControllerError.outputUnavailable("second") }
        trace.overlappingPlayback = trace.overlappingPlayback || trace.singleRunning
        outputs = outputUIDs
        input = programmeInputUID
        trace.pairRunning = true
        trace.events.append("pair.start:\(outputUIDs.joined(separator: ",")):\(programmeInputUID ?? "nil")")
    }

    func stop() async {
        trace.events.append("pair.stop.begin")
        if holdNextStop {
            holdNextStop = false
            await withCheckedContinuation { stopGate = $0; onStopWaiting?() }
        }
        trace.pairRunning = false
        trace.events.append("pair.stop.restored")
    }

    func calibrate(inputUID: String, configuration: CalibrationExperimentConfiguration, progress: @escaping @Sendable (CalibrationProgressUpdate) -> Void) async throws -> [CalibrationPassMeasurements] { [] }
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
final class PlaybackCoordinatorTests: XCTestCase {
    private func fixture(outputs: [String] = ["a", "b"]) -> (PlaybackCoordinator, SpeakerrViewModel, TestPairPlayback, PlaybackTrace) {
        let trace = PlaybackTrace()
        let pair = TestPairPlayback(trace)
        let defaults = UserDefaults(suiteName: "PlaybackCoordinatorTests-\(UUID().uuidString)")!
        let model = SpeakerrViewModel(controller: pair, preferences: SpeakerrPreferences(defaults: defaults))
        let coordinator = PlaybackCoordinator(singleSpeaker: TestSinglePlayback(trace), model: model, outputUIDs: outputs, inputUID: "blackhole")
        return (coordinator, model, pair, trace)
    }

    func testSavedPairStartsOnlyAggregateAndPreservesSelectionOrder() async {
        let (coordinator, model, pair, trace) = fixture(outputs: ["b", "a"])
        coordinator.start()
        await coordinator.waitForTransition()
        XCTAssertEqual(pair.outputs, ["b", "a"])
        XCTAssertEqual(pair.input, "blackhole")
        XCTAssertEqual(model.preferences.selectedSpeakerUIDs, ["b", "a"])
        XCTAssertFalse(trace.singleRunning)
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("single.start") }))
    }

    func testSingleToPairStopsLegacyBeforeAggregateStart() async {
        let (coordinator, _, _, trace) = fixture(outputs: ["a"])
        coordinator.start()
        await coordinator.waitForTransition()
        XCTAssertTrue(trace.singleRunning)
        trace.events.removeAll()
        coordinator.selectOutputs(["a", "b"])
        await coordinator.waitForTransition()
        XCTAssertEqual(trace.events.first, "single.stop")
        XCTAssertTrue(trace.pairRunning)
        XCTAssertFalse(trace.overlappingPlayback)
    }

    func testPairToSingleWaitsForRouteRestoration() async {
        let (coordinator, _, pair, trace) = fixture()
        coordinator.start()
        await coordinator.waitForTransition()
        let waiting = expectation(description: "Pair shutdown is waiting")
        pair.holdNextStop = true
        pair.onStopWaiting = { waiting.fulfill() }
        coordinator.selectOutputs(["b"])
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertFalse(trace.singleRunning)
        pair.stopGate?.resume()
        pair.stopGate = nil
        await coordinator.waitForTransition()
        XCTAssertEqual(Array(trace.events.suffix(2)), ["pair.stop.restored", "single.start:b:blackhole"])
        XCTAssertFalse(trace.overlappingPlayback)
    }

    func testLatestSelectionWinsDuringDelayedShutdown() async {
        let (coordinator, _, pair, trace) = fixture()
        coordinator.start()
        await coordinator.waitForTransition()
        let waiting = expectation(description: "Shutdown suspended")
        pair.holdNextStop = true
        pair.onStopWaiting = { waiting.fulfill() }
        coordinator.selectOutputs(["a"])
        await fulfillment(of: [waiting], timeout: 2)
        coordinator.selectOutputs(["b"])
        coordinator.selectOutputs(["b", "a"])
        pair.stopGate?.resume()
        pair.stopGate = nil
        await coordinator.waitForTransition()
        XCTAssertEqual(pair.outputs, ["b", "a"])
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("single.start") }))
        XCTAssertFalse(trace.overlappingPlayback)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testStopDuringPendingStartLeavesBothEnginesStopped() async {
        let (coordinator, _, pair, trace) = fixture()
        let waiting = expectation(description: "Start suspended")
        pair.holdNextStart = true
        pair.onStartWaiting = { waiting.fulfill() }
        coordinator.start()
        await fulfillment(of: [waiting], timeout: 2)
        coordinator.stop()
        pair.startGate?.resume()
        pair.startGate = nil
        await coordinator.waitForTransition()
        XCTAssertFalse(trace.singleRunning)
        XCTAssertFalse(trace.pairRunning)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testInputChangeFromEitherUIUsesSameSelectionAndRestartsActivePair() async {
        let (coordinator, model, pair, _) = fixture()
        coordinator.start()
        await coordinator.waitForTransition()
        model.selectProgrammeInput("background-music")
        await coordinator.waitForTransition()
        XCTAssertEqual(coordinator.inputUID, "background-music")
        XCTAssertEqual(pair.input, "background-music")
        coordinator.selectInput("blackhole")
        await coordinator.waitForTransition()
        XCTAssertEqual(model.preferences.programmeInputUID, "blackhole")
        XCTAssertEqual(pair.input, "blackhole")
    }

    func testFailedPairStartReportsErrorWithoutSingleSpeakerFallback() async {
        let (coordinator, model, pair, trace) = fixture()
        pair.failStart = true
        coordinator.start()
        await coordinator.waitForTransition()
        await model.refresh()
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(model.presentation.status, .audioError)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertFalse(trace.singleRunning)
        XCTAssertFalse(trace.pairRunning)
        XCTAssertFalse(trace.events.contains(where: { $0.hasPrefix("single.start") }))
    }

    func testClearSelectionAndPauseDoNotRestartWhenViewsRefresh() async {
        let (coordinator, model, _, trace) = fixture()
        coordinator.start()
        await coordinator.waitForTransition()
        model.pause()
        await coordinator.waitForTransition()
        coordinator.selectOutputs(["a", "b"])
        await model.refresh()
        XCTAssertFalse(trace.pairRunning)
        coordinator.selectOutputs([])
        await coordinator.waitForTransition()
        XCTAssertEqual(coordinator.selectedOutputUIDs, [])
        XCTAssertEqual(model.preferences.selectedSpeakerUIDs, [])
        XCTAssertFalse(trace.singleRunning)
    }

    func testMainInputWinsOverStaleProgrammeInputAndBlackHoleIsDefault() {
        let bgm = InputDevice(id: "bgm", coreAudioID: 63, name: "Background Music", transport: .virtual, sampleRate: 44_100, channelCount: 2)
        let blackhole = InputDevice(id: "blackhole", coreAudioID: 84, name: "BlackHole 2ch", transport: .virtual, sampleRate: 44_100, channelCount: 2)
        let inputs = [bgm, blackhole]
        XCTAssertEqual(PlaybackCoordinator.resolveInputUID(savedInputID: 84, savedProgrammeInputUID: "bgm", inputs: inputs), "blackhole")
        XCTAssertEqual(PlaybackCoordinator.resolveInputUID(savedInputID: 999, savedProgrammeInputUID: "bgm", inputs: inputs), "bgm")
        XCTAssertEqual(PlaybackCoordinator.resolveInputUID(savedInputID: nil, savedProgrammeInputUID: nil, inputs: inputs), "blackhole")
        XCTAssertNil(PlaybackCoordinator.resolveInputUID(savedInputID: nil, savedProgrammeInputUID: nil, inputs: [bgm]))
    }
}
