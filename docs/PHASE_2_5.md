# Microphone-based acoustic calibration

Status: implemented and hardware-tested on 4 September 2026.

## What works

`speakerr-test calibrate` now:

> **Listening position:** Calibration assumes the laptop and microphone are at your intended listening position. The resulting speaker sync is optimized for that position.

1. creates the existing private, non-stacked two-output aggregate;
2. uses output A as its clock source and verifies drift compensation for output B;
3. starts raw AUHAL microphone capture once;
4. starts aggregate output once;
5. emits an interleaved `A B A B A B` measurement sequence (with two bounded retry opportunities per speaker) on a precomputed output-frame timeline;
6. estimates each acoustic arrival with normalised cross-correlation;
7. rejects weak or ambiguous measurements;
8. uses the median of three valid measurements per speaker;
9. applies a non-negative fractional delay without restarting either stream;
10. verifies the result and performs at most two further corrections (three measurement passes total);
11. reports per-trial confidence, spread, median absolute deviation, residual, and convergence failure;
12. optionally writes microphone/reference WAV files and JSON metadata; and
13. optionally measures fixed-compensation stability at 0, 30, 60, 120, and 300 seconds.

The calibration engine is used by both the menu-bar calibration sheet and `speakerr-test`. It runs within the persistent two-speaker output session, so ordinary programme playback resumes without rebuilding the aggregate.

## Audio and timing architecture

The calibration path uses two AUHAL audio units:

- one output unit bound to the existing temporary CoreAudio aggregate;
- one input-only unit bound directly to the selected microphone.

The input unit requests non-interleaved 32-bit float PCM and does not use Voice Processing I/O. It therefore does not enable telephony echo cancellation, noise suppression, or voice AGC. Capture storage and timestamp anchors are preallocated; the realtime callback performs no file I/O or logging.

The streams start only once for the complete experiment. Chirps are scheduled at deterministic `Int64` frame positions in the continuously running output callback. When an emission begins, Speakerr derives its host time from the callback's valid `AudioTimeStamp.mHostTime` plus its exact in-buffer frame offset. Every microphone callback stores its first capture sample index, `mHostTime`, and (when valid) `mSampleTime`.

Detected microphone sample positions are interpolated against the nearest capture host-time anchor. For each emission:

```text
acousticLatency = detectedInputHostTime - scheduledOutputHostTime
```

For the two speakers:

```text
relativeArrival =
    (detectedArrivalB - detectedArrivalA)
    - (scheduledEmissionB - scheduledEmissionA)
```

Computing the two host-referenced acoustic latencies and subtracting them is algebraically equivalent to that expression. CLI scheduling latency, pass analysis time, and the time taken to invoke the next command are not part of the result. Polling sleeps are used only to learn that a pre-scheduled pass has finished; they never establish an audio timestamp.

The microphone's native nominal rate must match the aggregate rate for acoustic calibration. Bose, MIDDLETON, and the built-in Mac microphone all ran at 44.1 kHz during these tests. A mismatched input fails clearly instead of silently applying an unverified clock conversion or sample-rate conversion.

## Calibration signal

The default signal is a deterministic logarithmic chirp:

- 500 Hz to 12 kHz;
- 30 ms during the fast calibration schedule;
- 10 ms Hann-shaped fade-in and fade-out;
- `0.12` default digital level, configurable from `0` to `0.5`;
- `0.08` used for the hardware experiments below.

The generator validates Nyquist limits, duration, and safe level. It produces the same samples for the same configuration and rate.

## Estimator and confidence

The initial estimator is zero-mean normalised cross-correlation. Correlation is calculated as an FFT convolution, with sliding recording energy derived from prefix sums. It searches only the expected acoustic-latency window (currently 0–80 ms, with 20 ms of pre-search tolerance).

The reported peak position uses three-point parabolic interpolation. Internal values retain sample/sub-sample precision; CLI formatting does not alter the compensation value.

Confidence combines:

- absolute normalised peak magnitude (75% weight); and
- prominence over the strongest peak outside a 12 ms exclusion region (25% weight).

A result is rejected unless peak magnitude is at least `0.12`, prominence is at least `1.08`, confidence is at least `0.35`, and recording/reference energy is sufficient. These thresholds are deliberately conservative starting points, not claims of universal room robustness.

## Compensation and convergence

Manual and calibration delays are separate:

```text
effectiveDelay = manualDelay + calibrationDelay
```

Only the earlier arrival is delayed. Subsequent residual corrections only add non-negative delay to the currently earlier side, so no negative playback delay is requested. Effective delay remains bounded by the existing 1000 ms delay-line limit.

The target is an absolute residual no greater than 2 ms. Calibration stops after three total measurement passes, or sooner on success. It also stops if correction signs oscillate repeatedly. Failure is reported rather than declaring alignment.

## Automated tests

There are 28 passing tests. New coverage includes:

- chirp sample count, duration, determinism, finite values, fades, amplitude, clipping prevention, and invalid configuration;
- clean synthetic delays of 0, 10, 68, 73.5, 150, and 300 ms at 44.1 and 48 kHz;
- fractional delay recovery;
- gain reduction and deterministic moderate noise;
- direct arrival plus reflections at +17 ms / -8 dB and +41 ms / -13 dB;
- multiple/ambiguous competing peaks and weak-signal rejection;
- restricted expected-arrival search windows;
- median, spread, median absolute deviation, compensation direction and maximum delay;
- convergence, pass limit, and oscillation handling;
- host-time/sample-index mapping and stability scheduling; and
- diagnostic IEEE-float WAV structure.

