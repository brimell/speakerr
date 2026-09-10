import CoreAudio
import XCTest
@testable import SpeakerrAudio

final class CalibrationTimingTests: XCTestCase {
    func testCaptureHostTimeMappingRoundTrips() throws {
        let baseHost = AudioConvertNanosToHostTime(2_000_000_000)
        let audio = CapturedAudio(
            samples: [Float](repeating: 0, count: 48_000),
            sampleRate: 48_000,
            anchors: [CaptureTimestampAnchor(sampleIndex: 0, hostTime: baseHost, sampleTime: 10_000)]
        )
        let requestedHost = AudioConvertNanosToHostTime(2_250_000_000)
        let sampleIndex = try audio.sampleIndex(atHostTime: requestedHost)
        XCTAssertEqual(sampleIndex, 12_000, accuracy: 0.01)
        let roundTrip = try audio.hostTime(atSampleIndex: sampleIndex)
        XCTAssertEqual(AudioConvertHostTimeToNanos(roundTrip), 2_250_000_000, accuracy: 2)
    }

    func testExperimentScheduleIsInterleavedAndBounded() throws {
        let configuration = CalibrationExperimentConfiguration()
        try configuration.validate()
        XCTAssertEqual(configuration.eventsPerPass, 10)
        XCTAssertEqual(configuration.passStartSeconds(0), 0.2, accuracy: 0.0001)
        XCTAssertGreaterThan(configuration.passStartSeconds(1), configuration.passStartSeconds(0) + Double(configuration.eventsPerPass - 1) * configuration.intervalSeconds + configuration.chirpDurationSeconds)
    }

    func testUnsafeGainAndOverlappingIntervalsAreRejected() {
        var configuration = CalibrationExperimentConfiguration()
        configuration.level = 0.8
        XCTAssertThrowsError(try configuration.validate())
        configuration = CalibrationExperimentConfiguration(intervalSeconds: 0.1)
        try? configuration.validate()
        XCTAssertThrowsError(try configuration.validateSchedule(signalDurationSeconds: 8_192 * 2 / 44_100 + 0.03))
    }

    func testStabilityPassesUseRequestedOffsets() throws {
        let configuration = CalibrationExperimentConfiguration(stabilityMeasurementOffsetsSeconds: [0, 30, 60, 120, 300])
        try configuration.validate()
        XCTAssertEqual(configuration.totalScheduledPasses, 8)
        let baseline = configuration.passStartSeconds(configuration.maximumPasses)
        XCTAssertEqual(configuration.passStartSeconds(configuration.maximumPasses + 1) - baseline, 30, accuracy: 0.0001)
        XCTAssertEqual(configuration.passStartSeconds(configuration.maximumPasses + 4) - baseline, 300, accuracy: 0.0001)
    }
}
