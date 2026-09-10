# Physical calibration level sweep — 10 September 2026

The level sweep does not justify a permanent level increase or relaxed acceptance thresholds. The latest run first rejected JBL (stage **F. speaker 1 measurement**), then finished its logged attempts with only one accepted MIDDLETON measurement out of five. That accepted measurement reports acoustic latency **400.405041 ms** and confidence **0.355822**, barely above 0.35 and far from the earlier cluster. No compensation, delay application, recheck, or aligned-state success is recorded. All logged microphone clipping counts are zero; this is not an independent measurement of render-path or speaker-internal clipping.

The user confirmed that some settings or physical conditions changed. The scope and timing of those changes are unknown. Consequently these are descriptive observations, not a controlled comparison establishing the effect of probe amplitude. There is no justified best candidate level or completed set of at least 10 estimates at a verified unchanged setup. No application code or settings were changed during this analysis; the existing temporary Debug 0.25 override remains in the checkout, with production behavior untouched.

**Evidence and provenance.** Recovered local unified logs with `/usr/bin/log show --start "2026-09-10 05:45:00" --style compact --info --debug` filtered to Speakerr subsystems. Times below use the local log timestamps. Levels and commits are attributed from the supplied launch history; the runtime logs do not independently record probe amplitude or a binary hash. Current checkout before this report: `bd27e0c55e2ba1d13e8636e7a4b1d01e1adb7128`. Historical app path: `/Users/bill/Documents/GitHub/speakerr/build/ThreeSpeakerTrace/Build/Products/Debug/speakerr.app`. No Speakerr process was running when checked during this analysis. No rebuild or XCTest run was needed for this evidence-only report.

| Run ID | Level | Commit from launch history | First–last measurement | First rejection |
| --- | --- | --- | --- | --- |
| 80293-1 | 0.12 | ba1c085 | 06:10:24.391–06:10:40.508 | H. speaker 2 measurement / attempt 2 |
| 80293-2 | 0.12 | ba1c085 | 06:11:44.839–06:12:02.703 | F. speaker 1 measurement / attempt 1 |
| 81929-1 | 0.18 | 9a1f727 | 06:14:35.378–06:14:53.120 | F. speaker 1 measurement / attempt 1 |
| 82930-1 | 0.25 | bd27e0c | 06:17:07.057–06:17:23.282 | H. speaker 2 measurement / attempt 1 |
| 82930-2 | 0.25 | bd27e0c | 13:26:19.537–13:26:35.559 | H. speaker 2 measurement / attempt 1 |
| 82930-3 | 0.25 | bd27e0c | 13:27:12.071–13:27:29.833 | F. speaker 1 measurement / attempt 1 |

The first 0.12 run is the baseline most closely matching the supplied summary. A second baseline-process run and two later 0.25 runs are retained explicitly instead of pooling them by PID. All attempt rows, including exact localized estimator errors, are in [measurements.csv](measurements.csv); source events, request IDs, frame/host timestamps and mappings are in [runtime.log](runtime.log).

**Measurement definitions.** Tables report per-run, per-speaker medians including rejected attempts, except clipping is the sum and acceptance is a count. RMS and microphone peak use normalized sample amplitude; SNR is the existing diagnostic estimate in dB. The logged SNR is `20 log10(RMS(candidate A/B windows) / RMS(pre-candidate window))`; wrong candidates can make this a poor estimate of actual probe SNR. It is not an independent SNR measurement.

The field named `detectedLatencyMilliseconds` in the diagnostic line is actually the candidate offset relative to the capture slice, including roughly 5 ms of pre-roll. Tables label it **slice offset** to keep comparisons consistent with the earlier “~302 ms” baseline. Approximate emission-relative candidate latency is `sliceOffsetMs + (captureSliceStart - microphoneSampleIndex) / 44.1`. Accepted `Calibration measurement result` events use host-time conversion and are authoritative for acoustic latency; small differences from the sample-derived value are possible. Rejected candidates are not validated acoustic arrivals.

**Original level sequence.**

