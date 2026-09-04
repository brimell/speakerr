import AppKit
import SpeakerrPresentation
import SwiftUI

@main
struct SpeakerrApp: App {
    @State private var model = SpeakerrViewModel()

    var body: some Scene {
        MenuBarExtra("Speakerr", systemImage: menuBarSymbol) {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Speakerr", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 610)
                .task {
                    model.beginMonitoring()
                    await model.refresh()
                    model.startSavedSessionIfNeeded()
                }
        }
        .defaultSize(width: 680, height: 610)
        .windowResizability(.contentMinSize)
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
    @Environment(\.openWindow) private var openWindow
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
        Button("Open Speakerr") { openWindow(id: "main") }
        Button("Calibrate…") {
            model.isCalibrationPresented = true
            openWindow(id: "main")
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
            Task {
                await model.shutdown()
                await MainActor.run { NSApplication.shared.terminate(nil) }
            }
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
