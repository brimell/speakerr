import Foundation

public struct CalibrationSignal: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var durationSeconds: Double { Double(samples.count) / sampleRate }
}

public protocol CalibrationSignalGenerator: Sendable {
    func generate(sampleRate: Double) throws -> CalibrationSignal
}

public enum CalibrationSignalError: LocalizedError, Equatable {
    case invalidSampleRate
    case invalidFrequencyRange
    case invalidDuration
    case invalidLevel

    public var errorDescription: String? {
        switch self {
        case .invalidSampleRate: "Calibration sample rate must be positive."
        case .invalidFrequencyRange: "Calibration frequencies must be positive and below Nyquist."
        case .invalidDuration: "Calibration duration must be positive."
        case .invalidLevel: "Calibration level must be greater than zero and no greater than 0.5."
        }
    }
}

public struct LogarithmicChirpGenerator: CalibrationSignalGenerator, Sendable {
    public let startFrequency: Double
    public let endFrequency: Double
    public let durationSeconds: Double
    public let fadeSeconds: Double
    public let level: Double

    public init(
        startFrequency: Double = 500,
        endFrequency: Double = 12_000,
        durationSeconds: Double = 0.3,
        fadeSeconds: Double = 0.01,
        level: Double = 0.12
    ) {
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.durationSeconds = durationSeconds
        self.fadeSeconds = fadeSeconds
        self.level = level
    }

    public func generate(sampleRate: Double) throws -> CalibrationSignal {
        guard sampleRate > 0 else { throw CalibrationSignalError.invalidSampleRate }
        guard startFrequency > 0, endFrequency > startFrequency, endFrequency < sampleRate * 0.5 else {
            throw CalibrationSignalError.invalidFrequencyRange
        }
        guard durationSeconds > 0, fadeSeconds >= 0, fadeSeconds * 2 <= durationSeconds else {
            throw CalibrationSignalError.invalidDuration
        }
        guard level > 0, level <= 0.5 else { throw CalibrationSignalError.invalidLevel }

        let sampleCount = Int((durationSeconds * sampleRate).rounded())
        let fadeCount = min(Int((fadeSeconds * sampleRate).rounded()), sampleCount / 2)
        let logarithmicRatio = log(endFrequency / startFrequency)
        let phaseScale = 2 * Double.pi * startFrequency * durationSeconds / logarithmicRatio
        var samples = [Float](repeating: 0, count: sampleCount)

        for index in samples.indices {
            let time = Double(index) / sampleRate
            let phase = phaseScale * (exp(logarithmicRatio * time / durationSeconds) - 1)
            var envelope = 1.0
            if fadeCount > 0, index < fadeCount {
                envelope = 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(fadeCount))
            } else if fadeCount > 0, index >= sampleCount - fadeCount {
                let remaining = Double(sampleCount - 1 - index)
                envelope = 0.5 - 0.5 * cos(Double.pi * remaining / Double(fadeCount))
            }
            samples[index] = Float(level * envelope * sin(phase))
        }
        return CalibrationSignal(samples: samples, sampleRate: sampleRate)
    }
}
