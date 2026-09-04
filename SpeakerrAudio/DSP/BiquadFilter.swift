import Foundation

/// Biquad filter for parametric EQ
/// Based on Audio EQ Cookbook by Robert Bristow-Johnson
public final class BiquadFilter: @unchecked Sendable {
    private var b0: Float = 1.0
    private var b1: Float = 0.0
    private var b2: Float = 0.0
    private var a1: Float = 0.0
    private var a2: Float = 0.0

    // State variables for filtering (per channel)
    private var x1: [Float] = [0, 0]  // x[n-1] for each channel
    private var x2: [Float] = [0, 0]  // x[n-2] for each channel
    private var y1: [Float] = [0, 0]  // y[n-1] for each channel
    private var y2: [Float] = [0, 0]  // y[n-2] for each channel

    public var type: EQFilterType = .peak
    public var frequency: Float = 1000
    public var gain: Float = 0  // in dB
    public var q: Float = 1.0
    public var sampleRate: Float = 48000

    public init() {}

    public func configure(with band: EQBand, sampleRate: Float) {
        type = band.type
        frequency = band.frequency
        gain = band.gain
        q = band.q
        self.sampleRate = sampleRate
        updateCoefficients()
    }

    /// Calculate coefficients for the configured filter type.
    public func updateCoefficients() {
        let limitedSampleRate = max(8000.0, sampleRate)
        let nyquist = (limitedSampleRate * 0.5) - 1.0
        let limitedFrequency = max(20.0, min(frequency, nyquist))
        let limitedQ = max(0.05, q)
        let limitedGain = max(-24.0, min(24.0, gain))

        let A = powf(10, limitedGain / 40.0)  // amplitude
        let omega = 2.0 * Float.pi * limitedFrequency / limitedSampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2.0 * limitedQ)
        let sqrtA = sqrt(A)

        var b0Raw: Float = 1.0
        var b1Raw: Float = 0.0
        var b2Raw: Float = 0.0
        var a0Raw: Float = 1.0
        var a1Raw: Float = 0.0
        var a2Raw: Float = 0.0

