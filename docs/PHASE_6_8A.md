# Device lifecycle and system-audio playback

Status: implemented and integrated into the menu-bar application and CLI.
Automated coverage includes state transitions, route rebuilds, calibration
invalidation, buffering, programme playback, and presentation behavior.
Hardware validation has been performed with the Bose SoundLink Max and
MIDDLETON pair. Bluetooth timing can vary between fresh connections, so the
app requests a fresh calibration after a route rebuild.

## 1. Device lifecycle architecture

`CoreAudioDeviceMonitor` (`SpeakerrAudio/Session/CoreAudioDeviceMonitor.swift`)
watches:

- the global CoreAudio device list (`kAudioHardwarePropertyDevices`);
- the default output device;
- per-selected-device `kAudioDevicePropertyNominalSampleRate`,
  `kAudioDevicePropertyStreamConfiguration`, and `kAudioDevicePropertyDeviceIsAlive`;
- an optional aggregate-device liveness listener (`watchAggregate`), used to
  detect destruction of Speakerr's own private aggregate from outside the
  process;
- `NSWorkspace` sleep/wake notifications.

CoreAudio commonly delivers several related property-listener callbacks for a
single physical event (e.g. a Bluetooth reconnect can produce 3-5
notifications in quick succession). All notifications are coalesced onto a
private serial queue with a 350 ms debounce window before the monitor
re-enumerates devices and diffs them, so one physical event yields one
`AudioLifecycleEvent.devicesChanged` callback. `NotificationCoalescer` captures
the coalescing rule as pure, independently-testable logic (see
`testDuplicateNotificationsCoalesce`).

`DeviceLifecycleComparison.compare` is the pure diffing function. It compares
a `[String: DeviceIdentitySnapshot]` map keyed by stable `kAudioDevicePropertyDeviceUID`
values, never by `AudioObjectID`, and reports, per selected UID:

- `.disconnected` — UID present before, absent now;
- `.reconnected(uid:oldObjectID:newObjectID:)` — UID present in both, but the
  `AudioObjectID` differs (this is the common Bluetooth-reconnect case: macOS
  assigns a new object ID to the same physical/UID device);
  the case where the UID first appears with no prior identity is also
  reported as `.reconnected(oldObjectID: nil, ...)`;
- `.sampleRateChanged` — UID's nominal rate differs;
- `.channelLayoutChanged` — UID's output channel count differs.

AudioObjectIDs are only ever read from `AudioDeviceDiscovery` at the moment
they are needed; they are never persisted across a disconnect. Everything
that identifies a device or a calibration result keys off the UID.

## 2. Session state machine

`SpeakerSessionStateMachine` (`SpeakerrAudio/Session/SpeakerSessionState.swift`)
is a small, dependency-free value type independent of CoreAudio, so it is
tested purely as a state graph (`SpeakerSessionStateTests`, 15 tests):

```
idle --prepare--> preparing --prepared--> ready
ready/aligned/calibrationStale --beginCalibration--> calibrating
calibrating --calibrationSucceeded--> aligned
calibrating --calibrationFailed--> failed
ready/aligned/calibrating --invalidate(reason)--> calibrationStale(reason)
ready/aligned/calibrationStale/unavailable/failed --beginRebuild--> rebuilding
rebuilding --prepare--> preparing (re-enters the normal prepare/prepared path)
rebuilding --rebuildSucceeded--> calibrationStale(.routeRebuilt)  (used only if prepare is skipped)
any state --outputUnavailable(reason)--> unavailable(reason)
any state --stop--> idle
```

`PersistentSpeakerSession.rebuild(reason:)` drives `beginRebuild`, tears down
and recreates the aggregate/output unit, then re-enters through `prepare` /
`prepared` (reusing the same code path as the initial `start()`), and finally
calls `invalidate(reason)` so the final state carries the *actual* reason
(`deviceReconnected`, `sampleRateChanged`, `systemWoke`, `deviceSetChanged`,
...) rather than a generic "route rebuilt" placeholder. `beginRebuild` is
rejected from `.idle` (a session that has never started has nothing to
rebuild), which is deliberate and unit-tested
(`testBeginRebuildIsRejectedBeforeTheSessionHasEverStarted`).

## 3. Calibration validity / session generation

`CalibrationSnapshot` records `outputUIDs`, `sampleRate`,
`compensationByUID`, `residualMilliseconds`, `confidence`, `calibratedAt`,
and `sessionGeneration`. `PersistentSpeakerSession.generation` is a `UInt64`
that increments on every event that can change latency:

- device disconnect (`markOutputsUnavailable`);
- successful or failed rebuild (`performRebuild`);
- explicit `invalidate(_:)` calls.

`calibrationIsValid` requires **all** of:

