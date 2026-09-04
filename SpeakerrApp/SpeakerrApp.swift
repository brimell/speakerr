import AppKit
import SpeakerrPresentation
import SwiftUI

@MainActor
private enum AppModelStore {
    static let model = SpeakerrViewModel()
}

final class SpeakerrAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let model = AppModelStore.model
            model.beginMonitoring()
            await model.refresh()
            model.startSavedSessionIfNeeded()
            MainWindowCoordinator.shared.show(model: model)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModelStore.model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class MainWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = MainWindowCoordinator()
    private var window: NSWindow?

    func show(model: SpeakerrViewModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speakerr"
        window.minSize = NSSize(width: 620, height: 520)
        window.contentView = NSHostingView(rootView: MainWindowView(model: model))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SpeakerrMainWindow")
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct SpeakerrApp: App {
    @NSApplicationDelegateAdaptor(SpeakerrAppDelegate.self) private var appDelegate
    @State private var model = AppModelStore.model

    var body: some Scene {
        MenuBarExtra("Speakerr", systemImage: menuBarSymbol) {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Recheck Alignment") { model.recheck() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Calibrate Speakers") {
                    model.isCalibrationPresented = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 520, height: 330)
        }
    }

    private var menuBarSymbol: String {
        switch model.presentation.status {
        case .aligned: "hifispeaker.2.fill"
        case .calibrating, .preparing: "speaker.wave.2.fill"
        case .calibrationStale, .alignmentDrifting, .waitingForSpeaker, .audioError: "speaker.badge.exclamationmark.fill"
        default: "speaker.wave.2"
        }
    }
}

private struct MenuBarContent: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Section {
            Label(model.presentation.status.rawValue, systemImage: statusSymbol(model.presentation.status))
            if !model.presentation.speakers.isEmpty {
                Text(model.presentation.speakers.map(\.name).joined(separator: " + "))
            }
            if let residual = displayedResidual {
                Text("Residual: \(residual, format: .number.precision(.fractionLength(1))) ms")
            }
            if let detail = model.presentation.statusDetail {
                Text(detail)
            }
        }
        Divider()
        Button("Open Speakerr") { MainWindowCoordinator.shared.show(model: model) }
        Button("Calibrate…") {
            model.isCalibrationPresented = true
            MainWindowCoordinator.shared.show(model: model)
        }
        .disabled(model.presentation.speakers.count != 2 || model.presentation.status == .waitingForSpeaker)
        Button("Recheck Alignment") { model.recheck() }
            .disabled(model.presentation.status != .aligned && model.presentation.status != .alignmentDrifting)
        Divider()
        if model.presentation.playback.isActive {
            Button("Pause Speakerr") { model.pause() }
        } else {
            Button("Resume Speakerr") { model.start() }
                .disabled(model.preferences.selectedSpeakerUIDs.count != 2)
        }
        Button("Settings…") { openSettings() }
        Divider()
        Button("Quit Speakerr") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var displayedResidual: Double? {
        switch model.presentation.calibration {
        case .valid(let residual, _, _): residual
        default: model.presentation.latestRecheckResidualMilliseconds.map(abs)
        }
    }
}

func statusSymbol(_ status: UserSessionStatus) -> String {
    switch status {
    case .aligned: "checkmark.circle.fill"
    case .calibrating, .preparing: "arrow.triangle.2.circlepath"
    case .readyToCalibrate, .calibrationStale, .alignmentDrifting: "exclamationmark.triangle.fill"
    case .waitingForSpeaker: "antenna.radiowaves.left.and.right.slash"
    case .audioError: "xmark.octagon.fill"
    case .inactive, .paused: "pause.circle"
    }
}

func statusColor(_ status: UserSessionStatus) -> Color {
    switch status {
    case .aligned: .green
    case .calibrating, .preparing: .accentColor
    case .readyToCalibrate, .calibrationStale, .alignmentDrifting: .orange
    case .waitingForSpeaker, .audioError: .red
    case .inactive, .paused: .secondary
    }
}
