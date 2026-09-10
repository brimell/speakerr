# Speakerr two-speaker playback and routing

Status: implemented and integrated into the menu-bar application and `speakerr-test` diagnostics.

This documents the native CoreAudio two-speaker playback path. The same routing backend is used by the menu-bar app and the CLI diagnostics; microphone calibration and system-audio playback are documented in the later sections.

## What works

- Enumerates CoreAudio output devices and microphones with stable UID, current numeric CoreAudio ID, transport, sample rate, and channel count.
- Selects two non-aggregate output devices interactively or by UID.
- Creates and removes a process-private CoreAudio aggregate automatically; Audio MIDI Setup does not need manual configuration.
- Uses the first selected output as the aggregate clock source and enables maximum-quality CoreAudio drift compensation for the second output.
- Exposes each physical device as an independent channel range in one aggregate render callback.
- Plays the same repeating, deterministic broadband transient through both outputs.
- Applies an independent 0–1000 ms fractional delay to each device, adjustable live to 0.1 ms.
- Routes stereo to stereo devices, downmixes to mono, and silences channels beyond the first stereo pair.
- Emits unified logs under the `com.brimell.speakerr` subsystem and prints the selected UIDs, rates, clock source, drift state, delays, and routing status in the CLI.
- Restores any changed physical-device sample rates on shutdown on a best-effort basis.

The implementation has been exercised with Bose SoundLink Max and Marshall MIDDLETON Bluetooth speakers at 44.1 kHz. The temporary aggregate exposed four independent channels and was absent again after shutdown.

## Current constraints

- Exactly two physical output devices are supported per synchronized group.
- System-audio input requires BlackHole or another stereo virtual/loopback input.
- More than two simultaneous outputs and nesting an existing Aggregate/Multi-Output Device are not supported.
- Continuous automatic drift correction during programme playback is not enabled; use calibration or an explicit recheck/correction.
- CamillaDSP and a custom virtual audio driver are not required or included.

## Architecture

`SpeakerrAudio` is a Swift 6 static framework. `AudioDeviceDiscovery` handles CoreAudio enumeration. `AudioRoutingBackend` isolates routing operations, and `CoreAudioAggregateRoutingBackend` is the native Phase 1 implementation.

For playback, Speakerr creates a non-stacked private aggregate. This concatenates the physical output channels rather than collapsing them into a duplicated stereo pair. A single AUHAL callback generates stereo source frames once, runs one realtime-safe fractional delay line per device, then writes each result into that device's aggregate channels. The delay target is published atomically; the callback performs no locks, logging, or allocation.

The aggregate creation dictionary and its returned composition identify the first device as clock source and the second as drift compensated. Playback fails clearly if the aggregate does not expose the expected channel count or if drift compensation is not present in the returned composition.

CamillaDSP is not required. BlackHole is not required by `speakerr-test`; it remains required for the existing system-wide EQ feature.

## Build and test

Install XcodeGen once if necessary:

```bash
brew install xcodegen
```

Generate the project, build both products, and run the signal-processing tests:

```bash
xcodegen generate
xcodebuild -project speakerr.xcodeproj -scheme speakerr -configuration Debug -derivedDataPath /tmp/speakerr-app CODE_SIGNING_ALLOWED=NO build
xcodebuild -project speakerr.xcodeproj -scheme speakerr-test -configuration Debug -derivedDataPath /tmp/speakerr-cli CODE_SIGNING_ALLOWED=NO build
xcodebuild -project speakerr.xcodeproj -scheme SpeakerrAudio -configuration Debug -derivedDataPath /tmp/speakerr-tests CODE_SIGNING_ALLOWED=NO test
```

The tests cover integer and fractional delay, stereo separation, circular-buffer wraparound, atomic delay updates, bounds rejection, channel assignment for mono/stereo/wider devices, aggregate configuration, and interactive command parsing.

## Reproduce the two-speaker test

1. Connect both speakers in macOS and make sure each appears as an output device.
2. Build the CLI:

   ```bash
   xcodegen generate
   xcodebuild -project speakerr.xcodeproj -scheme speakerr-test -configuration Debug -derivedDataPath /tmp/speakerr-cli CODE_SIGNING_ALLOWED=NO build
   ```

3. Confirm both speakers and the intended future calibration microphone are visible:

   ```bash
   /tmp/speakerr-cli/Build/Products/Debug/speakerr-test devices
   ```

4. Start the interactive test and choose two different non-aggregate output indices:

   ```bash
   /tmp/speakerr-cli/Build/Products/Debug/speakerr-test play
   ```

   For repeatable selection, pass the stable UIDs printed by `devices`:

   ```bash
   /tmp/speakerr-cli/Build/Products/Debug/speakerr-test play --output-a '<speaker-a-uid>' --output-b '<speaker-b-uid>'
   ```

5. Adjust either route while the transient repeats:

   ```text
   a +10
   a -1
   b +0.1
   a 73.4
   status
   quit
   ```

6. Optionally inspect structured logs in another terminal:

   ```bash
   log stream --level info --predicate 'subsystem == "com.brimell.speakerr"'
   ```

`quit`, end-of-input, or Control-C stops AUHAL and destroys the private aggregate. Because this phase performs manual alignment only, the result is not saved after exit.