```swift
calibrationSnapshot?.isValid(outputUIDs: outputUIDs, sampleRate: sampleRate, sessionGeneration: generation) == true
    && stateMachine.state == .aligned
```

`CalibrationSnapshot.isValid` checks generation, exact UID *order* (not just
set membership — swapping A/B is not the same calibration), and sample rate.
Device names are never consulted; two devices can share a name, and a UID can
in principle survive a firmware update that changes the reported name, so
name equality is deliberately not part of the validity check.

## 4. Automatic aggregate reconstruction

`PersistentSpeakerSession.performRebuild(reason:)`:

1. guarded by a `rebuilding` boolean so concurrent/duplicate lifecycle events
   coalesce into one rebuild instead of stacking;
2. remembers the previously attached programme (system-audio) input, if any;
3. stops programme capture, stops/destroys the microphone capture, stops and
   disposes the output `AudioUnit`, releases the render state, and destroys
   the private aggregate (`AggregateDeviceManager.destroy()` — idempotent by
   construction, it is a no-op if there is no live session);
4. re-resolves each selected UID to a **current** `OutputDevice` via a fresh
   `AudioDeviceDiscovery().outputDevices()` call; if any selected UID is not
   currently present, the rebuild stops here and the state becomes
   `.unavailable(...)` — it does not throw a hard error, because "the speaker
   is still disconnected" is an expected, recoverable condition, not a bug;
5. increments `generation` and clears `calibrationSnapshot`;
6. calls `start()` again, which creates a fresh private aggregate from the
   newly-resolved `AudioObjectID`s, builds a fresh render state and output
   unit, and restarts output;
7. re-applies the previously-configured `DelayComponents` (manual +
   calibration + dynamic) to the new render state — the *numbers* survive a
   rebuild, but calibration is immediately marked stale afterwards so no one
   can act on stale numbers as if they were still valid;
8. marks the outcome stale with the real reason;
9. re-attaches the programme (system-audio) capture if one was active before
   the rebuild, so ordinary system audio resumes automatically once the
   rebuilt aggregate is live;
10. re-installs the aggregate-liveness listener on the new aggregate's
    `AudioObjectID` (the old one is gone).

Repeated notifications for one physical event do not cause repeated rebuilds:
the monitor's own debouncing collapses the CoreAudio notification burst
before `performRebuild` is even called, and `rebuilding` additionally guards
against any residual re-entrancy.

No `sleep()` calls are used for synchronisation anywhere in this path; the
debounce uses `DispatchWorkItem` + `asyncAfter` cancellation/rescheduling, and
render-state readiness is polled by comparing `renderState.renderedFrames`
against a target frame count computed from the sample rate — a small poll
interval, not a fixed sleep used as a correctness mechanism.

## 5. System-audio capture architecture

Investigation of the existing EQ app (`speakerr/Audio`) confirmed it opens
its own AUHAL input bound to BlackHole, feeding its own bounded ring buffer
and its own AUHAL output — entirely separate CoreAudio objects from anything
in `SpeakerrAudio`. Nothing under `speakerr/` was modified. `SpeakerrAudio`
does not import or reference any EQ-specific type; the two only happen to use
the same *idea* (BlackHole ingress, bounded SPSC transport) independently.

`SystemAudioCapture` (`SpeakerrAudio/Capture/SystemAudioCapture.swift`) is a
new, small AUHAL input unit that:

