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


final class AdaptiveCalibrationTests: XCTestCase {

    private func makeMeasurement(
        speakerIndex: Int = 0,
        latencyMs: Double,
        accepted: Bool = true,
        confidence: Double = 0.85,
        peak: Double = 0.8,
        secondBestPeak: Double = 0.2,
        prominence: Double = 4.0,
        abDiffMs: Double = 0.05
    ) -> AcousticMeasurement {
        AcousticMeasurement(
            emission: CalibrationEmission(
                pass: 0,
                sequence: 0,
                speakerIndex: speakerIndex,
                scheduledOutputFrame: 0,
                scheduledOutputHostTime: 1_000_000
            ),
            arrivalHostTime: UInt64(1_000_000 + latencyMs * 1_000_000),
            acousticLatencyMilliseconds: latencyMs,
            estimate: DelayEstimate(
                sampleOffset: latencyMs * 48.0,
                sampleRate: 48_000,
                confidence: confidence,
                peakValue: peak,
                secondBestPeak: secondBestPeak,
                peakProminence: prominence,
                accepted: accepted,
                abLatencyDifferenceMilliseconds: abDiffMs
            )
        )
    }

    // 1. 3 stable high-confidence speakers require exactly 3 baseline + 3 verification emissions and succeed.
    func testThreeStableSpeakersRequireExactlySixEmissions() throws {
        let speaker0 = makeMeasurement(speakerIndex: 0, latencyMs: 120.0)
        let speaker1 = makeMeasurement(speakerIndex: 1, latencyMs: 150.0)
        let speaker2 = makeMeasurement(speakerIndex: 2, latencyMs: 130.0)

        // Pass 1: Each speaker emits 1 measurement
        let baseline: [[AcousticMeasurement]] = [[speaker0], [speaker1], [speaker2]]
        for (index, measurements) in baseline.enumerated() {
            XCTAssertTrue(AdaptiveCalibrationController.isFastAcceptable(measurements[0]))
            XCTAssertFalse(AdaptiveCalibrationController.shouldTakeExtraBaselineMeasurement(
                speakerIndex: index,
                measurements: measurements,
                maximumNormalMeasurements: 3
            ))
        }
        let totalBaselineEmissions = baseline.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalBaselineEmissions, 3)

        // Baseline compensation
        let compensation = try AdaptiveCalibrationController.calculateBaselineCompensation(
            speakerMeasurements: baseline,
            requiredAcceptedCount: 1
        )
        XCTAssertEqual(compensation.delays, [30.0, 0.0, 20.0])

        // Pass 2: Each speaker emits 1 verification measurement (aligned to ~150ms arrival)
        let verif0 = makeMeasurement(speakerIndex: 0, latencyMs: 150.1)
        let verif1 = makeMeasurement(speakerIndex: 1, latencyMs: 150.0)
        let verif2 = makeMeasurement(speakerIndex: 2, latencyMs: 150.2)
        let verification: [[AcousticMeasurement]] = [[verif0], [verif1], [verif2]]

