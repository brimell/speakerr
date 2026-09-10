import Foundation

public struct DelayEstimate: Sendable, Equatable, Codable {
    public let sampleOffset: Double
    public let milliseconds: Double
    public let confidence: Double
    public let peakValue: Double
    public let secondBestPeak: Double
    public let peakProminence: Double

    public init(sampleOffset: Double, sampleRate: Double, confidence: Double, peakValue: Double, secondBestPeak: Double, peakProminence: Double) {
        self.sampleOffset = sampleOffset
        milliseconds = sampleOffset * 1_000 / sampleRate
        self.confidence = confidence
        self.peakValue = peakValue
        self.secondBestPeak = secondBestPeak
        self.peakProminence = peakProminence
    }
}

public struct DelayCorrelationDiagnostics: Sendable, Equatable {
    public let sampleOffset: Double
    public let peakIndex: Int
    public let searchRange: Range<Int>
    public let peakValue: Double
    public let secondBestPeak: Double
    public let peakProminence: Double
    public let confidence: Double
    public let peakScore: Double
    public let prominenceScore: Double
    public let aPeak: Double
    public let bPeak: Double
    public let signedCombinedPeak: Double
    public let correlations: [Double]
    public let aCorrelations: [Double]
    public let bCorrelations: [Double]

    public var candidateNearSearchBoundary: Bool {
        peakIndex == searchRange.lowerBound || peakIndex + 1 >= searchRange.upperBound
    }
}

public enum DelayEstimatorError: LocalizedError, Equatable {
    case invalidSampleRate
    case insufficientRecording
    case invalidSearchWindow
    case signalTooWeak
    case lowConfidence(confidence: Double, peak: Double, secondBestPeak: Double, prominence: Double, sampleOffset: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidSampleRate: "Delay-estimator sample rate must be positive."
        case .insufficientRecording: "The recording is shorter than the calibration signal."
        case .invalidSearchWindow: "The requested correlation search window contains no complete signal."
        case .signalTooWeak: "The microphone signal is too weak for calibration."
        case .lowConfidence(let confidence, let peak, let secondBestPeak, let prominence, let sampleOffset):
            "Correlation confidence is too low (confidence=\(String(format: "%.2f", confidence)), peak=\(String(format: "%.3f", peak)), secondBest=\(String(format: "%.3f", secondBestPeak)), prominence=\(String(format: "%.2f", prominence)), offset=\(String(format: "%.1f", sampleOffset)) samples)."
        }
    }
}

public protocol DelayEstimator: Sendable {
    func estimateDelay(reference: [Float], recording: [Float], sampleRate: Double, searchRange: Range<Int>?) throws -> DelayEstimate
}

public struct NormalizedCrossCorrelationEstimator: DelayEstimator, Sendable {
    public let minimumPeak: Double
    public let minimumProminence: Double
    public let minimumConfidence: Double
    public let exclusionMilliseconds: Double

    public init(minimumPeak: Double = 0.12, minimumProminence: Double = 1.08, minimumConfidence: Double = 0.35, exclusionMilliseconds: Double = 12) {
        self.minimumPeak = minimumPeak
        self.minimumProminence = minimumProminence
        self.minimumConfidence = minimumConfidence
        self.exclusionMilliseconds = exclusionMilliseconds
    }

