import Foundation
import CoreAudio

public struct RobustMeasurementSummary: Sendable, Equatable, Codable {
    public let medianMilliseconds: Double
    public let spreadMilliseconds: Double
    public let medianAbsoluteDeviationMilliseconds: Double

    public init(values: [Double]) throws {
        guard !values.isEmpty else { throw CalibrationMathError.noMeasurements }
        let median = Self.median(values)
        medianMilliseconds = median
        spreadMilliseconds = values.max()! - values.min()!
        medianAbsoluteDeviationMilliseconds = Self.median(values.map { abs($0 - median) })
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) * 0.5 : sorted[middle]
    }
}

public enum CalibrationMathError: LocalizedError, Equatable {
    case noMeasurements
    case compensationExceedsMaximum(Double)

    public var errorDescription: String? {
        switch self {
        case .noMeasurements: "No valid calibration measurements were available."
        case .compensationExceedsMaximum(let value): "Required calibration delay \(String(format: "%.2f", value)) ms exceeds the 1000 ms limit."
        }
    }
}

public struct DelayCompensation: Sendable, Equatable, Codable {
    public let delays: [Double]

    public var calibrationDelayA: Double { delays.indices.contains(0) ? delays[0] : 0 }
    public var calibrationDelayB: Double { delays.indices.contains(1) ? delays[1] : 0 }

    public init(calibrationDelayA: Double, calibrationDelayB: Double) {
        delays = [calibrationDelayA, calibrationDelayB]
    }

    public init(delays: [Double]) {
        self.delays = delays
    }

    public static func calculate(relativeArrivalBMinusA: Double, maximumDelay: Double = FractionalDelayLine.maximumDelayMilliseconds) throws -> DelayCompensation {
        let result: DelayCompensation
        if relativeArrivalBMinusA >= 0 {
            result = DelayCompensation(calibrationDelayA: relativeArrivalBMinusA, calibrationDelayB: 0)
        } else {
            result = DelayCompensation(calibrationDelayA: 0, calibrationDelayB: -relativeArrivalBMinusA)
        }
        let required = max(result.calibrationDelayA, result.calibrationDelayB)
        guard required <= maximumDelay else { throw CalibrationMathError.compensationExceedsMaximum(required) }
        return result
    }

    public static func calculate(arrivalMilliseconds: [Double], maximumDelay: Double = FractionalDelayLine.maximumDelayMilliseconds) throws -> DelayCompensation {
        guard !arrivalMilliseconds.isEmpty, arrivalMilliseconds.allSatisfy(\.isFinite) else {
            throw CalibrationMathError.noMeasurements
        }
        guard let latest = arrivalMilliseconds.max() else { throw CalibrationMathError.noMeasurements }
        let delays = arrivalMilliseconds.map { latest - $0 }
        guard let required = delays.max(), required <= maximumDelay else {
            throw CalibrationMathError.compensationExceedsMaximum(delays.max() ?? 0)
        }
        return DelayCompensation(delays: delays)
    }
}

public struct ConvergenceController: Sendable {
    public let targetResidualMilliseconds: Double
    public let maximumPasses: Int
    public let signChangeLimit: Int

    public init(targetResidualMilliseconds: Double = 2, maximumPasses: Int = 3, signChangeLimit: Int = 2) {
        self.targetResidualMilliseconds = targetResidualMilliseconds
        self.maximumPasses = maximumPasses
        self.signChangeLimit = signChangeLimit
    }

    public func shouldContinue(residuals: [Double]) -> Bool {
        guard let latest = residuals.last, abs(latest) > targetResidualMilliseconds, residuals.count < maximumPasses else { return false }
        let signs = residuals.map { $0 == 0 ? 0 : ($0 > 0 ? 1 : -1) }
        let changes = zip(signs, signs.dropFirst()).filter { $0 != 0 && $1 != 0 && $0 != $1 }.count
        return changes < signChangeLimit
    }

    public func isSuccessful(residuals: [Double]) -> Bool {
        residuals.last.map { abs($0) <= targetResidualMilliseconds } ?? false
    }
}

public enum CalibrationQuality: String, Sendable, Codable, Equatable {
    case high, provisional, poor, unavailable
}