All synthetic accepted-delay assertions pass within 0.12 ms or better; clean cases use a 0.04 ms tolerance and fractional recovery a 0.025 ms tolerance.

## Bose / MIDDLETON hardware results

Hardware:

- output A / aggregate clock: Bose SoundLink Max (`68-F2-1F-55-9C-BA:output`);
- output B / drift compensated: MIDDLETON (`68-59-32-EA-E5-67:output`);
- input: MacBook Pro Microphone (`BuiltInMicrophoneDevice`);
- rate: 44,100 Hz;
- calibration level: 0.08.

Four fresh continuous sessions were run. Three were ordinary complete calibration attempts; the fourth continued through a five-minute fixed-delay stability experiment.

| Run | Initial B−A | Initial paired range | Applied result | Final residual | Outcome |
| --- | ---: | ---: | --- | ---: | --- |
| 1 | -47.89 ms | -47.58…-48.28 ms | MIDDLETON +49.97 ms after two corrections | -1.41 ms | success |
| 2 | -66.04 ms | -66.16…-65.76 ms | MIDDLETON +66.04 ms, then Bose +2.31 ms | +2.56 ms | bounded non-convergence |
| 3 | -58.00 ms | -58.00…-57.92 ms | MIDDLETON +58.00 ms | +0.50 ms | success |
| 4 | -57.77 ms | -57.77…-57.70 ms | MIDDLETON +57.77 ms | +0.47 ms | success |

Negative B−A means MIDDLETON arrived earlier and therefore needed delay. Across the four fresh sessions, the median initial offset was `-57.89 ms` and the mean was `-57.43 ms`. The range was large: 18.15 ms from least to most negative. This is direct evidence that an old calibration should not be blindly reused after a new Bluetooth session.

Initial within-pass paired relative spreads were 0.70, 0.40, 0.08, and 0.07 ms respectively. Three of four runs met the 2 ms target. Runs 3 and 4 needed one correction. Run 1 needed two. Run 2 crossed correction sign and remained at 2.56 ms when the bounded pass limit was reached; it was correctly reported as failure.

Confidence was approximately 0.40–0.51 for Bose and 0.53–0.60 for MIDDLETON. Peak prominence remained well above the acceptance threshold. The lower Bose confidence was repeatable and appears attributable to its captured response/room path rather than unstable peak selection.

### Fixed-compensation stability

Run 4 held MIDDLETON at exactly +57.766334 ms after verification and made no later corrections:

| Stability checkpoint | Median residual B−A | Pair values |
| --- | ---: | --- |
| verification | +0.47 ms | +0.36, +0.47, +0.59 ms |
| t=0 s baseline | +1.73 ms | +1.65, +1.73, +1.81 ms |
| t=30 s | +2.41 ms | +2.36, +2.41, +2.46 ms |
| t=60 s | +2.72 ms | +2.71, +2.72, +2.75 ms |
| t=120 s | +2.25 ms | +2.23, +2.25, +2.26 ms |
| t=300 s | +3.21 ms | +2.90, +3.23, +3.21 ms |

The `t=0` stability baseline occurs after the pre-reserved third correction-pass slot, approximately 47 seconds into the continuous stream. This keeps every later checkpoint on a schedule created before audio started.

MIDDLETON's host-referenced arrival was nearly flat during the later checkpoints. Bose's arrival shortened slowly, causing residual to move by a few milliseconds. There was no runaway divergence and no obvious discrete jump within the five-minute session. There were, however, large discrete changes between fresh sessions (`-47.89`, `-66.04`, `-58.00`, and `-57.77 ms`).

Drift compensation therefore appears to keep the sample streams coherent, but it cannot guarantee constant Bluetooth buffering/internal-DSP latency. A reconnect-aware recalibration policy remains necessary, and a longer-term product may need occasional explicit probe/recalibration if a persistent <=2 ms target is required.

## Running it

```bash
xcodegen generate
xcodebuild -project speakerr.xcodeproj \
  -scheme speakerr-test \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO
.build/Build/Products/Debug/speakerr-test devices
.build/Build/Products/Debug/speakerr-test calibrate
```

Explicit verbose run:

```bash
.build/Build/Products/Debug/speakerr-test calibrate \
  --output-a '68-F2-1F-55-9C-BA:output' \
  --output-b '68-59-32-EA-E5-67:output' \
  --input 'BuiltInMicrophoneDevice' \
  --gain 0.08 \
  --verbose \
  --save-diagnostics ./diagnostics/run
```

Add `--stability` to run the fixed-compensation 0/30/60/120/300-second sequence. Recordings are never saved unless `--save-diagnostics` is present. The `diagnostics/` directory is ignored by Git. The first microphone run may cause macOS to request permission for the invoking terminal/development process; denial is reported clearly.

## Known limits and failure cases

- Input and aggregate sample rates must currently match exactly.
- The expected acoustic latency window is capped at 80 ms.
- Normalised cross-correlation can still fail if the direct path is much weaker than a reflection, the room is very noisy, a speaker heavily suppresses the chirp band, or two plausible peaks have similar strength.
- The current confidence thresholds are based on synthetic cases and this one room/device pair; broader hardware validation is needed.
- No GCC-PHAT, band-pass preprocessing, automatic gain adaptation, device reconnect handling, or persistence is part of this phase.
- Calibrated delays remain active for the current persistent speaker session and are invalidated when the route is rebuilt; the menu-bar app prompts for a fresh calibration.
- Stability measurements observe and report drift but intentionally do not correct it.
- The CLI does not silently accept non-convergence. Run 2 demonstrates the bounded failure path.

CamillaDSP and BlackHole are not required for calibration. No custom virtual audio driver is used.