        switch type {
        case .peak:
            if abs(limitedGain) < 0.01 {
                b0 = 1.0
                b1 = 0.0
                b2 = 0.0
                a1 = 0.0
                a2 = 0.0
                return
            }

            b0Raw = 1.0 + alpha * A
            b1Raw = -2.0 * cosOmega
            b2Raw = 1.0 - alpha * A
            a0Raw = 1.0 + alpha / A
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha / A

        case .lowShelf:
            if abs(limitedGain) < 0.01 {
                b0 = 1.0
                b1 = 0.0
                b2 = 0.0
                a1 = 0.0
                a2 = 0.0
                return
            }

            b0Raw = A * ((A + 1.0) - (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha)
            b1Raw = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosOmega)
            b2Raw = A * ((A + 1.0) - (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha)
            a0Raw = (A + 1.0) + (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha
            a1Raw = -2.0 * ((A - 1.0) + (A + 1.0) * cosOmega)
            a2Raw = (A + 1.0) - (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha

        case .highShelf:
            if abs(limitedGain) < 0.01 {
                b0 = 1.0
                b1 = 0.0
                b2 = 0.0
                a1 = 0.0
                a2 = 0.0
                return
            }

            b0Raw = A * ((A + 1.0) + (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha)
            b1Raw = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosOmega)
            b2Raw = A * ((A + 1.0) + (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha)
            a0Raw = (A + 1.0) - (A - 1.0) * cosOmega + 2.0 * sqrtA * alpha
            a1Raw = 2.0 * ((A - 1.0) - (A + 1.0) * cosOmega)
            a2Raw = (A + 1.0) - (A - 1.0) * cosOmega - 2.0 * sqrtA * alpha

        case .lowPass:
            b0Raw = (1.0 - cosOmega) * 0.5
            b1Raw = 1.0 - cosOmega
            b2Raw = (1.0 - cosOmega) * 0.5
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha

        case .highPass:
            b0Raw = (1.0 + cosOmega) * 0.5
            b1Raw = -(1.0 + cosOmega)
            b2Raw = (1.0 + cosOmega) * 0.5
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha

        case .notch:
            b0Raw = 1.0
            b1Raw = -2.0 * cosOmega
            b2Raw = 1.0
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha

        case .bandPass:
            b0Raw = alpha
            b1Raw = 0.0
            b2Raw = -alpha
            a0Raw = 1.0 + alpha
            a1Raw = -2.0 * cosOmega
            a2Raw = 1.0 - alpha
        }

        let safeA0 = abs(a0Raw) < 1e-8 ? 1.0 : a0Raw
        b0 = b0Raw / safeA0
        b1 = b1Raw / safeA0
        b2 = b2Raw / safeA0
        a1 = a1Raw / safeA0
        a2 = a2Raw / safeA0
    }

    /// Process a single sample for a given channel
    public func process(sample: Float, channel: Int) -> Float {
        let ch = min(channel, 1)

        // Direct Form II Transposed
        let output = b0 * sample + b1 * x1[ch] + b2 * x2[ch] - a1 * y1[ch] - a2 * y2[ch]

        // Update state
        x2[ch] = x1[ch]
        x1[ch] = sample
        y2[ch] = y1[ch]
        y1[ch] = output

        return output
    }

    /// Reset filter state
    public func reset() {
        x1 = [0, 0]
        x2 = [0, 0]
        y1 = [0, 0]
        y2 = [0, 0]
    }
}

/// Multi-band parametric EQ using biquad filters
public final class ParametricEQ: @unchecked Sendable {
    private var filters: [BiquadFilter] = []
    private var enabledFilters: [BiquadFilter] = []
    private var activeBands: [EQBand] = []
    private var pendingBands: [EQBand]?
    private var filtersEnabled = true
    private var pendingFiltersEnabled: Bool?
    private var preGainDB: Float = 0.0
    private var preGainLinear: Float = 1.0
    private var pendingPreGainDB: Float?
    private let updateLock = NSLock()
    private var sampleRate: Float = 48000
    public var bypass: Bool = false

    public init(sampleRate: Double, bands: [EQBand] = EQBand.defaultTenBand) {
        self.sampleRate = Float(sampleRate)
        applyBandsImmediately(bands)
    }

    public func setBands(_ bands: [EQBand]) {
        updateLock.lock()
        pendingBands = bands
        updateLock.unlock()
    }

    public func setGain(band: Int, gain: Float) {
        guard activeBands.indices.contains(band) else { return }
        var updated = activeBands
        updated[band].gain = gain
        setBands(updated)
    }

    public func setAllGains(_ gains: [Float]) {
        var updated = activeBands
        for index in updated.indices where index < gains.count {
            updated[index].gain = gains[index]
        }
        setBands(updated)
    }

    public func setPreGain(_ gain: Float) {
        updateLock.lock()
        pendingPreGainDB = max(-12.0, min(0.0, gain))
        updateLock.unlock()
    }

    public func setFiltersEnabled(_ enabled: Bool) {
        updateLock.lock()
        pendingFiltersEnabled = enabled
        updateLock.unlock()
    }

    /// Process audio buffer in place
    public func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard !bypass else { return }

        applyPendingUpdatesIfNeeded()

        if !filtersEnabled {
            return
        }

        for frame in 0..<frameCount {
            var sample = buffer[frame] * preGainLinear

            // Apply each enabled filter in series.
            for filter in enabledFilters {
                sample = filter.process(sample: sample, channel: channel)
            }

            buffer[frame] = sample
        }
    }

    public func reset() {
        for filter in filters {
            filter.reset()
        }
    }

    private func applyPendingUpdatesIfNeeded() {
        updateLock.lock()
        let nextBands = pendingBands
        let nextFiltersEnabled = pendingFiltersEnabled
        let nextPreGainDB = pendingPreGainDB
        pendingBands = nil
        pendingFiltersEnabled = nil
        pendingPreGainDB = nil
        updateLock.unlock()

        if let nextFiltersEnabled {
            filtersEnabled = nextFiltersEnabled
            rebuildEnabledFilters()
        }

        if let nextPreGainDB {
            preGainDB = nextPreGainDB
            preGainLinear = powf(10.0, preGainDB / 20.0)
        }

        guard let nextBands else { return }
        applyBandsImmediately(nextBands)
    }

    private func applyBandsImmediately(_ bands: [EQBand]) {
        let normalizedBands = bands.isEmpty ? EQBand.defaultTenBand : bands

        if filters.count != normalizedBands.count {
            filters = normalizedBands.map { _ in BiquadFilter() }
            for filter in filters {
                filter.reset()
            }
        }

        activeBands = normalizedBands

        for index in activeBands.indices {
            filters[index].configure(with: activeBands[index], sampleRate: sampleRate)
        }

        rebuildEnabledFilters()
    }

    private func rebuildEnabledFilters() {
        guard filtersEnabled else {
            enabledFilters = []
            return
        }

        var updatedEnabledFilters: [BiquadFilter] = []
        updatedEnabledFilters.reserveCapacity(filters.count)

        for index in activeBands.indices where activeBands[index].isEnabled {
            updatedEnabledFilters.append(filters[index])
        }

        enabledFilters = updatedEnabledFilters
    }

    public func updateSampleRate(_ newSampleRate: Double) {
        sampleRate = Float(newSampleRate)
        for (index, band) in activeBands.enumerated() {
            filters[index].configure(with: band, sampleRate: sampleRate)
        }
    }

    public func response(at frequency: Float) -> Float {
        var totalResponseDB: Float = 0

        for (index, band) in activeBands.enumerated() {
            guard band.isEnabled else { continue }
            let filter = filters[index]
            totalResponseDB += calculateFilterResponse(filter: filter, frequency: frequency)
        }

        return totalResponseDB
    }

    private func calculateFilterResponse(filter: BiquadFilter, frequency: Float) -> Float {
        let nyquist = sampleRate * 0.5
        guard frequency > 0 && frequency < nyquist else { return 0 }

        let omega = 2.0 * Float.pi * frequency / sampleRate
        let phi = powf(sin(omega / 2.0), 2.0)

        let band = EQBand(type: filter.type, frequency: filter.frequency, gain: filter.gain, q: filter.q)
        let tempFilter = BiquadFilter()
        tempFilter.configure(with: band, sampleRate: sampleRate)

        let limitedSampleRate = max(8000.0, sampleRate)
        let limitedFreq = max(20.0, min(filter.frequency, (limitedSampleRate * 0.5) - 1.0))
        let limitedQ = max(0.05, filter.q)
        let limitedGain = max(-24.0, min(24.0, filter.gain))

        let A = powf(10, limitedGain / 40.0)
        let w0 = 2.0 * Float.pi * limitedFreq / limitedSampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * limitedQ)

        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a0: Float = 1, a1: Float = 0, a2: Float = 0

        switch filter.type {
        case .peak:
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosW0
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha / A
        case .lowShelf:
            let sqrtA = sqrt(A)
            b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha)
            a0 = (A + 1.0) + (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
            a2 = (A + 1.0) - (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha
        case .highShelf:
            let sqrtA = sqrt(A)
            b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha)
            a0 = (A + 1.0) - (A - 1.0) * cosW0 + 2.0 * sqrtA * alpha
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
            a2 = (A + 1.0) - (A - 1.0) * cosW0 - 2.0 * sqrtA * alpha
        case .lowPass:
            b0 = (1.0 - cosW0) * 0.5
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .highPass:
            b0 = (1.0 + cosW0) * 0.5
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .notch:
            b0 = 1.0
            b1 = -2.0 * cosW0
            b2 = 1.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .bandPass:
            b0 = alpha
            b1 = 0.0
            b2 = -alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        }

        let num = powf(b0 + b1 + b2, 2.0) - 4.0 * (b0 * b1 + 4.0 * b0 * b2 + b1 * b2) * phi + 16.0 * b0 * b2 * phi * phi
        let den = powf(a0 + a1 + a2, 2.0) - 4.0 * (a0 * a1 + 4.0 * a0 * a2 + a1 * a2) * phi + 16.0 * a0 * a2 * phi * phi

        guard den > 0 && num > 0 else { return 0 }

        let h2 = num / den
        return 10.0 * log10f(max(h2, 1e-10))
    }
}

/// Lightweight stereo-linked limiter used as the final output safety stage.
public final class OutputLimiter: @unchecked Sendable {
    private let sampleRate: Float
    private var ceilingDB: Float
    private var ceilingLinear: Float
    private var currentGain: Float = 1.0

