import AppKit
import SpeakerrAudio
import SpeakerrPresentation
import SwiftUI

struct MainWindowView: View {
    @Bindable var model: SpeakerrViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.preferences.selectedSpeakerUIDs.count != 2 && model.presentation.speakers.isEmpty {
                firstRun
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        speakersSection
                        Divider()
                        calibrationSection
                        Divider()
                        playbackSection
                        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                            AdvancedTimingView(model: model)
                                .padding(.top, 10)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(.background)
        .sheet(isPresented: $model.isSpeakerSelectionPresented) {
            SpeakerSelectionView(model: model)
        }
        .sheet(isPresented: $model.isCalibrationPresented) {
            CalibrationSheet(model: model)
        }
        .sheet(isPresented: $model.isDiagnosticsPresented) {
            DiagnosticsView(model: model)
        }
        .overlay {
            if model.isBusy && model.presentation.status != .calibrating {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Speakerr")
                .font(.title2.weight(.semibold))
            Spacer()
            Label(model.presentation.status.rawValue, systemImage: statusSymbol(model.presentation.status))
                .foregroundStyle(statusColor(model.presentation.status))
                .accessibilityLabel("Speakerr status: \(model.presentation.status.rawValue)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var firstRun: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Image(systemName: "hifispeaker.2")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Play two speakers in sync.")
                .font(.title2.weight(.semibold))
            Text("Speakerr measures acoustic timing with your Mac’s microphone and compensates for differences automatically.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430, alignment: .leading)
            Button("Choose Speakers…") { model.isSpeakerSelectionPresented = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Speakers")
            if model.presentation.speakers.isEmpty {
                Text("Select two output devices to create a Speakerr group.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 32) {
                    ForEach(model.presentation.speakers) { speaker in
                        SpeakerSummaryView(speaker: speaker)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button("Change Speakers…") { model.isSpeakerSelectionPresented = true }
        }
    }

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Calibration")
            CalibrationSummaryView(presentation: model.presentation.calibration, detail: model.presentation.statusDetail)
            HStack {
                Button(calibrationButtonTitle) { model.isCalibrationPresented = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.presentation.status == .waitingForSpeaker || model.presentation.speakers.count != 2)
                Button("Recheck") { model.recheck() }
                    .disabled(model.presentation.status != .aligned && model.presentation.status != .alignmentDrifting)
                if model.presentation.status == .alignmentDrifting {
                    Button("Apply Correction") { model.applyLatestCorrection() }
                }
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Playback")
            LabeledContent("System Audio") {
                Text(model.presentation.playback.statusText)
                    .foregroundStyle(model.presentation.playback.isProgrammeAttached ? .primary : .secondary)
            }
            if model.presentation.status == .waitingForSpeaker, let detail = model.presentation.statusDetail {
                Label(detail, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if model.presentation.playback.isActive {
                    Button("Pause Speakerr") { model.pause() }
                } else {
                    Button("Resume Speakerr") { model.start() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Diagnostics…") { model.isDiagnosticsPresented = true }
                Button("Settings…") { openSettings() }
            }
        }
    }

    private var calibrationButtonTitle: String {
        switch model.presentation.calibration {
        case .valid: "Calibrate Again…"
        default: "Calibrate…"
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

private struct SpeakerSummaryView: View {
    let speaker: SpeakerViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speaker.name)
                .font(.headline)
                .lineLimit(1)
            Label(speaker.isConnected ? "Connected" : "Disconnected", systemImage: speaker.isConnected ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(speaker.isConnected ? Color.secondary : Color.red)
            Text(transportName(speaker.transport))
                .foregroundStyle(.secondary)
            Text("Delay \(speaker.effectiveDelayMilliseconds, format: .number.precision(.fractionLength(1))) ms")
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CalibrationSummaryView: View {
    let presentation: CalibrationPresentation
    let detail: String?

    var body: some View {
        switch presentation {
        case .valid(let residual, _, let date):
            LabeledContent("Residual error") { Text("\(residual, format: .number.precision(.fractionLength(2))) ms").monospacedDigit() }
            LabeledContent("Last calibrated") { Text(date, style: .relative) }
        case .required(let reason):
            Label("Calibration required", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(reason).foregroundStyle(.secondary)
        case .ready:
            Text("Ready to calibrate").font(.headline)
            Text("Place this Mac near your normal listening position.").foregroundStyle(.secondary)
        case .running(let progress):
            ProgressView()
            Text(progress.map(calibrationPhaseText) ?? "Preparing calibration…")
        case .failed(let outcome):
            Text(calibrationOutcomeText(outcome)).foregroundStyle(.secondary)
        case .unavailable:
            Text(detail ?? "Calibration is unavailable until both speakers are connected.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AdvancedTimingView: View {
    @Bindable var model: SpeakerrViewModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(model.presentation.speakers) { speaker in
                GridRow {
                    Text(speaker.name).lineLimit(1)
                    if let components = speaker.delayComponents {
                        DelayField(value: components.manual) { model.setManualDelay(outputUID: speaker.id, milliseconds: $0) }
                        Text("Calibration \(components.calibration, format: .number.precision(.fractionLength(2))) ms")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("Dynamic \(components.dynamicCorrection, format: .number.precision(.fractionLength(2))) ms")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

private struct DelayField: View {
    @State var value: Double
    let commit: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField("Manual delay", value: $value, format: .number.precision(.fractionLength(2)))
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .onSubmit { commit(max(0, value)) }
            Text("ms").foregroundStyle(.secondary)
        }
    }
}

func transportName(_ transport: TransportType) -> String {
    switch transport {
    case .builtIn: "Built-in"
    case .bluetooth: "Bluetooth"
    case .usb: "USB"
    case .hdmi: "HDMI"
    case .displayPort: "DisplayPort"
    case .airPlay: "AirPlay"
    case .virtual: "Virtual"
    case .aggregate: "Aggregate"
    case .thunderbolt: "Thunderbolt"
    case .pci: "PCI"
    case .fireWire: "FireWire"
    case .avb: "AVB"
    case .unknown: "Audio device"
    }
}

func calibrationPhaseText(_ update: CalibrationProgressUpdate) -> String {
    switch update.phase {
    case .measuring(_, let name, let pass, let totalPasses, let measurement, let totalMeasurements):
        "Measuring \(name) — measurement \(measurement) of \(totalMeasurements), pass \(pass) of \(totalPasses)"
    case .applyingCorrection: "Applying correction…"
    case .verifying: "Verifying alignment…"
    }
}

func calibrationOutcomeText(_ outcome: CalibrationOutcome) -> String {
    switch outcome {
    case .none: ""
    case .success(let residual): "Speakers aligned with \(residual.formatted(.number.precision(.fractionLength(2)))) ms residual."
    case .nonConverged(let residual, _): "Speakerr could not fully align the speakers. Current residual: \(residual.formatted(.number.precision(.fractionLength(2)))) ms."
    case .lowConfidence(let message): message
    case .cancelled: "Calibration was cancelled."
    }
}