    public func estimateDelay(
        referenceA: [Float],
        referenceB: [Float],
        recording: [Float],
        sampleRate: Double,
        interSequenceSilenceSamples: Int,
        searchRange: Range<Int>? = nil
    ) throws -> DelayEstimate {
        let diagnostics = try diagnoseDelay(referenceA: referenceA, referenceB: referenceB, recording: recording, sampleRate: sampleRate, interSequenceSilenceSamples: interSequenceSilenceSamples, searchRange: searchRange)
        let estimate = DelayEstimate(sampleOffset: diagnostics.sampleOffset, sampleRate: sampleRate, confidence: diagnostics.confidence, peakValue: diagnostics.peakValue, secondBestPeak: diagnostics.secondBestPeak, peakProminence: diagnostics.peakProminence)
        guard diagnostics.peakValue >= minimumPeak, diagnostics.peakProminence >= minimumProminence, diagnostics.confidence >= minimumConfidence else {
            throw DelayEstimatorError.lowConfidence(confidence: diagnostics.confidence, peak: diagnostics.peakValue, secondBestPeak: diagnostics.secondBestPeak, prominence: diagnostics.peakProminence, sampleOffset: estimate.sampleOffset)
        }
        return estimate
    }

    public func diagnoseDelay(
        referenceA: [Float],
        referenceB: [Float],
        recording: [Float],
        sampleRate: Double,
        interSequenceSilenceSamples: Int,
        searchRange: Range<Int>? = nil
    ) throws -> DelayCorrelationDiagnostics {
        guard referenceA.count == referenceB.count, !referenceA.isEmpty else {
            throw DelayEstimatorError.insufficientRecording
        }
        let combinedLength = referenceA.count * 2 + max(0, interSequenceSilenceSamples)
        guard recording.count >= combinedLength else { throw DelayEstimatorError.insufficientRecording }
        let maximumStart = recording.count - combinedLength + 1
        let requested = searchRange ?? 0..<maximumStart
        let lower = max(0, requested.lowerBound)
        let upper = min(maximumStart, requested.upperBound)
        guard lower < upper else { throw DelayEstimatorError.invalidSearchWindow }

        let first = correlationSeries(reference: referenceA, recording: recording, lower: lower, upper: upper)
        let secondLower = lower + referenceA.count + max(0, interSequenceSilenceSamples)
        let secondUpper = upper + referenceA.count + max(0, interSequenceSilenceSamples)
        let second = correlationSeries(reference: referenceB, recording: recording, lower: secondLower, upper: secondUpper)
        let combinedReferenceEnergy = first.referenceEnergy + second.referenceEnergy
        let aCorrelations = first.numerators.indices.map { index in
            let denominator = sqrt(first.referenceEnergy * first.recordingEnergies[index])
            return denominator > 1e-12 ? abs(first.numerators[index] / denominator) : 0
        }
        let bCorrelations = second.numerators.indices.map { index in
            let denominator = sqrt(second.referenceEnergy * second.recordingEnergies[index])
            return denominator > 1e-12 ? abs(second.numerators[index] / denominator) : 0
        }
        let correlations = first.numerators.indices.map { index in
            let combinedRecordingEnergy = first.recordingEnergies[index] + second.recordingEnergies[index]
            let denominator = sqrt(combinedReferenceEnergy * combinedRecordingEnergy)
            let numerator = first.numerators[index] + second.numerators[index]
            return denominator > 1e-12 ? abs(numerator / denominator) : 0
        }
        guard let peakIndex = correlations.indices.max(by: { correlations[$0] < correlations[$1] }) else {
            throw DelayEstimatorError.invalidSearchWindow
        }
        let peak = correlations[peakIndex]
        let exclusion = max(1, Int((exclusionMilliseconds * sampleRate / 1_000).rounded()))
        let secondBest = correlations.indices
            .filter { abs($0 - peakIndex) > exclusion }
            .map { correlations[$0] }
            .max() ?? 0
        let prominence = peak / max(secondBest, 1e-9)
        let peakScore = min(1, max(0, (peak - minimumPeak) / max(1e-9, 1 - minimumPeak)))
        let prominenceScore = min(1, max(0, (prominence - 1) / 0.5))
        let confidence = 0.75 * peakScore + 0.25 * prominenceScore
        var fractionalIndex = Double(peakIndex)
        if peakIndex > 0, peakIndex + 1 < correlations.count {
            let left = correlations[peakIndex - 1]
            let center = correlations[peakIndex]
            let right = correlations[peakIndex + 1]
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-12 {
                let offset = 0.5 * (left - right) / denominator
                fractionalIndex += max(-0.5, min(0.5, offset))
            }
        }
        let candidateIndex = lower + peakIndex
        let combinedDenominator = sqrt(combinedReferenceEnergy * (first.recordingEnergies[candidateIndex - lower] + second.recordingEnergies[candidateIndex - lower]))
        let signedCombinedPeak = combinedDenominator > 1e-12
            ? (first.numerators[peakIndex - lower] + second.numerators[peakIndex - lower]) / combinedDenominator
            : 0
        return DelayCorrelationDiagnostics(
            sampleOffset: Double(lower) + fractionalIndex,
            peakIndex: candidateIndex,
            searchRange: lower..<upper,
            peakValue: peak,
            secondBestPeak: secondBest,
            peakProminence: prominence,
            confidence: confidence,
            peakScore: peakScore,
            prominenceScore: prominenceScore,
            aPeak: aCorrelations[candidateIndex - lower],
            bPeak: bCorrelations[candidateIndex - lower],
            signedCombinedPeak: signedCombinedPeak,
            correlations: correlations,
            aCorrelations: aCorrelations,
            bCorrelations: bCorrelations
        )
    }

