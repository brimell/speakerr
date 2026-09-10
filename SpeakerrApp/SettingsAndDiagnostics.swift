import ServiceManagement
import SpeakerrPresentation
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SpeakerrViewModel

    var body: some View {
        TabView {
            Form {
                Toggle("Launch Speakerr at login", isOn: Binding(get: { model.preferences.launchAtLogin }, set: { enabled in updateLaunchAtLogin(enabled) }))
                Toggle("Open window when calibration fails", isOn: Binding(get: { model.preferences.openWindowOnCalibrationFailure }, set: { model.preferences.openWindowOnCalibrationFailure = $0 }))
                Text("Speakerr always remains available in the menu bar while running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Picker("Default microphone", selection: Binding(get: { model.preferences.preferredMicrophoneUID ?? "" }, set: { model.preferences.preferredMicrophoneUID = $0 })) {
                    ForEach(model.availableInputs) { input in Text(input.name).tag(input.id) }
                }
                Picker("System audio device", selection: Binding(get: { model.preferences.programmeInputUID ?? "" }, set: { model.selectProgrammeInput($0.isEmpty ? nil : $0) })) {
                    ForEach(model.availableInputs.filter { input in model.availableOutputs.contains(where: { $0.id == input.id }) }) { input in
                        Text(input.name).tag(input.id)
                    }
                }
                HStack {
                    Text("Calibration volume")
                    Slider(value: Binding(get: { model.preferences.calibrationVolume }, set: { model.preferences.calibrationVolume = $0 }), in: 0.03...0.3)
                }
                Picker("Measurements per speaker", selection: Binding(get: { model.preferences.measurementsPerSpeaker }, set: { model.preferences.measurementsPerSpeaker = $0 })) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Suggest recalibration after reconnect", isOn: Binding(get: { model.preferences.suggestRecalibrationAfterReconnect }, set: { model.preferences.suggestRecalibrationAfterReconnect = $0 }))
            }
            .padding(20)
            .tabItem { Label("Audio", systemImage: "speaker.wave.2") }

            Form {
                Toggle("Show detailed timing information", isOn: Binding(get: { model.preferences.showDetailedTiming }, set: { model.preferences.showDetailedTiming = $0 }))
                Toggle("Save diagnostic recordings", isOn: Binding(get: { model.preferences.saveDiagnosticRecordings }, set: { model.preferences.saveDiagnosticRecordings = $0 }))
                Text("Diagnostic recordings are never saved unless this option is enabled. Ordinary playback does not use the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Diagnostics…") { model.isDiagnosticsPresented = true }
            }
            .padding(20)
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            model.preferences.launchAtLogin = enabled
        } catch {
            model.preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct DiagnosticsView: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Diagnostics").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                    diagnosticRow("SESSION", "")
                    diagnosticRow("Generation", "\(model.presentation.generation)")
                    diagnosticRow("State", model.presentation.status.rawValue)
                    diagnosticRow("Sample rate", "\(Int(model.presentation.sampleRate)) Hz")
                    ForEach(model.presentation.speakers) { speaker in
                        diagnosticRow(speaker.name.uppercased(), "")
                        diagnosticRow("UID", speaker.id)
                        diagnosticRow("Connected", speaker.isConnected ? "Yes" : "No")
                        if let delay = speaker.delayComponents {
                            diagnosticRow("Manual delay", milliseconds(delay.manual))
                            diagnosticRow("Calibration delay", milliseconds(delay.calibration))
                            diagnosticRow("Dynamic correction", milliseconds(delay.dynamicCorrection))
                            diagnosticRow("Effective delay", milliseconds(delay.effectiveMilliseconds))
                        }
                    }
                    diagnosticRow("STREAM", "")
                    diagnosticRow("Render callbacks", "\(model.presentation.renderCallbacks)")
                    diagnosticRow("Captured frames", "\(model.presentation.transport.capturedFrames)")
                    diagnosticRow("Rendered frames", "\(model.presentation.transport.renderedFrames)")
                    diagnosticRow("Underflows", "\(model.presentation.transport.underflowCallbacks)")
                    diagnosticRow("Overflows", "\(model.presentation.transport.overflowCallbacks)")
                    diagnosticRow("Dropped frames", "\(model.presentation.transport.droppedFrames)")
                    if let error = model.presentation.technicalError {
                        diagnosticRow("Last error", error)
                    }
                }
                .textSelection(.enabled)
                .monospacedDigit()
            }
        }
        .padding(24)
        .frame(width: 600, height: 520)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(value.isEmpty ? .primary : .secondary)
            Text(value).lineLimit(nil)
        }
    }

    private func milliseconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(3)))) ms"
    }
}