| Speaker / level / start | N | Mic RMS A | Mic RMS B | Mic peak | Noise RMS | SNR dB | Clipping total |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MacBook Pro Speakers / 0.12 / 06:10:24 | 3 | 0.064819 | 0.063337 | 0.184162 | 0.004494 | 23.156842 | 0 |
| JBL Go 5 / 0.12 / 06:10:24 | 3 | 0.008237 | 0.008125 | 0.032730 | 0.004078 | 5.174768 | 0 |
| MIDDLETON / 0.12 / 06:10:24 | 5 | 0.005817 | 0.005679 | 0.023300 | 0.004011 | 3.206933 | 0 |
| MacBook Pro Speakers / 0.18 / 06:14:35 | 3 | 0.064838 | 0.063714 | 0.186555 | 0.003865 | 24.162958 | 0 |
| JBL Go 5 / 0.18 / 06:14:35 | 4 | 0.009043 | 0.009000 | 0.033136 | 0.003857 | 7.432627 | 0 |
| MIDDLETON / 0.18 / 06:14:35 | 5 | 0.005388 | 0.005451 | 0.021798 | 0.003676 | 3.420855 | 0 |
| MacBook Pro Speakers / 0.25 / 06:17:07 | 3 | 0.064984 | 0.063277 | 0.179533 | 0.000827 | 37.698996 | 0 |
| JBL Go 5 / 0.25 / 06:17:07 | 3 | 0.008037 | 0.008046 | 0.027052 | 0.000769 | 19.805325 | 0 |
| MIDDLETON / 0.25 / 06:17:07 | 5 | 0.003856 | 0.003868 | 0.014074 | 0.000820 | 13.503492 | 0 |

| Speaker / level / start | Correlation peak | Second-best | Prominence | Peak score | Prominence score | Confidence | Slice offset ms | Accepted / rejected |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MacBook Pro Speakers / 0.12 / 06:10:24 | 0.596530 | 0.060907 | 9.821366 | 0.541512 | 1.000000 | 0.656134 | 323.445937 | 3 / 0 |
| JBL Go 5 / 0.12 / 06:10:24 | 0.576722 | 0.058036 | 10.511517 | 0.519002 | 1.000000 | 0.639252 | 461.781566 | 3 / 0 |
| MIDDLETON / 0.12 / 06:10:24 | 0.216981 | 0.054330 | 4.114291 | 0.110206 | 1.000000 | 0.332655 | 302.270001 | 1 / 4 |
| MacBook Pro Speakers / 0.18 / 06:14:35 | 0.578045 | 0.062417 | 9.263432 | 0.520506 | 1.000000 | 0.640379 | 323.528968 | 3 / 0 |
| JBL Go 5 / 0.18 / 06:14:35 | 0.561063 | 0.057641 | 9.734387 | 0.501208 | 1.000000 | 0.625906 | 470.228580 | 3 / 1 |
| MIDDLETON / 0.18 / 06:14:35 | 0.094724 | 0.085370 | 1.135683 | 0.000000 | 0.271366 | 0.067841 | 311.499816 | 0 / 5 |
| MacBook Pro Speakers / 0.25 / 06:17:07 | 0.591921 | 0.062287 | 9.503085 | 0.536273 | 1.000000 | 0.652205 | 323.446133 | 3 / 0 |
| JBL Go 5 / 0.25 / 06:17:07 | 0.561685 | 0.069705 | 8.104716 | 0.501915 | 1.000000 | 0.626436 | 465.114477 | 3 / 0 |
| MIDDLETON / 0.25 / 06:17:07 | 0.165792 | 0.098576 | 1.655160 | 0.052037 | 1.000000 | 0.289028 | 306.390507 | 0 / 5 |

**Additional recovered runs.**

| Speaker / level / start | N | Mic RMS A | Mic RMS B | Mic peak | Noise RMS | SNR dB | Clipping total |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MacBook Pro Speakers / 0.12 / 06:11:44 | 3 | 0.064658 | 0.064178 | 0.184528 | 0.003851 | 24.469242 | 0 |
| JBL Go 5 / 0.12 / 06:11:44 | 4 | 0.009045 | 0.009031 | 0.034933 | 0.003802 | 6.556057 | 0 |
| MIDDLETON / 0.12 / 06:11:44 | 5 | 0.005447 | 0.005507 | 0.021684 | 0.004113 | 2.486947 | 0 |
| MacBook Pro Speakers / 0.25 / 13:26:19 | 3 | 0.022602 | 0.022698 | 0.058731 | 0.000877 | 28.240966 | 0 |
| JBL Go 5 / 0.25 / 13:26:19 | 3 | 0.024201 | 0.024187 | 0.083759 | 0.000365 | 31.894956 | 0 |
| MIDDLETON / 0.25 / 13:26:19 | 5 | 0.000942 | 0.001684 | 0.010092 | 0.000461 | 9.968941 | 0 |
| MacBook Pro Speakers / 0.25 / 13:27:12 | 3 | 0.070065 | 0.068344 | 0.202352 | 0.000469 | 43.438204 | 0 |
| JBL Go 5 / 0.25 / 13:27:12 | 4 | 0.101953 | 0.101861 | 0.346490 | 0.000417 | 47.839602 | 0 |
| MIDDLETON / 0.25 / 13:27:12 | 5 | 0.016838 | 0.016874 | 0.069011 | 0.000367 | 33.235058 | 0 |