    // Conservative defaults: fast attack, moderate release.
    private let attackMs: Float = 1.5
    private let releaseMs: Float = 80.0
    private let attackCoeff: Float
    private let releaseCoeff: Float

    public init(sampleRate: Float, ceilingDB: Float = -1.0) {
        self.sampleRate = max(8_000.0, sampleRate)
        self.attackCoeff = expf(-1.0 / (attackMs * 0.001 * self.sampleRate))
        self.releaseCoeff = expf(-1.0 / (releaseMs * 0.001 * self.sampleRate))
        let clampedCeiling = max(-6.0, min(-0.1, ceilingDB))
        self.ceilingDB = clampedCeiling
        self.ceilingLinear = powf(10.0, clampedCeiling / 20.0)
    }

    public func setCeilingDB(_ value: Float) {
        let clamped = max(-6.0, min(-0.1, value))
        guard clamped != ceilingDB else { return }
        ceilingDB = clamped
        ceilingLinear = powf(10.0, ceilingDB / 20.0)
    }

    public func process(left: Float, right: Float) -> (left: Float, right: Float, wasLimited: Bool) {
        let stereoPeak = max(max(fabsf(left), fabsf(right)), 1e-9)
        let desiredGain = min(1.0, ceilingLinear / stereoPeak)

        if desiredGain < currentGain {
            currentGain = (attackCoeff * currentGain) + ((1.0 - attackCoeff) * desiredGain)
        } else {
            currentGain = (releaseCoeff * currentGain) + ((1.0 - releaseCoeff) * desiredGain)
        }

        var outLeft = left * currentGain
        var outRight = right * currentGain

        // Final hard safety clamp at the configured ceiling.
        outLeft = max(-ceilingLinear, min(ceilingLinear, outLeft))
        outRight = max(-ceilingLinear, min(ceilingLinear, outRight))

        let wasLimited = desiredGain < 0.9999 || currentGain < 0.9999
        return (outLeft, outRight, wasLimited)
    }

    public func reset() {
        currentGain = 1.0
    }
}