public struct SpeakerCalibrationEstimate: Sendable, Codable, Equatable {
    public let delayMilliseconds: Double?
    public let quality: CalibrationQuality
    public let confidence: Double
    public let measurementCount: Int
    public let acceptedMeasurementCount: Int
    public let summary: RobustMeasurementSummary?
    public let clusterMembers: [Double]
    public let excludedOutliers: [Double]
    public let medianProminence: Double
    public let method: String
    public var canApply: Bool { quality == .high || quality == .provisional }

    /// Maximum cluster diameter, not single-link distance: chains cannot bridge outliers.
    /// 3 ms allows a small timing spread without depending on a particular speaker latency.
    public init(measurements: [AcousticMeasurement], requiredAcceptedCount: Int = 3, clusterToleranceMilliseconds: Double = 3) {
        let candidates = measurements.filter { $0.acousticLatencyMilliseconds.isFinite && $0.estimate.confidence.isFinite && $0.estimate.peakValue.isFinite && $0.estimate.peakProminence.isFinite }
        let accepted = candidates.filter { $0.estimate.accepted }
        measurementCount = candidates.count
        acceptedMeasurementCount = accepted.count
        var chosen: [AcousticMeasurement] = []
        var supporting: [AcousticMeasurement] = []
        if !accepted.isEmpty {
            chosen = accepted
            let center = try! RobustMeasurementSummary(values: accepted.map(\.acousticLatencyMilliseconds)).medianMilliseconds
            supporting = candidates.filter { !$0.estimate.accepted && abs($0.acousticLatencyMilliseconds - center) <= clusterToleranceMilliseconds / 2 }
            if accepted.count >= requiredAcceptedCount {
                if accepted.count == 1 {
                    quality = AdaptiveCalibrationController.isFastAcceptable(accepted[0], clusterToleranceMilliseconds: clusterToleranceMilliseconds) ? .high : .provisional
                } else {
                    quality = .high
                }
            } else {
                quality = .provisional
            }
            method = "acceptedMedian"
        } else {
            let sorted = candidates.sorted { $0.acousticLatencyMilliseconds < $1.acousticLatencyMilliseconds }
            var clusters: [[AcousticMeasurement]] = []
            for start in sorted.indices {
                let cluster = Array(sorted[start...].prefix { $0.acousticLatencyMilliseconds - sorted[start].acousticLatencyMilliseconds <= clusterToleranceMilliseconds })
                clusters.append(cluster)
            }
            let largest = clusters.max { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return lhs.map { Self.score($0.estimate) }.reduce(0, +) < rhs.map { Self.score($0.estimate) }.reduce(0, +)
            } ?? []
            // A tied, disjoint cluster is ambiguous. Require a strict majority as well as two observations.
            if largest.count >= 2 && largest.count * 2 > candidates.count {
                chosen = largest
                quality = .provisional
                method = "clusterMedian"
            } else if let best = candidates.max(by: { Self.score($0.estimate) < Self.score($1.estimate) }) {
                chosen = [best]
                quality = .poor
                method = "strongestRawCandidate"
            } else {
                quality = .unavailable
                method = "noEstimate"
            }
        }
        summary = try? RobustMeasurementSummary(values: chosen.map(\.acousticLatencyMilliseconds))
        delayMilliseconds = summary?.medianMilliseconds
        confidence = (try? RobustMeasurementSummary(values: chosen.map(\.estimate.confidence)).medianMilliseconds) ?? 0
        medianProminence = (try? RobustMeasurementSummary(values: chosen.map(\.estimate.peakProminence)).medianMilliseconds) ?? 0
        clusterMembers = (chosen + supporting).map(\.acousticLatencyMilliseconds)
        excludedOutliers = candidates.filter { !chosen.contains($0) && !supporting.contains($0) }.map(\.acousticLatencyMilliseconds)
    }

    private static func score(_ estimate: DelayEstimate) -> Double {
        let consistency = estimate.abLatencyDifferenceMilliseconds.map { 1 / (1 + abs($0)) } ?? 0
        return 0.45 * estimate.confidence + 0.25 * min(1, max(0, estimate.peakProminence - 1) / 0.5)
            + 0.2 * min(1, abs(estimate.peakValue)) + 0.1 * consistency
    }
}