| Speaker / level / start | Correlation peak | Second-best | Prominence | Peak score | Prominence score | Confidence | Slice offset ms | Accepted / rejected |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MacBook Pro Speakers / 0.12 / 06:11:44 | 0.591866 | 0.062924 | 9.405981 | 0.536212 | 1.000000 | 0.652159 | 323.447078 | 3 / 0 |
| JBL Go 5 / 0.12 / 06:11:44 | 0.564873 | 0.055777 | 10.219285 | 0.505537 | 1.000000 | 0.629153 | 459.387452 | 3 / 1 |
| MIDDLETON / 0.12 / 06:11:44 | 0.188606 | 0.061217 | 2.981353 | 0.077961 | 1.000000 | 0.308471 | 302.940830 | 0 / 5 |
| MacBook Pro Speakers / 0.25 / 13:26:19 | 0.613088 | 0.060171 | 10.196948 | 0.560327 | 1.000000 | 0.670245 | 323.536596 | 3 / 0 |
| JBL Go 5 / 0.25 / 13:26:19 | 0.524643 | 0.070551 | 7.436352 | 0.459822 | 1.000000 | 0.594866 | 472.429333 | 3 / 0 |
| MIDDLETON / 0.25 / 13:26:19 | 0.132469 | 0.093886 | 1.397720 | 0.014169 | 0.795440 | 0.202586 | 326.183565 | 0 / 5 |
| MacBook Pro Speakers / 0.25 / 13:27:12 | 0.584139 | 0.062177 | 9.400433 | 0.527431 | 1.000000 | 0.645573 | 323.529501 | 3 / 0 |
| JBL Go 5 / 0.25 / 13:27:12 | 0.549368 | 0.065179 | 8.483210 | 0.487918 | 1.000000 | 0.615938 | 466.522765 | 3 / 1 |
| MIDDLETON / 0.25 / 13:27:12 | 0.147366 | 0.094544 | 1.653277 | 0.031098 | 1.000000 | 0.273324 | 223.264214 | 1 / 4 |

**MIDDLETON repeatability, including rejects.** Each run has only five estimates. Standard deviation uses the sample denominator N−1; MAD is the unscaled median absolute deviation from the median. Within-tolerance counts are relative to each run’s median. Pooling these changed-condition runs would not satisfy the requested stationary ten-estimate experiment.

| Level / start | N | Accepted | Median ms | MAD ms | SD ms | Min ms | Max ms | Range ms | ±0.25 | ±0.5 | ±1.0 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.12 / 06:10:24 | 5 | 1 | 302.270001 | 0.452570 | 0.752672 | 301.817431 | 303.649274 | 1.831843 | 2 | 3 | 4 |
| 0.12 / 06:11:44 | 5 | 0 | 302.940830 | 0.724195 | 0.888596 | 302.216635 | 304.370017 | 2.153382 | 1 | 2 | 4 |
| 0.18 / 06:14:35 | 5 | 0 | 311.499816 | 2.516172 | 97.685115 | 94.147523 | 314.706049 | 220.558526 | 1 | 1 | 1 |
| 0.25 / 06:17:07 | 5 | 0 | 306.390507 | 0.752301 | 1.358376 | 305.638206 | 308.766986 | 3.128780 | 1 | 2 | 3 |
| 0.25 / 13:26:19 | 5 | 0 | 326.183565 | 4.778058 | 154.033758 | 108.047308 | 543.671202 | 435.623894 | 1 | 1 | 2 |
| 0.25 / 13:27:12 | 5 | 1 | 223.264214 | 72.210718 | 120.546134 | 82.512387 | 405.428878 | 322.916491 | 1 | 1 | 1 |

