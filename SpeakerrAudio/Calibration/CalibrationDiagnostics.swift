import Foundation

public struct CalibrationDiagnosticMetadata: Sendable, Codable {
    public let createdAt: Date
    public let outputUIDs: [String]
    public let outputNames: [String]
    public let inputUID: String
    public let inputName: String
    public let sampleRate: Double
    public let configuration: CalibrationExperimentConfiguration
    public let emissions: [CalibrationEmission]
    public let passes: [CalibrationPassMeasurements]
    public let finalCalibrationDelays: [Double]

    public init(
        outputUIDs: [String], outputNames: [String], inputUID: String, inputName: String,
        sampleRate: Double, configuration: CalibrationExperimentConfiguration,
        emissions: [CalibrationEmission], passes: [CalibrationPassMeasurements], finalCalibrationDelays: [Double]
    ) {
        createdAt = Date()
        self.outputUIDs = outputUIDs
        self.outputNames = outputNames
        self.inputUID = inputUID
        self.inputName = inputName
        self.sampleRate = sampleRate
        self.configuration = configuration
        self.emissions = emissions
        self.passes = passes
        self.finalCalibrationDelays = finalCalibrationDelays
    }
}

public enum CalibrationDiagnosticWriter {
    public static func write(
        directory: URL,
        reference: CalibrationSignal,
        captured: CapturedAudio,
        metadata: CalibrationDiagnosticMetadata
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFloatWAV(samples: reference.samples, sampleRate: reference.sampleRate, to: directory.appendingPathComponent("reference.wav"))
        try writeFloatWAV(samples: captured.samples, sampleRate: captured.sampleRate, to: directory.appendingPathComponent("microphone.wav"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
        try encoder.encode(captured.anchors).write(to: directory.appendingPathComponent("capture-timestamps.json"), options: .atomic)
    }

    static func writeFloatWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 32
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let dataSize = UInt32(samples.count) * bytesPerSample
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLE(UInt32(36) + dataSize)
        data.appendASCII("WAVEfmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(3)) // IEEE float
        data.appendLE(channelCount)
        data.appendLE(UInt32(sampleRate.rounded()))
        data.appendLE(UInt32(sampleRate.rounded()) * bytesPerSample * UInt32(channelCount))
        data.appendLE(UInt16(bytesPerSample) * channelCount)
        data.appendLE(bitsPerSample)
        data.appendASCII("data")
        data.appendLE(dataSize)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) { append(value.data(using: .ascii)!) }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