- binds directly to whatever stereo `InputDevice` is selected at the CLI
  (typically BlackHole 2ch, but any stereo input works, including a physical
  interface's loopback if one exists);
- requests the **render** sample rate as its client-side format, so Apple's
  AUHAL sample-rate converter — not a hand-rolled one — absorbs any
  capture/render rate mismatch;
- writes captured frames into the session's `StereoRingBuffer` from the
  capture realtime callback, doing no allocation, logging, or file I/O in
  that callback.

BlackHole (or an equivalent virtual stereo device) is the practical ingress
for arbitrary system audio, because macOS has no public way to tap "whatever
the current default output device is playing" without a virtual audio driver
or an app-specific capture API. When a programme input is selected, Speakerr
temporarily makes that input the macOS default output, then restores the
previous route when playback stops. A custom `AudioServerPlugIn` is not
included.

Graph in practice:

```
macOS applications
     |
BlackHole 2ch (system output route, set by the user)
     |
SystemAudioCapture (AUHAL input, client format = render rate)
     |
StereoRingBuffer (bounded SPSC, capacity ~1s of frames)
     |
PersistentRenderState (single AUHAL output bound to the private aggregate)
     |-- FractionalDelayLine A -> Bose
     `-- FractionalDelayLine B -> MIDDLETON
```

## 6. Realtime buffering design

`StereoRingBuffer` (`SpeakerrAudio/DSP/StereoRingBuffer.swift`) is the shared
transport between the capture clock domain and the render clock domain:

- preallocated at construction (default capacity: 44,100 frames, ~1 s at
  44.1 kHz); no allocation ever happens in `write`/`read`;
- single-producer/single-consumer: the capture callback only calls `write`,
  the render callback only calls `read`; each side owns one atomic index and
  never blocks on the other;
- **overflow** (producer faster than consumer, or consumer paused/stalled):
  accepts as many frames as fit and drops the *newest* tail of the incoming
  block, incrementing `overflowCallbacks`/`droppedFrames`; existing buffered
  audio is left intact rather than being overwritten;
- **underflow** (consumer faster than producer, e.g. right after a mode
  switch): zero-fills the missing frames and increments `underflowCallbacks`;
  it never blocks or reads uninitialised memory;
- `discardAll()` is used only while the producer/consumer around it are
  paused (e.g. right before switching from programme to calibration mode) to
  avoid replaying stale audio;
- `counters()` returns a `Sendable` snapshot (`AudioTransportCounters`) for
  status reporting — no per-buffer logging is ever emitted from the realtime
  path, only monotonically increasing counters that the CLI/diagnostics layer
  can sample.

Capture clock domain: the AUHAL input unit's I/O clock, running at whatever
rate BlackHole (or the chosen input) is opened at, converted to the render
rate by AUHAL's own converter before it reaches `write`. Render clock domain:
the private aggregate's own output I/O clock (Bose as timing master, drift
compensation active for MIDDLETON) — this is the single authoritative clock
for calibration, delay lines, and playback.

## 7. Sample-rate handling

`SampleRateConversionPlan` (in `SystemAudioCapture.swift`) records
`captureRate`, `renderRate`, `ratio`, and `requiresConversion`, and is printed
by `speakerr-test system-audio` at startup. The AUHAL input unit is told to
present the render rate as its client format
(`kAudioUnitProperty_StreamFormat` on the output scope of the input unit), so
the OS-native converter does the resampling before Speakerr ever sees the
samples; Speakerr does not implement its own resampler. `SystemAudioCapture`
always uses a bounded 4,096-frame maximum callback size, so converter
buffering latency is bounded and does not grow over time — it only affects
absolute pipeline latency (acceptable per the requirements), not the
inter-speaker relative timing that calibration controls.

The Bose/MIDDLETON aggregate and its calibration require exact-rate-matching
between the aggregate and the microphone (documented already in Phase 2-5);
this constraint is unchanged. It does not extend to the *programme* audio
path, which is explicitly allowed to run at a different native rate from the
render/aggregate rate.

## 8. Calibration and normal audio share one output session

`PersistentSpeakerSession` owns exactly one `AudioUnit` bound to exactly one
private aggregate for its entire lifetime between `start()` and `stop()`/
`rebuild()`. `PersistentRenderState` has three render modes (`muted`,
`programme`, `calibration`) selected by an atomic flag read at the top of
every render callback; switching modes never stops or restarts the output
unit or the aggregate:

- `performCalibration` pauses (not stops) programme capture, discards
  buffered programme audio, switches the render mode to `.calibration`, runs
  the interleaved chirp measurement sequence against the *same* live output
  session, and on success or failure always calls `resumeProgramme()`, which
  switches the mode back to `.programme` (or `.muted` if no programme input
  was ever attached) and restarts programme capture;
- `recheck` does the same pause/measure/resume dance without applying any
  correction;
- manual delay changes (`setDelayComponents`) update the live
  `FractionalDelayLine` in place and never require a mode switch or restart.

This directly encodes the critical invariant from the spec: **a calibration
result belongs to one continuously live output session; only an event that
actually recreates that session invalidates it.** The only thing that
invalidates calibration is `invalidate(_:)`/`performRebuild(_:)`, and those
are exactly the operations that tear down and recreate the aggregate/output
unit. Ordinary calibrate → programme → calibrate cycles on a healthy,
connected pair never touch the aggregate or output unit at all.

## 9. Delay composition

```
effectiveDelay = manual + calibration + dynamicCorrection
```

`DelayComponents` (`SpeakerSessionState.swift`) validates each component
individually against `[0, 1000]` ms and validates the *sum* against
`FractionalDelayLine.maximumDelayMilliseconds`. `dynamicCorrection` starts at
`0` for every output and is only ever changed by the explicit `correct` CLI
command (`applyDynamicCorrection(relativeResidualBMinusA:)`), never
automatically. `recheck` reports residual and does not touch any delay
component. This plumbing exists specifically so a later continuous-correction
mechanism can be added by writing to `dynamicCorrection` without touching
`manual` or `calibration` semantics.

## 10. CLI: `speakerr-test system-audio`

```
speakerr-test system-audio [--output-a <uid>] [--output-b <uid>]
                            [--input <uid>] [--system-input <uid>]
                            [--gain <0.01...0.5>]
```

Flow: select A/B outputs -> select a microphone (for calibration/recheck) ->
select a stereo system-audio capture input (e.g. BlackHole 2ch) -> start the
persistent session -> start lifecycle monitoring -> run one full calibration
-> attach the system-audio input as programme source -> enter an interactive
loop:

- `status` — state, per-output manual/calibration/dynamic/effective delay,
  calibration validity + residual + confidence, transport counters
  (`captured`, `rendered`, `underflows`, `overflows`, `dropped`), render
  callback count, last render error if any;
- `recheck` — pause programme audio, one short interleaved timing check,
  report residual, resume; applies no correction;
- `correct` — apply the residual from the last `recheck` as a
  `dynamicCorrection` on the currently-early output; requires a prior
  `recheck` in the same command;
- `calibrate` — re-run the full calibration without restarting the output
  session;
- `a`/`b` `+0.1`/`-0.1`/`+10`/`-10`/absolute-ms — manual delay adjustment,
  reusing the existing `InteractiveDelayCommand` parser from Phase 1;
- `quit` / Ctrl-C — stop the session (idempotent; safe to call twice).

## 11. Reconnect measurements

Collected on 4 September 2026 with the real Bose SoundLink Max + MIDDLETON,
driving `speakerr-test system-audio` interactively (stdin fed through a
named pipe so the process stayed alive across the physical
disconnect/reconnect):

| Step | Observed |
| --- | --- |
| Standalone `calibrate` (sanity check) | B-A -71.66 ms -> converged to -1.55 ms residual |
| `system-audio` calibrate | Converged to -0.27 ms residual, state `aligned`, BlackHole attached as programme input |
| Disconnect MIDDLETON | `CoreAudioDeviceMonitor` detected it within the debounce window; state -> `unavailable("one or more selected outputs are not currently connected")`; `calibrationSnapshot` cleared; output unit stopped/disposed and aggregate destroyed; render callbacks reset to 0; transport drained with 0 underflows/overflows/dropped frames |
| Reconnect MIDDLETON | Detected automatically; `performRebuild(.deviceReconnected)` resolved both UIDs to current `AudioObjectID`s, recreated the private aggregate and output unit, and resumed rendering (callback count climbing again: 488, then 746); state -> `calibrationStale(deviceReconnected)` — the **prior 58.62 ms calibration was not treated as valid**, even though its numeric delay was still applied pending recalibration |
| Recalibrate after rebuild | Converged to +1.38 ms residual; state -> `aligned`; render-callback count kept climbing continuously through calibrate/status calls afterwards (up to 4536), confirming the output session was not restarted again by the recalibration itself |

This directly confirms the two central claims of this phase on real
hardware: (1) a reconnect is detected and safely rebuilt without leaving a
corrupt aggregate or a hung capture unit, and (2) the stale calibration is
never silently reused — the CLI explicitly reported `stale/none` until a
fresh calibration pass completed.

The diagnostics and menu-bar app expose transport counters and timing state so
long-running playback can be monitored directly. Bluetooth buffering can
change between sessions, so a previous numeric delay is retained only as a
safe starting point and is never presented as valid alignment after a rebuild.

## 12. Sleep/wake behaviour

`systemSleep` marks calibration stale immediately (`invalidate(.systemWoke)`)
since Bluetooth links are commonly dropped/renegotiated across sleep.
`systemWake` triggers a full `performRebuild(.systemWoke)`, which re-resolves
both outputs by UID (they may or may not have new `AudioObjectID`s after
wake) and rebuilds the aggregate before resuming programme audio. This has
been implemented as the recovery path used by the application; calibration
remains stale until a fresh measurement completes.

## 13. Underflow/overflow counters

Exposed end-to-end via `PersistentSessionStatus.transport` ->
`AudioTransportCounters` -> the `status` CLI command. Synthetic
ring-buffer overflow/underflow behavior is covered by
`StereoRingBufferTests`, and the counters are available during ordinary
playback for diagnostics.

## 14. Known limitations

- BlackHole (or an equivalent virtual stereo device) is still required as
  system-audio ingress; Speakerr does not install its own virtual audio driver.
- `performRebuild` currently re-attaches the previous programme input by
  device reference; if the previously-selected BlackHole instance itself
  disappears (unlikely, but possible if the user removes the driver), the
  rebuild will still realign the two speakers but will not resume programme
  audio, and `status` will show `.aligned`/`.ready` with no active programme
  capture.
- Continuous automatic dynamic correction while music plays is intentionally
  not enabled; `correct` is a one-shot, explicit, user-triggered action.
