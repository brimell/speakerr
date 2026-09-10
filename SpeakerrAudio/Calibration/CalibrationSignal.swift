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
    public let golayOrder: Int
    public let interSequenceSilenceSeconds: Double
    public let lowFrequency: Double
    public let highFrequency: Double
    public let fadeSeconds: Double
    public let level: Double

    public init(
        golayOrder: Int = 13,
        interSequenceSilenceSeconds: Double = 0.03,
        lowFrequency: Double = 700,
        highFrequency: Double = 10_000,
        fadeSeconds: Double = 0.003,
        level: Double = pow(10, -12 / 20)
    ) {
        self.golayOrder = golayOrder
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

        guard golayOrder > 0, interSequenceSilenceSeconds >= 0, fadeSeconds >= 0 else {
            throw CalibrationSignalError.invalidDuration
        }
        guard level > 0, level <= 1.0 else { throw CalibrationSignalError.invalidLevel }

        // An order-13 pair is 8192 chips: 170.7 ms at 48 kHz without a
        // zero-order hold that would introduce a 6 kHz spectral null.
        let silenceCount = Int((interSequenceSilenceSeconds * sampleRate).rounded())
        let chipsA = Self.golay(order: golayOrder).0
        let chipsB = Self.golay(order: golayOrder).1
        let rawA = chipsA
        let rawB = chipsB
        let sequenceDuration = Double(chipsA.count) / sampleRate
        guard fadeSeconds * 2 <= sequenceDuration else { throw CalibrationSignalError.invalidDuration }
        let filteredA = Self.bandLimit(rawA, sampleRate: sampleRate, low: lowFrequency, high: highFrequency, fadeSeconds: fadeSeconds)
        let filteredB = Self.bandLimit(rawB, sampleRate: sampleRate, low: lowFrequency, high: highFrequency, fadeSeconds: fadeSeconds)
        let peak = max(filteredA.map { abs($0) }.max() ?? 0, filteredB.map { abs($0) }.max() ?? 0)
        let scale = peak > 0 ? Float(level) / peak : 0
        let a = filteredA.map { $0 * scale }
        let b = filteredB.map { $0 * scale }
        let samples = a + [Float](repeating: 0, count: silenceCount) + b
        return CalibrationSignal(samples: samples, sampleRate: sampleRate, complementarySequences: (a, b), interSequenceSilenceSamples: silenceCount)
    }

    public static func rawPair(order: Int = 13) -> ([Float], [Float]) {
        golay(order: order)
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

    private static func bandLimit(_ input: [Float], sampleRate: Double, low: Double, high: Double, fadeSeconds: Double) -> [Float] {
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
            output[index] = Float(sum)
        }
        let fadeCount = min(Int((fadeSeconds * sampleRate).rounded()), output.count / 2)
        for index in 0..<fadeCount {
            let envelope = 0.5 - 0.5 * cos(.pi * Double(index) / Double(fadeCount))
            output[index] *= Float(envelope)
            output[output.count - 1 - index] *= Float(envelope)
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
