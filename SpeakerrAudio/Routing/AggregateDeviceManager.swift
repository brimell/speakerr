import CoreAudio
import Foundation
import os

public final class AggregateDeviceManager {
    public struct Session: Sendable {
        public let deviceID: AudioDeviceID
        public let uid: String
        public let sampleRate: Double
        public let channelCounts: [Int]
        public let mainDeviceUID: String
        public let driftCompensatedUIDs: [String]

        public init(deviceID: AudioDeviceID, uid: String, sampleRate: Double, channelCounts: [Int], mainDeviceUID: String, driftCompensatedUIDs: [String]) {
            self.deviceID = deviceID
            self.uid = uid
            self.sampleRate = sampleRate
            self.channelCounts = channelCounts
            self.mainDeviceUID = mainDeviceUID
            self.driftCompensatedUIDs = driftCompensatedUIDs
        }
    }

    private let logger = Logger(subsystem: "com.brimell.speakerr", category: "AggregateDevice")
    private var session: Session?
    private var originalSampleRates: [AudioDeviceID: Double] = [:]

    public init() {}

    deinit { destroy() }

    public func create(outputs: [OutputDevice]) throws -> Session {
        guard session == nil else { throw AudioRoutingError.alreadyRunning }
        guard outputs.count == 2 else { throw AudioRoutingError.requiresExactlyTwoOutputs }
        guard outputs[0].id != outputs[1].id else { throw AudioRoutingError.duplicateOutput }
        for output in outputs {
            guard !output.isAggregate else { throw AudioRoutingError.aggregateOutputUnsupported(output.name) }
            guard output.channelCount > 0 else { throw AudioRoutingError.deviceUnavailable(output.name) }
        }

        let rate = try selectCommonSampleRate(outputs: outputs)
        do {
            for output in outputs {
                let current = try CoreAudioProperty.double(output.coreAudioID, selector: kAudioDevicePropertyNominalSampleRate)
                originalSampleRates[output.coreAudioID] = current
                if abs(current - rate) > 0.01 {
                    try CoreAudioProperty.setDouble(output.coreAudioID, selector: kAudioDevicePropertyNominalSampleRate, value: rate)
                }
            }

            let uid = "com.brimell.speakerr.aggregate.\(UUID().uuidString)"
            let description = Self.makeDescription(outputs: outputs, uid: uid)
            var aggregateID = AudioDeviceID(kAudioObjectUnknown)
            try CoreAudioProperty.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "Create Speakerr aggregate output")

            let expectedChannels = outputs.reduce(0) { $0 + $1.channelCount }
            let actualChannels = try CoreAudioProperty.channelCount(aggregateID, scope: kAudioObjectPropertyScopeOutput)
            guard actualChannels == expectedChannels else {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                throw CoreAudioError("Verify aggregate channel map (expected \(expectedChannels), received \(actualChannels))", status: kAudioHardwareUnsupportedOperationError)
            }

            let composition = try CoreAudioProperty.dictionary(aggregateID, selector: kAudioAggregateDevicePropertyComposition)
            guard let composedSubdevices = composition["subdevices"] as? [[String: Any]], composedSubdevices.count == outputs.count else {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                throw CoreAudioError("Verify aggregate subdevices", status: kAudioHardwareNotRunningError)
            }
            for (index, subdevice) in composedSubdevices.enumerated() {
                let outputChannels = (subdevice["channels-out"] as? NSNumber)?.intValue
                guard outputChannels == outputs[index].channelCount else {
                    AudioHardwareDestroyAggregateDevice(aggregateID)
                    throw CoreAudioError("Verify aggregate output channels", status: kAudioHardwareUnsupportedOperationError)
                }
            }
            let driftReadback = (composedSubdevices[1]["drift"] as? NSNumber)?.intValue
            guard driftReadback == 1 else {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                throw CoreAudioError("Verify drift compensation", status: kAudioHardwareUnsupportedOperationError)
            }

            let created = Session(
                deviceID: aggregateID,
                uid: uid,
                sampleRate: try CoreAudioProperty.double(aggregateID, selector: kAudioDevicePropertyNominalSampleRate),
                channelCounts: outputs.map(\.channelCount),
                mainDeviceUID: outputs[0].id,
                driftCompensatedUIDs: [outputs[1].id]
            )
            session = created
            logger.info("Created private aggregate id=\(aggregateID, privacy: .public) rate=\(created.sampleRate, privacy: .public) channels=\(actualChannels, privacy: .public) clock=\(outputs[0].id, privacy: .public) drift=\(outputs[1].id, privacy: .public)")
            return created
        } catch {
            restoreSampleRates()
            throw error
        }
    }

    public static func makeDescription(outputs: [OutputDevice], uid: String) -> [String: Any] {
        let subdevices: [[String: Any]] = outputs.enumerated().map { index, output in
            [
                "uid": output.id,
                "drift": index == 0 ? 0 : 1,
                "drift quality": index == 0 ? 0 : Int(kAudioAggregateDriftCompensationMaxQuality),
                "channels-out": output.channelCount
            ]
        }
        return [
            "name": "Speakerr Temporary Output",
            "uid": uid,
            "subdevices": subdevices,
            "master": outputs[0].id,
            "private": 1,
            // A non-stacked aggregate concatenates subdevice channels, allowing per-device DSP.
            "stacked": 0
        ]
    }

    public func destroy() {
        if let session {
            let status = AudioHardwareDestroyAggregateDevice(session.deviceID)
            if status == noErr {
                logger.info("Destroyed private aggregate id=\(session.deviceID, privacy: .public)")
            } else {
                logger.error("Failed to destroy aggregate id=\(session.deviceID, privacy: .public) status=\(status, privacy: .public)")
            }
            self.session = nil
        }
        restoreSampleRates()
    }

    public var currentSession: Session? { session }

    private func selectCommonSampleRate(outputs: [OutputDevice]) throws -> Double {
        let supported = try outputs.map { output in
            try CoreAudioProperty.availableNominalSampleRates(output.coreAudioID)
        }
        let candidates = [outputs[0].sampleRate, 48_000, 44_100, outputs[1].sampleRate]
        guard let selected = candidates.first(where: { candidate in
            supported.allSatisfy { ranges in ranges.contains { $0.mMinimum <= candidate && candidate <= $0.mMaximum } }
        }) else {
            throw AudioRoutingError.noCommonSampleRate
        }
        return selected
    }

    private func restoreSampleRates() {
        for (deviceID, rate) in originalSampleRates {
            do {
                try CoreAudioProperty.setDouble(deviceID, selector: kAudioDevicePropertyNominalSampleRate, value: rate)
            } catch {
                logger.error("Failed to restore rate device=\(deviceID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        originalSampleRates.removeAll()
    }
}
