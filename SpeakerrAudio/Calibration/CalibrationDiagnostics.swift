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
        emissions: [CalibrationEmission], passes: [CalibrationPassMeasurements], finalCalibrationDelays: [Double],
        createdAt: Date = Date()
    ) {
        self.createdAt = createdAt
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

public struct CalibrationReport: Sendable, Codable, Equatable {
    public struct Speaker: Sendable, Codable, Equatable {
        public let name: String
        public let uid: String
        public let medianArrivalMilliseconds: Double
        public let medianAbsoluteDeviationMilliseconds: Double
        public let appliedDelayMilliseconds: Double

        public init(name: String, uid: String, medianArrivalMilliseconds: Double, medianAbsoluteDeviationMilliseconds: Double, appliedDelayMilliseconds: Double) {
            self.name = name
            self.uid = uid
            self.medianArrivalMilliseconds = medianArrivalMilliseconds
            self.medianAbsoluteDeviationMilliseconds = medianAbsoluteDeviationMilliseconds
            self.appliedDelayMilliseconds = appliedDelayMilliseconds
        }
    }

    public struct DriftMeasurement: Sendable, Codable, Equatable {
        public let offsetSeconds: Double
        public let relativeArrivalsToReferenceMilliseconds: [Double]

        public init(offsetSeconds: Double, relativeArrivalsToReferenceMilliseconds: [Double]) {
            self.offsetSeconds = offsetSeconds
            self.relativeArrivalsToReferenceMilliseconds = relativeArrivalsToReferenceMilliseconds
        }
    }

    public let createdAt: Date
    public let sampleRate: Double
    public let microphoneName: String
    public let speakers: [Speaker]
    public let residualSpreadMilliseconds: Double
    public let calibrationPassCount: Int
    public let rejectedMeasurementCount: Int
    public let driftMeasurements: [DriftMeasurement]

    public init(metadata: CalibrationDiagnosticMetadata) {
        createdAt = metadata.createdAt
        sampleRate = metadata.sampleRate
        microphoneName = metadata.inputName

        let calibrationPasses = metadata.passes.filter { $0.pass < metadata.configuration.maximumPasses }
        let finalPass = calibrationPasses.last ?? metadata.passes.last
        let summaries = finalPass?.summariesBySpeaker ?? []
        speakers = metadata.outputNames.enumerated().map { index, name in
            let summary = summaries.indices.contains(index) ? summaries[index] : nil
            return Speaker(
                name: name,
                uid: metadata.outputUIDs.indices.contains(index) ? metadata.outputUIDs[index] : "",
                medianArrivalMilliseconds: summary?.medianMilliseconds ?? 0,
                medianAbsoluteDeviationMilliseconds: summary?.medianAbsoluteDeviationMilliseconds ?? 0,
                appliedDelayMilliseconds: metadata.finalCalibrationDelays.indices.contains(index) ? metadata.finalCalibrationDelays[index] : 0
            )
        }
        let relativeArrivals = finalPass?.relativeArrivalsToReferenceMilliseconds ?? []
        residualSpreadMilliseconds = relativeArrivals.isEmpty ? 0 : (relativeArrivals.max()! - relativeArrivals.min()!)
        calibrationPassCount = calibrationPasses.count
        rejectedMeasurementCount = calibrationPasses.reduce(0) { $0 + $1.failures.count }

        let stabilityPasses = metadata.passes.filter { $0.pass >= metadata.configuration.maximumPasses }
        driftMeasurements = stabilityPasses.enumerated().map { index, pass in
            DriftMeasurement(
                offsetSeconds: metadata.configuration.stabilityMeasurementOffsetsSeconds.indices.contains(index)
                    ? metadata.configuration.stabilityMeasurementOffsetsSeconds[index]
                    : 0,
                relativeArrivalsToReferenceMilliseconds: pass.relativeArrivalsToReferenceMilliseconds
            )
        }
    }
}

public enum CalibrationReportExporter {
    public static func report(from metadata: CalibrationDiagnosticMetadata) -> CalibrationReport {
        CalibrationReport(metadata: metadata)
    }

    public static func text(for report: CalibrationReport) -> String {
        let date = DateFormatter.calibrationReport.string(from: report.createdAt)
        var lines = [
            "Speakerr Calibration Report",
            date,
            "",
            "Sample rate: \(format(report.sampleRate, decimals: 0, grouping: true)) Hz",
            "Speakers: \(report.speakers.count)",
            "Microphone: \(report.microphoneName)",
            ""
        ]

        for (index, speaker) in report.speakers.enumerated() {
            lines += [
                "Speaker \(index + 1): \(speaker.name)",
                "Median arrival: \(format(speaker.medianArrivalMilliseconds)) ms",
                "MAD: \(format(speaker.medianAbsoluteDeviationMilliseconds)) ms",
                "Applied delay: \(format(speaker.appliedDelayMilliseconds)) ms",
                ""
            ]
        }

        lines += [
            "Residual spread: \(format(report.residualSpreadMilliseconds)) ms",
            "Passes: \(report.calibrationPassCount)",
            "Rejected measurements: \(report.rejectedMeasurementCount)",
            "",
            "Drift measurements:"
        ]
        for measurement in report.driftMeasurements {
            let values = measurement.relativeArrivalsToReferenceMilliseconds.map { format($0) + " ms" }.joined(separator: ", ")
            lines.append("\(format(measurement.offsetSeconds, decimals: 0)) s: \(values)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(report: CalibrationReport, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("calibration-report.json"), options: .atomic)
        try text(for: report).write(to: directory.appendingPathComponent("calibration-report.txt"), atomically: true, encoding: .utf8)
    }

    private static func format(_ value: Double, decimals: Int = 2, grouping: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

private extension DateFormatter {
    static let calibrationReport: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
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
        try CalibrationReportExporter.write(report: CalibrationReport(metadata: metadata), to: directory)
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
