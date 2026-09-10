import Foundation
import Observation
import SpeakerrAudio

@MainActor
public protocol SingleSpeakerPlaybackControlling: AnyObject {
    var isRunning: Bool { get }
    func start(outputUID: String, inputUID: String) throws
    func stop()
}

/// Owns the handoff between the legacy single output and the aggregate session.
/// A transition waits for the previous transition (including route restoration),
/// then checks its revision before starting any audio.
@MainActor
@Observable
public final class PlaybackCoordinator {
    public private(set) var selectedOutputUIDs: [String]
    public private(set) var inputUID: String?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    public private(set) var wantsPlayback = false
    public var onSelectionChanged: (([String], String?) -> Void)?

    private let singleSpeaker: any SingleSpeakerPlaybackControlling
    private let model: SpeakerrViewModel
    private var revision: UInt64 = 0
    private var transition: Task<Void, Never>?

    public init(singleSpeaker: any SingleSpeakerPlaybackControlling, model: SpeakerrViewModel, outputUIDs: [String] = [], inputUID: String? = nil) {
        self.singleSpeaker = singleSpeaker
        self.model = model
        self.selectedOutputUIDs = Self.orderedSelection(outputUIDs)
        self.inputUID = inputUID
        model.playbackCoordinator = self
        synchronizePreferences()
    }

    public var isRunning: Bool {
        guard wantsPlayback else { return false }
        return selectedOutputUIDs.count == 1
            ? singleSpeaker.isRunning
            : model.presentation.playback.isActive && model.presentation.playback.isProgrammeAttached
    }

    public func selectOutputs(_ uids: [String]) {
        let selection = Self.orderedSelection(uids)
        guard selectedOutputUIDs != selection else { return }
        selectedOutputUIDs = selection
        synchronizePreferences()
        requestPlayback(!selection.isEmpty)
    }

    public func selectInput(_ uid: String?) {
        guard inputUID != uid else { return }
        inputUID = uid
        synchronizePreferences()
        requestPlayback(wantsPlayback)
    }

    public func start() { requestPlayback(true) }
    public func stop() { requestPlayback(false) }
    public func togglePlayback() { requestPlayback(!wantsPlayback) }

    public func waitForTransition() async {
        // A new selection may arrive while a previous shutdown is awaited.
        var observed: UInt64
        repeat {
            observed = revision
            await transition?.value
        } while revision != observed
    }

    public static func resolveInputUID(savedInputID: UInt32?, savedProgrammeInputUID: String?, inputs: [InputDevice]) -> String? {
        if let savedInputID, let input = inputs.first(where: { $0.coreAudioID == savedInputID }) { return input.id }
        if let savedProgrammeInputUID, inputs.contains(where: { $0.id == savedProgrammeInputUID }) { return savedProgrammeInputUID }
        return inputs.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") })?.id
    }

    private static func orderedSelection(_ uids: [String]) -> [String] {
        var seen = Set<String>()
        return Array(uids.filter { seen.insert($0).inserted }.prefix(2))
    }

    private func synchronizePreferences() {
        model.preferences.selectedSpeakerUIDs = selectedOutputUIDs.count == 2 ? selectedOutputUIDs : []
        model.preferences.programmeInputUID = inputUID
        onSelectionChanged?(selectedOutputUIDs, inputUID)
    }

    private func requestPlayback(_ enabled: Bool) {
        wantsPlayback = enabled && !selectedOutputUIDs.isEmpty
        revision &+= 1
        let requestedRevision = revision
        let previous = transition
        let outputs = selectedOutputUIDs
        let input = inputUID
        let shouldStart = wantsPlayback
        let routingMode = model.preferences.routingMode
        let calibrationLevel = model.preferences.calibrationVolume
        errorMessage = nil
        isBusy = true
        transition = Task {
            await previous?.value
            guard requestedRevision == revision else { return }
            singleSpeaker.stop()
            await model.pauseSession()
            guard requestedRevision == revision else { return }
            do {
                if shouldStart {
                    guard let input else { throw SessionControllerError.inputUnavailable("Choose an audio input") }
                    if outputs.count == 1 {
                        try singleSpeaker.start(outputUID: outputs[0], inputUID: input)
                    } else {
                        try await model.startSession(outputUIDs: outputs, inputUID: input, calibrationLevel: calibrationLevel, routingMode: routingMode)
                    }
                }
            } catch {
                if requestedRevision == revision {
                    errorMessage = error.localizedDescription
                    wantsPlayback = false
                    model.presentPlaybackError(error)
                }
            }
            guard requestedRevision == revision else { return }
            isBusy = false
            transition = nil
        }
    }
}
