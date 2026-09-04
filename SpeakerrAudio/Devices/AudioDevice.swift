import CoreAudio
import Foundation

public enum TransportType: String, Codable, Sendable {
    case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, virtual, aggregate
    case thunderbolt, pci, fireWire, avb, unknown

    init(coreAudioValue: UInt32) {
        switch coreAudioValue {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        case kAudioDeviceTransportTypeAVB: self = .avb
        default: self = .unknown
        }
    }
}

public struct OutputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let coreAudioID: AudioDeviceID
    public let name: String
    public let manufacturer: String?
    public let transport: TransportType
    public let sampleRate: Double
    public let channelCount: Int
    public let isAggregate: Bool
    public var delayMilliseconds: Double
    public var enabled: Bool

    public init(id: String, coreAudioID: AudioDeviceID, name: String, manufacturer: String? = nil, transport: TransportType, sampleRate: Double, channelCount: Int, isAggregate: Bool = false, delayMilliseconds: Double = 0, enabled: Bool = true) {
        self.id = id
        self.coreAudioID = coreAudioID
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isAggregate = isAggregate
        self.delayMilliseconds = delayMilliseconds
        self.enabled = enabled
    }
}

public struct InputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let coreAudioID: AudioDeviceID
    public let name: String
    public let manufacturer: String?
    public let transport: TransportType
    public let sampleRate: Double
    public let channelCount: Int

    public init(id: String, coreAudioID: AudioDeviceID, name: String, manufacturer: String? = nil, transport: TransportType, sampleRate: Double, channelCount: Int) {
        self.id = id
        self.coreAudioID = coreAudioID
        self.name = name
        self.manufacturer = manufacturer
        self.transport = transport
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}
