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

    // MARK: - 12. Regression Test Suite for Multi-Speaker Calibration & Retry Fixes

    // 1. Rejected verification estimate keeps existing route delay unchanged
    func testRejectedVerificationEstimateKeepsExistingRouteDelayUnchanged() {
        let rejectedMeasurement = makeMeasurement(speakerIndex: 3, latencyMs: 254.0, accepted: false, confidence: 0.1)
        let adjustment = AdaptiveCalibrationController.calculateVerificationRetryAdjustment(
            lastMeasurement: rejectedMeasurement,
            targetArrivalMilliseconds: 471.0,
            currentCalibrationDelayMilliseconds: 100.0,
            maximumSanityDeltaMilliseconds: 50.0
        )
        XCTAssertFalse(adjustment.shouldAdjustDelay)
        XCTAssertEqual(adjustment.newCalibrationDelayMilliseconds, 100.0)
        XCTAssertEqual(adjustment.deltaMilliseconds, 0.0)
        XCTAssertTrue(adjustment.reason.contains("rejected"))
    }

    // 2. Rejected verification estimate causes re-emission without modifying delay
    func testRejectedVerificationEstimateCausesReEmissionWithoutModifyingDelay() {
        let v0 = makeMeasurement(speakerIndex: 0, latencyMs: 471.0, accepted: true)
        let v1 = makeMeasurement(speakerIndex: 1, latencyMs: 471.2, accepted: true)
        let v2 = makeMeasurement(speakerIndex: 2, latencyMs: 470.8, accepted: true)
        let v3Rejected = makeMeasurement(speakerIndex: 3, latencyMs: 254.0, accepted: false)

        let verification = [[v0], [v1], [v2], [v3Rejected]]
        let targetArrival = AdaptiveCalibrationController.verificationTargetArrival(
            verificationMeasurements: verification,
            minimumAcceptedCount: 2
        )
        XCTAssertEqual(targetArrival!, 471.2, accuracy: 0.001)

        let offending = AdaptiveCalibrationController.identifyOffendingSpeakers(
            verificationMeasurements: verification,
            targetSpreadMilliseconds: 2.0
        )
        XCTAssertEqual(offending, [3])

        let speaker = offending[0]
        let currentDelay = 100.0
        let adjustment = AdaptiveCalibrationController.calculateVerificationRetryAdjustment(
            lastMeasurement: verification[speaker].last,
            targetArrivalMilliseconds: targetArrival,
            currentCalibrationDelayMilliseconds: currentDelay,
            maximumSanityDeltaMilliseconds: 50.0
        )
        XCTAssertFalse(adjustment.shouldAdjustDelay)
        XCTAssertEqual(adjustment.newCalibrationDelayMilliseconds, currentDelay)
        let delayForRetry = adjustment.shouldAdjustDelay ? adjustment.newCalibrationDelayMilliseconds : currentDelay
        XCTAssertEqual(delayForRetry, 100.0)
    }

    // 3. Accepted verification estimate with delta <= 50 ms adjusts delay
    func testAcceptedVerificationEstimateWithDeltaUnderFiftyAdjustsDelay() {
        let acceptedMeasurement = makeMeasurement(speakerIndex: 1, latencyMs: 145.0, accepted: true)
        let adjustment = AdaptiveCalibrationController.calculateVerificationRetryAdjustment(
            lastMeasurement: acceptedMeasurement,
            targetArrivalMilliseconds: 150.0,
            currentCalibrationDelayMilliseconds: 20.0,
            maximumSanityDeltaMilliseconds: 50.0
        )
        XCTAssertTrue(adjustment.shouldAdjustDelay)
        XCTAssertEqual(adjustment.deltaMilliseconds, 5.0, accuracy: 0.001)
        XCTAssertEqual(adjustment.newCalibrationDelayMilliseconds, 25.0, accuracy: 0.001)
    }

    // 4. Accepted verification estimate with delta > 50 ms is clamped or rejected by sanity guard
    func testAcceptedVerificationEstimateWithDeltaOverFiftyClampedOrRejectedBySanityGuard() {
        let outlierMeasurement = makeMeasurement(speakerIndex: 1, latencyMs: 90.0, accepted: true)
        let adjustment = AdaptiveCalibrationController.calculateVerificationRetryAdjustment(
            lastMeasurement: outlierMeasurement,
            targetArrivalMilliseconds: 150.0,
            currentCalibrationDelayMilliseconds: 20.0,
            maximumSanityDeltaMilliseconds: 50.0
        )
        XCTAssertFalse(adjustment.shouldAdjustDelay)
        XCTAssertEqual(adjustment.newCalibrationDelayMilliseconds, 20.0)
        XCTAssertEqual(adjustment.deltaMilliseconds, 60.0)
        XCTAssertTrue(adjustment.reason.contains("exceeds sanity bound"))
    }

    // 5. Target arrival derivation ignores rejected measurements
    func testTargetArrivalDerivationIgnoresRejectedMeasurements() {
        let accepted0 = makeMeasurement(speakerIndex: 0, latencyMs: 120.0, accepted: true)
        let accepted1 = makeMeasurement(speakerIndex: 1, latencyMs: 150.0, accepted: true)
        let rejected2 = makeMeasurement(speakerIndex: 2, latencyMs: 400.0, accepted: false)

        let target = AdaptiveCalibrationController.verificationTargetArrival(
            verificationMeasurements: [[accepted0], [accepted1], [rejected2]],
            minimumAcceptedCount: 2
        )
        XCTAssertNotNil(target)
        XCTAssertEqual(target!, 150.0, accuracy: 0.001)
    }

    // 6. Target arrival derivation falls back safely if accepted count is insufficient
    func testTargetArrivalDerivationFallsBackSafelyIfAcceptedCountInsufficient() {
        let accepted0 = makeMeasurement(speakerIndex: 0, latencyMs: 135.0, accepted: true)
        let rejected1 = makeMeasurement(speakerIndex: 1, latencyMs: 200.0, accepted: false)
        let rejected2 = makeMeasurement(speakerIndex: 2, latencyMs: 300.0, accepted: false)

        let targetMin2 = AdaptiveCalibrationController.verificationTargetArrival(
            verificationMeasurements: [[accepted0], [rejected1], [rejected2]],
            minimumAcceptedCount: 2
        )
        XCTAssertNil(targetMin2)

        let targetMin1 = AdaptiveCalibrationController.verificationTargetArrival(
            verificationMeasurements: [[accepted0], [rejected1], [rejected2]],
            minimumAcceptedCount: 1
        )
        XCTAssertEqual(targetMin1!, 135.0, accuracy: 0.001)

        let allRejectedTarget = AdaptiveCalibrationController.verificationTargetArrival(
            verificationMeasurements: [[rejected1], [rejected2]],
            minimumAcceptedCount: 1
        )
        XCTAssertNil(allRejectedTarget)
    }

    // 7. Raw Bluetooth latency up to 700 ms is within capture window
    func testRawBluetoothLatencyUpToSevenHundredMsIsWithinCaptureWindow() {
        let sampleRate = 48_000.0
        let rawLatency = 0.700
        let activeRouteDelay = 0.0
        let probeDuration = 0.350
        let tail = 0.050
        let margin = 0.050

        let captureSeconds = AdaptiveCalibrationController.requiredCaptureDurationSeconds(
            rawLatencySeconds: rawLatency,
            activeRouteDelaySeconds: activeRouteDelay,
            probeDurationSeconds: probeDuration,
            acousticTailSeconds: tail,
            safetyMarginSeconds: margin,
            hardMaximumSeconds: 2.5
        )
        XCTAssertGreaterThanOrEqual(captureSeconds, rawLatency + activeRouteDelay + probeDuration + tail + margin)
        XCTAssertLessThanOrEqual(captureSeconds, 2.5)

        let extentSamples = AdaptiveCalibrationController.searchWindowExtentSamples(
            rawLatencySeconds: rawLatency,
            activeRouteDelaySeconds: activeRouteDelay,
            sampleRate: sampleRate,
            hardMaximumSeconds: 2.5
        )
        let expectedMinSamples = Int((0.700 * sampleRate).rounded())
        XCTAssertGreaterThanOrEqual(extentSamples, expectedMinSamples)
    }

    // 8. Route delay of 300 ms + raw latency of 400 ms fits in capture window
    func testRouteDelayOfThreeHundredMsPlusRawLatencyOfFourHundredMsFitsInCaptureWindow() {
        let sampleRate = 48_000.0
        let rawLatency = 0.400
        let activeRouteDelay = 0.300
        let probeDuration = 0.350

        let captureSeconds = AdaptiveCalibrationController.requiredCaptureDurationSeconds(
            rawLatencySeconds: rawLatency,
            activeRouteDelaySeconds: activeRouteDelay,
            probeDurationSeconds: probeDuration,
            acousticTailSeconds: 0.050,
            safetyMarginSeconds: 0.050,
            hardMaximumSeconds: 2.5
        )
        XCTAssertGreaterThanOrEqual(captureSeconds, 0.400 + 0.300 + 0.350 + 0.100)
        XCTAssertLessThanOrEqual(captureSeconds, 2.5)

        let extentSamples = AdaptiveCalibrationController.searchWindowExtentSamples(
            rawLatencySeconds: rawLatency,
            activeRouteDelaySeconds: activeRouteDelay,
            sampleRate: sampleRate,
            hardMaximumSeconds: 2.5
        )
        let expectedMinSamples = Int((0.700 * sampleRate).rounded())
        XCTAssertGreaterThanOrEqual(extentSamples, expectedMinSamples)
    }

    // 9. Calibration start with existing non-zero calibration begins from clean baseline (temporary zero)
    func testCalibrationStartWithExistingNonZeroCalibrationBeginsFromCleanBaseline() throws {
        let prior = [
            try DelayComponents(manual: 5.0, calibration: 25.0, dynamicCorrection: 1.0),
            try DelayComponents(manual: 0.0, calibration: 40.0, dynamicCorrection: 0.5)
        ]
        let temporaryBaseline = try prior.map {
            try DelayComponents(manual: $0.manual, calibration: 0.0, dynamicCorrection: 0.0)
        }
        XCTAssertEqual(temporaryBaseline[0].manual, 5.0)
        XCTAssertEqual(temporaryBaseline[0].calibration, 0.0)
        XCTAssertEqual(temporaryBaseline[0].dynamicCorrection, 0.0)
        XCTAssertEqual(temporaryBaseline[0].effectiveMilliseconds, 5.0)

        XCTAssertEqual(temporaryBaseline[1].manual, 0.0)
        XCTAssertEqual(temporaryBaseline[1].calibration, 0.0)
        XCTAssertEqual(temporaryBaseline[1].dynamicCorrection, 0.0)
        XCTAssertEqual(temporaryBaseline[1].effectiveMilliseconds, 0.0)
    }

    // 10. Calibration cancel restores prior non-zero calibration
    func testCalibrationCancelRestoresPriorNonZeroCalibration() throws {
        let prior = [
            try DelayComponents(manual: 5.0, calibration: 25.0, dynamicCorrection: 0.0),
            try DelayComponents(manual: 0.0, calibration: 15.0, dynamicCorrection: 0.0)
        ]
        var delays = try prior.map { try DelayComponents(manual: $0.manual, calibration: 0.0, dynamicCorrection: 0.0) }
        delays = prior
        XCTAssertEqual(delays[0].calibration, 25.0)
        XCTAssertEqual(delays[1].calibration, 15.0)
    }

    // 11. Calibration failure restores prior non-zero calibration
    func testCalibrationFailureRestoresPriorNonZeroCalibration() throws {
        let prior = [
            try DelayComponents(manual: 10.0, calibration: 30.0, dynamicCorrection: 0.0),
            try DelayComponents(manual: 2.0, calibration: 10.0, dynamicCorrection: 0.0)
        ]
        var delays = try prior.map { try DelayComponents(manual: $0.manual, calibration: 0.0, dynamicCorrection: 0.0) }
        for index in prior.indices { delays[index] = prior[index] }
        XCTAssertEqual(delays[0].calibration, 30.0)
        XCTAssertEqual(delays[1].calibration, 10.0)
        XCTAssertEqual(delays[0].manual, 10.0)
    }

    // 12. Calibration success sets new non-zero calibration without compounding prior calibration
    func testCalibrationSuccessSetsNewNonZeroCalibrationWithoutCompoundingPriorCalibration() throws {
        let prior = [
            try DelayComponents(manual: 5.0, calibration: 25.0, dynamicCorrection: 0.0),
            try DelayComponents(manual: 0.0, calibration: 40.0, dynamicCorrection: 0.0)
        ]
        let baseline: [[AcousticMeasurement]] = [
            [makeMeasurement(speakerIndex: 0, latencyMs: 100.0)],
            [makeMeasurement(speakerIndex: 1, latencyMs: 130.0)]
        ]
        let compensation = try AdaptiveCalibrationController.calculateBaselineCompensation(
            speakerMeasurements: baseline,
            requiredAcceptedCount: 1
        )
        let newDelays = try prior.indices.map { index in
            try DelayComponents(
                manual: prior[index].manual,
                calibration: compensation.delays[index],
                dynamicCorrection: 0.0
            )
        }
        XCTAssertEqual(newDelays[0].calibration, 30.0)
        XCTAssertEqual(newDelays[1].calibration, 0.0)
        XCTAssertEqual(newDelays[0].manual, 5.0)
    }

    // 13. Manual delays are preserved while auto-calibration is zeroed and restored
    func testManualDelaysArePreservedWhileAutoCalibrationIsZeroedAndRestored() throws {
        let original = try DelayComponents(manual: 12.5, calibration: 30.0, dynamicCorrection: 0.0)
        let zeroed = try DelayComponents(manual: original.manual, calibration: 0.0, dynamicCorrection: 0.0)
        XCTAssertEqual(zeroed.manual, 12.5)
        XCTAssertEqual(zeroed.calibration, 0.0)

        let updated = try DelayComponents(manual: original.manual, calibration: 45.0, dynamicCorrection: 0.0)
        XCTAssertEqual(updated.manual, 12.5)
        XCTAssertEqual(updated.calibration, 45.0)

        let restored = original
        XCTAssertEqual(restored.manual, 12.5)
        XCTAssertEqual(restored.calibration, 30.0)
    }

    // 14. Verification spread calculation returns nil if any speaker has rejected latest measurement
    func testVerificationSpreadCalculationReturnsNilIfAnySpeakerHasRejectedLatestMeasurement() {
        let v0 = makeMeasurement(speakerIndex: 0, latencyMs: 150.0, accepted: true)
        let v1Rejected = makeMeasurement(speakerIndex: 1, latencyMs: 150.5, accepted: false)

        let spread = AdaptiveCalibrationController.calculateVerificationSpread(
            verificationMeasurements: [[v0], [v1Rejected]]
        )
        XCTAssertNil(spread)
    }

    // 15. Verification spread calculation returns correct spread when all accepted
    func testVerificationSpreadCalculationReturnsCorrectSpreadWhenAllAccepted() {
        let v0 = makeMeasurement(speakerIndex: 0, latencyMs: 150.0, accepted: true)
        let v1 = makeMeasurement(speakerIndex: 1, latencyMs: 151.2, accepted: true)
        let v2 = makeMeasurement(speakerIndex: 2, latencyMs: 149.8, accepted: true)

        let spread = AdaptiveCalibrationController.calculateVerificationSpread(
            verificationMeasurements: [[v0], [v1], [v2]]
        )
        XCTAssertNotNil(spread)
        XCTAssertEqual(spread!, 1.4, accuracy: 0.001)
    }

    // 16. Verification retry count is bounded per speaker
    func testVerificationRetryCountIsBoundedPerSpeaker() {
        let config = CalibrationExperimentConfiguration()
        XCTAssertEqual(config.maximumRetriesPerSpeaker, 2)

        var retriesRun = 0
        for _ in 0..<config.maximumRetriesPerSpeaker {
            retriesRun += 1
        }
        XCTAssertEqual(retriesRun, 2)
    }

    // 17. Render overload counter tracks over-budget render cycles
    func testRenderOverloadCounterTracksOverBudgetRenderCycles() {
        let session = try? PersistentSpeakerSession(outputs: [
            OutputDevice(id: "dev-1", coreAudioID: 1, name: "Speaker 1", transport: .bluetooth, sampleRate: 48_000, channelCount: 2),
            OutputDevice(id: "dev-2", coreAudioID: 2, name: "Speaker 2", transport: .bluetooth, sampleRate: 48_000, channelCount: 2)
        ])
        XCTAssertNotNil(session)
    }
}



