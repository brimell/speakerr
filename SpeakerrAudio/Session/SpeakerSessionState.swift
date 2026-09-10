import Foundation

public enum CalibrationStaleReason: String, Codable, Sendable, Equatable {
    case deviceReconnected
    case sampleRateChanged
    case routeRebuilt
    case systemWoke
    case deviceSetChanged
    case manualInvalidation
    case outputPathRestarted
}

public enum SpeakerSessionState: Sendable, Equatable {
    case idle
    case preparing
    case ready
    case calibrating
    case aligned
    case calibrationStale(CalibrationStaleReason)
    case rebuilding
    case unavailable(String)
    case failed(String)
}

public struct CalibrationProgressUpdate: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case measuring(speakerIndex: Int, speakerName: String, pass: Int, totalPasses: Int, measurement: Int, totalMeasurements: Int)
        case applyingCorrection(residualMilliseconds: Double)
        case verifying(pass: Int)
        case completed
    }

    public let phase: Phase
    public let progressFraction: Double?

    public init(phase: Phase, progressFraction: Double? = nil) {
        self.phase = phase
        self.progressFraction = progressFraction
    }
}

public enum SpeakerSessionEvent: Sendable, Equatable {
    case prepare
    case prepared
    case beginCalibration
    case calibrationSucceeded
    case calibrationFailed(String)
    case invalidate(CalibrationStaleReason)
    case cancelCalibration(SpeakerSessionState)
    case beginRebuild
    case rebuildSucceeded
    case outputUnavailable(String)
    case stop
}

public enum SpeakerSessionTransitionError: LocalizedError, Equatable {
    case invalidTransition(from: SpeakerSessionState, event: SpeakerSessionEvent)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let state, let event):
            "Invalid speaker-session transition from \(state) for \(event)."
        }
    }
}

public struct SpeakerSessionStateMachine: Sendable {
    public private(set) var state: SpeakerSessionState = .idle

    public init(state: SpeakerSessionState = .idle) { self.state = state }

    @discardableResult
    public mutating func handle(_ event: SpeakerSessionEvent) throws -> SpeakerSessionState {
        let next: SpeakerSessionState
        switch (state, event) {
        case (_, .stop): next = .idle
        case (.idle, .prepare), (.rebuilding, .prepare): next = .preparing
        case (.preparing, .prepared): next = .ready
        case (.ready, .beginCalibration), (.aligned, .beginCalibration), (.calibrationStale, .beginCalibration): next = .calibrating
        case (.calibrating, .calibrationSucceeded): next = .aligned
        case (.calibrating, .calibrationFailed(let message)): next = .failed(message)
        case (.calibrating, .cancelCalibration(let priorState)): next = priorState
        case (.ready, .invalidate(let reason)), (.aligned, .invalidate(let reason)),
             (.calibrating, .invalidate(let reason)): next = .calibrationStale(reason)
        case (.calibrationStale, .invalidate(let reason)): next = .calibrationStale(reason)
        case (.ready, .beginRebuild), (.aligned, .beginRebuild), (.calibrationStale, .beginRebuild),
             (.unavailable, .beginRebuild), (.failed, .beginRebuild): next = .rebuilding
        case (.rebuilding, .rebuildSucceeded): next = .calibrationStale(.routeRebuilt)
        case (_, .outputUnavailable(let message)): next = .unavailable(message)
        default: throw SpeakerSessionTransitionError.invalidTransition(from: state, event: event)
        }
        state = next
        return next
    }
}

public struct CalibrationSnapshot: Codable, Sendable, Equatable {
    public let outputUIDs: [String]
    public let sampleRate: Double
    public let compensationByUID: [String: Double]
    public let residualMilliseconds: Double
    public let confidence: Double
    public let calibratedAt: Date
    public let sessionGeneration: UInt64
    private let storedQuality: CalibrationQuality?
    private let storedResidualQuality: CalibrationQuality?
    public var quality: CalibrationQuality { storedQuality ?? .high }
    public var residualQuality: CalibrationQuality { storedResidualQuality ?? .high }

