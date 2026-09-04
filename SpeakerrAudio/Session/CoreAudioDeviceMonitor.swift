import AppKit
import CoreAudio
import Foundation
import os

public enum AudioLifecycleEvent: Sendable, Equatable {
    case devicesChanged(changes: [DeviceLifecycleChange], notificationCount: Int)
    case defaultOutputChanged(uid: String?)
    case systemSleep
    case systemWake
    case aggregateDestroyed
}

/// Monitors durable UIDs but treats AudioObjectIDs as per-connection observations.
/// CoreAudio commonly emits a burst of related callbacks, so device/format changes
/// are coalesced on a serial queue before discovery and comparison.
public final class CoreAudioDeviceMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (AudioLifecycleEvent) -> Void

    private let logger = Logger(subsystem: "com.brimell.speakerr", category: "Lifecycle")
    private let selectedUIDs: [String]
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.brimell.speakerr.device-lifecycle")
    private var previous: [String: DeviceIdentitySnapshot]
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var selectedListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var aggregateListener: (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingWork: DispatchWorkItem?
    private var pendingNotifications = 0
    private var running = false

    public init(selectedUIDs: [String], handler: @escaping Handler) throws {
        self.selectedUIDs = selectedUIDs
        self.handler = handler
        previous = try Self.identityMap()
    }

    deinit { stop() }

    public func start() throws {
        guard !running else { return }
        running = true
        try installSystemListeners()
        try refreshSelectedListeners()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in self?.queue.async { self?.handler(.systemSleep) } },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.queue.async { self?.handler(.systemWake) } }
        ]
    }

    public func watchAggregate(deviceID: AudioObjectID) throws {
        removeAggregateListener()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            queue.async { [handler] in
                let alive = (try? CoreAudioProperty.uint32(deviceID, selector: kAudioDevicePropertyDeviceIsAlive)) == 1
                if !alive { handler(.aggregateDestroyed) }
            }
        }
        try CoreAudioProperty.check(AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener), "Monitor aggregate validity")
        aggregateListener = (deviceID, address, listener)
    }

    public func stop() {
        guard running else { return }
        running = false
        pendingWork?.cancel(); pendingWork = nil
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let listener = deviceListListener {
            var address = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
        }
        if let listener = defaultOutputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, listener)
        }
        removeSelectedListeners(); removeAggregateListener()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver); workspaceObservers.removeAll()
        deviceListListener = nil; defaultOutputListener = nil
    }

    private func installSystemListeners() throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devices = Self.deviceListAddress
        let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
        try CoreAudioProperty.check(AudioObjectAddPropertyListenerBlock(system, &devices, queue, deviceListener), "Monitor CoreAudio device list")
        deviceListListener = deviceListener

        var defaultOutput = Self.defaultOutputAddress
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            queue.async { [handler] in handler(.defaultOutputChanged(uid: Self.defaultOutputUID())) }
        }
        try CoreAudioProperty.check(AudioObjectAddPropertyListenerBlock(system, &defaultOutput, queue, defaultListener), "Monitor default output")
        defaultOutputListener = defaultListener
    }

    private func refreshSelectedListeners() throws {
        removeSelectedListeners()
        let current = try Self.identityMap()
        for uid in selectedUIDs {
            guard let identity = current[uid] else { continue }
            for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyDeviceIsAlive] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: selector == kAudioDevicePropertyStreamConfiguration ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
                let status = AudioObjectAddPropertyListenerBlock(identity.objectID, &address, queue, listener)
                if status == noErr { selectedListeners.append((identity.objectID, address, listener)) }
            }
        }
    }

    private func removeSelectedListeners() {
        for (object, storedAddress, listener) in selectedListeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        selectedListeners.removeAll()
    }

    private func removeAggregateListener() {
        if let (object, storedAddress, listener) = aggregateListener {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        aggregateListener = nil
    }

    private func scheduleRefresh() {
        queue.async { [weak self] in
            guard let self, running else { return }
            pendingNotifications += 1
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.performRefresh() }
            pendingWork = work
            queue.asyncAfter(deadline: .now() + .milliseconds(350), execute: work)
        }
    }

    private func performRefresh() {
        guard running else { return }
        do {
            let current = try Self.identityMap()
            let changes = DeviceLifecycleComparison.compare(previous: previous, current: current, selectedUIDs: selectedUIDs)
            let count = pendingNotifications
            pendingNotifications = 0
            previous = current
            try refreshSelectedListeners()
            if !changes.isEmpty {
                logger.info("Coalesced \(count, privacy: .public) CoreAudio notifications into \(changes.count, privacy: .public) selected-device changes")
                handler(.devicesChanged(changes: changes, notificationCount: count))
            }
        } catch {
            logger.error("Device lifecycle refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func identityMap() throws -> [String: DeviceIdentitySnapshot] {
        Dictionary(uniqueKeysWithValues: try AudioDeviceDiscovery().outputDevices().filter { !$0.isAggregate }.map {
            ($0.id, DeviceIdentitySnapshot(uid: $0.id, objectID: $0.coreAudioID, sampleRate: $0.sampleRate, channelCount: $0.channelCount))
        })
    }

    private static func defaultOutputUID() -> String? {
        var address = defaultOutputAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return try? CoreAudioProperty.string(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
