import Foundation

public struct CalibrationExperimentConfiguration: Sendable, Equatable, Codable {
    public var preRollSeconds: Double
    public var chirpDurationSeconds: Double
    public var intervalSeconds: Double
    public var passGapSeconds: Double
    public var postRollSeconds: Double
    public var measurementsPerSpeaker: Int
    public var maximumPasses: Int
    public var maximumRetriesPerSpeaker: Int
    public var maximumAcousticLatencySeconds: Double
    public var targetResidualMilliseconds: Double
    public var level: Double
    public var stabilityMeasurementOffsetsSeconds: [Double]

    public init(
        preRollSeconds: Double = 0.2,
        chirpDurationSeconds: Double = 0.16,
        intervalSeconds: Double = 0.40,
        passGapSeconds: Double = 0,
        postRollSeconds: Double = 0.08,
        measurementsPerSpeaker: Int = 3,
        maximumPasses: Int = 3,
        maximumRetriesPerSpeaker: Int = 2,
        maximumAcousticLatencySeconds: Double = 0.08,
        targetResidualMilliseconds: Double = 2,
        level: Double = 0.12,
        stabilityMeasurementOffsetsSeconds: [Double] = []
    ) {
        self.preRollSeconds = preRollSeconds
        self.chirpDurationSeconds = chirpDurationSeconds
        self.intervalSeconds = intervalSeconds
        self.passGapSeconds = passGapSeconds
        self.postRollSeconds = postRollSeconds
        self.measurementsPerSpeaker = measurementsPerSpeaker
        self.maximumPasses = maximumPasses
        self.maximumRetriesPerSpeaker = maximumRetriesPerSpeaker
        self.maximumAcousticLatencySeconds = maximumAcousticLatencySeconds
        self.targetResidualMilliseconds = targetResidualMilliseconds
        self.level = level
        self.stabilityMeasurementOffsetsSeconds = stabilityMeasurementOffsetsSeconds
        self.selectedSpeakerCount = 2
    }

    public func validate() throws {
        guard preRollSeconds >= 0,
              chirpDurationSeconds > 0,
              intervalSeconds > chirpDurationSeconds + maximumAcousticLatencySeconds,
              passGapSeconds >= 0,
              postRollSeconds >= maximumAcousticLatencySeconds,
              measurementsPerSpeaker > 0,
              selectedSpeakerCount > 0,
              maximumPasses > 0,
              maximumRetriesPerSpeaker >= 0,
              maximumAcousticLatencySeconds > 0,
              stabilityMeasurementOffsetsSeconds.allSatisfy({ $0 >= 0 }),
              stabilityMeasurementOffsetsSeconds == stabilityMeasurementOffsetsSeconds.sorted() else {
            throw CalibrationSessionError.invalidConfiguration
        }
        guard level > 0, level <= 0.5 else { throw CalibrationSignalError.invalidLevel }
    }

    public var eventsPerPass: Int { selectedSpeakerCount * (measurementsPerSpeaker + maximumRetriesPerSpeaker) }
    public var selectedSpeakerCount: Int

    private enum CodingKeys: String, CodingKey {
        case preRollSeconds, chirpDurationSeconds, intervalSeconds, passGapSeconds, postRollSeconds
        case measurementsPerSpeaker, maximumPasses, maximumRetriesPerSpeaker, maximumAcousticLatencySeconds
        case targetResidualMilliseconds, level, stabilityMeasurementOffsetsSeconds, selectedSpeakerCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preRollSeconds = try values.decode(Double.self, forKey: .preRollSeconds)
        chirpDurationSeconds = try values.decode(Double.self, forKey: .chirpDurationSeconds)
        intervalSeconds = try values.decode(Double.self, forKey: .intervalSeconds)
        passGapSeconds = try values.decode(Double.self, forKey: .passGapSeconds)
        postRollSeconds = try values.decode(Double.self, forKey: .postRollSeconds)
        measurementsPerSpeaker = try values.decode(Int.self, forKey: .measurementsPerSpeaker)
        maximumPasses = try values.decode(Int.self, forKey: .maximumPasses)
        maximumRetriesPerSpeaker = try values.decode(Int.self, forKey: .maximumRetriesPerSpeaker)
        maximumAcousticLatencySeconds = try values.decode(Double.self, forKey: .maximumAcousticLatencySeconds)
        targetResidualMilliseconds = try values.decode(Double.self, forKey: .targetResidualMilliseconds)
        level = try values.decode(Double.self, forKey: .level)
        stabilityMeasurementOffsetsSeconds = try values.decode([Double].self, forKey: .stabilityMeasurementOffsetsSeconds)
        selectedSpeakerCount = try values.decodeIfPresent(Int.self, forKey: .selectedSpeakerCount) ?? 2
    }

    public func passStartSeconds(_ pass: Int) -> Double {
        let passStride = Double(eventsPerPass) * intervalSeconds + passGapSeconds
        if pass < maximumPasses { return preRollSeconds + Double(pass) * passStride }
        let stabilityIndex = pass - maximumPasses
        return preRollSeconds + Double(maximumPasses) * passStride + stabilityMeasurementOffsetsSeconds[stabilityIndex]
    }

