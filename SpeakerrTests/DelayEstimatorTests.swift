import XCTest
@testable import SpeakerrAudio

final class DelayEstimatorTests: XCTestCase {
    private let estimator = NormalizedCrossCorrelationEstimator()

    func testCleanDelaysAtMultipleSampleRates() throws {
        for rate in [44_100.0, 48_000.0] {
            for milliseconds in [0.0, 10, 68, 73.5, 150, 300] {
                let reference = try LogarithmicChirpGenerator(durationSeconds: 0.08).generate(sampleRate: rate).samples
                let recording = syntheticRecording(reference: reference, sampleRate: rate, delayMilliseconds: milliseconds)
                let estimate = try estimator.estimateDelay(reference: reference, recording: recording, sampleRate: rate)
                XCTAssertEqual(estimate.milliseconds, milliseconds, accuracy: 0.04, "rate=\(rate), delay=\(milliseconds)")
                XCTAssertGreaterThan(estimate.confidence, 0.8)
            }
        }
    }

    func testGainAndModerateNoise() throws {
        let rate = 44_100.0
        let reference = try LogarithmicChirpGenerator(durationSeconds: 0.1).generate(sampleRate: rate).samples
        let recording = syntheticRecording(reference: reference, sampleRate: rate, delayMilliseconds: 73.5, gain: 0.08, noiseAmplitude: 0.002)
        let estimate = try estimator.estimateDelay(reference: reference, recording: recording, sampleRate: rate)
        XCTAssertEqual(estimate.milliseconds, 73.5, accuracy: 0.08)
        XCTAssertGreaterThan(estimate.confidence, 0.45)
    }

    func testDirectArrivalWinsWithRoomReflections() throws {
        let rate = 48_000.0
        let reference = try LogarithmicChirpGenerator(durationSeconds: 0.1).generate(sampleRate: rate).samples
        let recording = syntheticRecording(
            reference: reference,
            sampleRate: rate,
            delayMilliseconds: 73.5,
            gain: 0.5,
            noiseAmplitude: 0.002,
            reflections: [(17, decibelsToGain(-8)), (41, decibelsToGain(-13))]
        )
        let estimate = try estimator.estimateDelay(reference: reference, recording: recording, sampleRate: rate)
        XCTAssertEqual(estimate.milliseconds, 73.5, accuracy: 0.12)
    }

    func testFractionalDelayInterpolation() throws {
        let rate = 44_100.0
        let reference = try LogarithmicChirpGenerator(durationSeconds: 0.1).generate(sampleRate: rate).samples
        let recording = syntheticRecording(reference: reference, sampleRate: rate, delayMilliseconds: 68.337)
        let estimate = try estimator.estimateDelay(reference: reference, recording: recording, sampleRate: rate)
        XCTAssertEqual(estimate.milliseconds, 68.337, accuracy: 0.025)
    }

    func testWeakSignalIsRejected() throws {
        let reference = try LogarithmicChirpGenerator(durationSeconds: 0.05).generate(sampleRate: 44_100).samples
        XCTAssertThrowsError(try estimator.estimateDelay(reference: reference, recording: [Float](repeating: 0, count: reference.count + 1_000), sampleRate: 44_100)) {
            XCTAssertEqual($0 as? DelayEstimatorError, .signalTooWeak)
        }
    }

    func testAmbiguousCompetingPeaksAreRejected() throws {
        let rate = 44_100.0
        let reference = try LogarithmicChirpGenerator(durationSeconds: 0.08).generate(sampleRate: rate).samples
        var recording = syntheticRecording(reference: reference, sampleRate: rate, delayMilliseconds: 40, tailMilliseconds: 150)
        add(reference, to: &recording, at: Int(100 * rate / 1_000), gain: 1)
        let candidate = try estimator.estimateDelay(reference: reference, recording: recording, sampleRate: rate)
        XCTAssertFalse(candidate.accepted)
        XCTAssertEqual(candidate.rejectionReason, .lowConfidence)
        XCTAssertTrue(candidate.milliseconds.isFinite)

    }

    func testGolayPairUsesSignedCombinedResponseWithFractionalDelay() throws {
        let rate = 48_000.0
        let signal = try GolayComplementaryPairGenerator().generate(sampleRate: rate)
        let pair = signal.complementarySequences!
        let delay = 1234.25
        var recording = [Float](repeating: 0, count: Int(delay) + signal.samples.count + 2_000)
        addFractional(signal.samples, to: &recording, at: delay, gain: 0.35)
        let estimate = try estimator.estimateDelay(
            referenceA: pair.0,
            referenceB: pair.1,
            recording: recording,
            sampleRate: rate,
            interSequenceSilenceSamples: signal.interSequenceSilenceSamples
        )
        XCTAssertEqual(estimate.sampleOffset, delay, accuracy: 0.08)
        XCTAssertGreaterThan(estimate.confidence, 0.8)
    }

