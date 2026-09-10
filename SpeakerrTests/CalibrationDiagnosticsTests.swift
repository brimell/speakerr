import XCTest
@testable import SpeakerrAudio

final class CalibrationDiagnosticsTests: XCTestCase {
    func testCalibrationReportIncludesSummaryAndDrift() throws {
        let measurement = AcousticMeasurement(
            emission: CalibrationEmission(pass: 0, sequence: 0, speakerIndex: 0, scheduledOutputFrame: 0, scheduledOutputHostTime: 0),
            arrivalHostTime: 1,
            acousticLatencyMilliseconds: 12,
            estimate: DelayEstimate(sampleOffset: 576, sampleRate: 48_000, confidence: 1, peakValue: 1, secondBestPeak: 0, peakProminence: 2)
        )
        let secondMeasurement = AcousticMeasurement(
            emission: CalibrationEmission(pass: 0, sequence: 1, speakerIndex: 1, scheduledOutputFrame: 0, scheduledOutputHostTime: 0),
            arrivalHostTime: 1,
            acousticLatencyMilliseconds: 15,
            estimate: measurement.estimate
        )
        let calibrationPass = try CalibrationPassMeasurements(pass: 0, measurementsBySpeaker: [[measurement], [secondMeasurement]], failures: ["weak signal"])
        let driftPass = try CalibrationPassMeasurements(pass: 1, measurementsBySpeaker: [[measurement], [secondMeasurement]], failures: [])
        var configuration = CalibrationExperimentConfiguration(maximumPasses: 1, stabilityMeasurementOffsetsSeconds: [30])
        configuration.selectedSpeakerCount = 2
        let metadata = CalibrationDiagnosticMetadata(
            outputUIDs: ["speaker-a", "speaker-b"], outputNames: ["A", "B"], inputUID: "mic", inputName: "MacBook Pro Microphone",
            sampleRate: 48_000, configuration: configuration, emissions: [], passes: [calibrationPass, driftPass], finalCalibrationDelays: [3, 0],
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let report = CalibrationReport(metadata: metadata)
        XCTAssertEqual(report.speakers[0].medianArrivalMilliseconds, 12)
        XCTAssertEqual(report.residualSpreadMilliseconds, 3)
        XCTAssertEqual(report.calibrationPassCount, 1)
        XCTAssertEqual(report.rejectedMeasurementCount, 1)
        XCTAssertEqual(report.driftMeasurements.first?.offsetSeconds, 30)
        XCTAssertTrue(CalibrationReportExporter.text(for: report).contains("Rejected measurements: 1"))
    }

    func testFloatWAVHeaderAndPayload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.wav")
        try CalibrationDiagnosticWriter.writeFloatWAV(samples: [0, 0.25, -0.5, 0.75], sampleRate: 44_100, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(data.count, 44 + 4 * MemoryLayout<Float>.size)
    }
}
