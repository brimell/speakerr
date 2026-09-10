import Foundation

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
            quality = accepted.count >= requiredAcceptedCount ? .high : .provisional
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