| Level / start | Peak median | Peak range | Prominence median | Prominence range | Confidence median | Confidence range | SNR median | SNR range |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.12 / 06:10:24 | 0.216981 | 0.205474–0.255490 | 4.114291 | 3.781986–4.349480 | 0.332655 | 0.322847–0.365475 | 3.206933 | 2.434635–3.463085 |
| 0.12 / 06:11:44 | 0.188606 | 0.168588–0.201592 | 2.981353 | 2.853977–3.610319 | 0.308471 | 0.291410–0.319538 | 2.486947 | 2.185625–3.439923 |
| 0.18 / 06:14:35 | 0.094724 | 0.085591–0.099069 | 1.135683 | 1.002585–1.375007 | 0.067841 | 0.001293–0.187504 | 3.420855 | 1.812058–3.635763 |
| 0.25 / 06:17:07 | 0.165792 | 0.151735–0.173832 | 1.655160 | 1.341149–1.845491 | 0.289028 | 0.197621–0.295879 | 13.503492 | 12.563910–15.421443 |
| 0.25 / 13:26:19 | 0.132469 | 0.119639–0.156866 | 1.397720 | 1.147203–1.436765 | 0.202586 | 0.105022–0.231075 | 9.968941 | -1.899996–15.447225 |
| 0.25 / 13:27:12 | 0.147366 | 0.135491–0.244165 | 1.653277 | 1.068405–2.444284 | 0.273324 | 0.047405–0.355822 | 33.235058 | 27.998543–34.379033 |

Compared with the first baseline median slice offset 302.270001 ms, the original 0.18 median shifts +9.229815 ms with a 220.558526 ms range; original 0.25 shifts +4.120506 ms with a 3.128780 ms range. The baseline itself drifts from 303.649274 to 301.817431 ms rather than remaining within ±0.25 ms. The latest run ranges 82.512387–405.428878 ms. These observations do not support treating rejected estimates as reliably correct.

For completeness, these are the corresponding **approximate emission-relative candidate** statistics derived from the logged microphone sample mapping, including rejects. They remain candidate statistics, not validated acoustic arrival measurements.

| Run | Median ms | MAD ms | Sample SD ms | Min ms | Max ms | Range ms | ±0.25 ms | ±0.5 ms | ±1 ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 80293-1 | 297.244626 | 0.452612 | 0.752714 | 296.792014 | 298.623899 | 1.831885 | 2 | 3 | 4 |
| 80293-2 | 297.920965 | 0.724195 | 0.888670 | 297.196770 | 299.350319 | 2.153549 | 1 | 2 | 4 |
| 81929-1 | 306.477580 | 2.516214 | 97.685115 | 89.125287 | 309.683813 | 220.558526 | 1 | 1 | 1 |
| 82930-1 | 301.376267 | 0.752301 | 1.358385 | 300.623966 | 303.752746 | 3.128780 | 1 | 2 | 3 |
| 82930-2 | 321.156914 | 4.777933 | 154.033655 | 103.020739 | 538.644342 | 435.623603 | 1 | 1 | 2 |
| 82930-3 | 218.238476 | 72.210759 | 120.546153 | 77.486649 | 400.403181 | 322.916532 | 1 | 1 | 1 |

**Latest run, every MIDDLETON attempt.** Acoustic candidates below are derived from the logged sample mapping; the accepted attempt 4 separately logs 400.405041 ms via host-time conversion.

| Attempt | Slice offset ms | Approx acoustic candidate ms | Peak | Second-best | Prominence | Confidence | SNR dB | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 82.512387 | 77.486649 | 0.135491 | 0.126816 | 1.068405 | 0.047405 | 27.998543 | rejected: lowConfidence |
| 2 | 295.474932 | 290.449235 | 0.187709 | 0.091483 | 2.051850 | 0.307707 | 33.235058 | rejected: lowConfidence |
| 3 | 223.264214 | 218.238476 | 0.147366 | 0.094544 | 1.558707 | 0.273324 | 33.241021 | rejected: lowConfidence |
| 4 | 405.428878 | 400.403181 | 0.244165 | 0.099892 | 2.444284 | 0.355822 | 34.379033 | accepted |
| 5 | 188.984072 | 183.958333 | 0.140332 | 0.084881 | 1.653277 | 0.267328 | 31.601951 | rejected: lowConfidence |

First rejection of the latest run: JBL attempt 1 at 13:27:13.711, `lowConfidence peak=0.150 secondBest=0.124 prominence=1.201 confidence=0.126 offset=248.12ms`. Its preceding diagnostic gives peak=0.149517, secondBestPeak=0.124443, prominence=1.201488, confidence=0.125900. JBL attempts 2–4 then pass. The first 0.25 run at 06:17 instead first fails at H, MIDDLETON attempt 1: peak=0.169649, confidence=0.292315 (full precision in CSV).

