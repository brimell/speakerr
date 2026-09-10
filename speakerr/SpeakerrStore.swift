import Foundation
import CoreAudio
import SpeakerrAudio
import SpeakerrPresentation

@MainActor
public enum SpeakerrStore {
    public static let model = SpeakerrViewModel()
    public private(set) static var playback: PlaybackCoordinator?

    static func configurePlayback(audioEngine: AudioEngine) {
        guard playback == nil else { return }
        let selection = savedSelection()
        let coordinator = PlaybackCoordinator(singleSpeaker: LegacyPlaybackAdapter(engine: audioEngine), model: model, outputUIDs: selection.outputs, inputUID: selection.input)
        coordinator.onSelectionChanged = { outputs, input in
            persistSelection(outputs: outputs, input: input)
            loadSpeakerProfiles(outputs)
        }
        playback = coordinator
        persistSelection(outputs: selection.outputs, input: selection.input)
        loadSpeakerProfiles(selection.outputs)
    }

    static func restoreSelection() {
        let selection = savedSelection()
        playback?.selectInput(selection.input)
        playback?.selectOutputs(selection.outputs)
    }

    private static func savedSelection() -> (outputs: [String], input: String?) {
        let devices = AudioDeviceManager()
        let settings = AppSettingsStore.shared.load()
        let input = PlaybackCoordinator.resolveInputUID(
            savedInputID: settings?.selectedInputDeviceID.map { UInt32(bitPattern: $0) },
            savedProgrammeInputUID: model.preferences.programmeInputUID,
            inputs: (try? AudioDeviceDiscovery().inputDevices()) ?? []
        )
        let outputs: [String]
        if let saved = settings?.selectedOutputDeviceUIDs {
            // Retain disconnected selections so the session can reconnect them.
            outputs = saved
        } else if !model.preferences.selectedSpeakerUIDs.isEmpty {
            outputs = model.preferences.selectedSpeakerUIDs
        } else if let id = settings?.selectedOutputDeviceID,
                  let device = devices.outputDevices.first(where: { $0.id == UInt32(bitPattern: id) }) {
            outputs = [device.uid]
        } else if let id = devices.getDefaultOutputDevice(),
                  let device = devices.outputDevices.first(where: { $0.id == id && $0.uid != input }) {
            outputs = [device.uid]
        } else {
            outputs = []
        }
        return (outputs, input)
    }

    private static func persistSelection(outputs: [String], input: String?) {
        let devices = AudioDeviceManager()
        AppSettingsStore.shared.update {
            $0.selectedOutputDeviceUIDs = outputs
            $0.selectedOutputDeviceID = devices.outputDevices.first(where: { $0.uid == outputs.first }).map { Int32(bitPattern: $0.id) }
            $0.selectedInputDeviceID = devices.inputDevices.first(where: { $0.uid == input }).map { Int32(bitPattern: $0.id) }
        }
    }

    private static func loadSpeakerProfiles(_ outputs: [String]) {
        guard outputs.count >= 2 else { return }
        let profiles = DeviceProfileManager.shared
        let master = profiles.profile(for: "master")
        model.updateMasterEQ(bands: master?.effectiveBands ?? EQBand.defaultTenBand)
        model.updateMasterEQBypass(master.map { !$0.isEQEnabled || !$0.isEQFiltersEnabled } ?? false)
        for (route, uid) in outputs.enumerated() {
            let profile = profiles.profile(for: uid)
            model.updateRouteEQ(route: route, bands: profile?.effectiveBands ?? EQBand.defaultTenBand)
            model.updateRouteEQBypass(route: route, bypass: profile.map { !$0.isEQEnabled || !$0.isEQFiltersEnabled } ?? false)
            model.updateRouteVolume(route: route, volume: profile?.volume ?? 1)
        }
    }
}

@MainActor
private final class LegacyPlaybackAdapter: SingleSpeakerPlaybackControlling {
    private let engine: AudioEngine
    init(engine: AudioEngine) { self.engine = engine }
    var isRunning: Bool { engine.isRunning }

    func start(outputUID: String, inputUID: String) throws {
        let devices = AudioDeviceManager()
        guard let output = devices.outputDevices.first(where: { $0.uid == outputUID }) else { throw SessionControllerError.outputUnavailable(outputUID) }
        guard let input = devices.inputDevices.first(where: { $0.uid == inputUID }) else { throw SessionControllerError.inputUnavailable(inputUID) }
        guard inputUID != outputUID else { throw SessionControllerError.outputUnavailable("Choose a speaker instead of the audio input") }
        engine.setInputDevice(input.id)
        engine.setOutputDevice(output.id)
        engine.start()
        if !engine.isRunning {
            throw NSError(domain: "SpeakerrPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: engine.errorMessage ?? "Audio playback could not start."])
        }
    }

    func stop() { engine.stop() }
}