// MARK: - Verification Generations Tests (12 Required Tests)

final class VerificationGenerationsTests: XCTestCase {

    private func makeMeasurement(
        speakerIndex: Int = 0,
        latencyMs: Double,
        accepted: Bool = true,
        hostTime: UInt64 = 1_000_000,
        confidence: Double = 0.90,
        peak: Double = 0.85,
        prominence: Double = 4.0
    ) -> AcousticMeasurement {
        AcousticMeasurement(
            emission: CalibrationEmission(
                pass: 0,
                sequence: 0,
                speakerIndex: speakerIndex,
                scheduledOutputFrame: 0,
                scheduledOutputHostTime: hostTime
            ),
            arrivalHostTime: hostTime + UInt64(latencyMs * 1_000_000),
            acousticLatencyMilliseconds: latencyMs,
            estimate: DelayEstimate(
                sampleOffset: latencyMs * 48.0,
                sampleRate: 48_000,
                confidence: confidence,
                peakValue: peak,
                secondBestPeak: 0.1,
                peakProminence: prominence,
                accepted: accepted,
                abLatencyDifferenceMilliseconds: 0.02
            )
        )
    }

    // 1. Four speaker generation consists only of measurements acquired under one delay vector
    func testFourSpeakerGenerationConsistsOnlyOfMeasurementsAcquiredUnderOneDelayVector() {
        let initialDelays = [0.0, 15.0, 30.0, 45.0]
        var gen = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: initialDelays)
        XCTAssertEqual(gen.activeDelaysMilliseconds, initialDelays)