**Runtime setup.** Latest aggregate ID 267; sample rate 44100 Hz; selected names and UIDs: MacBook Pro Speakers / `BuiltInSpeakerDevice`, JBL Go 5 / `74-68-59-E0-71-4C:output`, MIDDLETON / `68-59-32-EA-E5-67:output`. Aggregate subdevice UID order is the same, channelCounts=[2,2,2], offsets=[0,2,4], total channels=6; clock master=`BuiltInSpeakerDevice`; drift compensated UIDs are the two Bluetooth outputs. outputs.count=3, delayComponents.count=3, renderState.delayLineCount=3; assignments route 0/offset 0/channels 2, route 1/offset 2/channels 2, route 2/offset 4/channels 2. Microphone is MacBook Pro Microphone / `BuiltInMicrophoneDevice`; configured acoustic search window 0.400000 s. These are runtime identity/routing values, not independent proof of physical audible playback.

**Capture and correlation inspection.** Existing rejected artifacts use only speaker UID and attempt number in their filenames and are overwritten across runs. Attempts 1, 2, 3 and 5 currently belong to 13:27; attempt 4 belongs to 13:26 because the later attempt 4 was accepted and wrote no dump. They were preserved without modifying the originals at `/var/folders/ys/3k6qsgx53g96h9y34s_00v5h0000gn/T/speakerr-sweep-evidence-9o_su97e/rejected-captures`. Earlier 0.12/0.18 waveform artifacts are no longer recoverable from that directory, so full acoustic presence cannot be certified for those runs from RMS alone.

All five surviving MIDDLETON WAV/metadata pairs contain complete 8192-sample A and B analysis windows, separated by the configured 1323 samples (30 ms). This confirms slice containment at each candidate, not the physical presence of the correct complete emitted pair. Latest attempts 1 and 5 have A RMS 0.000536/0.000287 versus B RMS 0.016874/0.016871, and A correlations 0.000559/0.000581 versus B 0.191732/0.198483 at the selected candidate. The candidate can be matching one half of the waveform; this does not prove Bluetooth truncated A.

Saved curves provide a concrete next investigation: latest attempt 2 independent A/B maxima occur at A-start coordinates 13031/13029 (values 0.293210/0.309322), whereas combined peak is 0.187709 at 13030. Attempt 3 independent maxima are 9823/9826 (0.291919/0.269487), while combined peak is 0.147366 at 9846. B-curve indices already account for the A+gap spacing. These misalignments warrant examining signed correlations, time variation across A/B and waveform distortion before changing scoring. The stored individual curves are absolute values, so they do not alone establish signed cancellation or a specific DSP/clock cause.

The existing `candidateNearSearchBoundary=false` flag means only “not the first or last candidate sample”, not “comfortably inside.” In the original baseline/0.18/0.25 runs, every MIDDLETON candidate is at least approximately 197/94/182 ms from either search boundary respectively (exact bounds retained in CSV). In the 13:26 attempt 2, the 543.671202 ms slice candidate is only 4.764172 ms from the last allowed candidate despite the flag being false; only about 4.79 ms remains after B in the analysed slice. Latest 13:27 candidates have at least 82 ms to the nearer boundary and complete pair-sized windows, yet are still unstable. The nominal 400 ms configuration is not itself the actual search end: the trace records the effective sample bounds.

**Confidence formula, unchanged.** `peakScore=clamp((peak−0.12)/0.88,0,1)`, `prominenceScore=clamp((prominence−1)/0.5,0,1)`, `confidence=0.75×peakScore+0.25×prominenceScore`. Acceptance additionally requires peak≥0.12, prominence≥1.08 and confidence≥0.35. Thus 0.12 is both a hard peak gate and the score’s zero point. Peak≈0.094 and prominence≈2.09 yield peakScore=0, prominenceScore=1, confidence=0.25. Even with saturated prominence, confidence 0.35 requires peak≥0.237333. The latest passing peak 0.244165 yields confidence 0.355822, a narrow margin and no evidence that its latency is correct.

**Decision.** Pattern C (unstable detection) is present. Pattern A is not established; no level delivers comfortable repeatable acceptance. Higher reported SNR without reliable correlation is compatible with a waveform/model limitation, but Pattern B cannot be attributed to amplitude because conditions changed and SNR is measured around potentially incorrect candidates. Do not raise the level further, lower thresholds, change routing, or choose a permanent fix from this trace. Next work should preserve the setup and collect at least ten MIDDLETON estimates with separately identified run artifacts while inspecting the A/B mismatch; choosing the test level requires a fresh controlled baseline, not pooling today’s changed-condition runs. Physical emission completeness, compensation, recheck and alignment remain unverified.

Validation: all 69 diagnostic records parsed with exact error text separated before key extraction (error text repeats keys such as peak and confidence); 30 MIDDLETON estimates retained, six runs of five each. Counts and acceptance were checked against source rejection/result events. Existing WAV RMS reproduced the logged A/B values for surviving dumps. No application tests were rerun and no fix is claimed.
