import Foundation

public protocol AudioRoutingBackend: Sendable {
    func configureOutputs(_ outputs: [OutputDevice]) async throws
    func setDelay(deviceID: String, milliseconds: Double) async throws
    func start() async throws
    func stop() async
}

public enum AudioRoutingError: LocalizedError, Equatable, Sendable {
    case requiresAtLeastTwoOutputs
    case duplicateOutput
    case aggregateOutputUnsupported(String)
    case deviceUnavailable(String)
    case noCommonSampleRate
    case delayOutOfRange(Double)
    case outputNotConfigured(String)
    case alreadyRunning
    case notConfigured
    case callbackTooLarge(UInt32)

    public var errorDescription: String? {
        switch self {
        case .requiresAtLeastTwoOutputs: "Select at least two enabled output devices."
        case .duplicateOutput: "Select two different output devices."
        case .aggregateOutputUnsupported(let name): "\(name) is already an aggregate or multi-output device and cannot be nested."
        case .deviceUnavailable(let name): "The output device \(name) is no longer available."
        case .noCommonSampleRate: "The selected outputs do not have a common supported sample rate."
        case .delayOutOfRange(let value): "Delay \(value) ms is outside the supported 0...1000 ms range."
        case .outputNotConfigured(let id): "No configured output has UID \(id)."
        case .alreadyRunning: "Audio routing is already running."
        case .notConfigured: "Configure at least two outputs before starting playback."
        case .callbackTooLarge(let frames): "CoreAudio requested an unsupported callback size of \(frames) frames."
        }
    }
}
