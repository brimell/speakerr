import XCTest
@testable import SpeakerrAudio

final class SpeakerSessionStateTests: XCTestCase {
    func testHappyPathAndRebuildInvalidatesCalibration() throws {
        var machine = SpeakerSessionStateMachine()
        XCTAssertEqual(try machine.handle(.prepare), .preparing)
        XCTAssertEqual(try machine.handle(.prepared), .ready)
        XCTAssertEqual(try machine.handle(.beginCalibration), .calibrating)
        XCTAssertEqual(try machine.handle(.calibrationSucceeded), .aligned)
        XCTAssertEqual(try machine.handle(.beginRebuild), .rebuilding)
        XCTAssertEqual(try machine.handle(.rebuildSucceeded), .calibrationStale(.routeRebuilt))
    }

    func testUnavailableAndCleanupAreDeterministic() throws {
        var machine = SpeakerSessionStateMachine(state: .aligned)
        XCTAssertEqual(try machine.handle(.outputUnavailable("missing")), .unavailable("missing"))
        XCTAssertEqual(try machine.handle(.stop), .idle)
        XCTAssertEqual(try machine.handle(.stop), .idle)
    }

    func testAlignedSessionCanRecalibrateWithoutRebuild() throws {
        var machine = SpeakerSessionStateMachine(state: .aligned)
        XCTAssertEqual(try machine.handle(.beginCalibration), .calibrating)
        XCTAssertEqual(try machine.handle(.calibrationSucceeded), .aligned)
    }

    func testInvalidTransitionIsRejected() {
        var machine = SpeakerSessionStateMachine()
        XCTAssertThrowsError(try machine.handle(.calibrationSucceeded))
    }

    func testCalibrationSnapshotRequiresGenerationUIDOrderAndRate() {
        let snapshot = CalibrationSnapshot(outputUIDs: ["a", "b"], sampleRate: 44_100, compensationByUID: ["b": 58], residualMilliseconds: 0.5, confidence: 0.8, sessionGeneration: 7)
        XCTAssertTrue(snapshot.isValid(outputUIDs: ["a", "b"], sampleRate: 44_100, sessionGeneration: 7))
        XCTAssertFalse(snapshot.isValid(outputUIDs: ["a", "b"], sampleRate: 44_100, sessionGeneration: 8))
        XCTAssertFalse(snapshot.isValid(outputUIDs: ["b", "a"], sampleRate: 44_100, sessionGeneration: 7))
        XCTAssertFalse(snapshot.isValid(outputUIDs: ["a", "b"], sampleRate: 48_000, sessionGeneration: 7))
    }

    func testDelayCompositionAndBounds() throws {
        XCTAssertEqual(try DelayComponents(manual: 1, calibration: 57.7, dynamicCorrection: 2.3).effectiveMilliseconds, 61, accuracy: 0.000_001)
        XCTAssertThrowsError(try DelayComponents(manual: -0.1))
        XCTAssertThrowsError(try DelayComponents(manual: 500, calibration: 500, dynamicCorrection: 0.1))
    }

    func testLifecycleComparisonRecognisesSameUIDNewObjectIDAndFormatChanges() {
        let previous = ["a": DeviceIdentitySnapshot(uid: "a", objectID: 10, sampleRate: 44_100, channelCount: 2)]
        XCTAssertEqual(DeviceLifecycleComparison.compare(previous: previous, current: [:], selectedUIDs: ["a"]), [.disconnected(uid: "a")])
        XCTAssertEqual(DeviceLifecycleComparison.compare(previous: previous, current: ["a": .init(uid: "a", objectID: 11, sampleRate: 44_100, channelCount: 2)], selectedUIDs: ["a"]), [.reconnected(uid: "a", oldObjectID: 10, newObjectID: 11)])
        XCTAssertEqual(DeviceLifecycleComparison.compare(previous: previous, current: ["a": .init(uid: "a", objectID: 10, sampleRate: 48_000, channelCount: 2)], selectedUIDs: ["a"]), [.sampleRateChanged(uid: "a", old: 44_100, new: 48_000)])
    }

    func testRebuildCanReprepareWithoutPassingThroughIdle() throws {
        var machine = SpeakerSessionStateMachine(state: .rebuilding)
        XCTAssertEqual(try machine.handle(.prepare), .preparing)
        XCTAssertEqual(try machine.handle(.prepared), .ready)
        XCTAssertEqual(try machine.handle(.invalidate(.deviceReconnected)), .calibrationStale(.deviceReconnected))
    }

    func testDuplicateNotificationsCoalesce() {
        var coalescer = NotificationCoalescer(intervalNanoseconds: 100)
        coalescer.receive(at: 0)
        coalescer.receive(at: 50)
        XCTAssertFalse(coalescer.consumeIfDue(at: 100))
        XCTAssertTrue(coalescer.consumeIfDue(at: 150))
        XCTAssertFalse(coalescer.consumeIfDue(at: 200))
    }

    func testChannelLayoutChangeIsDetectedIndependentlyOfSampleRate() {
        let previous = ["a": DeviceIdentitySnapshot(uid: "a", objectID: 10, sampleRate: 44_100, channelCount: 2)]
        let current = ["a": DeviceIdentitySnapshot(uid: "a", objectID: 10, sampleRate: 44_100, channelCount: 6)]
        XCTAssertEqual(DeviceLifecycleComparison.compare(previous: previous, current: current, selectedUIDs: ["a"]), [.channelLayoutChanged(uid: "a", old: 2, new: 6)])
    }

