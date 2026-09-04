import XCTest
@testable import SpeakerrAudio

final class CalibrationMathTests: XCTestCase {
    func testRobustMedianAndSpread() throws {
        let summary = try RobustMeasurementSummary(values: [68.2, 68.4, 130, 68.3, 68.1])
        XCTAssertEqual(summary.medianMilliseconds, 68.3, accuracy: 0.0001)
        XCTAssertEqual(summary.spreadMilliseconds, 61.9, accuracy: 0.0001)
        XCTAssertEqual(summary.medianAbsoluteDeviationMilliseconds, 0.1, accuracy: 0.0001)
    }

    func testCompensationAlwaysDelaysEarlierSpeaker() throws {
        XCTAssertEqual(try DelayCompensation.calculate(relativeArrivalBMinusA: 68.37), DelayCompensation(calibrationDelayA: 68.37, calibrationDelayB: 0))
        XCTAssertEqual(try DelayCompensation.calculate(relativeArrivalBMinusA: -12.5), DelayCompensation(calibrationDelayA: 0, calibrationDelayB: 12.5))
        XCTAssertThrowsError(try DelayCompensation.calculate(relativeArrivalBMinusA: 1_001))
    }

    func testConvergenceSuccessAndLimit() {
        let controller = ConvergenceController()
        XCTAssertTrue(controller.shouldContinue(residuals: [8]))
        XCTAssertTrue(controller.isSuccessful(residuals: [8, 1.2]))
        XCTAssertFalse(controller.shouldContinue(residuals: [8, 4, 3]))
    }

    func testConvergenceStopsAfterOscillation() {
        let controller = ConvergenceController(signChangeLimit: 2)
        XCTAssertTrue(controller.shouldContinue(residuals: [5, -3]))
        XCTAssertFalse(controller.shouldContinue(residuals: [5, -3, 2]))
        XCTAssertFalse(controller.isSuccessful(residuals: [5, -3, 2.1]))
    }
}
