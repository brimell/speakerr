import CoreAudio
import Foundation

public struct CoreAudioError: LocalizedError, Sendable {
    public let operation: String
    public let status: OSStatus

    public init(_ operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var errorDescription: String? {
        let bigEndian = UInt32(bitPattern: status).bigEndian
        let bytes = withUnsafeBytes(of: bigEndian) { Array($0) }
        let code = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
            ? String(bytes: bytes, encoding: .ascii) ?? "\(status)"
            : "\(status)"
        return "\(operation) failed (CoreAudio \(code))"
    }
}

enum CoreAudioProperty {
    static func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "Read audio device list size")
        var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &values), "Read audio device list")
        return values
    }

    static func string(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "Read CoreAudio string property")
        guard let value else { throw CoreAudioError("Read CoreAudio string property", status: kAudioHardwareUnspecifiedError) }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "Read CoreAudio integer property")
        return value
    }

    static func dictionary(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> [String: Any] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "Read CoreAudio dictionary property")
        guard let value, let dictionary = value.takeRetainedValue() as? [String: Any] else {
            throw CoreAudioError("Read CoreAudio dictionary property", status: kAudioHardwareUnspecifiedError)
        }
        return dictionary
    }

    static func double(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Double {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value), "Read CoreAudio floating-point property")
        return value
    }

    static func setDouble(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector, value: Double) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var mutableValue = value
        try check(AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &mutableValue), "Set CoreAudio floating-point property")
    }

    static func availableNominalSampleRates(_ objectID: AudioObjectID) throws -> [AudioValueRange] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "Read available sample-rate size")
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &ranges), "Read available sample rates")
        return ranges
    }

    static func channelCount(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size), "Read stream configuration size")
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage), "Read stream configuration")
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CoreAudioError(operation, status: status) }
    }
}
