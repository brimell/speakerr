# Speakerr UI Phase: Architecture, Lifecycle, and Verification

**Date:** September 4, 2026  
**Status:** Implemented, automated test suite passing (60/60 tests), and validated on live macOS CoreAudio hardware.

---

## 1. Overview and Design Principles

The UI phase delivers a native macOS menu-bar and desktop control interface for the `SpeakerrAudio` CoreAudio engine. The design adheres strictly to the following principles:

1. **Target Separation and Safety:**
   - The legacy `speakerr` application target (the prototype EQ application) remains completely untouched and independent.
   - A dedicated static framework, `SpeakerrPresentation`, encapsulates view models, presentation state mapping, and session control abstraction.
   - A modern SwiftUI menu-bar app target, `SpeakerrMenuApp` (`Speakerr.app`, bundle identifier `com.brimell.speakerr.menu`, `LSUIElement: true`), provides the user interface.
2. **Deterministic State Derivation:**
   - The UI never mutates audio hardware directly or synthesizes alignment states.
   - Stored delay parameters or non-zero delay registers *never* display as `Aligned` unless a valid `CalibrationSnapshot` matches the active session generation, output UID ordering, and sample rate.
   - The presentation state machine is pure, deterministic, and independently verified via unit tests.
3. **Lifecyle and Threading:**
   - Real-time CoreAudio callbacks and device notification threads never touch SwiftUI directly.
   - All state updates are marshaled to `@MainActor` via `SpeakerrViewModel`.
   - Closing the primary window does not interrupt background routing or playback.
   - Standard macOS application lifecycle is honored: quit events (`Cmd+Q`, menu item, AppleScript, or OS shutdown) asynchronously tear down private aggregate devices and restore the macOS default output route before process exit.

---

## 2. Target and Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       SpeakerrApp                           │
│ (SpeakerrApp.swift, MainWindowView, WorkflowViews, Settings) │
└──────────────────────────────┬──────────────────────────────┘
                               │ Imports
┌──────────────────────────────▼──────────────────────────────┐
│                   SpeakerrPresentation                      │
│ (PresentationState.swift, SpeakerrViewModel, SessionCtrl)    │
└──────────────────────────────┬──────────────────────────────┘
                               │ Imports