    public func estimateDelay(from diagnostics: DelayCorrelationDiagnostics, sampleRate: Double) throws -> DelayEstimate {
        let estimate = DelayEstimate(sampleOffset: diagnostics.sampleOffset, sampleRate: sampleRate, confidence: diagnostics.confidence, peakValue: diagnostics.peakValue, secondBestPeak: diagnostics.secondBestPeak, peakProminence: diagnostics.peakProminence)
        guard diagnostics.peakValue >= minimumPeak, diagnostics.peakProminence >= minimumProminence, diagnostics.confidence >= minimumConfidence else {
            throw DelayEstimatorError.lowConfidence(confidence: diagnostics.confidence, peak: diagnostics.peakValue, secondBestPeak: diagnostics.secondBestPeak, prominence: diagnostics.peakProminence, sampleOffset: estimate.sampleOffset)
        }
        return estimate
    }

    public func estimateDelay(reference: [Float], recording: [Float], sampleRate: Double, searchRange: Range<Int>? = nil) throws -> DelayEstimate {
        guard sampleRate > 0 else { throw DelayEstimatorError.invalidSampleRate }
        guard !reference.isEmpty, recording.count >= reference.count else { throw DelayEstimatorError.insufficientRecording }
        let maximumStart = recording.count - reference.count + 1
        let requested = searchRange ?? 0..<maximumStart
        let lower = max(0, requested.lowerBound)
        let upper = min(maximumStart, requested.upperBound)
        guard lower < upper else { throw DelayEstimatorError.invalidSearchWindow }

        let referenceDouble = reference.map(Double.init)
        let referenceMean = referenceDouble.reduce(0, +) / Double(referenceDouble.count)
        let centeredReference = referenceDouble.map { $0 - referenceMean }
        let referenceEnergy = centeredReference.reduce(0) { $0 + $1 * $1 }
        guard referenceEnergy > 1e-12 else { throw DelayEstimatorError.signalTooWeak }

        let recordingDouble = recording.map(Double.init)
        let convolution = FFT.convolve(recordingDouble, centeredReference.reversed())
        var prefix = [Double](repeating: 0, count: recordingDouble.count + 1)
        var prefixSquares = [Double](repeating: 0, count: recordingDouble.count + 1)
        for index in recordingDouble.indices {
            prefix[index + 1] = prefix[index] + recordingDouble[index]
            prefixSquares[index + 1] = prefixSquares[index] + recordingDouble[index] * recordingDouble[index]
        }

        var correlations = [Double](repeating: 0, count: upper - lower)
        let length = Double(reference.count)
        var recordingEnergyMaximum = 0.0
        for start in lower..<upper {
            let sum = prefix[start + reference.count] - prefix[start]
            let squares = prefixSquares[start + reference.count] - prefixSquares[start]
            let centeredEnergy = max(0, squares - sum * sum / length)
            recordingEnergyMaximum = max(recordingEnergyMaximum, centeredEnergy / length)
            let numerator = convolution[start + reference.count - 1]
            let denominator = sqrt(referenceEnergy * centeredEnergy)
            correlations[start - lower] = denominator > 1e-12 ? abs(numerator / denominator) : 0
        }
        guard recordingEnergyMaximum > 1e-10 else { throw DelayEstimatorError.signalTooWeak }

        guard let localPeakIndex = correlations.indices.max(by: { correlations[$0] < correlations[$1] }) else {
            throw DelayEstimatorError.invalidSearchWindow
        }
        let peak = correlations[localPeakIndex]
        let exclusion = max(1, Int((exclusionMilliseconds * sampleRate / 1_000).rounded()))
        var secondBest = 0.0
        for index in correlations.indices where abs(index - localPeakIndex) > exclusion {
            secondBest = max(secondBest, correlations[index])
        }
        let prominence = peak / max(secondBest, 1e-9)
        let peakScore = min(1, max(0, (peak - minimumPeak) / max(1e-9, 1 - minimumPeak)))
        let prominenceScore = min(1, max(0, (prominence - 1) / 0.5))
        let confidence = 0.75 * peakScore + 0.25 * prominenceScore

        var fractionalIndex = Double(localPeakIndex)
        if localPeakIndex > 0, localPeakIndex + 1 < correlations.count {
            let left = correlations[localPeakIndex - 1]
            let center = correlations[localPeakIndex]
            let right = correlations[localPeakIndex + 1]
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-12 {
                fractionalIndex += max(-0.5, min(0.5, 0.5 * (left - right) / denominator))
            }

        }
        let estimate = DelayEstimate(
            sampleOffset: Double(lower) + fractionalIndex,
            sampleRate: sampleRate,
            confidence: confidence,
            peakValue: peak,
            secondBestPeak: secondBest,
            peakProminence: prominence
        )
        guard peak >= minimumPeak, prominence >= minimumProminence, confidence >= minimumConfidence else {
            throw DelayEstimatorError.lowConfidence(confidence: confidence, peak: peak, secondBestPeak: secondBest, prominence: prominence, sampleOffset: estimate.sampleOffset)
        }
        return estimate
    }

