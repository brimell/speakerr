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

    func testCompensationAlignsAnyNumberOfSpeakersToLatestArrival() throws {
        let result = try DelayCompensation.calculate(arrivalMilliseconds: [81.37, 137.84, 95.62, 111.20])
        for (actual, expected) in zip(result.delays, [56.47, 0, 42.22, 26.64]) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
    }

    func testCompensationAlignsEightSpeakersWithoutPairwiseAssumptions() throws {
        let arrivals = [81.37, 137.84, 95.62, 111.20, 64.50, 128.25, 104.75, 149.00]
        let result = try DelayCompensation.calculate(arrivalMilliseconds: arrivals)

        XCTAssertEqual(result.delays.count, arrivals.count)
        for (actual, expected) in zip(result.delays, arrivals.map { 149.00 - $0 }) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(result.delays.max()!, 84.50, accuracy: 0.0001)
        XCTAssertEqual(result.delays[7], 0, accuracy: 0.0001)
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
