import CoreAudio
import Foundation

public struct AudioDeviceDiscovery: Sendable {
    public init() {}

    public func outputDevices() throws -> [OutputDevice] {
        try CoreAudioProperty.deviceIDs().compactMap { deviceID in
            let channels = try CoreAudioProperty.channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
            guard channels > 0 else { return nil }
            let transportValue = try CoreAudioProperty.uint32(deviceID, selector: kAudioDevicePropertyTransportType)
            let classID = try CoreAudioProperty.uint32(deviceID, selector: kAudioObjectPropertyClass)
            return OutputDevice(
                id: try CoreAudioProperty.string(deviceID, selector: kAudioDevicePropertyDeviceUID),
                coreAudioID: deviceID,
                name: try CoreAudioProperty.string(deviceID, selector: kAudioObjectPropertyName),
                manufacturer: try? CoreAudioProperty.string(deviceID, selector: kAudioObjectPropertyManufacturer),
                transport: TransportType(coreAudioValue: transportValue),
                sampleRate: try CoreAudioProperty.double(deviceID, selector: kAudioDevicePropertyNominalSampleRate),
                channelCount: channels,
                isAggregate: classID == kAudioAggregateDeviceClassID || transportValue == kAudioDeviceTransportTypeAggregate
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func inputDevices() throws -> [InputDevice] {
        try CoreAudioProperty.deviceIDs().compactMap { deviceID in
            let channels = try CoreAudioProperty.channelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
            guard channels > 0 else { return nil }
            return InputDevice(
                id: try CoreAudioProperty.string(deviceID, selector: kAudioDevicePropertyDeviceUID),
                coreAudioID: deviceID,
                name: try CoreAudioProperty.string(deviceID, selector: kAudioObjectPropertyName),
                manufacturer: try? CoreAudioProperty.string(deviceID, selector: kAudioObjectPropertyManufacturer),
                transport: TransportType(coreAudioValue: try CoreAudioProperty.uint32(deviceID, selector: kAudioDevicePropertyTransportType)),
                sampleRate: try CoreAudioProperty.double(deviceID, selector: kAudioDevicePropertyNominalSampleRate),
                channelCount: channels
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