public struct AdaptiveCalibrationController: Sendable {
    public static let strongConsistencyToleranceMilliseconds: Double = 0.25
    public static let defaultClusterToleranceMilliseconds: Double = 3.0
    public static let defaultTargetResidualMilliseconds: Double = 2.0
    public static let defaultSanityBoundDeltaMilliseconds: Double = 50.0

    public static func isFastAcceptable(
        _ measurement: AcousticMeasurement,
        priorMeasurements: [AcousticMeasurement] = [],
        strongConsistencyToleranceMilliseconds: Double = strongConsistencyToleranceMilliseconds,
        clusterToleranceMilliseconds: Double = defaultClusterToleranceMilliseconds
    ) -> Bool {
        guard measurement.estimate.accepted else { return false }
        guard let abDiff = measurement.estimate.abLatencyDifferenceMilliseconds,
              abs(abDiff) <= strongConsistencyToleranceMilliseconds else {
            return false
        }
        for prior in priorMeasurements where prior.estimate.accepted {
            if abs(measurement.acousticLatencyMilliseconds - prior.acousticLatencyMilliseconds) > clusterToleranceMilliseconds {
                return false
            }
        }
        return true
    }

    public enum TemporalStability: Sendable, Equatable {
        case singleMeasurement(isFastAccepted: Bool)
        case stableCluster(spread: Double)
        case monotonicDrift(slopeMillisecondsPerSecond: Double)
        case inconsistent(spread: Double)
        case insufficientData
    }

    public static func assessTemporalStability(
        measurements: [AcousticMeasurement],
        driftThresholdMillisecondsPerSecond: Double = 0.25
    ) -> TemporalStability {
        guard !measurements.isEmpty else { return .insufficientData }
        if measurements.count == 1 {
            return .singleMeasurement(isFastAccepted: isFastAcceptable(measurements[0]))
        }
        let sorted = measurements.sorted { $0.emission.scheduledOutputHostTime < $1.emission.scheduledOutputHostTime }
        guard sorted.count >= 2 else { return .insufficientData }
        let lats = sorted.map(\.acousticLatencyMilliseconds)
        let firstHost = sorted.first!.emission.scheduledOutputHostTime
        let lastHost = sorted.last!.emission.scheduledOutputHostTime
        let dtNanos = Int64(AudioConvertHostTimeToNanos(lastHost)) - Int64(AudioConvertHostTimeToNanos(firstHost))
        let dtSeconds = Double(max(1, dtNanos)) / 1_000_000_000.0

        let totalLatDelta = lats.last! - lats.first!
        let slope = totalLatDelta / dtSeconds

        var isMonotonicIncreasing = true
        var isMonotonicDecreasing = true
        for i in 0..<(lats.count - 1) {
            let step = lats[i + 1] - lats[i]
            if step < 0.1 { isMonotonicIncreasing = false }
            if step > -0.1 { isMonotonicDecreasing = false }
        }

        let spread = (lats.max() ?? 0) - (lats.min() ?? 0)
        if (isMonotonicIncreasing || isMonotonicDecreasing) && abs(slope) >= driftThresholdMillisecondsPerSecond && spread > 0.5 {
            return .monotonicDrift(slopeMillisecondsPerSecond: slope)
        }
        if spread <= defaultClusterToleranceMilliseconds {
            return .stableCluster(spread: spread)
        }
        return .inconsistent(spread: spread)
    }

    public static func shouldTakeExtraBaselineMeasurement(
        speakerIndex: Int,
        measurements: [AcousticMeasurement],
        maximumNormalMeasurements: Int = 3
    ) -> Bool {
        if measurements.isEmpty { return true }
        if measurements.count >= maximumNormalMeasurements { return false }
        if measurements.count == 1 {
            return !isFastAcceptable(measurements[0])
        }
        let accepted = measurements.filter { $0.estimate.accepted }
        if accepted.isEmpty {
            return true
        }
        if accepted.count == 1 {
            return !isFastAcceptable(accepted[0])
        }
        let lats = accepted.map(\.acousticLatencyMilliseconds)
        let diff = (lats.max() ?? 0) - (lats.min() ?? 0)
        if diff > 1.5 { return true }
        let stability = assessTemporalStability(measurements: measurements)
        if case .monotonicDrift = stability { return true }
        return false
    }

