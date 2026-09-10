import Foundation
import SpeakerrAudio

public enum UserSessionStatus: String, Sendable, Equatable {
    case inactive = "Inactive"
    case preparing = "Preparing"
    case readyToCalibrate = "Ready to Calibrate"
    case calibrating = "Calibrating"
    case aligned = "Aligned"
    case alignmentDrifting = "Alignment Drifting"
    case calibrationStale = "Calibration Stale"
    case waitingForSpeaker = "Waiting for Speaker"
    case audioError = "Audio Error"
    case paused = "Paused"
}

public struct SpeakerViewState: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let transport: TransportType
    public let sampleRate: Double
    public let channelCount: Int
    public let isConnected: Bool
    public let effectiveDelayMilliseconds: Double
    public let delayComponents: DelayComponents?

    public init(id: String, name: String, transport: TransportType, sampleRate: Double, channelCount: Int, isConnected: Bool, effectiveDelayMilliseconds: Double, delayComponents: DelayComponents? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isConnected = isConnected
        self.effectiveDelayMilliseconds = effectiveDelayMilliseconds
        self.delayComponents = delayComponents
    }
}

public enum CalibrationOutcome: Sendable, Equatable {
    case none
    case success(residualMilliseconds: Double)
    case nonConverged(residualMilliseconds: Double, canKeepCurrentAlignment: Bool)
    case lowConfidence(message: String)
    case cancelled
    case estimated(residualMilliseconds: Double?, applied: Bool, residualQuality: CalibrationQuality)
}

public struct CalibrationCompletionDiagnostic: Sendable, Equatable, Identifiable {
    public var id: Int { speakerIndex }
    public let speakerIndex: Int
    public let speakerName: String
    public let arrivalMilliseconds: Double
    public let appliedDelayMilliseconds: Double
    public let residualMilliseconds: Double

    public init(speakerIndex: Int, speakerName: String, arrivalMilliseconds: Double, appliedDelayMilliseconds: Double, residualMilliseconds: Double) {
        self.speakerIndex = speakerIndex
        self.speakerName = speakerName
        self.arrivalMilliseconds = arrivalMilliseconds
        self.appliedDelayMilliseconds = appliedDelayMilliseconds
        self.residualMilliseconds = residualMilliseconds
    }
}

public struct CalibrationCompletionDiagnostics: Sendable, Equatable {
    public let speakers: [CalibrationCompletionDiagnostic]
    public let residualSpreadMilliseconds: Double

    public init(speakers: [CalibrationCompletionDiagnostic], residualSpreadMilliseconds: Double) {
        self.speakers = speakers
        self.residualSpreadMilliseconds = residualSpreadMilliseconds
    }
}

public struct CalibrationSpeakerResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let speakerName: String
    public let detectedLatencyMilliseconds: Double?
    public let confidence: Double
    public let quality: CalibrationQuality
    public let measurementCount: Int
    public let acceptedMeasurementCount: Int
    public let spreadMilliseconds: Double?
    public let evidenceCount: Int

    public init(id: String, speakerName: String, detectedLatencyMilliseconds: Double?, confidence: Double, quality: CalibrationQuality = .high, measurementCount: Int = 0, acceptedMeasurementCount: Int = 0, spreadMilliseconds: Double? = nil, evidenceCount: Int = 0) {
        self.id = id
        self.speakerName = speakerName
        self.detectedLatencyMilliseconds = detectedLatencyMilliseconds
        self.confidence = confidence
        self.quality = quality
        self.measurementCount = measurementCount
        self.acceptedMeasurementCount = acceptedMeasurementCount
        self.spreadMilliseconds = spreadMilliseconds
        self.evidenceCount = evidenceCount
    }
}

public enum CalibrationPresentation: Sendable, Equatable {
    case unavailable
    case required(reason: String)
    case ready
    case running(CalibrationProgressUpdate?)
    case valid(residualMilliseconds: Double, confidence: Double, calibratedAt: Date)
    case failed(CalibrationOutcome)
}

public struct PlaybackViewState: Sendable, Equatable {
    public let isActive: Bool
    public let isProgrammeAttached: Bool
    public let statusText: String

    public init(isActive: Bool, isProgrammeAttached: Bool, statusText: String) {
        self.isActive = isActive
        self.isProgrammeAttached = isProgrammeAttached
        self.statusText = statusText
    }
}

