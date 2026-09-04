import XCTest
@testable import SpeakerrAudio

final class CalibrationDiagnosticsTests: XCTestCase {
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