    public init(outputUIDs: [String], sampleRate: Double, compensationByUID: [String: Double], residualMilliseconds: Double, confidence: Double, calibratedAt: Date = Date(), sessionGeneration: UInt64, quality: CalibrationQuality = .high, residualQuality: CalibrationQuality = .high) {
        self.outputUIDs = outputUIDs
        self.sampleRate = sampleRate
        self.compensationByUID = compensationByUID
        self.residualMilliseconds = residualMilliseconds
        self.confidence = confidence
        self.calibratedAt = calibratedAt
        self.sessionGeneration = sessionGeneration
        storedQuality = quality
        storedResidualQuality = residualQuality
    }

    public func isValid(outputUIDs currentUIDs: [String], sampleRate currentRate: Double, sessionGeneration currentGeneration: UInt64) -> Bool {
        sessionGeneration == currentGeneration && outputUIDs == currentUIDs && abs(sampleRate - currentRate) < 0.01
    }
}

public struct DelayComponents: Sendable, Equatable {
    public static let maximumComponentMilliseconds = 1_000.0
    public let manual: Double
    public let calibration: Double
    public let dynamicCorrection: Double

    public init(manual: Double = 0, calibration: Double = 0, dynamicCorrection: Double = 0) throws {
        for value in [manual, calibration, dynamicCorrection] where !(0...Self.maximumComponentMilliseconds).contains(value) {
            throw AudioRoutingError.delayOutOfRange(value)
        }
        let total = manual + calibration + dynamicCorrection
        guard total <= FractionalDelayLine.maximumDelayMilliseconds else { throw AudioRoutingError.delayOutOfRange(total) }
        self.manual = manual
        self.calibration = calibration
        self.dynamicCorrection = dynamicCorrection
    }

    public var effectiveMilliseconds: Double { manual + calibration + dynamicCorrection }
}

public struct DeviceIdentitySnapshot: Sendable, Equatable {
    public let uid: String
    public let objectID: UInt32
    public let sampleRate: Double
    public let channelCount: Int

    public init(uid: String, objectID: UInt32, sampleRate: Double, channelCount: Int) {
        self.uid = uid
        self.objectID = objectID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public enum DeviceLifecycleChange: Sendable, Equatable {
    case unchanged
    case disconnected(uid: String)
    case reconnected(uid: String, oldObjectID: UInt32?, newObjectID: UInt32)
    case sampleRateChanged(uid: String, old: Double, new: Double)
    case channelLayoutChanged(uid: String, old: Int, new: Int)
}

public enum DeviceLifecycleComparison {
    public static func compare(previous: [String: DeviceIdentitySnapshot], current: [String: DeviceIdentitySnapshot], selectedUIDs: [String]) -> [DeviceLifecycleChange] {
        selectedUIDs.compactMap { uid in
            let old = previous[uid]
            let new = current[uid]
            if old != nil, new == nil { return .disconnected(uid: uid) }
            guard let new else { return .unchanged }
            guard let old else { return .reconnected(uid: uid, oldObjectID: nil, newObjectID: new.objectID) }
            if old.objectID != new.objectID { return .reconnected(uid: uid, oldObjectID: old.objectID, newObjectID: new.objectID) }
            if abs(old.sampleRate - new.sampleRate) >= 0.01 { return .sampleRateChanged(uid: uid, old: old.sampleRate, new: new.sampleRate) }
            if old.channelCount != new.channelCount { return .channelLayoutChanged(uid: uid, old: old.channelCount, new: new.channelCount) }
            return .unchanged
        }.filter { $0 != .unchanged }
    }
}

public struct NotificationCoalescer: Sendable {
    public let intervalNanoseconds: UInt64
    public private(set) var deadline: UInt64?

    public init(intervalNanoseconds: UInt64 = 350_000_000) { self.intervalNanoseconds = intervalNanoseconds }

    public mutating func receive(at timestamp: UInt64) { deadline = timestamp &+ intervalNanoseconds }

    public mutating func consumeIfDue(at timestamp: UInt64) -> Bool {
        guard let deadline, timestamp >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