    public static func identifyOffendingSpeakers(
        verificationMeasurements: [[AcousticMeasurement]],
        targetSpreadMilliseconds: Double = defaultTargetResidualMilliseconds
    ) -> [Int] {
        var offending: [Int] = []
        let latest = verificationMeasurements.enumerated().compactMap { index, list -> (index: Int, measurement: AcousticMeasurement)? in
            guard let last = list.last else { return nil }
            return (index: index, measurement: last)
        }
        guard latest.count == verificationMeasurements.count else {
            return verificationMeasurements.indices.filter { verificationMeasurements[$0].isEmpty }
        }

        for item in latest {
            if !item.measurement.estimate.accepted || !isFastAcceptable(item.measurement) {
                offending.append(item.index)
            }
        }

        let accepted = latest.filter { $0.measurement.estimate.accepted }
        guard !accepted.isEmpty else {
            return Array(verificationMeasurements.indices)
        }
        let lats = accepted.map(\.measurement.acousticLatencyMilliseconds)
        let minLat = lats.min()!
        let maxLat = lats.max()!
        if maxLat - minLat <= targetSpreadMilliseconds {
            return offending.sorted()
        }

        let medianLat = (try? RobustMeasurementSummary(values: lats).medianMilliseconds) ?? (minLat + maxLat) / 2
        for item in accepted {
            if abs(item.measurement.acousticLatencyMilliseconds - medianLat) > targetSpreadMilliseconds / 2 {
                if !offending.contains(item.index) {
                    offending.append(item.index)
                }
            }
        }
        if offending.isEmpty && (maxLat - minLat > targetSpreadMilliseconds) {
            if let worst = accepted.max(by: { abs($0.measurement.acousticLatencyMilliseconds - medianLat) < abs($1.measurement.acousticLatencyMilliseconds - medianLat) }) {
                offending.append(worst.index)
            }
        }
        return offending.sorted()
    }

    public static func calculateBaselineCompensation(
        speakerMeasurements: [[AcousticMeasurement]],
        requiredAcceptedCount: Int = 1,
        clusterToleranceMilliseconds: Double = defaultClusterToleranceMilliseconds
    ) throws -> DelayCompensation {
        let estimates = speakerMeasurements.map {
            SpeakerCalibrationEstimate(
                measurements: $0,
                requiredAcceptedCount: requiredAcceptedCount,
                clusterToleranceMilliseconds: clusterToleranceMilliseconds
            )
        }
        guard estimates.allSatisfy(\.canApply) else {
            throw CalibrationSessionError.didNotConverge(residualMilliseconds: .infinity)
        }
        let arrivals = estimates.compactMap(\.delayMilliseconds)
        guard arrivals.count == speakerMeasurements.count else {
            throw CalibrationSessionError.didNotConverge(residualMilliseconds: .infinity)
        }
        return try DelayCompensation.calculate(arrivalMilliseconds: arrivals)
    }

    public static func calculateVerificationSpread(
        verificationMeasurements: [[AcousticMeasurement]]
    ) -> Double? {
        let latest = verificationMeasurements.compactMap { $0.last }
        guard latest.count == verificationMeasurements.count else { return nil }
        guard latest.allSatisfy({ $0.estimate.accepted }) else { return nil }
        let lats = latest.map(\.acousticLatencyMilliseconds).filter(\.isFinite)
        guard lats.count == verificationMeasurements.count, let minLat = lats.min(), let maxLat = lats.max() else { return nil }
        return maxLat - minLat
    }

    public static func verificationTargetArrival(
        verificationMeasurements: [[AcousticMeasurement]],
        minimumAcceptedCount: Int = 1
    ) -> Double? {
        let accepted = verificationMeasurements.compactMap { $0.last }.filter { $0.estimate.accepted }
        guard accepted.count >= minimumAcceptedCount else { return nil }
        let lats = accepted.map(\.acousticLatencyMilliseconds).filter(\.isFinite)
        guard !lats.isEmpty else { return nil }
        return lats.max()
    }

    public struct VerificationRetryAdjustment: Sendable, Equatable {
        public let shouldAdjustDelay: Bool
        public let deltaMilliseconds: Double
        public let newCalibrationDelayMilliseconds: Double
        public let reason: String

