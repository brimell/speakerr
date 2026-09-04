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
}
