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
    public let calibrationDelayA: Double
    public let calibrationDelayB: Double

    public init(calibrationDelayA: Double, calibrationDelayB: Double) {
        self.calibrationDelayA = calibrationDelayA
        self.calibrationDelayB = calibrationDelayB
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
