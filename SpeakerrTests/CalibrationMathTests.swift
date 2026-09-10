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

extension CalibrationMathTests {
    private func candidate(_ latency: Double, accepted: Bool = false, confidence: Double = 0.32, abDifference: Double = 0) -> AcousticMeasurement {
        AcousticMeasurement(emission: CalibrationEmission(pass: 0, sequence: 0, speakerIndex: 0, scheduledOutputFrame: 0, scheduledOutputHostTime: 1), arrivalHostTime: 2, acousticLatencyMilliseconds: latency,
            estimate: DelayEstimate(sampleOffset: latency, sampleRate: 1_000, confidence: confidence, peakValue: 0.22, secondBestPeak: 0.05, peakProminence: 4.4, accepted: accepted, abLatencyDifferenceMilliseconds: abDifference))
    }

    func testReliableThreeSpeakerCalibrationRetainsAcceptedMedians() throws {
        let pass = try CalibrationPassMeasurements(pass: 0, measurementsBySpeaker: [
            [318.3, 318.4, 318.5].map { candidate($0, accepted: true) },
            [455.5, 455.6, 455.7].map { candidate($0, accepted: true) },
            [302.1, 302.2, 302.3].map { candidate($0, accepted: true) }
        ], failures: [])
        XCTAssertEqual(pass.quality, .high)
        XCTAssertTrue(pass.canApplyCompensation)
        let compensation = try DelayCompensation.calculate(arrivalMilliseconds: pass.speakerEstimates.compactMap(\.delayMilliseconds))
        for (actual, expected) in zip(compensation.delays, [137.2, 0, 153.4]) { XCTAssertEqual(actual, expected, accuracy: 0.001) }
    }

    func testClusteredRejectedSpeakerProducesProvisionalNSpeakerCompensation() throws {
        let pass = try CalibrationPassMeasurements(pass: 0, measurementsBySpeaker: [
            [318.3, 318.4, 318.5].map { candidate($0, accepted: true) },
            [455.5, 455.6, 455.7].map { candidate($0, accepted: true) },
            [301.8, 302.1, 302.4, 303.0, 94.0].map { candidate($0) }
        ], failures: [])
        let fallback = pass.speakerEstimates[2]
        XCTAssertEqual(fallback.delayMilliseconds!, 302.25, accuracy: 0.001)
        XCTAssertEqual(fallback.clusterMembers.count, 4)
        XCTAssertEqual(fallback.excludedOutliers, [94])
        XCTAssertEqual(fallback.summary!.medianAbsoluteDeviationMilliseconds, 0.3, accuracy: 0.001)
        XCTAssertEqual(fallback.summary!.spreadMilliseconds, 1.2, accuracy: 0.001)
        XCTAssertEqual(pass.quality, .provisional)
        XCTAssertTrue(pass.canApplyCompensation)
        XCTAssertEqual(pass.rejectedBySpeaker[2].count, 5)
        let delays = try DelayCompensation.calculate(arrivalMilliseconds: pass.speakerEstimates.compactMap(\.delayMilliseconds)).delays
        XCTAssertEqual(delays[2], 153.35, accuracy: 0.001)
    }

    func testScatteredCandidatesExposeBestRawWithoutAutomaticCompensation() throws {
        let measurements = [candidate(80, confidence: 0.1), candidate(190, confidence: 0.15), candidate(290, confidence: 0.33), candidate(400, confidence: 0.2), candidate(520, confidence: 0.12)]
        let result = SpeakerCalibrationEstimate(measurements: measurements)
        XCTAssertEqual(result.quality, .poor)
        XCTAssertEqual(result.delayMilliseconds, 290)
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.method, "strongestRawCandidate")
        let pass = try CalibrationPassMeasurements(pass: 0, measurementsBySpeaker: [[candidate(318, accepted: true)], measurements], failures: [])
        XCTAssertFalse(pass.canApplyCompensation)
        XCTAssertNotNil(pass.residualSpreadMilliseconds)
    }

    func testAcceptedMedianDominatesEvenLargerRejectedCluster() {
        let measurements = [candidate(110, accepted: true), candidate(112, accepted: true)] + [400, 400.2, 400.5, 110.8].map { candidate($0) }
        let result = SpeakerCalibrationEstimate(measurements: measurements)
        XCTAssertEqual(result.delayMilliseconds, 111)
        XCTAssertEqual(result.quality, .provisional)
        XCTAssertEqual(result.method, "acceptedMedian")
        XCTAssertEqual(result.acceptedMeasurementCount, 2)
    }

    func testMissingSpeakerDoesNotEraseOtherSpeakersOrInventResidual() throws {
        let pass = try CalibrationPassMeasurements(pass: 0, measurementsBySpeaker: [[candidate(100, accepted: true)], []], failures: ["capture failure"])
        XCTAssertEqual(pass.speakerEstimates[0].delayMilliseconds, 100)
        XCTAssertNil(pass.speakerEstimates[1].delayMilliseconds)
        XCTAssertEqual(pass.quality, .unavailable)
        XCTAssertFalse(pass.canApplyCompensation)
        XCTAssertNil(pass.residualSpreadMilliseconds)
        XCTAssertEqual(pass.relativeArrivalsToReferenceMilliseconds, [])
        XCTAssertNoThrow(try JSONEncoder().encode(pass))
    }

    func testClusterDoesNotChainAndTiedClustersRemainPoor() {
        for values in [[100.0, 102, 104, 106, 108], [100, 100.2, 400, 400.2]] {
            XCTAssertEqual(SpeakerCalibrationEstimate(measurements: values.map { candidate($0) }).quality, .poor)
        }
    }

    func testABConsistencyBreaksTieBetweenWeakRawCandidates() {
        let result = SpeakerCalibrationEstimate(measurements: [candidate(100, abDifference: 20), candidate(400, abDifference: 0.1)])
        XCTAssertEqual(result.delayMilliseconds, 400)
        XCTAssertEqual(result.quality, .poor)
    }
}
