import Foundation
import SpeakerrAudio

private func printUsage() {
    print("""
    Usage:
      speakerr-test devices
      speakerr-test play [--output-a <uid>] [--output-b <uid>]
    """)
}

private func printDevices() throws {
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

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "devices":
        try printDevices()
    case "play":
        fputs("play is added in Phase 1 of this build\n", stderr)
        exit(EXIT_FAILURE)
    default:
        printUsage()
        exit(arguments.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }
} catch {
    fputs("speakerr-test: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