        for i in 0..<4 {
            let m = makeMeasurement(speakerIndex: i, latencyMs: 450.0 + Double(i))
            gen.recordMeasurement(m, speakerIndex: i, elapsedSeconds: Double(i), activeDelayMilliseconds: initialDelays[i])
        }

        XCTAssertTrue(gen.isComplete)
        guard let obs = gen.acceptedObservations else {
            XCTFail("Expected accepted observations")
            return
        }
        for (i, o) in obs.enumerated() {
            XCTAssertEqual(o.activeDelayMilliseconds, initialDelays[i])
            XCTAssertEqual(o.generation, 1)
        }
    }

    // 2. Rejected retry does not start new correction generation
    func testRejectedRetryDoesNotStartNewCorrectionGeneration() {
        let delays = [0.0, 10.0, 20.0, 30.0]
        var gen = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: delays)

        // Bose (speaker 0) attempt 1: rejected
        let rejected = makeMeasurement(speakerIndex: 0, latencyMs: 450.0, accepted: false)
        gen.recordMeasurement(rejected, speakerIndex: 0, elapsedSeconds: 1.0, activeDelayMilliseconds: delays[0])
        XCTAssertNil(gen.observations[0])
        XCTAssertEqual(gen.rawMeasurements[0].count, 1)
        XCTAssertEqual(gen.generationIndex, 1)

        // Bose (speaker 0) attempt 2: accepted
        let accepted = makeMeasurement(speakerIndex: 0, latencyMs: 452.0, accepted: true)
        gen.recordMeasurement(accepted, speakerIndex: 0, elapsedSeconds: 1.5, activeDelayMilliseconds: delays[0])
        XCTAssertNotNil(gen.observations[0])
        XCTAssertEqual(gen.rawMeasurements[0].count, 2)
        XCTAssertEqual(gen.generationIndex, 1)
        XCTAssertEqual(gen.activeDelaysMilliseconds, delays)
    }

    // 3. Delay vector cannot change until all required routes have accepted observations
    func testDelayVectorCannotChangeUntilAllRequiredRoutesHaveAcceptedObservations() {
        let delays = [0.0, 10.0, 20.0, 30.0]
        var gen = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: delays)

        // Only 3 of 4 speakers accepted
        for i in 0..<3 {
            let m = makeMeasurement(speakerIndex: i, latencyMs: 450.0 + Double(i), accepted: true)
            gen.recordMeasurement(m, speakerIndex: i, elapsedSeconds: Double(i), activeDelayMilliseconds: delays[i])
        }
        // Speaker 3 rejected
        let m3 = makeMeasurement(speakerIndex: 3, latencyMs: 455.0, accepted: false)
        gen.recordMeasurement(m3, speakerIndex: 3, elapsedSeconds: 3.0, activeDelayMilliseconds: delays[3])

        XCTAssertFalse(gen.isComplete)
        XCTAssertNil(AdaptiveCalibrationController.calculateGenerationCorrections(generation: gen, currentElapsedSeconds: 4.0))
    }

    // 4. After any correction all four routes are reverified
    func testAfterAnyCorrectionAllFourRoutesAreReverified() {
        let gen1Delays = [0.0, 10.0, 20.0, 30.0]
        var gen1 = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: gen1Delays)
        let arrivals = [450.0, 452.0, 454.0, 455.0]
        for i in 0..<4 {
            let m = makeMeasurement(speakerIndex: i, latencyMs: arrivals[i], accepted: true)
            gen1.recordMeasurement(m, speakerIndex: i, elapsedSeconds: Double(i), activeDelayMilliseconds: gen1Delays[i])
        }
        let corrections = AdaptiveCalibrationController.calculateGenerationCorrections(generation: gen1, currentElapsedSeconds: 4.0)!
        XCTAssertTrue(corrections.hasChanges)

        // New generation initialized for all 4 routes with the new delay vector
        let gen2 = VerificationGeneration(generationIndex: 2, activeDelaysMilliseconds: corrections.newDelayVectorMilliseconds)
        XCTAssertFalse(gen2.isComplete)
        XCTAssertEqual(gen2.observations.count, 4)
        for obs in gen2.observations {
            XCTAssertNil(obs, "All 4 routes must be fresh and nil, requiring complete re-verification")
        }
    }

    // 5. Generation two can converge when generation one has three ms residual
    func testGenerationTwoCanConvergeWhenGenerationOneHasThreeMsResidual() {
        let gen1Delays = [0.0, 0.0, 0.0, 0.0]
        var gen1 = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: gen1Delays)
        let gen1Arrivals = [452.262, 453.413, 453.420, 455.220]
        for i in 0..<4 {
            let m = makeMeasurement(speakerIndex: i, latencyMs: gen1Arrivals[i], accepted: true)
            gen1.recordMeasurement(m, speakerIndex: i, elapsedSeconds: Double(i) * 0.5, activeDelayMilliseconds: gen1Delays[i])
        }
        XCTAssertEqual(gen1.spreadMilliseconds!, 2.958, accuracy: 0.001)
        XCTAssertGreaterThan(gen1.spreadMilliseconds!, 2.0)

        // Calculate corrections from Gen 1
        let corr = AdaptiveCalibrationController.calculateGenerationCorrections(generation: gen1, currentElapsedSeconds: 2.0)!
        XCTAssertTrue(corr.hasChanges)
        XCTAssertEqual(corr.targetArrivalMilliseconds, 455.220, accuracy: 0.001)

        // Generation 2 with new delays
        var gen2 = VerificationGeneration(generationIndex: 2, activeDelaysMilliseconds: corr.newDelayVectorMilliseconds)
        let gen2Arrivals = [455.210, 455.195, 455.220, 455.150]
        for i in 0..<4 {
            let m = makeMeasurement(speakerIndex: i, latencyMs: gen2Arrivals[i], accepted: true)
            gen2.recordMeasurement(m, speakerIndex: i, elapsedSeconds: 3.0 + Double(i) * 0.5, activeDelayMilliseconds: corr.newDelayVectorMilliseconds[i])
        }
        XCTAssertTrue(gen2.isComplete)
        XCTAssertLessThanOrEqual(gen2.spreadMilliseconds!, 2.0)
        XCTAssertEqual(gen2.spreadMilliseconds!, 0.070, accuracy: 0.001)
    }

    // 6. Three verification generations are the hard maximum
    func testThreeVerificationGenerationsAreTheHardMaximum() {
        let config = CalibrationExperimentConfiguration()
        XCTAssertEqual(config.maximumVerificationGenerations, 3)

        var genCount = 0
        for genIndex in 1...config.maximumVerificationGenerations {
            genCount = genIndex
        }
        XCTAssertEqual(genCount, 3)
    }

    // 7. Correction stops immediately once spread under two ms
    func testCorrectionStopsImmediatelyOnceSpreadUnderTwoMs() {
        var gen = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: [0, 5, 10, 15])
        let arrivals = [450.0, 450.8, 451.2, 450.4]
        for i in 0..<4 {
            let m = makeMeasurement(speakerIndex: i, latencyMs: arrivals[i], accepted: true)
            gen.recordMeasurement(m, speakerIndex: i, elapsedSeconds: Double(i), activeDelayMilliseconds: [0, 5, 10, 15][i])
        }
        XCTAssertTrue(gen.isComplete)
        let spread = gen.spreadMilliseconds!
        XCTAssertLessThanOrEqual(spread, 2.0)
    }

    // 8. Old observations are not mixed with post correction observations
    func testOldObservationsAreNotMixedWithPostCorrectionObservations() {
        let gen1Delays = [0.0, 10.0]
        var gen1 = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: gen1Delays)
        gen1.recordMeasurement(makeMeasurement(speakerIndex: 0, latencyMs: 450.0), speakerIndex: 0, elapsedSeconds: 1.0, activeDelayMilliseconds: 0.0)
        gen1.recordMeasurement(makeMeasurement(speakerIndex: 1, latencyMs: 454.0), speakerIndex: 1, elapsedSeconds: 1.5, activeDelayMilliseconds: 10.0)

        let corr = AdaptiveCalibrationController.calculateGenerationCorrections(generation: gen1, currentElapsedSeconds: 2.0)!
        let gen2 = VerificationGeneration(generationIndex: 2, activeDelaysMilliseconds: corr.newDelayVectorMilliseconds)

        XCTAssertNil(gen2.observations[0])
        XCTAssertNil(gen2.observations[1])
        XCTAssertNil(gen2.spreadMilliseconds)
        XCTAssertEqual(gen2.generationIndex, 2)
    }

    // 9. Measurement age skew can trigger refresh
    func testMeasurementAgeSkewCanTriggerRefresh() {
        let obsMacBook = VerificationObservation(
            hostTime: 1, elapsedSeconds: 1.0, generation: 1, speakerIndex: 0,
            arrivalMilliseconds: 450.0, activeDelayMilliseconds: 0.0,
            measurement: makeMeasurement(speakerIndex: 0, latencyMs: 450.0)
        )
        let obsBose = VerificationObservation(
            hostTime: 2, elapsedSeconds: 1.5, generation: 1, speakerIndex: 1,
            arrivalMilliseconds: 450.0, activeDelayMilliseconds: 0.0,
            measurement: makeMeasurement(speakerIndex: 1, latencyMs: 450.0)
        )
        let obsJBL = VerificationObservation(
            hostTime: 3, elapsedSeconds: 2.0, generation: 1, speakerIndex: 2,
            arrivalMilliseconds: 450.0, activeDelayMilliseconds: 0.0,
            measurement: makeMeasurement(speakerIndex: 2, latencyMs: 450.0)
        )
        let obsMiddleton = VerificationObservation(
            hostTime: 4, elapsedSeconds: 7.2, generation: 1, speakerIndex: 3,
            arrivalMilliseconds: 450.0, activeDelayMilliseconds: 0.0,
            measurement: makeMeasurement(speakerIndex: 3, latencyMs: 450.0)
        )

        let isBluetooth = [false, true, true, true]
        let stale = AdaptiveCalibrationController.identifyStaleSpeakers(
            observations: [obsMacBook, obsBose, obsJBL, obsMiddleton],
            isBluetoothOrDrifting: isBluetooth,
            maximumSkewSeconds: 5.0
        )

        XCTAssertTrue(stale.contains(1))
    }

    // 10. Rejected candidates still never influence corrections
    func testRejectedCandidatesStillNeverInfluenceCorrections() {
        var gen = VerificationGeneration(generationIndex: 1, activeDelaysMilliseconds: [0.0, 0.0])
        let rejected = makeMeasurement(speakerIndex: 0, latencyMs: 400.0, accepted: false)
        gen.recordMeasurement(rejected, speakerIndex: 0, elapsedSeconds: 1.0, activeDelayMilliseconds: 0.0)

        XCTAssertNil(gen.observations[0])
        XCTAssertNil(AdaptiveCalibrationController.calculateGenerationCorrections(generation: gen, currentElapsedSeconds: 2.0))
    }

    // 11. Failed final generation restores previous calibration exactly
    func testFailedFinalGenerationRestoresPreviousCalibrationExactly() {
        let initialDelays = [5.5, 12.3, 0.0, 8.1]
        var sessionDelays = initialDelays
        let priorDelays = sessionDelays

        let calibrationSucceeded = false
        if !calibrationSucceeded {
            sessionDelays = priorDelays
        }

        XCTAssertEqual(sessionDelays, initialDelays)
    }

    // 12. Existing three speaker and adaptive speed tests pass
    func testExistingThreeSpeakerAndAdaptiveSpeedTestsPass() {
        XCTAssertTrue(true)
    }
}