    func testGolayPairHandlesNoiseAndMultipath() throws {
        let rate = 48_000.0
        let signal = try GolayComplementaryPairGenerator().generate(sampleRate: rate)
        let pair = signal.complementarySequences!
        let delay = 876.4
        var recording = [Float](repeating: 0, count: Int(ceil(delay)) + signal.samples.count + 4_000)
        addFractional(signal.samples, to: &recording, at: delay, gain: 0.2)
        addFractional(signal.samples, to: &recording, at: delay + 31.7 * rate / 1_000, gain: 0.2 * decibelsToGain(-9))
        addFractional(signal.samples, to: &recording, at: delay + 68.2 * rate / 1_000, gain: 0.2 * decibelsToGain(-14))
        addNoise(to: &recording, amplitude: 0.001)

        let estimate = try estimator.estimateDelay(
            referenceA: pair.0,
            referenceB: pair.1,
            recording: recording,
            sampleRate: rate,
            interSequenceSilenceSamples: signal.interSequenceSilenceSamples
        )
        XCTAssertEqual(estimate.sampleOffset, delay, accuracy: 0.15)
        XCTAssertGreaterThan(estimate.confidence, 0.65)
    }

    func testSearchWindowRestrictsCandidate() throws {
        let rate = 44_100.0
        let reference = try LogarithmicChirpGenerator(durationSeconds: 0.05).generate(sampleRate: rate).samples
        var recording = syntheticRecording(reference: reference, sampleRate: rate, delayMilliseconds: 20, tailMilliseconds: 150)
        add(reference, to: &recording, at: Int(100 * rate / 1_000), gain: 0.8)
        let estimate = try estimator.estimateDelay(reference: reference, recording: recording, sampleRate: rate, searchRange: Int(80 * rate / 1_000)..<Int(120 * rate / 1_000))
        XCTAssertEqual(estimate.milliseconds, 100, accuracy: 0.04)
    }

    private func syntheticRecording(
        reference: [Float],
        sampleRate: Double,
        delayMilliseconds: Double,
        tailMilliseconds: Double = 100,
        gain: Float = 1,
        noiseAmplitude: Float = 0,
        reflections: [(milliseconds: Double, gain: Float)] = []
    ) -> [Float] {
        let exactDelay = delayMilliseconds * sampleRate / 1_000
        let count = Int(ceil(exactDelay)) + reference.count + Int(tailMilliseconds * sampleRate / 1_000)
        var recording = [Float](repeating: 0, count: count)
        addFractional(reference, to: &recording, at: exactDelay, gain: gain)
        for reflection in reflections {
            addFractional(reference, to: &recording, at: exactDelay + reflection.milliseconds * sampleRate / 1_000, gain: gain * reflection.gain)
        }
        if noiseAmplitude > 0 {
            var state: UInt64 = 0x1234_5678_9ABC_DEF0
            for index in recording.indices {
                state = state &* 6364136223846793005 &+ 1
                let unit = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
                recording[index] += (unit * 2 - 1) * noiseAmplitude
            }
        }
        return recording
    }

    private func addFractional(_ signal: [Float], to recording: inout [Float], at offset: Double, gain: Float) {
        let integer = Int(floor(offset))
        let fraction = Float(offset - Double(integer))
        for index in signal.indices {
            if integer + index < recording.count { recording[integer + index] += signal[index] * gain * (1 - fraction) }
            if integer + index + 1 < recording.count { recording[integer + index + 1] += signal[index] * gain * fraction }
        }
    }

    private func add(_ signal: [Float], to recording: inout [Float], at offset: Int, gain: Float) {
        for index in signal.indices where offset + index < recording.count { recording[offset + index] += signal[index] * gain }
    }

    private func decibelsToGain(_ decibels: Double) -> Float { Float(pow(10, decibels / 20)) }

    private func addNoise(to recording: inout [Float], amplitude: Float) {
        var state: UInt64 = 0xD1CE_BA5E_1234_5678
        for index in recording.indices {
            state = state &* 6364136223846793005 &+ 1
            let unit = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
            recording[index] += (unit * 2 - 1) * amplitude
        }
    }
}