    func testUnrelatedDeviceChangesAreIgnored() {
        let previous = ["a": DeviceIdentitySnapshot(uid: "a", objectID: 10, sampleRate: 44_100, channelCount: 2)]
        let current = ["a": DeviceIdentitySnapshot(uid: "a", objectID: 10, sampleRate: 44_100, channelCount: 2), "unrelated": DeviceIdentitySnapshot(uid: "unrelated", objectID: 99, sampleRate: 48_000, channelCount: 2)]
        XCTAssertEqual(DeviceLifecycleComparison.compare(previous: previous, current: current, selectedUIDs: ["a"]), [])
    }

    func testDynamicCorrectionAloneRespectsBounds() {
        XCTAssertThrowsError(try DelayComponents(dynamicCorrection: 1_000.1))
        XCTAssertNoThrow(try DelayComponents(dynamicCorrection: 3.5))
    }

    func testBeginRebuildIsRejectedBeforeTheSessionHasEverStarted() {
        var machine = SpeakerSessionStateMachine(state: .idle)
        XCTAssertThrowsError(try machine.handle(.beginRebuild))
    }

    func testCalibrationStaleReasonIsPreservedThroughRebuild() throws {
        var machine = SpeakerSessionStateMachine(state: .aligned)
        XCTAssertEqual(try machine.handle(.beginRebuild), .rebuilding)
        XCTAssertEqual(try machine.handle(.prepare), .preparing)
        XCTAssertEqual(try machine.handle(.prepared), .ready)
        XCTAssertEqual(try machine.handle(.invalidate(.sampleRateChanged)), .calibrationStale(.sampleRateChanged))
    }

    func testCalibrationProgressUpdateFormattedTimeRemaining() {
        let measuring = CalibrationProgressUpdate(phase: .measuring(speakerIndex: 0, speakerName: "Left", pass: 1, totalPasses: 3, measurement: 1, totalMeasurements: 3), progressFraction: 0.1, timeRemaining: nil)
        XCTAssertNil(measuring.formattedTimeRemaining)

        let completed = CalibrationProgressUpdate(phase: .completed, progressFraction: 1.0, timeRemaining: 0)
        XCTAssertNil(completed.formattedTimeRemaining)

        let negative = CalibrationProgressUpdate(phase: .verifying(pass: 2), progressFraction: 0.5, timeRemaining: -1)
        XCTAssertNil(negative.formattedTimeRemaining)

        let oneSecond = CalibrationProgressUpdate(phase: .measuring(speakerIndex: 0, speakerName: "Left", pass: 1, totalPasses: 3, measurement: 1, totalMeasurements: 3), progressFraction: 0.9, timeRemaining: 0.8)
        XCTAssertEqual(oneSecond.formattedTimeRemaining, "About 1 second remaining")

        let seconds = CalibrationProgressUpdate(phase: .measuring(speakerIndex: 0, speakerName: "Left", pass: 1, totalPasses: 3, measurement: 1, totalMeasurements: 3), progressFraction: 0.5, timeRemaining: 15.4)
        XCTAssertEqual(seconds.formattedTimeRemaining, "About 15 seconds remaining")

        let oneMinute = CalibrationProgressUpdate(phase: .measuring(speakerIndex: 0, speakerName: "Left", pass: 1, totalPasses: 3, measurement: 1, totalMeasurements: 3), progressFraction: 0.2, timeRemaining: 65)
        XCTAssertEqual(oneMinute.formattedTimeRemaining, "About 1 minute remaining")

        let twoMinutes = CalibrationProgressUpdate(phase: .measuring(speakerIndex: 0, speakerName: "Left", pass: 1, totalPasses: 3, measurement: 1, totalMeasurements: 3), progressFraction: 0.1, timeRemaining: 120)
        XCTAssertEqual(twoMinutes.formattedTimeRemaining, "About 2 minutes remaining")
    }

    func testPersistentSpeakerSessionEstimateTimeRemaining() {
        // When all measurements are already complete, time remaining should be 0.
        let zeroRemaining = PersistentSpeakerSession.estimateTimeRemaining(
            pass: 0,
            totalPasses: 1,
            outputsCount: 2,
            measurementsPerSpeaker: 3,
            acceptedCounts: [3, 3],
            singleMeasurementDuration: 0.85,
            elapsedSeconds: 10,
            completedGlobalAttempts: 6
        )
        XCTAssertEqual(zeroRemaining, 0)

        // At start (completedGlobalAttempts == 0), pace falls back to singleMeasurementDuration.
        // 2 speakers * 3 measurements = 6 remaining measurements.
        let initialRemaining = PersistentSpeakerSession.estimateTimeRemaining(
            pass: 0,
            totalPasses: 1,
            outputsCount: 2,
            measurementsPerSpeaker: 3,
            acceptedCounts: [0, 0],
            singleMeasurementDuration: 0.9,
            elapsedSeconds: 0,
            completedGlobalAttempts: 0
        )
        XCTAssertEqual(initialRemaining, 6.0 * 0.9, accuracy: 0.001)

        // With multi-pass: current pass (pass 0 of 2) has 3 remaining (accepted: [2, 1]),
        // plus next pass has 2 * 3 = 6 remaining. Total = 9 remaining measurements.
        // Measured pace: 4 attempts in 4.0s = 1.0s/attempt.
        let multiPassRemaining = PersistentSpeakerSession.estimateTimeRemaining(
            pass: 0,
            totalPasses: 2,
            outputsCount: 2,
            measurementsPerSpeaker: 3,
            acceptedCounts: [2, 1],
            singleMeasurementDuration: 0.9,
            elapsedSeconds: 4.0,
            completedGlobalAttempts: 4
        )
        XCTAssertEqual(multiPassRemaining, 9.0 * 1.0, accuracy: 0.001)
    }
}
