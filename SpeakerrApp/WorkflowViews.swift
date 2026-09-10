import AppKit
import SpeakerrAudio
import SpeakerrPresentation
import SwiftUI

struct SpeakerSelectionView: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Speakers").font(.title2.weight(.semibold))
            Text("Select two or more output devices.").foregroundStyle(.secondary)
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
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Selected") {
                    model.useSelectedSpeakers(selected)
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.count < 2)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .onAppear { selected = model.playbackCoordinator?.selectedOutputUIDs ?? model.preferences.selectedSpeakerUIDs }
    }

    private func toggle(_ uid: String) {
        if let index = selected.firstIndex(of: uid) {
            selected.remove(at: index)
        } else { selected.append(uid) }
    }
}

struct CalibrationSheet: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
            if !model.calibrationAttempts.isEmpty {
                diagnostics
            }
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
            calibrationProgressDetails(model.calibrationProgress, speakerCount: model.preferences.selectedSpeakerUIDs.count)
            calibrationProgressView(model.calibrationProgress)
            Text("Keep the Mac near your listening position.")
                .foregroundStyle(.secondary)
        } else {
            switch model.calibrationOutcome {
            case .success(let residual): success(residual, results: model.calibrationSpeakerResults)
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
                Slider(value: Binding(get: { model.preferences.calibrationVolume }, set: { model.preferences.calibrationVolume = $0 }), in: 0.03...0.5)
                Text(model.preferences.calibrationVolume, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(width: 42, alignment: .trailing)
            }
        }
    }

    private func success(_ residual: Double, results: [CalibrationSpeakerResult]) -> some View {
        Group {
            Label("Speakers Aligned", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.green)
            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.speakerName).font(.headline)
                    HStack {
                        LabeledContent("Detected") { Text("\(result.detectedLatencyMilliseconds, format: .number.precision(.fractionLength(1))) ms").monospacedDigit() }
                        LabeledContent("Confidence") { Text(calibrationConfidenceLabel(result.confidence)) }
                    }
                }
            }
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
            Label("Measurement failed", systemImage: "arrow.clockwise.circle")
                .font(.title2.weight(.semibold))
            Text("Retry required before the speakers can be aligned.")
                .foregroundStyle(.orange)
            Text(message).foregroundStyle(.secondary)
            Text("Try moving the Mac closer, reducing background noise, or increasing calibration volume slightly.")
                .foregroundStyle(.secondary)
            diagnosticsDisclosure(fallback: message)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let completion = model.calibrationCompletion {
                Text("Completed Calibration").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Speaker").font(.caption.weight(.semibold))
                        Text("Arrival").font(.caption.weight(.semibold))
                        Text("Applied delay").font(.caption.weight(.semibold))
                        Text("Residual").font(.caption.weight(.semibold))
                    }
                    ForEach(completion.speakers) { row in
                        GridRow {
                            Text(row.speakerName)
                            timing(row.arrivalMilliseconds)
                            timing(row.appliedDelayMilliseconds)
                            timing(row.residualMilliseconds, signed: true)
                        }
                    }
                }
                Text("Residual spread = \(completion.residualSpreadMilliseconds, format: .number.precision(.fractionLength(2))) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Attempts").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Speaker").font(.caption.weight(.semibold))
                        Text("Attempt").font(.caption.weight(.semibold))
                        Text("Measured latency").font(.caption.weight(.semibold))
                        Text("Peak").font(.caption.weight(.semibold))
                        Text("Second-best").font(.caption.weight(.semibold))
                        Text("Prominence").font(.caption.weight(.semibold))
                        Text("Confidence").font(.caption.weight(.semibold))
                        Text("Result").font(.caption.weight(.semibold))
                    }
                    ForEach(model.calibrationAttempts) { attempt in
                        GridRow {
                            Text(attempt.speakerName)
                            Text("\(attempt.attempt)").monospacedDigit()
                            metric(attempt.measuredLatencyMilliseconds, suffix: " ms")
                            metric(attempt.peak)
                            metric(attempt.secondBestPeak)
                            metric(attempt.prominence)
                            metric(attempt.confidence)
                            if attempt.accepted {
                                Text("Accepted").foregroundStyle(.green)
                            } else {
                                Text("Rejected: \(attempt.failureReason ?? "unknown failure")")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .font(.caption)
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 150)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func timing(_ value: Double, signed: Bool = false) -> some View {
        Text(signed ? String(format: "%+.2f ms", value) : String(format: "%.2f ms", value))
            .monospacedDigit()
    }

    private func metric(_ value: Double?, suffix: String = "") -> some View {
        Text(value.map { "\($0, specifier: "%.3f")\(suffix)" } ?? "-")
            .monospacedDigit()
    }

    private func diagnosticsDisclosure(fallback: String) -> some View {
        DisclosureGroup("Technical diagnostics") {
            Text(model.presentation.technicalError ?? fallback)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    Button("Calibrate Again") { model.calibrate() }
                        .buttonStyle(.bordered)
                        .disabled(model.availableInputs.isEmpty)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .nonConverged, .lowConfidence, .cancelled:
                    Button("Try Again") { model.calibrate() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case .none:
                    Button("Start Calibration") { model.calibrate() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.availableInputs.isEmpty)
                }
            }
        }
    }
}

@ViewBuilder
private func calibrationProgressDetails(_ update: CalibrationProgressUpdate?, speakerCount: Int) -> some View {
    if let update {
        switch update.phase {
        case .measuring(let speakerIndex, let speakerName, let pass, let totalPasses, let measurement, let totalMeasurements):
            VStack(alignment: .leading, spacing: 4) {
                Text(speakerName).font(.headline)
                Text("Speaker \(speakerIndex + 1) of \(max(1, speakerCount))")
                    .foregroundStyle(.secondary)
                Text("Emission \(speakerIndex + 1) of \(max(1, speakerCount))")
                    .foregroundStyle(.secondary)
                Text("Measurement \(measurement) of \(totalMeasurements) · Pass \(pass) of \(totalPasses)")
                    .foregroundStyle(.secondary)
            }
        case .applyingCorrection(let residual):
            Text("Applying correction · residual \(residual, format: .number.precision(.fractionLength(1))) ms")
                .foregroundStyle(.secondary)
        case .verifying(let pass):
            Text("Verifying alignment · pass \(pass)").foregroundStyle(.secondary)
        case .completed:
            Text("Calibration complete").foregroundStyle(.secondary)
        }
    } else {
        Text("Preparing calibration…").foregroundStyle(.secondary)
    }
}

private func calibrationConfidenceLabel(_ confidence: Double) -> String {
    switch confidence {
    case 0.8...: "High"
    case 0.6..<0.8: "Medium"
    default: "Low"
    }
}