    public var maximumSessionSeconds: Double {
        // Analysis runs while the streams remain alive. Reserve bounded headroom so a
        // slower debug build cannot overrun capture while writing diagnostics.
        let finalPass = maximumPasses + stabilityMeasurementOffsetsSeconds.count - 1
        return passStartSeconds(finalPass) + Double(eventsPerPass) * intervalSeconds + postRollSeconds + 15
    }

    public var totalScheduledPasses: Int { maximumPasses + stabilityMeasurementOffsetsSeconds.count }
}

public struct CalibrationEmission: Sendable, Equatable, Codable {
    public let pass: Int
    public let sequence: Int
    public let speakerIndex: Int
    public let scheduledOutputFrame: Int64
    public let scheduledOutputHostTime: UInt64
}

public struct AcousticMeasurement: Sendable, Equatable, Codable {
    public let emission: CalibrationEmission
    public let arrivalHostTime: UInt64
    public let acousticLatencyMilliseconds: Double
    public let estimate: DelayEstimate
}

public struct CalibrationPassMeasurements: Sendable, Equatable, Codable {
    public let pass: Int
    public let measurementsA: [AcousticMeasurement]
    public let measurementsB: [AcousticMeasurement]
    public let failures: [String]
    public let summaryA: RobustMeasurementSummary
    public let summaryB: RobustMeasurementSummary
    public let relativeArrivalBMinusAMilliseconds: Double
    public let measurementsBySpeaker: [[AcousticMeasurement]]
    public let summariesBySpeaker: [RobustMeasurementSummary]

    public init(pass: Int, measurementsA: [AcousticMeasurement], measurementsB: [AcousticMeasurement], failures: [String]) throws {
        try self.init(pass: pass, measurementsBySpeaker: [measurementsA, measurementsB], failures: failures)
    }

    public init(pass: Int, measurementsBySpeaker: [[AcousticMeasurement]], failures: [String]) throws {
        guard measurementsBySpeaker.count >= 2 else { throw CalibrationMathError.noMeasurements }
        self.pass = pass
        self.measurementsBySpeaker = measurementsBySpeaker
        self.summariesBySpeaker = try measurementsBySpeaker.map { try RobustMeasurementSummary(values: $0.map(\.acousticLatencyMilliseconds)) }
        self.measurementsA = measurementsBySpeaker[0]
        self.measurementsB = measurementsBySpeaker[1]
        self.failures = failures
        summaryA = summariesBySpeaker[0]
        summaryB = summariesBySpeaker[1]
        relativeArrivalBMinusAMilliseconds = summaryB.medianMilliseconds - summaryA.medianMilliseconds
    }

    public var relativeArrivalsToReferenceMilliseconds: [Double] {
        guard let reference = summariesBySpeaker.first?.medianMilliseconds else { return [] }
        return summariesBySpeaker.map { $0.medianMilliseconds - reference }
    }

    private enum CodingKeys: String, CodingKey {
        case pass, measurementsA, measurementsB, failures, summaryA, summaryB
        case relativeArrivalBMinusAMilliseconds, measurementsBySpeaker, summariesBySpeaker
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pass = try values.decode(Int.self, forKey: .pass)
        measurementsA = try values.decode([AcousticMeasurement].self, forKey: .measurementsA)
        measurementsB = try values.decode([AcousticMeasurement].self, forKey: .measurementsB)
        failures = try values.decode([String].self, forKey: .failures)
        summaryA = try values.decode(RobustMeasurementSummary.self, forKey: .summaryA)
        summaryB = try values.decode(RobustMeasurementSummary.self, forKey: .summaryB)
        relativeArrivalBMinusAMilliseconds = try values.decode(Double.self, forKey: .relativeArrivalBMinusAMilliseconds)
        measurementsBySpeaker = try values.decodeIfPresent([[AcousticMeasurement]].self, forKey: .measurementsBySpeaker) ?? [measurementsA, measurementsB]
        summariesBySpeaker = try values.decodeIfPresent([RobustMeasurementSummary].self, forKey: .summariesBySpeaker) ?? [summaryA, summaryB]
    }
}

public enum CalibrationSessionError: LocalizedError {
    case invalidConfiguration
    case requiresMatchingSampleRates(output: Double, input: Double)
    case inputUnavailable(String)
    case timestampUnavailable(String)
    case captureOverflow
    case renderFailed(OSStatus)
    case insufficientValidMeasurements(speaker: String, valid: Int, required: Int)
    case didNotConverge(residualMilliseconds: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Calibration experiment parameters are inconsistent."
        case .requiresMatchingSampleRates(let output, let input): "The first prototype requires matching output and microphone rates (output=\(output)Hz, input=\(input)Hz)."
        case .inputUnavailable(let name): "Microphone \(name) is unavailable."
        case .timestampUnavailable(let stream): "\(stream) did not provide valid CoreAudio host timestamps."
        case .captureOverflow: "The preallocated microphone capture buffer overflowed."
        case .renderFailed(let status): "A realtime audio callback failed with CoreAudio status \(status)."
        case .insufficientValidMeasurements(let speaker, let valid, let required): "\(speaker) produced only \(valid) valid measurements; \(required) are required."
        case .didNotConverge(let residual): "Calibration did not converge within the bounded pass limit (residual=\(String(format: "%.2f", abs(residual))) ms)."
        }
    }
}
