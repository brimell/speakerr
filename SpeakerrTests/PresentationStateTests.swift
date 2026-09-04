import XCTest
@testable import SpeakerrAudio
@testable import SpeakerrPresentation

final class PresentationStateTests: XCTestCase {
    func testValidAlignedSessionMapsToAligned() {
        XCTAssertEqual(PresentationStateMapper.userStatus(for: .aligned, calibrationIsValid: true, latestRecheckResidualMilliseconds: nil), .aligned)
    }

    func testAlignedEngineStateWithoutValidSnapshotNeverMapsToAligned() {
        XCTAssertEqual(PresentationStateMapper.userStatus(for: .aligned, calibrationIsValid: false, latestRecheckResidualMilliseconds: nil), .calibrationStale)
    }

    func testReconnectMapsToCalibrationRequiredWithMeaningfulReason() {
        let calibration = PresentationStateMapper.calibration(for: .calibrationStale(.deviceReconnected), snapshot: nil, calibrationIsValid: false)
        XCTAssertEqual(calibration, .required(reason: "A selected speaker reconnected. Bluetooth latency may have changed."))
        XCTAssertEqual(PresentationStateMapper.userStatus(for: .calibrationStale(.deviceReconnected), calibrationIsValid: false, latestRecheckResidualMilliseconds: nil), .calibrationStale)
    }

    func testMissingOutputMapsToWaitingForSpeaker() {
        XCTAssertEqual(PresentationStateMapper.userStatus(for: .unavailable("missing"), calibrationIsValid: false, latestRecheckResidualMilliseconds: nil), .waitingForSpeaker)
    }

    func testCalibrationMapsToCalibrating() {
        XCTAssertEqual(PresentationStateMapper.userStatus(for: .calibrating, calibrationIsValid: false, latestRecheckResidualMilliseconds: nil), .calibrating)
        XCTAssertEqual(PresentationStateMapper.calibration(for: .calibrating, snapshot: nil, calibrationIsValid: false), .running(nil))
    }

    func testRecheckAboveThresholdMapsToDrifting() {
        XCTAssertEqual(PresentationStateMapper.userStatus(for: .aligned, calibrationIsValid: true, latestRecheckResidualMilliseconds: 2.01), .alignmentDrifting)
    }

    func testNonConvergenceHasFirstClassPresentation() {
        let outcome = CalibrationOutcome.nonConverged(residualMilliseconds: 2.6, canKeepCurrentAlignment: false)
        XCTAssertEqual(PresentationStateMapper.calibration(for: .failed("did not converge"), snapshot: nil, calibrationIsValid: false, outcome: outcome), .failed(outcome))
    }

    func testPausedOverridesEngineState() {
        XCTAssertEqual(PresentationStateMapper.userStatus(for: .aligned, calibrationIsValid: true, latestRecheckResidualMilliseconds: nil, isPaused: true), .paused)
    }
}
