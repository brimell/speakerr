import AppKit
import SpeakerrPresentation
import SwiftUI

@MainActor
public final class MainWindowCoordinator: NSObject, NSWindowDelegate {
    public static let shared = MainWindowCoordinator()
    private var window: NSWindow?

    public func show() {
        show(model: SpeakerrStore.model)
    }

    public func show(model: SpeakerrViewModel) {
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

public struct SpeakerrAlignmentMenuView: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.openSettings) private var openSettings

    public init() {
        self.model = SpeakerrStore.model
    }

    public init(model: SpeakerrViewModel) {
        self.model = model
    }

    public var body: some View {
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
    }

    private var displayedResidual: Double? {
        switch model.presentation.calibration {
        case .valid(let residual, _, _): residual
        default: model.presentation.latestRecheckResidualMilliseconds.map(abs)
        }
    }
}

public func statusSymbol(_ status: UserSessionStatus) -> String {
    switch status {
    case .aligned: "checkmark.circle.fill"
    case .calibrating, .preparing: "arrow.triangle.2.circlepath"
    case .readyToCalibrate, .calibrationStale, .alignmentDrifting: "exclamationmark.triangle.fill"
    case .waitingForSpeaker: "antenna.radiowaves.left.and.right.slash"
    case .audioError: "xmark.octagon.fill"
    case .inactive, .paused: "pause.circle"
    }
}

public func statusColor(_ status: UserSessionStatus) -> Color {
    switch status {
    case .aligned: .green
    case .calibrating, .preparing: .accentColor
    case .readyToCalibrate, .calibrationStale, .alignmentDrifting: .orange
    case .waitingForSpeaker, .audioError: .red
    case .inactive, .paused: .secondary
    }
}
