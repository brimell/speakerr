import AppKit
import SpeakerrAudio
import SpeakerrPresentation
import SwiftUI

struct SpeakerSelectionView: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Speakers").font(.title2.weight(.semibold))
            Text("Select exactly two output devices.").foregroundStyle(.secondary)
            List(model.availableOutputs) { device in
                Button {
                    toggle(device.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(device.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected.contains(device.id) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("\(transportName(device.transport)) · \(device.channelCount == 2 ? "Stereo" : "\(device.channelCount) channels") · \(device.sampleRate / 1000, format: .number.precision(.fractionLength(1))) kHz")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(device.name), \(selected.contains(device.id) ? "selected" : "not selected")")
            }
            .frame(minHeight: 260)
            if selected.count == 1 {
                Text("Select one more output device to create a Speakerr group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if selected.count > 2 {
                Text("Speakerr currently supports exactly two speakers.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Selected") {
                    model.useSelectedSpeakers(model.availableOutputs.filter { selected.contains($0.id) }.map(\.id))
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.count != 2)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .onAppear { selected = Set(model.preferences.selectedSpeakerUIDs) }
    }

    private func toggle(_ uid: String) {
        if selected.contains(uid) {
            selected.remove(uid)
        } else if selected.count < 2 {
            selected.insert(uid)
        }
    }
}

struct CalibrationSheet: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
            Spacer(minLength: 4)
            controls
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 520, maxWidth: 520, minHeight: 330)
    }

    @ViewBuilder
    private var content: some View {
        if model.microphonePermissionDenied {
            Text("Microphone Access Required").font(.title2.weight(.semibold))
            Text("Speakerr uses the microphone briefly during calibration to measure when sound from each speaker reaches your listening position.")
            Text("Speakerr does not record audio during ordinary playback.")
                .foregroundStyle(.secondary)
        } else if model.isBusy || model.presentation.status == .calibrating {
            Text("Calibrating Speakers").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.calibrationProgress.map(calibrationPhaseText) ?? "Preparing calibration…")
            }
            if let progress = model.calibrationProgress?.progressFraction {
                ProgressView(value: progress)
            }
            Text("Keep the Mac near your listening position.")
                .foregroundStyle(.secondary)
        } else {
            switch model.calibrationOutcome {
            case .success(let residual): success(residual)
            case .nonConverged(let residual, let canKeep): nonConvergence(residual, canKeep: canKeep)
            case .lowConfidence(let message): lowConfidence(message)
            case .cancelled:
                Text("Calibration Cancelled").font(.title2.weight(.semibold))
                Text("Programme audio has resumed. Any calibration that was valid before this attempt remains unchanged.")
                    .foregroundStyle(.secondary)
            case .none: introduction
            }
        }
    }

    private var introduction: some View {
        Group {
            Text("Calibrate Speakers").font(.title2.weight(.semibold))
            Text("Place this Mac near your normal listening position.")
            Text("Speakerr will briefly play test sounds through each speaker and use the microphone to align their arrival times.")
                .foregroundStyle(.secondary)
            Picker("Microphone", selection: Binding(get: { model.preferences.preferredMicrophoneUID ?? "" }, set: { model.preferences.preferredMicrophoneUID = $0 })) {
                ForEach(model.availableInputs) { input in Text(input.name).tag(input.id) }
            }
            HStack {
                Text("Calibration volume")
                Slider(value: Binding(get: { model.preferences.calibrationVolume }, set: { model.preferences.calibrationVolume = $0 }), in: 0.03...0.3)
                Text(model.preferences.calibrationVolume, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(width: 42, alignment: .trailing)
            }
        }
    }

    private func success(_ residual: Double) -> some View {
        Group {
            Label("Speakers Aligned", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.green)
            Text("Residual error").foregroundStyle(.secondary)
            Text("\(residual, format: .number.precision(.fractionLength(2))) ms")
                .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(residual <= 1 ? "Excellent alignment" : residual <= 2 ? "Aligned" : "Slight offset")
        }
    }

    private func nonConvergence(_ residual: Double, canKeep: Bool) -> some View {
        Group {
            Text("Could Not Fully Align Speakers").font(.title2.weight(.semibold))
            Text("Speakerr reduced the timing difference, but verification still measured a residual after the maximum number of correction attempts.")
                .foregroundStyle(.secondary)
            LabeledContent("Current residual") { Text("\(residual, format: .number.precision(.fractionLength(2))) ms").monospacedDigit() }
            if canKeep { Text("You can keep this partial alignment or try again.").foregroundStyle(.secondary) }
        }
    }

    private func lowConfidence(_ message: String) -> some View {
        Group {
            Text("Could Not Measure Reliably").font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            Text("Try moving the Mac closer, reducing background noise, or increasing calibration volume slightly.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if model.microphonePermissionDenied {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                Spacer()
                Button("Done") { dismiss() }
            } else if model.isBusy || model.presentation.status == .calibrating {
                Spacer()
                Button("Cancel") { model.cancelCalibration() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                switch model.calibrationOutcome {
                case .success:
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case .nonConverged, .lowConfidence, .cancelled:
                    Button("Try Again") { model.calibrate() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case .none:
                    Button("Start Calibration") { model.calibrate() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.preferences.preferredMicrophoneUID == nil)
                }
            }
        }
    }
}