    private func correlationSeries(reference: [Float], recording: [Float], lower: Int, upper: Int) -> (numerators: [Double], referenceEnergy: Double, recordingEnergies: [Double]) {
        let ref = reference.map(Double.init)
        let mean = ref.reduce(0, +) / Double(ref.count)
        let centered = ref.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        let recordingDouble = recording.map(Double.init)
        let convolution = FFT.convolve(recordingDouble, centered.reversed())
        var prefix = [Double](repeating: 0, count: recording.count + 1)
        var prefixSquares = [Double](repeating: 0, count: recording.count + 1)
        for index in recording.indices {
            prefix[index + 1] = prefix[index] + recordingDouble[index]
            prefixSquares[index + 1] = prefixSquares[index] + recordingDouble[index] * recordingDouble[index]
        }
        var numerators = [Double](repeating: 0, count: upper - lower)
        var recordingEnergies = [Double](repeating: 0, count: upper - lower)
        for start in lower..<upper {
            let sum = prefix[start + ref.count] - prefix[start]
            let squares = prefixSquares[start + ref.count] - prefixSquares[start]
            let centeredEnergy = max(0, squares - sum * sum / Double(ref.count))
            numerators[start - lower] = convolution[start + ref.count - 1]
            recordingEnergies[start - lower] = centeredEnergy
        }
        return (numerators, energy, recordingEnergies)
    }
}
