import XCTest
@testable import SpeakerrAudio

final class CalibrationSignalTests: XCTestCase {
    func testChirpShapeAndDurationAtBothRates() throws {
        let generator = LogarithmicChirpGenerator()
        for rate in [44_100.0, 48_000.0] {
            let signal = try generator.generate(sampleRate: rate)
            XCTAssertEqual(signal.samples.count, Int((0.3 * rate).rounded()))
            XCTAssertEqual(signal.durationSeconds, 0.3, accuracy: 1 / rate)
            XCTAssertTrue(signal.samples.allSatisfy(\.isFinite))
            XCTAssertLessThanOrEqual(signal.samples.map { abs($0) }.max()!, 0.120_001)
            XCTAssertEqual(signal.samples.first!, 0, accuracy: 0.000_001)
            XCTAssertEqual(signal.samples.last!, 0, accuracy: 0.000_001)
        }
    }

    func testChirpIsDeterministicAndDoesNotClip() throws {
        let generator = LogarithmicChirpGenerator(level: 0.2)
        let first = try generator.generate(sampleRate: 44_100)
        let second = try generator.generate(sampleRate: 44_100)
        XCTAssertEqual(first, second)
        XCTAssertLessThan(first.samples.map { abs($0) }.max()!, 1)
    }

    func testInvalidChirpConfigurationIsRejected() {
        XCTAssertThrowsError(try LogarithmicChirpGenerator(endFrequency: 30_000).generate(sampleRate: 44_100))
        XCTAssertThrowsError(try LogarithmicChirpGenerator(level: 1).generate(sampleRate: 44_100))
    }

    func testOrder13GolayPairHasComplementarySidelobes() {
        let (a, b) = GolayComplementaryPairGenerator.rawPair()
        XCTAssertEqual(a.count, 8_192)
        XCTAssertEqual(b.count, 8_192)
        let center = a.count - 1
        for lag in 0..<a.count {
            let aCorrelation = (0..<a.count).compactMap { index -> Float? in
                let other = index + lag
                return other < a.count ? a[index] * a[other] : nil
            }.reduce(0, +)
            let bCorrelation = (0..<b.count).compactMap { index -> Float? in
                let other = index + lag
                return other < b.count ? b[index] * b[other] : nil
            }.reduce(0, +)
            if lag == 0 {
                XCTAssertEqual(aCorrelation + bCorrelation, Float(a.count * 2))
            } else {
                XCTAssertEqual(aCorrelation + bCorrelation, 0, accuracy: 0.001, "lag=\(lag), center=\(center)")
            }
        }
    }

    func testGolaySignalUsesCommonPeakScaleAndExpectedBandDuration() throws {
        let signal = try GolayComplementaryPairGenerator().generate(sampleRate: 48_000)
        let (a, b) = signal.complementarySequences!
        XCTAssertEqual(a.count, 8_192)
        XCTAssertEqual(b.count, 8_192)
        XCTAssertEqual(signal.interSequenceSilenceSamples, 1_440)
        XCTAssertEqual(signal.samples.count, 17_824)
        XCTAssertLessThanOrEqual(max(a.map { abs($0) }.max()!, b.map { abs($0) }.max()!), pow(10, -12 / 20) + 0.0001)
    }
}