        public init(shouldAdjustDelay: Bool, deltaMilliseconds: Double, newCalibrationDelayMilliseconds: Double, reason: String) {
            self.shouldAdjustDelay = shouldAdjustDelay
            self.deltaMilliseconds = deltaMilliseconds
            self.newCalibrationDelayMilliseconds = newCalibrationDelayMilliseconds
            self.reason = reason
        }
    }

    public static func calculateVerificationRetryAdjustment(
        lastMeasurement: AcousticMeasurement?,
        targetArrivalMilliseconds: Double?,
        currentCalibrationDelayMilliseconds: Double,
        maximumSanityDeltaMilliseconds: Double = defaultSanityBoundDeltaMilliseconds
    ) -> VerificationRetryAdjustment {
        guard let last = lastMeasurement else {
            return VerificationRetryAdjustment(
                shouldAdjustDelay: false,
                deltaMilliseconds: 0.0,
                newCalibrationDelayMilliseconds: currentCalibrationDelayMilliseconds,
                reason: "No prior measurement"
            )
        }
        guard last.estimate.accepted else {
            return VerificationRetryAdjustment(
                shouldAdjustDelay: false,
                deltaMilliseconds: 0.0,
                newCalibrationDelayMilliseconds: currentCalibrationDelayMilliseconds,
                reason: "Measurement rejected (accepted == false); candidate latency \(last.acousticLatencyMilliseconds) ms ignored"
            )
        }
        guard let targetArrival = targetArrivalMilliseconds, targetArrival.isFinite else {
            return VerificationRetryAdjustment(
                shouldAdjustDelay: false,
                deltaMilliseconds: 0.0,
                newCalibrationDelayMilliseconds: currentCalibrationDelayMilliseconds,
                reason: "No valid target arrival"
            )
        }
        let currentArrival = last.acousticLatencyMilliseconds
        guard currentArrival.isFinite else {
            return VerificationRetryAdjustment(
                shouldAdjustDelay: false,
                deltaMilliseconds: 0.0,
                newCalibrationDelayMilliseconds: currentCalibrationDelayMilliseconds,
                reason: "Measurement arrival is not finite"
            )
        }
        let delta = targetArrival - currentArrival
        if abs(delta) > maximumSanityDeltaMilliseconds {
            return VerificationRetryAdjustment(
                shouldAdjustDelay: false,
                deltaMilliseconds: delta,
                newCalibrationDelayMilliseconds: currentCalibrationDelayMilliseconds,
                reason: "Correction delta \(delta) ms exceeds sanity bound \(maximumSanityDeltaMilliseconds) ms"
            )
        }
        if abs(delta) <= 0.1 {
            return VerificationRetryAdjustment(
                shouldAdjustDelay: false,
                deltaMilliseconds: delta,
                newCalibrationDelayMilliseconds: currentCalibrationDelayMilliseconds,
                reason: "Correction delta \(delta) ms below threshold 0.1 ms"
            )
        }
        let newDelay = max(0.0, currentCalibrationDelayMilliseconds + delta)
        return VerificationRetryAdjustment(
            shouldAdjustDelay: true,
            deltaMilliseconds: delta,
            newCalibrationDelayMilliseconds: newDelay,
            reason: "Adjusting delay by \(delta) ms (target \(targetArrival) ms - current \(currentArrival) ms)"
        )
    }

    public static func requiredCaptureDurationSeconds(
        rawLatencySeconds: Double,
        activeRouteDelaySeconds: Double,
        probeDurationSeconds: Double,
        acousticTailSeconds: Double = 0.05,
        safetyMarginSeconds: Double = 0.05,
        hardMaximumSeconds: Double = 2.5
    ) -> Double {
        let expectedArrival = min(hardMaximumSeconds - 0.6, max(0, rawLatencySeconds) + max(0, activeRouteDelaySeconds))
        let total = expectedArrival + probeDurationSeconds + acousticTailSeconds + safetyMarginSeconds
        return min(hardMaximumSeconds, total)
    }

    public static func searchWindowExtentSamples(
        rawLatencySeconds: Double,
        activeRouteDelaySeconds: Double,
        sampleRate: Double,
        hardMaximumSeconds: Double = 2.5
    ) -> Int {
        let expectedArrival = min(hardMaximumSeconds - 0.6, max(0, rawLatencySeconds) + max(0, activeRouteDelaySeconds))
        return Int(ceil((expectedArrival + 0.02) * sampleRate))
    }
}
