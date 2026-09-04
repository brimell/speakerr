import Darwin
import Foundation
import SpeakerrAudio

private enum CLIError: LocalizedError {
    case missingOptionValue(String)
    case unknownOption(String)
    case outputNotFound(String)
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .missingOptionValue(let option): "Missing value for \(option)."
        case .unknownOption(let option): "Unknown option \(option)."
        case .outputNotFound(let uid): "No available non-aggregate output has UID \(uid)."
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
}
