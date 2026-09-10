import Foundation

public struct CalibrationSignal: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double
    public let complementarySequences: ([Float], [Float])?
    public let interSequenceSilenceSamples: Int

    public init(samples: [Float], sampleRate: Double, complementarySequences: ([Float], [Float])? = nil, interSequenceSilenceSamples: Int = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.complementarySequences = complementarySequences
        self.interSequenceSilenceSamples = interSequenceSilenceSamples
    }

    public var durationSeconds: Double { Double(samples.count) / sampleRate }

    public static func == (lhs: CalibrationSignal, rhs: CalibrationSignal) -> Bool {
        lhs.samples == rhs.samples &&
        lhs.sampleRate == rhs.sampleRate &&
        lhs.interSequenceSilenceSamples == rhs.interSequenceSilenceSamples &&
        lhs.complementarySequences?.0 == rhs.complementarySequences?.0 &&
        lhs.complementarySequences?.1 == rhs.complementarySequences?.1
    }
}

public struct GolayComplementaryPairGenerator: CalibrationSignalGenerator, Sendable {
    public let sequenceDurationSeconds: Double
    public let interSequenceSilenceSeconds: Double
    public let lowFrequency: Double
    public let highFrequency: Double
    public let fadeSeconds: Double
    public let level: Double

    public init(
        sequenceDurationSeconds: Double = 0.16,
        interSequenceSilenceSeconds: Double = 0.03,
        lowFrequency: Double = 700,
        highFrequency: Double = 10_000,
        fadeSeconds: Double = 0.003,
        level: Double = pow(10, -12 / 20)
    ) {
        self.sequenceDurationSeconds = sequenceDurationSeconds
        self.interSequenceSilenceSeconds = interSequenceSilenceSeconds
        self.lowFrequency = lowFrequency
        self.highFrequency = highFrequency
        self.fadeSeconds = fadeSeconds
        self.level = level
    }

    public func generate(sampleRate: Double) throws -> CalibrationSignal {
        guard sampleRate > 0 else { throw CalibrationSignalError.invalidSampleRate }
        guard lowFrequency > 0, highFrequency > lowFrequency, highFrequency < sampleRate * 0.5 else {
            throw CalibrationSignalError.invalidFrequencyRange
        }
        guard sequenceDurationSeconds > 0, interSequenceSilenceSeconds >= 0,
              fadeSeconds >= 0, fadeSeconds * 2 <= sequenceDurationSeconds else {
            throw CalibrationSignalError.invalidDuration
        }
        guard level > 0, level <= 0.5 else { throw CalibrationSignalError.invalidLevel }

        // 1024 chips at 8 samples/chip gives a 170.7 ms sequence at 48 kHz.
        let chipCount = 1 << 10
        let chipSamples = max(1, Int((sequenceDurationSeconds * sampleRate / Double(chipCount)).rounded()))
        let silenceCount = Int((interSequenceSilenceSeconds * sampleRate).rounded())
        let chipsA = Self.golay(order: 10).0
        let chipsB = Self.golay(order: 10).1
        let rawA = Self.expand(chipsA, samplesPerChip: chipSamples)
        let rawB = Self.expand(chipsB, samplesPerChip: chipSamples)
        let a = Self.bandLimit(rawA, sampleRate: sampleRate, low: lowFrequency, high: highFrequency, level: level, fadeSeconds: fadeSeconds)
        let b = Self.bandLimit(rawB, sampleRate: sampleRate, low: lowFrequency, high: highFrequency, level: level, fadeSeconds: fadeSeconds)
        let samples = a + [Float](repeating: 0, count: silenceCount) + b
        return CalibrationSignal(samples: samples, sampleRate: sampleRate, complementarySequences: (a, b), interSequenceSilenceSamples: silenceCount)
    }

    private static func golay(order: Int) -> ([Float], [Float]) {
        var a: [Float] = [1]
        var b: [Float] = [1]
        for _ in 0..<order {
            let oldA = a
            let oldB = b
            a = oldA + oldB
            b = oldA + oldB.map(-)
        }
        return (a, b)
    }

    private static func expand(_ chips: [Float], samplesPerChip: Int) -> [Float] {
        chips.flatMap { Array(repeating: $0, count: samplesPerChip) }
    }

    private static func bandLimit(_ input: [Float], sampleRate: Double, low: Double, high: Double, level: Double, fadeSeconds: Double) -> [Float] {
        let taps = 161
        let half = taps / 2
        var output = [Float](repeating: 0, count: input.count)
        for index in input.indices {
            var sum = 0.0
            for tap in 0..<taps {
                let offset = tap - half
                let source = index + offset
                guard input.indices.contains(source) else { continue }
                let x = Double(offset)
                let sincHigh = x == 0 ? 2 * high / sampleRate : sin(2 * .pi * high * x / sampleRate) / (.pi * x)
                let sincLow = x == 0 ? 2 * low / sampleRate : sin(2 * .pi * low * x / sampleRate) / (.pi * x)
                let window = 0.54 - 0.46 * cos(2 * .pi * Double(tap) / Double(taps - 1))
                sum += Double(input[source]) * (sincHigh - sincLow) * window
            }
            output[index] = Float(sum * level)
        }
        let fadeCount = min(Int((fadeSeconds * sampleRate).rounded()), output.count / 2)
        for index in 0..<fadeCount {
            let envelope = 0.5 - 0.5 * cos(.pi * Double(index) / Double(fadeCount))
            output[index] *= Float(envelope)
            output[output.count - 1 - index] *= Float(envelope)
        }
        if let peak = output.map({ abs($0) }).max(), peak > 0 {
            let scale = Float(level) / peak
            for index in output.indices { output[index] *= scale }
        }
        return output
    }
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
