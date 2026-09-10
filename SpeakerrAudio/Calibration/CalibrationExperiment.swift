import Foundation
import CoreAudio

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
        intervalSeconds: Double = 0.85,
        passGapSeconds: Double = 0,
        postRollSeconds: Double = 0.4,
        measurementsPerSpeaker: Int = 3,
        maximumPasses: Int = 3,
        maximumRetriesPerSpeaker: Int = 2,
        maximumAcousticLatencySeconds: Double = 0.4,
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
              intervalSeconds > maximumAcousticLatencySeconds,
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

    public func validateSchedule(signalDurationSeconds: Double, safetyGuardSeconds: Double = 0.03) throws {
        guard signalDurationSeconds > 0,
              intervalSeconds >= signalDurationSeconds + maximumAcousticLatencySeconds + safetyGuardSeconds else {
            throw CalibrationSessionError.invalidConfiguration
        }
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

public struct CalibrationAttemptDiagnostic: Sendable, Equatable, Codable, Identifiable {
    public var id: String { "\(pass)-\(speakerIndex)-\(attempt)" }
    public let pass: Int
    public let attempt: Int
    public let speakerIndex: Int
    public let speakerName: String
    public let measuredLatencyMilliseconds: Double?
    public let peak: Double?
    public let secondBestPeak: Double?
    public let prominence: Double?
    public let confidence: Double?
    public let accepted: Bool
    public let failureReason: String?

    public init(pass: Int, attempt: Int, speakerIndex: Int, speakerName: String, measuredLatencyMilliseconds: Double?, peak: Double?, secondBestPeak: Double?, prominence: Double?, confidence: Double?, accepted: Bool, failureReason: String? = nil) {
        self.pass = pass
        self.attempt = attempt
        self.speakerIndex = speakerIndex
        self.speakerName = speakerName
        self.measuredLatencyMilliseconds = measuredLatencyMilliseconds
        self.peak = peak
        self.secondBestPeak = secondBestPeak
        self.prominence = prominence
        self.confidence = confidence
        self.accepted = accepted
        self.failureReason = failureReason
    }
}

public struct CalibrationPassMeasurements: Sendable, Equatable, Codable {
    public let pass: Int
    /// All usable candidates; accepted and rejected remain distinguishable.
    public let measurementsBySpeaker: [[AcousticMeasurement]]
    public let speakerEstimates: [SpeakerCalibrationEstimate]
    public let failures: [String]
    public let attempts: [CalibrationAttemptDiagnostic]
    public var measurementsA: [AcousticMeasurement] { measurementsBySpeaker[0] }
    public var measurementsB: [AcousticMeasurement] { measurementsBySpeaker[1] }
    public var acceptedBySpeaker: [[AcousticMeasurement]] { measurementsBySpeaker.map { $0.filter { $0.estimate.accepted } } }
    public var rejectedBySpeaker: [[AcousticMeasurement]] { measurementsBySpeaker.map { $0.filter { !$0.estimate.accepted } } }
    public var summariesBySpeaker: [RobustMeasurementSummary?] { speakerEstimates.map(\.summary) }
    public var summaryA: RobustMeasurementSummary? { summariesBySpeaker[0] }
    public var summaryB: RobustMeasurementSummary? { summariesBySpeaker[1] }
    public var relativeArrivalBMinusAMilliseconds: Double {
        guard let a = summaryA, let b = summaryB else { return .nan }
        return b.medianMilliseconds - a.medianMilliseconds
    }
    public var canApplyCompensation: Bool { speakerEstimates.allSatisfy(\.canApply) }
    public var quality: CalibrationQuality {
        if speakerEstimates.contains(where: { $0.quality == .unavailable }) { return .unavailable }
        if speakerEstimates.contains(where: { $0.quality == .poor }) { return .poor }
        return speakerEstimates.allSatisfy { $0.quality == .high } ? .high : .provisional
    }
    public var residualSpreadMilliseconds: Double? {
        let arrivals = speakerEstimates.compactMap(\.delayMilliseconds)
        guard arrivals.count == speakerEstimates.count, let minimum = arrivals.min(), let maximum = arrivals.max() else { return nil }
        return maximum - minimum
    }

    public init(pass: Int, measurementsA: [AcousticMeasurement], measurementsB: [AcousticMeasurement], failures: [String], attempts: [CalibrationAttemptDiagnostic] = []) throws {
        try self.init(pass: pass, measurementsBySpeaker: [measurementsA, measurementsB], failures: failures, attempts: attempts)
    }

    public init(pass: Int, measurementsBySpeaker: [[AcousticMeasurement]], failures: [String], attempts: [CalibrationAttemptDiagnostic] = [], requiredAcceptedCount: Int = 3) throws {
        guard measurementsBySpeaker.count >= 2 else { throw CalibrationMathError.noMeasurements }
        self.pass = pass
        self.measurementsBySpeaker = measurementsBySpeaker
        speakerEstimates = measurementsBySpeaker.map { SpeakerCalibrationEstimate(measurements: $0, requiredAcceptedCount: requiredAcceptedCount) }
        self.failures = failures
        self.attempts = attempts
    }

    public var relativeArrivalsToReferenceMilliseconds: [Double] {
        let arrivals = speakerEstimates.compactMap(\.delayMilliseconds)
        guard arrivals.count == speakerEstimates.count, let reference = arrivals.first else { return [] }
        return arrivals.map { $0 - reference }
    }

    private enum CodingKeys: String, CodingKey {
        case pass, measurementsA, measurementsB, failures, measurementsBySpeaker, speakerEstimates, attempts
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pass = try values.decode(Int.self, forKey: .pass)
        measurementsBySpeaker = try values.decodeIfPresent([[AcousticMeasurement]].self, forKey: .measurementsBySpeaker)
            ?? [values.decode([AcousticMeasurement].self, forKey: .measurementsA), values.decode([AcousticMeasurement].self, forKey: .measurementsB)]
        guard measurementsBySpeaker.count >= 2 else { throw CalibrationMathError.noMeasurements }
        speakerEstimates = try values.decodeIfPresent([SpeakerCalibrationEstimate].self, forKey: .speakerEstimates)
            ?? measurementsBySpeaker.map { SpeakerCalibrationEstimate(measurements: $0) }
        failures = try values.decode([String].self, forKey: .failures)
        attempts = try values.decodeIfPresent([CalibrationAttemptDiagnostic].self, forKey: .attempts) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pass, forKey: .pass)
        try values.encode(measurementsBySpeaker, forKey: .measurementsBySpeaker)
        try values.encode(speakerEstimates, forKey: .speakerEstimates)
        try values.encode(failures, forKey: .failures)
        try values.encode(attempts, forKey: .attempts)
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

public struct CalibrationTimingSummary: Sendable, Codable, Equatable {
    public let preRollMilliseconds: Double
    public let probeAMilliseconds: Double
    public let abGapMilliseconds: Double
    public let probeBMilliseconds: Double
    public let acousticTailMilliseconds: Double
    public let postProbeGuardMilliseconds: Double
    public let estimatorProcessingMilliseconds: Double
    public let diskWritingMilliseconds: Double
    public let transitionToNextOutputMilliseconds: Double
    public let totalElapsedMilliseconds: Double
    public let emissionCount: Int

    public init(
        preRollMilliseconds: Double = 0,
        probeAMilliseconds: Double = 0,
        abGapMilliseconds: Double = 0,
        probeBMilliseconds: Double = 0,
        acousticTailMilliseconds: Double = 0,
        postProbeGuardMilliseconds: Double = 0,
        estimatorProcessingMilliseconds: Double = 0,
        diskWritingMilliseconds: Double = 0,
        transitionToNextOutputMilliseconds: Double = 0,
        totalElapsedMilliseconds: Double = 0,
        emissionCount: Int = 0
    ) {
        self.preRollMilliseconds = preRollMilliseconds
        self.probeAMilliseconds = probeAMilliseconds
        self.abGapMilliseconds = abGapMilliseconds
        self.probeBMilliseconds = probeBMilliseconds
        self.acousticTailMilliseconds = acousticTailMilliseconds
        self.postProbeGuardMilliseconds = postProbeGuardMilliseconds
        self.estimatorProcessingMilliseconds = estimatorProcessingMilliseconds
        self.diskWritingMilliseconds = diskWritingMilliseconds
        self.transitionToNextOutputMilliseconds = transitionToNextOutputMilliseconds
        self.totalElapsedMilliseconds = totalElapsedMilliseconds
        self.emissionCount = emissionCount
    }

    public var formattedSummary: String {
        """
        Calibration Timing Summary (\(emissionCount) emissions, total: \(String(format: "%.1f", totalElapsedMilliseconds)) ms):
          pre-roll: \(String(format: "%.1f", preRollMilliseconds)) ms
          probe A: \(String(format: "%.1f", probeAMilliseconds)) ms
          A/B gap: \(String(format: "%.1f", abGapMilliseconds)) ms
          probe B: \(String(format: "%.1f", probeBMilliseconds)) ms
          acoustic tail: \(String(format: "%.1f", acousticTailMilliseconds)) ms
          post-probe guard: \(String(format: "%.1f", postProbeGuardMilliseconds)) ms
          estimator processing: \(String(format: "%.1f", estimatorProcessingMilliseconds)) ms
          disk writing: \(String(format: "%.1f", diskWritingMilliseconds)) ms
          transition to next: \(String(format: "%.1f", transitionToNextOutputMilliseconds)) ms
        """
    }
}

public final class CalibrationTimingCollector: @unchecked Sendable {
    public var preRollMilliseconds: Double = 0
    public var probeAMilliseconds: Double = 0
    public var abGapMilliseconds: Double = 0
    public var probeBMilliseconds: Double = 0
    public var acousticTailMilliseconds: Double = 0
    public var postProbeGuardMilliseconds: Double = 0
    public var estimatorProcessingMilliseconds: Double = 0
    public var diskWritingMilliseconds: Double = 0
    public var transitionToNextOutputMilliseconds: Double = 0
    public var emissionCount: Int = 0
    public var startTime: ContinuousClock.Instant?
    public var lastEmissionEndTime: ContinuousClock.Instant?

    public init() {}

    public func start() {
        startTime = ContinuousClock.now
    }

    public func recordPreRoll(milliseconds: Double) {
        preRollMilliseconds += milliseconds
    }

    public func recordEmission(
        probeAMS: Double,
        abGapMS: Double,
        probeBMS: Double,
        acousticTailMS: Double,
        postProbeGuardMS: Double,
        estimatorMS: Double,
        diskWritingMS: Double
    ) {
        if let last = lastEmissionEndTime {
            let now = ContinuousClock.now
            let duration = now - last
            let transitionMS = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
            transitionToNextOutputMilliseconds += max(0, transitionMS)
        }
        probeAMilliseconds += probeAMS
        abGapMilliseconds += abGapMS
        probeBMilliseconds += probeBMS
        acousticTailMilliseconds += acousticTailMS
        postProbeGuardMilliseconds += postProbeGuardMS
        estimatorProcessingMilliseconds += estimatorMS
        diskWritingMilliseconds += diskWritingMS
        emissionCount += 1
        lastEmissionEndTime = ContinuousClock.now
    }

    public func finish() -> CalibrationTimingSummary {
        let totalMS: Double
        if let start = startTime {
            let duration = ContinuousClock.now - start
            totalMS = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        } else {
            totalMS = preRollMilliseconds + probeAMilliseconds + abGapMilliseconds + probeBMilliseconds + acousticTailMilliseconds + postProbeGuardMilliseconds + estimatorProcessingMilliseconds + diskWritingMilliseconds + transitionToNextOutputMilliseconds
        }
        return CalibrationTimingSummary(
            preRollMilliseconds: preRollMilliseconds,
            probeAMilliseconds: probeAMilliseconds,
            abGapMilliseconds: abGapMilliseconds,
            probeBMilliseconds: probeBMilliseconds,
            acousticTailMilliseconds: acousticTailMilliseconds,
            postProbeGuardMilliseconds: postProbeGuardMilliseconds,
            estimatorProcessingMilliseconds: estimatorProcessingMilliseconds,
            diskWritingMilliseconds: diskWritingMilliseconds,
            transitionToNextOutputMilliseconds: transitionToNextOutputMilliseconds,
            totalElapsedMilliseconds: totalMS,
            emissionCount: emissionCount
        )
    }
}