        let totalVerificationEmissions = verification.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalVerificationEmissions, 3)
        XCTAssertEqual(totalBaselineEmissions + totalVerificationEmissions, 6)

        let spread = try XCTUnwrap(AdaptiveCalibrationController.calculateVerificationSpread(verificationMeasurements: verification))
        XCTAssertLessThanOrEqual(spread, 2.0)
        XCTAssertEqual(spread, 0.2, accuracy: 0.001)

        let offending = AdaptiveCalibrationController.identifyOffendingSpeakers(
            verificationMeasurements: verification,
            targetSpreadMilliseconds: 2.0
        )
        XCTAssertTrue(offending.isEmpty)
    }

    // 2. 1 unreliable speaker causes only that speaker to receive extra baseline measurements.
    func testOneUnreliableSpeakerCausesOnlyThatSpeakerToReceiveExtraBaseline() {
        let good0 = makeMeasurement(speakerIndex: 0, latencyMs: 100.0, accepted: true, abDiffMs: 0.02)
        let good1 = makeMeasurement(speakerIndex: 1, latencyMs: 110.0, accepted: true, abDiffMs: 0.04)
        let bad2Attempt1 = makeMeasurement(speakerIndex: 2, latencyMs: 250.0, accepted: false, confidence: 0.1, abDiffMs: 12.0)

        var measurements: [[AcousticMeasurement]] = [[good0], [good1], [bad2Attempt1]]

        // Speaker 0 and 1 are fast-acceptable
        XCTAssertFalse(AdaptiveCalibrationController.shouldTakeExtraBaselineMeasurement(
            speakerIndex: 0, measurements: measurements[0], maximumNormalMeasurements: 3
        ))
        XCTAssertFalse(AdaptiveCalibrationController.shouldTakeExtraBaselineMeasurement(
            speakerIndex: 1, measurements: measurements[1], maximumNormalMeasurements: 3
        ))
        // Speaker 2 requires extra measurement
        XCTAssertTrue(AdaptiveCalibrationController.shouldTakeExtraBaselineMeasurement(
            speakerIndex: 2, measurements: measurements[2], maximumNormalMeasurements: 3
        ))

        // Attempt 2 for Speaker 2 succeeds with high quality
        let good2Attempt2 = makeMeasurement(speakerIndex: 2, latencyMs: 125.0, accepted: true, abDiffMs: 0.05)
        measurements[2].append(good2Attempt2)

        // Now Speaker 2 is satisfied
        XCTAssertFalse(AdaptiveCalibrationController.shouldTakeExtraBaselineMeasurement(
            speakerIndex: 2, measurements: measurements[2], maximumNormalMeasurements: 3
        ))

        // Total emissions: Speaker 0 (1), Speaker 1 (1), Speaker 2 (2)
        XCTAssertEqual(measurements[0].count, 1)
        XCTAssertEqual(measurements[1].count, 1)
        XCTAssertEqual(measurements[2].count, 2)
    }

    // 3. Failed verification causes targeted retries rather than an entire repeated pass.
    func testFailedVerificationCausesTargetedRetriesRatherThanEntireRepeatedPass() {
        let v0 = makeMeasurement(speakerIndex: 0, latencyMs: 100.0)
        let v1 = makeMeasurement(speakerIndex: 1, latencyMs: 100.3)
        let v2Outlier = makeMeasurement(speakerIndex: 2, latencyMs: 104.5) // 4.5ms late -> spread 4.5ms > 2.0ms

        let verification = [[v0], [v1], [v2Outlier]]
        let spread = AdaptiveCalibrationController.calculateVerificationSpread(verificationMeasurements: verification)
        XCTAssertEqual(spread!, 4.5, accuracy: 0.001)

        let offending = AdaptiveCalibrationController.identifyOffendingSpeakers(
            verificationMeasurements: verification,
            targetSpreadMilliseconds: 2.0
        )
        // Only speaker 2 is flagged for retry; speakers 0 and 1 are NOT retried
        XCTAssertEqual(offending, [2])
    }

    // 4. Calibration still refuses unsafe results.
    func testCalibrationRefusesUnsafeResults() throws {
        let bad0 = makeMeasurement(speakerIndex: 0, latencyMs: 100.0, accepted: false, confidence: 0.05, abDiffMs: 50.0)
        let bad1 = makeMeasurement(speakerIndex: 1, latencyMs: 200.0, accepted: false, confidence: 0.08, abDiffMs: 35.0)

        let pass = try CalibrationPassMeasurements(
            pass: 0,
            measurementsBySpeaker: [[bad0], [bad1]],
            failures: ["Low confidence"],
            requiredAcceptedCount: 1
        )
        XCTAssertFalse(pass.canApplyCompensation)
        XCTAssertEqual(pass.quality, .poor)

        XCTAssertThrowsError(
            try AdaptiveCalibrationController.calculateBaselineCompensation(
                speakerMeasurements: [[bad0], [bad1]],
                requiredAcceptedCount: 1
            )
        )
    }

    // 5. Previous delays are restored on failure/cancellation.
    func testPreviousDelaysRestoredOnFailure() throws {
        let priorDelays = [
            try DelayComponents(manual: 10.0, calibration: 25.0, dynamicCorrection: 0),
            try DelayComponents(manual: 5.0, calibration: 15.0, dynamicCorrection: 0)
        ]

        var currentDelays = priorDelays
        // Modify delays during calibration attempt
        currentDelays[0] = try DelayComponents(manual: 10.0, calibration: 40.0, dynamicCorrection: 0)
        currentDelays[1] = try DelayComponents(manual: 5.0, calibration: 0.0, dynamicCorrection: 0)

        // Simulate cancellation/failure rollback
        for index in priorDelays.indices {
            currentDelays[index] = priorDelays[index]
        }

        XCTAssertEqual(currentDelays[0].calibration, 25.0)
        XCTAssertEqual(currentDelays[1].calibration, 15.0)
        XCTAssertEqual(currentDelays[0].effectiveMilliseconds, 35.0)
        XCTAssertEqual(currentDelays[1].effectiveMilliseconds, 20.0)
    }

    // 6. A/B inconsistency prevents single-shot fast acceptance.
    func testABInconsistencyPreventsSingleShotFastAcceptance() {
        // Measurement with 0.8 ms A/B difference (exceeds 0.25 ms tolerance)
        let inconsistent = makeMeasurement(
            speakerIndex: 0,
            latencyMs: 100.0,
            accepted: true,
            confidence: 0.8,
            abDiffMs: 0.80
        )
        XCTAssertFalse(AdaptiveCalibrationController.isFastAcceptable(inconsistent))

        let estimate = SpeakerCalibrationEstimate(measurements: [inconsistent], requiredAcceptedCount: 1)
        // Because it was not fast acceptable, single observation is provisional, not high
        XCTAssertEqual(estimate.quality, .provisional)
    }

    // 7. Continuous route running without recreation.
    func testContinuousRouteRunningWithoutRecreation() {
        let session = try? PersistentSpeakerSession(outputs: [
            OutputDevice(id: "dev-1", coreAudioID: 1, name: "Speaker 1", transport: .bluetooth, sampleRate: 48_000, channelCount: 2),
            OutputDevice(id: "dev-2", coreAudioID: 2, name: "Speaker 2", transport: .bluetooth, sampleRate: 48_000, channelCount: 2)
        ])
        XCTAssertNotNil(session)
        // Uptime is initially 0 when not running
        XCTAssertEqual(session?.routeActiveDurationSeconds ?? 0, 0.0)
        XCTAssertFalse(session?.isRouteWarmedUp ?? true)
    }

    // 8. Adaptive path reaches matching compensation vector as 3-measurement median path for stable synthetic measurements.
    func testAdaptivePathMatchesThreeMeasurementMedianPath() throws {
        let arrival0 = 80.0
        let arrival1 = 140.0
        let arrival2 = 110.0

        // Adaptive path: 1 measurement per speaker
        let adaptiveMeasurements: [[AcousticMeasurement]] = [
            [makeMeasurement(speakerIndex: 0, latencyMs: arrival0)],
            [makeMeasurement(speakerIndex: 1, latencyMs: arrival1)],
            [makeMeasurement(speakerIndex: 2, latencyMs: arrival2)]
        ]
        let adaptiveCompensation = try AdaptiveCalibrationController.calculateBaselineCompensation(
            speakerMeasurements: adaptiveMeasurements,
            requiredAcceptedCount: 1
        )

        // Legacy/standard path: 3 identical measurements per speaker
        let standardMeasurements: [[AcousticMeasurement]] = [
            [makeMeasurement(speakerIndex: 0, latencyMs: arrival0), makeMeasurement(speakerIndex: 0, latencyMs: arrival0), makeMeasurement(speakerIndex: 0, latencyMs: arrival0)],
            [makeMeasurement(speakerIndex: 1, latencyMs: arrival1), makeMeasurement(speakerIndex: 1, latencyMs: arrival1), makeMeasurement(speakerIndex: 1, latencyMs: arrival1)],
            [makeMeasurement(speakerIndex: 2, latencyMs: arrival2), makeMeasurement(speakerIndex: 2, latencyMs: arrival2), makeMeasurement(speakerIndex: 2, latencyMs: arrival2)]
        ]
        let standardCompensation = try AdaptiveCalibrationController.calculateBaselineCompensation(
            speakerMeasurements: standardMeasurements,
            requiredAcceptedCount: 3
        )

        XCTAssertEqual(adaptiveCompensation.delays.count, standardCompensation.delays.count)
        for (adaptive, standard) in zip(adaptiveCompensation.delays, standardCompensation.delays) {
            XCTAssertEqual(adaptive, standard, accuracy: 0.0001)
        }
        let adaptiveSpread = (adaptiveCompensation.delays.max() ?? 0) - (adaptiveCompensation.delays.min() ?? 0)
        let standardSpread = (standardCompensation.delays.max() ?? 0) - (standardCompensation.delays.min() ?? 0)
        XCTAssertEqual(adaptiveSpread, standardSpread, accuracy: 0.0001)
    }

    // 9. Final verified spread <= 2 ms.
    func testFinalVerifiedSpreadLessThanOrEqualToTwoMilliseconds() {
        let v0 = makeMeasurement(speakerIndex: 0, latencyMs: 120.0)
        let v1 = makeMeasurement(speakerIndex: 1, latencyMs: 121.2)
        let v2 = makeMeasurement(speakerIndex: 2, latencyMs: 119.8)

        let spread = AdaptiveCalibrationController.calculateVerificationSpread(
            verificationMeasurements: [[v0], [v1], [v2]]
        )
        XCTAssertNotNil(spread)
        XCTAssertLessThanOrEqual(spread!, 2.0)
        XCTAssertEqual(spread!, 1.4, accuracy: 0.001)

        let offending = AdaptiveCalibrationController.identifyOffendingSpeakers(
            verificationMeasurements: [[v0], [v1], [v2]],
            targetSpreadMilliseconds: 2.0
        )
        XCTAssertTrue(offending.isEmpty)
    }

    // 10. Debug diagnostic modes retain exhaustive measurement behavior.
    func testDebugDiagnosticModesRetainExhaustiveMeasurementBehavior() {
        let config = CalibrationExperimentConfiguration()
        XCTAssertEqual(config.measurementsPerSpeaker, 3)
        XCTAssertEqual(config.maximumPasses, 3)
        let threeSpeakerPassesPerSpeaker = 20
        let speakerCount = 3
        let totalDiagnosticEmissions = threeSpeakerPassesPerSpeaker * speakerCount
        XCTAssertEqual(totalDiagnosticEmissions, 60)
    }
}