public struct SpeakerrPresentationState: Sendable, Equatable {
    public var status: UserSessionStatus
    public var statusDetail: String?
    public var speakers: [SpeakerViewState]
    public var calibration: CalibrationPresentation
    public var playback: PlaybackViewState
    public var generation: UInt64
    public var sampleRate: Double
    public var transport: AudioTransportCounters
    public var renderCallbacks: UInt64
    public var technicalError: String?
    public var latestRecheckResidualMilliseconds: Double?

    public init(status: UserSessionStatus = .inactive, statusDetail: String? = nil, speakers: [SpeakerViewState] = [], calibration: CalibrationPresentation = .unavailable, playback: PlaybackViewState = .init(isActive: false, isProgrammeAttached: false, statusText: "Inactive"), generation: UInt64 = 0, sampleRate: Double = 0, transport: AudioTransportCounters = .init(), renderCallbacks: UInt64 = 0, technicalError: String? = nil, latestRecheckResidualMilliseconds: Double? = nil) {
        self.status = status
        self.statusDetail = statusDetail
        self.speakers = speakers
        self.calibration = calibration
        self.playback = playback
        self.generation = generation
        self.sampleRate = sampleRate
        self.transport = transport
        self.renderCallbacks = renderCallbacks
        self.technicalError = technicalError
        self.latestRecheckResidualMilliseconds = latestRecheckResidualMilliseconds
    }
}

public enum PresentationStateMapper {
    public static func userStatus(for engineState: SpeakerSessionState, calibrationIsValid: Bool, latestRecheckResidualMilliseconds: Double?, isPaused: Bool = false) -> UserSessionStatus {
        if isPaused { return .paused }
        switch engineState {
        case .idle: return .inactive
        case .preparing, .rebuilding: return .preparing
        case .ready: return .readyToCalibrate
        case .calibrating: return .calibrating
        case .aligned:
            guard calibrationIsValid else { return .calibrationStale }
            if let residual = latestRecheckResidualMilliseconds, abs(residual) > 2 { return .alignmentDrifting }
            return .aligned
        case .calibrationStale: return .calibrationStale
        case .unavailable: return .waitingForSpeaker
        case .failed: return .audioError
        }
    }

    public static func staleReason(_ reason: CalibrationStaleReason) -> String {
        switch reason {
        case .deviceReconnected: "A selected speaker reconnected. Bluetooth latency may have changed."
        case .sampleRateChanged: "The audio sample rate changed, so the previous timing measurement is no longer valid."
        case .routeRebuilt: "The speaker route was rebuilt, so calibration is required."
        case .systemWoke: "Calibration is required after wake."
        case .deviceSetChanged: "The selected speakers changed."
        case .manualInvalidation: "Calibration was manually invalidated."
        case .outputPathRestarted: "The speaker output path restarted, so calibration is required."
        }
    }

    public static func calibration(for engineState: SpeakerSessionState, snapshot: CalibrationSnapshot?, calibrationIsValid: Bool, progress: CalibrationProgressUpdate? = nil, outcome: CalibrationOutcome = .none) -> CalibrationPresentation {
        if case .estimated = outcome { return .failed(outcome) }
        if outcome.isFailed { return .failed(outcome) }
        switch engineState {
        case .calibrating: return .running(progress)
        case .calibrationStale(let reason): return .required(reason: staleReason(reason))
        case .unavailable: return .unavailable
        case .ready: return .ready
        case .aligned where calibrationIsValid:
            guard let snapshot else { return .required(reason: "Calibration is required for this speaker session.") }
            if snapshot.quality != .high { return .failed(.estimated(residualMilliseconds: snapshot.residualMilliseconds, applied: true, residualQuality: snapshot.residualQuality)) }
            return .valid(residualMilliseconds: snapshot.residualMilliseconds, confidence: snapshot.confidence, calibratedAt: snapshot.calibratedAt)
        case .failed:
            return outcome == .none ? .failed(.lowConfidence(message: "Speakerr could not complete the audio operation.")) : .failed(outcome)
        default: return .unavailable
        }
    }
}

private extension CalibrationOutcome {
    var isFailed: Bool {
        switch self {
        case .nonConverged, .lowConfidence: true
        default: false
        }
    }
}
