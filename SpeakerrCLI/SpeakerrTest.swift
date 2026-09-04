import Darwin
import AVFoundation
import Foundation
import SpeakerrAudio

private enum CLIError: LocalizedError {
    case missingOptionValue(String)
    case unknownOption(String)
    case outputNotFound(String)
    case inputNotFound(String)
    case invalidNumber(option: String, value: String)
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .missingOptionValue(let option): "Missing value for \(option)."
        case .unknownOption(let option): "Unknown option \(option)."
        case .outputNotFound(let uid): "No available non-aggregate output has UID \(uid)."
        case .inputNotFound(let uid): "No available input has UID \(uid)."
        case .invalidNumber(let option, let value): "Invalid numeric value '\(value)' for \(option)."
        case .invalidSelection: "Enter the number of an available output device."
        }
    }
}

@main
struct SpeakerrTest {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "devices":
                try printDevices()
            case "play":
                try await play(arguments: Array(arguments.dropFirst()))
            case "calibrate":
                try await calibrate(arguments: Array(arguments.dropFirst()))
            default:
                printUsage()
                if !arguments.isEmpty { exit(EXIT_FAILURE) }
            }
        } catch {
            fputs("speakerr-test: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          speakerr-test devices
          speakerr-test play [--output-a <uid>] [--output-b <uid>]
          speakerr-test calibrate [--output-a <uid>] [--output-b <uid>] [--input <uid>]
                                 [--gain <0.01...0.5>] [--verbose]
                                 [--save-diagnostics <directory>]
        """)
    }

    private static func printDevices() throws {
        let discovery = AudioDeviceDiscovery()
        print("OUTPUTS")
        for (index, device) in try discovery.outputDevices().enumerated() {
            let unsupported = device.isAggregate ? " [aggregate: unavailable for nesting]" : ""
            print("[\(index)] \(device.name)\(unsupported)")
            print("    uid=\(device.id) coreAudioID=\(device.coreAudioID) transport=\(device.transport.rawValue) rate=\(device.sampleRate)Hz channels=\(device.channelCount)")
        }

        print("\nMICROPHONES / INPUTS")
        for (index, device) in try discovery.inputDevices().enumerated() {
            print("[\(index)] \(device.name)")
            print("    uid=\(device.id) coreAudioID=\(device.coreAudioID) transport=\(device.transport.rawValue) rate=\(device.sampleRate)Hz channels=\(device.channelCount)")
        }
    }

    private static func play(arguments: [String]) async throws {
        let options = try parseOptions(arguments)
        let outputs = try AudioDeviceDiscovery().outputDevices().filter { !$0.isAggregate }
        guard outputs.count >= 2 else { throw AudioRoutingError.requiresExactlyTwoOutputs }

        print("Available non-aggregate outputs:")
        for (index, output) in outputs.enumerated() {
            print("[\(index)] \(output.name) — \(output.transport.rawValue), \(output.channelCount)ch, \(output.sampleRate)Hz")
        }

        let outputA = try selectOutput(label: "A", uid: options.outputA, outputs: outputs)
        let outputB = try selectOutput(label: "B", uid: options.outputB, outputs: outputs)
        guard outputA.id != outputB.id else { throw AudioRoutingError.duplicateOutput }

        let backend = CoreAudioAggregateRoutingBackend()
        try await backend.configureOutputs([outputA, outputB])
        try await backend.start()

        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signalSource.setEventHandler {
            Task {
                await backend.stop()
                fputs("\nStopped.\n", stderr)
                exit(EXIT_SUCCESS)
            }
        }
        signalSource.resume()

        let status = backend.status()
        print("""

        Playing a repeating broadband transient.
        A: \(outputA.name) (uid=\(outputA.id))
        B: \(outputB.name) (uid=\(outputB.id))
        Sample rate: \(status.sampleRate ?? 0) Hz
        Clock source: \(status.clockDeviceUID ?? "unknown")
        Drift compensated: \(status.driftCompensatedDeviceUIDs.joined(separator: ", "))

        Commands: a|b +0.1, -0.1, +1, -1, +10, -10, or absolute milliseconds.
        Also: status, help, quit
        """)

        while let line = readLine(strippingNewline: true) {
            guard let command = InteractiveDelayCommand.parse(line) else {
                print("Unrecognised command. Enter 'help' for examples.")
                continue
            }
            switch command {
            case .adjust(let device, let delta):
                let target = device == "a" ? outputA.id : outputB.id
                let current = backend.status().outputs.first(where: { $0.id == target })?.delayMilliseconds ?? 0
                let adjusted = max(0, min(FractionalDelayLine.maximumDelayMilliseconds, current + delta))
                try await backend.setDelay(deviceID: target, milliseconds: adjusted)
                printStatus(backend.status())
            case .set(let device, let milliseconds):
                let target = device == "a" ? outputA.id : outputB.id
                try await backend.setDelay(deviceID: target, milliseconds: milliseconds)
                printStatus(backend.status())
            case .status:
                printStatus(backend.status())
            case .help:
                print("Examples: 'a +10', 'b -0.1', 'a 73.4', 'status', 'quit'")
            case .quit:
                await backend.stop()
                signalSource.cancel()
                print("Stopped.")
                return
            }
        }
        await backend.stop()
        signalSource.cancel()
    }

    private struct CalibrationOptions {
        var outputA: String?
        var outputB: String?
        var input: String?
        var gain = 0.12
        var verbose = false
        var diagnosticsDirectory: String?
    }

    private static func calibrate(arguments: [String]) async throws {
        let options = try parseCalibrationOptions(arguments)
        let discovery = AudioDeviceDiscovery()
        let outputs = try discovery.outputDevices().filter { !$0.isAggregate }
        let inputs = try discovery.inputDevices()
        guard outputs.count >= 2 else { throw AudioRoutingError.requiresExactlyTwoOutputs }

        print("Available non-aggregate outputs:")
        for (index, output) in outputs.enumerated() {
            print("[\(index)] \(output.name) — \(output.transport.rawValue), \(output.channelCount)ch, \(output.sampleRate)Hz")
        }
        let outputA = try selectOutput(label: "A", uid: options.outputA, outputs: outputs)
        let outputB = try selectOutput(label: "B", uid: options.outputB, outputs: outputs)
        guard outputA.id != outputB.id else { throw AudioRoutingError.duplicateOutput }

        print("\nAvailable microphones / inputs:")
        for (index, input) in inputs.enumerated() {
            print("[\(index)] \(input.name) — \(input.transport.rawValue), \(input.channelCount)ch, \(input.sampleRate)Hz")
        }
        let input = try selectInput(uid: options.input, inputs: inputs)
        guard await requestMicrophoneAccess() else {
            throw CalibrationSessionError.inputUnavailable("\(input.name) (microphone permission denied)")
        }

        var configuration = CalibrationExperimentConfiguration()
        configuration.level = options.gain
        let session = try AcousticCalibrationSession(outputs: [outputA, outputB], input: input, configuration: configuration)
        var completedPasses: [CalibrationPassMeasurements] = []
        var residuals: [Double] = []
        var compensation = DelayCompensation(calibrationDelayA: 0, calibrationDelayB: 0)
        let convergence = ConvergenceController(targetResidualMilliseconds: configuration.targetResidualMilliseconds, maximumPasses: configuration.maximumPasses)
        var success = false

        print("""

        Output A: \(outputA.name)
          uid=\(outputA.id)
        Output B: \(outputB.name)
          uid=\(outputB.id)
        Input: \(input.name)
          uid=\(input.id)
        Calibration gain: \(String(format: "%.3f", options.gain)) (conservative digital full scale)

        Place the Mac near the listening position and keep the room reasonably quiet.
        Starting one continuous output and microphone-capture session...
        """)

        do {
            try await session.start()
            print("Sample rate: \(Int(session.sampleRate)) Hz")
            print("Output clock: \(outputA.name); drift compensation: \(outputB.name)\n")

            for pass in 0..<configuration.maximumPasses {
                print(pass == 0 ? "Initial measurement" : "Verification pass \(pass)/\(configuration.maximumPasses - 1)")
                let measured = try await session.waitForPass(pass)
                completedPasses.append(measured)
                printPass(measured, outputs: [outputA, outputB], verbose: options.verbose)
                let residual = measured.relativeArrivalBMinusAMilliseconds
                residuals.append(residual)

                if pass > 0, convergence.isSuccessful(residuals: residuals) {
                    success = true
                    print("\nResidual offset: \(String(format: "%.2f", abs(residual))) ms")
                    print("Calibration successful.")
                    break
                }
                if pass == 0, abs(residual) <= configuration.targetResidualMilliseconds {
                    success = true
                    print("\nSpeakers are already within \(String(format: "%.2f", abs(residual))) ms; no compensation required.")
                    print("Calibration successful.")
                    break
                }
                guard convergence.shouldContinue(residuals: residuals) else {
                    print("\nCalibration stopped: residual is unstable or the correction-pass limit was reached.")
                    break
                }

                if residual >= 0 {
                    compensation = DelayCompensation(calibrationDelayA: compensation.calibrationDelayA + residual, calibrationDelayB: compensation.calibrationDelayB)
                } else {
                    compensation = DelayCompensation(calibrationDelayA: compensation.calibrationDelayA, calibrationDelayB: compensation.calibrationDelayB - residual)
                }
                try session.setCalibrationDelays(compensation)
                print("""

                Applying compensation without restarting streams:
                  \(outputA.name): manual +\(String(format: "%.2f", session.manualDelays[0])) ms, calibration +\(String(format: "%.2f", compensation.calibrationDelayA)) ms
                  \(outputB.name): manual +\(String(format: "%.2f", session.manualDelays[1])) ms, calibration +\(String(format: "%.2f", compensation.calibrationDelayB)) ms
                """)
            }

            if let path = options.diagnosticsDirectory {
                let captured = try session.capturedAudio()
                let reference = try LogarithmicChirpGenerator(durationSeconds: configuration.chirpDurationSeconds, level: configuration.level).generate(sampleRate: session.sampleRate)
                let metadata = CalibrationDiagnosticMetadata(
                    outputUIDs: [outputA.id, outputB.id], outputNames: [outputA.name, outputB.name],
                    inputUID: input.id, inputName: input.name, sampleRate: session.sampleRate,
                    configuration: configuration, emissions: session.allEmissions(), passes: completedPasses,
                    finalCalibrationDelays: [compensation.calibrationDelayA, compensation.calibrationDelayB]
                )
                let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                try CalibrationDiagnosticWriter.write(directory: url, reference: reference, captured: captured, metadata: metadata)
                print("Diagnostics saved to \(url.path)")
            }
            await session.stop()
        } catch {
            if let path = options.diagnosticsDirectory, session.sampleRate > 0,
               let captured = try? session.capturedAudio(),
               let reference = try? LogarithmicChirpGenerator(durationSeconds: configuration.chirpDurationSeconds, level: configuration.level).generate(sampleRate: session.sampleRate) {
                let metadata = CalibrationDiagnosticMetadata(
                    outputUIDs: [outputA.id, outputB.id], outputNames: [outputA.name, outputB.name], inputUID: input.id, inputName: input.name,
                    sampleRate: session.sampleRate, configuration: configuration, emissions: session.allEmissions(), passes: completedPasses,
                    finalCalibrationDelays: [compensation.calibrationDelayA, compensation.calibrationDelayB]
                )
                let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                try? CalibrationDiagnosticWriter.write(directory: url, reference: reference, captured: captured, metadata: metadata)
                fputs("Partial diagnostics saved to \(url.path)\n", stderr)
            }
            await session.stop()
            throw error
        }
        if !success { throw CalibrationSessionError.didNotConverge(residualMilliseconds: residuals.last ?? .infinity) }
    }

    private static func printPass(_ pass: CalibrationPassMeasurements, outputs: [OutputDevice], verbose: Bool) {
        let paired = min(pass.measurementsA.count, pass.measurementsB.count)
        for index in 0..<paired {
            printMeasurement(pass.measurementsA[index], label: "A\(index + 1)", name: outputs[0].name, verbose: verbose)
            printMeasurement(pass.measurementsB[index], label: "B\(index + 1)", name: outputs[1].name, verbose: verbose)
            let relative = pass.measurementsB[index].acousticLatencyMilliseconds - pass.measurementsA[index].acousticLatencyMilliseconds
            print("    paired relative B-A=\(String(format: "%+.2f", relative)) ms")
        }
        for failure in pass.failures { print("  rejected: \(failure)") }
        print("  \(outputs[0].name): median=\(String(format: "%.2f", pass.summaryA.medianMilliseconds)) ms spread=\(String(format: "%.2f", pass.summaryA.spreadMilliseconds)) ms MAD=\(String(format: "%.2f", pass.summaryA.medianAbsoluteDeviationMilliseconds)) ms")
        print("  \(outputs[1].name): median=\(String(format: "%.2f", pass.summaryB.medianMilliseconds)) ms spread=\(String(format: "%.2f", pass.summaryB.spreadMilliseconds)) ms MAD=\(String(format: "%.2f", pass.summaryB.medianAbsoluteDeviationMilliseconds)) ms")
        let relative = pass.relativeArrivalBMinusAMilliseconds
        print("  Relative B-A: \(String(format: "%+.2f", relative)) ms (\(relative >= 0 ? outputs[0].name + " arrives earlier" : outputs[1].name + " arrives earlier"))")
    }

    private static func printMeasurement(_ measurement: AcousticMeasurement, label: String, name: String, verbose: Bool) {
        print("  \(label) \(name): arrival=\(String(format: "%.2f", measurement.acousticLatencyMilliseconds)) ms confidence=\(String(format: "%.2f", measurement.estimate.confidence))")
        if verbose {
            print("    outputFrame=\(measurement.emission.scheduledOutputFrame) outputHost=\(measurement.emission.scheduledOutputHostTime) inputHost=\(measurement.arrivalHostTime)")
            print("    correlation peak=\(String(format: "%.4f", measurement.estimate.peakValue)) second=\(String(format: "%.4f", measurement.estimate.secondBestPeak)) prominence=\(String(format: "%.2f", measurement.estimate.peakProminence)) sampleOffset=\(String(format: "%.3f", measurement.estimate.sampleOffset))")
        }
    }

    private static func selectInput(uid: String?, inputs: [InputDevice]) throws -> InputDevice {
        if let uid {
            guard let input = inputs.first(where: { $0.id == uid }) else { throw CLIError.inputNotFound(uid) }
            return input
        }
        print("Select microphone/input: ", terminator: "")
        guard let line = readLine(), let index = Int(line), inputs.indices.contains(index) else { throw CLIError.invalidSelection }
        return inputs[index]
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private static func printStatus(_ status: RoutingStatus) {
        let labels = ["A", "B"]
        for (index, output) in status.outputs.enumerated() {
            print("\(labels[index]) \(output.name): \(String(format: "%.1f", output.delayMilliseconds)) ms")
        }
        if let error = status.lastRenderError {
            print("Render callback error: \(error)")
        }
    }

    private static func selectOutput(label: String, uid: String?, outputs: [OutputDevice]) throws -> OutputDevice {
        if let uid {
            guard let output = outputs.first(where: { $0.id == uid }) else { throw CLIError.outputNotFound(uid) }
            return output
        }
        print("Select output \(label): ", terminator: "")
        guard let line = readLine(), let index = Int(line), outputs.indices.contains(index) else { throw CLIError.invalidSelection }
        return outputs[index]
    }

    private static func parseOptions(_ arguments: [String]) throws -> (outputA: String?, outputB: String?) {
        var outputA: String?
        var outputB: String?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option == "--output-a" || option == "--output-b" else { throw CLIError.unknownOption(option) }
            guard arguments.indices.contains(index + 1) else { throw CLIError.missingOptionValue(option) }
            if option == "--output-a" { outputA = arguments[index + 1] } else { outputB = arguments[index + 1] }
            index += 2
        }
        return (outputA, outputB)
    }

    private static func parseCalibrationOptions(_ arguments: [String]) throws -> CalibrationOptions {
        var result = CalibrationOptions()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--verbose" {
                result.verbose = true
                index += 1
                continue
            }
            guard ["--output-a", "--output-b", "--input", "--gain", "--save-diagnostics"].contains(option) else { throw CLIError.unknownOption(option) }
            guard arguments.indices.contains(index + 1) else { throw CLIError.missingOptionValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--output-a": result.outputA = value
            case "--output-b": result.outputB = value
            case "--input": result.input = value
            case "--gain":
                guard let gain = Double(value) else { throw CLIError.invalidNumber(option: option, value: value) }
                result.gain = gain
            case "--save-diagnostics": result.diagnosticsDirectory = value
            default: break
            }
            index += 2
        }
        return result
    }
}