┌──────────────────────────────▼──────────────────────────────┐
│                      SpeakerrAudio                          │
│ (PersistentSpeakerSession, Calibration, Device Discovery)   │
└─────────────────────────────────────────────────────────────┘
```

### 2.1 `SpeakerrPresentation`
- **`PresentationState.swift`**: Defines pure user-facing types (`UserSessionStatus`, `SpeakerViewState`, `CalibrationPresentation`, `CalibrationOutcome`, `PlaybackViewState`, `SpeakerrPresentationState`) and the pure `PresentationStateMapper`.
- **`SessionController.swift`**: Defines `SpeakerSessionControlling` and the actor implementation `CoreAudioSpeakerSessionController`. It wraps `PersistentSpeakerSession`, device discovery, and `SystemOutputRoute` (which switches the macOS default output device to BlackHole 2ch on start and restores the previous device on stop/deinit).
- **`SpeakerrViewModel.swift`**: An `@Observable` `@MainActor` coordinator that polls and reacts to session state, initiates calibration and recheck tasks, handles cooperative cancellation, and synchronizes user preferences to `UserDefaults`.

### 2.2 `SpeakerrApp`
- **`SpeakerrApp.swift`**: Root `@main` app with `MenuBarExtra` and custom `NSApplicationDelegate` (`SpeakerrAppDelegate`). Manages single-instance window presentation via `MainWindowCoordinator`.
- **`MainWindowView.swift`**: Native macOS window (680×610 pt) with header badge, speaker overview, calibration status, playback control, and collapsible Advanced Timing diagnostics.
- **`WorkflowViews.swift`**: Modal sheets for 2-speaker selection (with exact 2-device validation) and calibration (intro, mic permission, chirp progress, success, low-confidence, and non-convergence).
- **`SettingsAndDiagnostics.swift`**: Native settings tab view (General with `SMAppService.mainApp` launch-at-login, Audio with microphone/loopback selectors, Advanced with technical readouts).

---

## 3. Menu-Bar and Window Lifecycle

### 3.1 Menu Bar Integration
Because `Speakerr.app` is marked `LSUIElement: true`, it does not clutter the macOS Dock. The primary interface is a menu-bar item with dynamic SF Symbol representation:
- **`hifispeaker.2.fill`**: Aligned and playing.
- **`speaker.wave.2.fill`**: Calibrating or preparing audio engine.
- **`speaker.badge.exclamationmark.fill`**: Warning state (Calibration Stale, Waiting for Speaker, Alignment Drifting, or Audio Error).
- **`speaker.wave.2`**: Ready or inactive.

The menu bar dropdown includes real-time speaker names, latest residual error (in ms), quick actions (`Open Speakerr`, `Calibrate…`, `Recheck Alignment`, `Pause/Resume Speakerr`, `Settings…`), and a clean `Quit Speakerr` command.

### 3.2 Window Coordinator
The main window is managed by `MainWindowCoordinator.shared`:
- Setting `window.isReleasedWhenClosed = false` allows closing the window via the standard red close button without destroying view model state or restarting audio pipelines.
- Choosing `Open Speakerr` from the menu bar orders the existing window forward and activates the application.
- Window coordinates and dimensions are saved across sessions via `setFrameAutosaveName("SpeakerrMainWindow")`.

### 3.3 Asynchronous Termination Handling
When the application is asked to quit:
1. `NSApplicationDelegate.applicationShouldTerminate(_:)` is invoked.
2. It returns `.terminateLater` to AppKit to prevent abrupt process death.
3. An asynchronous Task invokes `await model.shutdown()`.
4. `controller.stop()` shuts down `PersistentSpeakerSession`, de-registers device listeners, terminates the private CoreAudio aggregate device, and invokes `SystemOutputRoute.restore()` to restore macOS system audio output to the user's prior output device.
5. The app calls `NSApplication.shared.reply(toApplicationShouldTerminate: true)` and cleanly exits with status code 0.

---

## 4. State Mapping and Determinism

`PresentationStateMapper` maps internal `SpeakerSessionState` to user-facing `UserSessionStatus`:

| Engine State (`SessionState`) | Calibration Valid? | User Status (`UserSessionStatus`) | UI Description / Action |
|:---|:---:|:---|:---|
| `idle` | — | `.inactive` | "Select two speakers to create a Speakerr group." |
| `preparing` | — | `.preparing` | "Creating aggregate device and allocating audio buffers…" |
| `ready` | No | `.readyToCalibrate` | "Speakers connected. Calibration is required for alignment." |
| `ready` / `aligned` | Stale UID / Generation | `.calibrationStale` | "Hardware configuration or rate changed. Recalibration required." |
| `calibrating` | — | `.calibrating` | Real-time progress bar, phase display, and chirp animation. |
| `aligned` | Yes | `.aligned` | Aligned banner with measured residual delay (e.g. `< 0.2 ms`). |
| `aligned` | Recheck > threshold | `.alignmentDrifting` | Warning badge, residual display, and dynamic correction button. |
| `unavailable` | — | `.waitingForSpeaker` | Missing speaker UID display; automatic reconnect monitor running. |
| `audioError` | — | `.audioError` | Specific error description with recovery recommendations. |
| Any (when paused) | — | `.paused` | "Routing paused. Background monitoring active." |

### 4.1 Calibration Snapshot Invalidation
The engine and presentation enforce that an alignment snapshot is valid if and only if:
- `outputUIDs == [speakerA.id, speakerB.id]` (exact identity and order)
- `sampleRate == session.sampleRate`
- `sessionGeneration == session.generation`

Any hardware disconnect, format change, or aggregate rebuild increments the session generation, immediately rendering the snapshot stale and preventing the UI from claiming alignment.

---

## 5. Calibration and Recheck Flow

1. **Permission Check:** Evaluates `AVCaptureDevice.authorizationStatus(for: .audio)`. Prompts natively for microphone access if ungranted.
2. **Measurement Phase:** Interleaves sweeps across both speakers, estimates arrival time via normalized cross-correlation (NCC), and calculates relative delay compensation.
3. **Outcomes:**
   - **Convergence:** Applies compensation delays to the Fractional Delay Line; status transitions to `.aligned`.
   - **Low Confidence:** Triggered if cross-correlation peak is below threshold; presents actionable feedback (adjust volume, reduce ambient noise, reposition mic).
   - **Non-Convergence:** Triggered if measurements exhibit high variance or room flutter; displays diagnostic details without invalidating previous safe delays.
   - **Cancellation:** If cancelled by the user, the calibration task is aborted and the pre-calibration state is seamlessly restored.

---

## 6. Verification and Validation Results

### 6.1 Automated Suite
The automated test suite in `SpeakerrAudioTests` covers 60 unit and integration tests across:
- Fractional delay lines and stereo ring buffers.
- FFT, chirp synthesis, and Normalized Cross Correlation delay estimation.
- Device discovery, aggregate construction, and stacked channel routing.
- State machine transitions, generation tracking, and lifecycle diffing.
- Pure presentation mapping (`PresentationStateMapper`).
- View model calibration cancellation and window close/reopen idempotency.

All 60 tests pass cleanly under `xcodebuild test -scheme SpeakerrAudio -destination 'platform=macOS'`.

### 6.2 Hardware Validation
Executed on Apple Silicon macOS 15 with:
- **Speaker A:** Bose SoundLink Max (`68-F2-1F-55-9C-BA:output`, Bluetooth, 44.1 kHz)
- **Speaker B:** MIDDLETON (`68-59-32-EA-E5-67:output`, Bluetooth, 44.1 kHz)
- **Microphone:** MacBook Pro Microphone (`BuiltInMicrophoneDevice`, Built-in, 44.1 kHz)
- **Loopback Input:** BlackHole 2ch (`BlackHole2ch_UID`, Virtual, 44.1 kHz)

**Observations:**
1. **Saved-UID Auto-Resume:**
   - Persisted preferences in `com.brimell.speakerr.menu` containing both speaker UIDs and BlackHole loopback were seeded.
   - On launching `Speakerr.app`, the session controller instantiated a private aggregate device (`com.brimell.speakerr.aggregate.*`) holding both Bluetooth outputs.
   - CoreAudio system logs confirmed input attached to `BlackHole2ch_UID` and output routed to the aggregate.
   - System output device was routed to BlackHole 2ch.
2. **Window and Menu Bar Interaction:**
   - Menu bar extra initialized immediately with current status.
   - Main window opened cleanly, reflecting both hardware devices and delay configurations.
   - Closing the window did not disrupt the CoreAudio IOProc or terminate playback.
3. **Graceful Teardown:**
   - Sending application quit event triggered AppKit `applicationShouldTerminate(_:) -> .terminateLater`.
   - CoreAudio logs showed:
     - `SessionCore_macOS_Legacy.mm:131 --> setPlayState Stopped Input {BlackHole2ch_UID}`
     - `SessionCore_macOS_Legacy.mm:131 --> setPlayState Stopped Output {com.brimell.speakerr.aggregate.*}`
     - Destructors for all AUHAL and IOProcs ran cleanly.
     - System default audio route was restored.
     - Process exited cleanly with return code 0.

---

## 7. Known Boundaries and Next Steps

- **Speaker Constraints:** Speakerr is designed specifically for stereo pairs (exactly two output endpoints). Multi-speaker (> 2) routing is deliberately not permitted in this phase.
- **Drift Correction Boundary:** As specified in the design requirements, continuous drift tracking is disabled. Alignment rechecks and corrections are user-initiated via the UI / Menu Bar Extra.
