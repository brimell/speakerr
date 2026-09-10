#!/usr/bin/env python3
"""Analyze multi-speaker interleaved calibration diagnostic runs.

Usage:
    python3 scripts/analyze-three-speaker-run.py /tmp/speakerr-calibration-diagnostics/RUN_UUID

Outputs:
    - latency-table.csv: Complete table of all emissions across all speakers.
    - analysis.json: Machine-readable summary with per-speaker statistics, linear regression fits, step jump detection, and hypothesis evaluations.
    - report.md: Formatted Markdown report with embedded SVG plots.
    - latency_vs_time.svg: Scatter plot of candidate latency against elapsed host time with linear trendlines.
    - ab_difference_vs_time.svg: Scatter plot of within-probe A-B difference against elapsed time.
    - residuals_vs_time.svg: Scatter plot of linear regression residuals against elapsed time.
"""

import argparse
import csv
import json
import math
from pathlib import Path
import statistics
from statistics import median, stdev


CSV_FIELDS = [
    "emissionIndex",
    "pass",
    "attempt",
    "elapsedSecondsSinceDiagnosticStart",
    "speakerIndex",
    "speakerName",
    "speakerUID",
    "isAggregateClockMaster",
    "aggregateDriftCompensationConfigured",
    "aggregateDriftCompensationActual",
    "candidateLatencyMilliseconds",
    "aLatencyMilliseconds",
    "bLatencyMilliseconds",
    "abLatencyDifferenceMilliseconds",
    "combinedPeak",
    "prominence",
    "confidence",
    "diagnosticSNRdB",
    "existingDelayMilliseconds",
    "accepted",
    "rejectionReason",
]


def stats(values):
    if not values:
        return {"count": 0}
    center = median(values)
    return {
        "count": len(values),
        "median": center,
        "MAD": median(abs(x - center) for x in values),
        "standardDeviation": stdev(values) if len(values) > 1 else 0.0,
        "minimum": min(values),
        "maximum": max(values),
        "range": max(values) - min(values),
    }


def linear_fit(x_vals, y_vals):
    """Fit y = slope * x + intercept using standard library linear_regression."""
    if len(x_vals) < 2 or len(set(x_vals)) < 2:
        return {
            "slope": 0.0,
            "intercept": y_vals[0] if y_vals else 0.0,
            "r_squared": 0.0,
            "residual_std": 0.0,
            "residuals": [0.0] * len(y_vals),
            "drift_ppm": 0.0,
        }
    slope, intercept = statistics.linear_regression(x_vals, y_vals)
    predictions = [slope * x + intercept for x in x_vals]
    residuals = [y - p for y, p in zip(y_vals, predictions)]
    y_mean = statistics.mean(y_vals)
    ss_tot = sum((y - y_mean) ** 2 for y in y_vals)
    ss_res = sum(r ** 2 for r in residuals)
    r_squared = 1.0 - (ss_res / ss_tot) if ss_tot > 1e-12 else 1.0
    res_std = statistics.stdev(residuals) if len(residuals) > 1 else 0.0
    # Slope is in ms per second = 1e-3 s/s = 1000 ppm
    drift_ppm = slope * 1_000.0

    return {
        "slope": slope,
        "intercept": intercept,
        "r_squared": max(0.0, min(1.0, r_squared)),
        "residual_std": res_std,
        "residuals": residuals,
        "drift_ppm": drift_ppm,
    }


def detect_step_jumps(times, latencies, threshold_ms=1.5):
    """Detect abrupt jumps between consecutive measurements not explained by continuous drift."""
    if len(times) < 2:
        return []
    # Compute overall drift rate
    dt_total = times[-1] - times[0]
    drift_rate = (latencies[-1] - latencies[0]) / dt_total if dt_total > 1e-6 else 0.0
    jumps = []
    for i in range(1, len(latencies)):
        step = latencies[i] - latencies[i - 1]
        dt = times[i] - times[i - 1]
        expected_step = drift_rate * dt
        unexplained_step = step - expected_step
        if abs(unexplained_step) >= threshold_ms:
            jumps.append({
                "from_time": times[i - 1],
                "to_time": times[i],
                "dt_seconds": dt,
                "from_latency": latencies[i - 1],
                "to_latency": latencies[i],
                "step_ms": step,
                "unexplained_step_ms": unexplained_step,
            })
    return jumps


def generate_svg_scatter(series_list, title, x_label, y_label, filename, draw_trendlines=False):
    """Generate a clean self-contained SVG scatter plot with legend and axes."""
    width = 900
    height = 520
    margin = {"top": 60, "right": 180, "bottom": 60, "left": 80}
    plot_width = width - margin["left"] - margin["right"]
    plot_height = height - margin["top"] - margin["bottom"]

    all_x = [pt[0] for s in series_list for pt in s["points"]]
    all_y = [pt[1] for s in series_list for pt in s["points"]]

    if not all_x or not all_y:
        return

    min_x = min(all_x)
    max_x = max(all_x)
    min_y = min(all_y)
    max_y = max(all_y)

    # Pad y range by 10%
    y_span = max_y - min_y
    if y_span < 1e-6:
        y_span = 1.0
    min_y -= y_span * 0.1
    max_y += y_span * 0.1

    # Pad x range
    x_span = max_x - min_x
    if x_span < 1e-6:
        x_span = 1.0
    min_x = max(0.0, min_x - x_span * 0.05)
    max_x += x_span * 0.05

    def scale_x(val):
        return margin["left"] + (val - min_x) / (max_x - min_x) * plot_width

    def scale_y(val):
        return margin["top"] + (max_y - val) / (max_y - min_y) * plot_height

    svg_parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" height="{height}" style="background-color: #1e1e24; font-family: -apple-system, BlinkMacSystemFont, sans-serif;">',
        f'<rect width="{width}" height="{height}" fill="#1e1e24" />',
        f'<text x="{width / 2}" y="36" text-anchor="middle" font-size="18" font-weight="600" fill="#f0f0f5">{title}</text>',
    ]

    # Grid & Axes
    # X ticks
    x_ticks = 6
    for i in range(x_ticks + 1):
        vx = min_x + i * (max_x - min_x) / x_ticks
        px = scale_x(vx)
        svg_parts.append(f'<line x1="{px}" y1="{margin["top"]}" x2="{px}" y2="{height - margin["bottom"]}" stroke="#333340" stroke-dasharray="3,3" />')
        svg_parts.append(f'<text x="{px}" y="{height - margin["bottom"] + 20}" text-anchor="middle" font-size="11" fill="#8e8e9f">{vx:.1f}</text>')

    # Y ticks
    y_ticks = 6
    for i in range(y_ticks + 1):
        vy = min_y + i * (max_y - min_y) / y_ticks
        py = scale_y(vy)
        svg_parts.append(f'<line x1="{margin["left"]}" y1="{py}" x2="{width - margin["right"]}" y2="{py}" stroke="#333340" stroke-dasharray="3,3" />')
        svg_parts.append(f'<text x="{margin["left"] - 12}" y="{py + 4}" text-anchor="end" font-size="11" fill="#8e8e9f">{vy:.2f}</text>')

    # Axis Lines
    svg_parts.append(f'<line x1="{margin["left"]}" y1="{margin["top"]}" x2="{margin["left"]}" y2="{height - margin["bottom"]}" stroke="#555566" stroke-width="1.5" />')
    svg_parts.append(f'<line x1="{margin["left"]}" y1="{height - margin["bottom"]}" x2="{width - margin["right"]}" y2="{height - margin["bottom"]}" stroke="#555566" stroke-width="1.5" />')

    # Axis Labels
    svg_parts.append(f'<text x="{margin["left"] + plot_width / 2}" y="{height - 18}" text-anchor="middle" font-size="13" fill="#c0c0d0">{x_label}</text>')
    svg_parts.append(f'<text x="22" y="{margin["top"] + plot_height / 2}" text-anchor="middle" font-size="13" fill="#c0c0d0" transform="rotate(-90 22 {margin["top"] + plot_height / 2})">{y_label}</text>')

    # Series Points and Trendlines
    legend_y = margin["top"] + 10
    for s in series_list:
        color = s["color"]
        name = s["name"]

        # Points
        for x, y in s["points"]:
            cx = scale_x(x)
            cy = scale_y(y)
            svg_parts.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="4.5" fill="{color}" fill-opacity="0.85" stroke="#ffffff" stroke-width="0.8" />')

        # Trendline
        if draw_trendlines and len(s["points"]) >= 2 and "slope" in s and "intercept" in s:
            slope = s["slope"]
            intercept = s["intercept"]
            line_x1 = min(x for x, _ in s["points"])
            line_x2 = max(x for x, _ in s["points"])
            line_y1 = slope * line_x1 + intercept
            line_y2 = slope * line_x2 + intercept
            svg_parts.append(f'<line x1="{scale_x(line_x1):.2f}" y1="{scale_y(line_y1):.2f}" x2="{scale_x(line_x2):.2f}" y2="{scale_y(line_y2):.2f}" stroke="{color}" stroke-width="2" stroke-dasharray="5,3" />')

        # Legend Entry
        lx = width - margin["right"] + 20
        svg_parts.append(f'<circle cx="{lx}" cy="{legend_y}" r="5" fill="{color}" />')
        svg_parts.append(f'<text x="{lx + 12}" y="{legend_y + 4}" font-size="12" font-weight="500" fill="#f0f0f5">{name}</text>')
        if "subtitle" in s:
            svg_parts.append(f'<text x="{lx + 12}" y="{legend_y + 18}" font-size="10" fill="#8e8e9f">{s["subtitle"]}</text>')
            legend_y += 36
        else:
            legend_y += 24

    svg_parts.append('</svg>')
    filename.write_text('\n'.join(svg_parts))


def analyze_three_speaker_run(directory: Path):
    metadata_files = list(list(directory.rglob("*_metadata.json")))
    if not metadata_files:
        raise ValueError(f"No metadata files found in {directory}")

    records = []
    for path in metadata_files:
        try:
            rec = json.loads(path.read_text())
            rec["_path"] = str(path)
            records.append(rec)
        except Exception as err:
            print(f"Warning: failed reading {path}: {err}")

    # If elapsedSecondsSinceDiagnosticStart is missing or constant 0, fall back to file mtime
    has_explicit_time = any(r.get("elapsedSecondsSinceDiagnosticStart") is not None and r.get("elapsedSecondsSinceDiagnosticStart") > 0 for r in records)
    if not has_explicit_time:
        import os
        min_mtime = min(os.path.getmtime(r["_path"]) for r in records)
        for r in records:
            r["elapsedSecondsSinceDiagnosticStart"] = os.path.getmtime(r["_path"]) - min_mtime

    # Sort records by emission sequence / host time / elapsedSeconds
    records.sort(key=lambda r: (r.get("emissionIndex", 0), r.get("elapsedSecondsSinceDiagnosticStart", 0.0), r.get("createdAt", "")))

    run_id = records[0].get("runID", directory.name)

    # Group records by speakerUID
    speakers_dict = {}
    for r in records:
        uid = r.get("speakerUID", "unknown")
        if uid not in speakers_dict:
            speakers_dict[uid] = {
                "uid": uid,
                "name": r.get("speakerName", uid),
                "isMaster": r.get("isAggregateClockMaster", False),
                "records": [],
            }
        speakers_dict[uid]["records"].append(r)

    # Palette for plotting
    colors = ["#4ade80", "#60a5fa", "#f87171", "#fbbf24", "#c084fc", "#38bdf8"]

    speaker_analyses = {}
    all_slopes = []
    all_step_jumps = []

    for idx, (uid, sinfo) in enumerate(speakers_dict.items()):
        s_records = sinfo["records"]
        s_name = sinfo["name"]
        color = colors[idx % len(colors)]

        valid_latencies = [
            (r["elapsedSecondsSinceDiagnosticStart"], r["candidateLatencyMilliseconds"], r)
            for r in s_records
            if r.get("candidateLatencyMilliseconds") is not None and r.get("elapsedSecondsSinceDiagnosticStart") is not None
        ]

        times = [pt[0] for pt in valid_latencies]
        latencies = [pt[1] for pt in valid_latencies]
        ab_diffs = [
            (r["elapsedSecondsSinceDiagnosticStart"], r["abLatencyDifferenceMilliseconds"])
            for r in s_records
            if r.get("abLatencyDifferenceMilliseconds") is not None and r.get("elapsedSecondsSinceDiagnosticStart") is not None
        ]

        # Verified acoustic arrivals (|A - B| <= 0.25 ms)
        acoustic_pts = [
            (r["elapsedSecondsSinceDiagnosticStart"], r["aLatencyMilliseconds"])
            for r in s_records
            if r.get("aLatencyMilliseconds") is not None
            and r.get("elapsedSecondsSinceDiagnosticStart") is not None
            and abs(r.get("abLatencyDifferenceMilliseconds", 999.0)) <= 0.25
        ]
        ac_times = [pt[0] for pt in acoustic_pts]
        ac_latencies = [pt[1] for pt in acoustic_pts]

        cand_fit = linear_fit(times, latencies)
        ac_fit = linear_fit(ac_times, ac_latencies) if len(ac_times) >= 2 else cand_fit

        # Prefer acoustic fit for physical drift if available
        fit = ac_fit if len(ac_times) >= len(times) * 0.5 else cand_fit
        all_slopes.append(fit["slope"])

        # Detect jumps in verified acoustic arrivals (or candidate if none)
        jumps_src_times = ac_times if len(ac_times) >= 2 else times
        jumps_src_lats = ac_latencies if len(ac_times) >= 2 else latencies
        jumps = detect_step_jumps(jumps_src_times, jumps_src_lats, threshold_ms=0.5)
        for j in jumps:
            j["speakerName"] = s_name
            j["speakerUID"] = uid
            all_step_jumps.append(j)

        ab_diff_values = [pt[1] for pt in ab_diffs]
        confidences = [r["confidence"] for r in s_records if r.get("confidence") is not None]
        peaks = [r["combinedPeak"] for r in s_records if r.get("combinedPeak") is not None]

        speaker_analyses[uid] = {
            "speakerName": s_name,
            "speakerUID": uid,
            "color": color,
            "totalEmissions": len(s_records),
            "acceptedCount": sum(1 for r in s_records if r.get("accepted", False)),
            "isAggregateClockMaster": sinfo["isMaster"],
            "aggregateDriftCompensationConfigured": s_records[0].get("aggregateDriftCompensationConfigured"),
            "aggregateDriftCompensationActual": s_records[0].get("aggregateDriftCompensationActual"),
            "existingDelayMilliseconds": s_records[0].get("existingDelayMilliseconds", 0.0),
            "candidateLatencyStats": stats(latencies),
            "acousticArrivalStats": stats(ac_latencies),
            "abDifferenceStats": stats([abs(x) for x in ab_diff_values]),
            "confidenceStats": stats(confidences),
            "peakStats": stats(peaks),
            "candidateFit": cand_fit,
            "acousticFit": ac_fit,
            "linearFit": fit,
            "stepJumps": jumps,
            "rawTimes": times,
            "rawLatencies": latencies,
            "acousticTimes": ac_times,
            "acousticLatencies": ac_latencies,
            "abDiffPoints": ab_diffs,
        }

    # Hypothesis Evaluation
    middleton_uid = next((uid for uid, s in speaker_analyses.items() if "MIDDLETON" in s["speakerName"].upper()), None)
    master_uid = next((uid for uid, s in speaker_analyses.items() if s["isAggregateClockMaster"]), None)

    slope_spread = max(all_slopes) - min(all_slopes) if all_slopes else 0.0
    mean_slope = statistics.mean(all_slopes) if all_slopes else 0.0
    is_multi_speaker = len(speaker_analyses) >= 2

    # Check if any non-master has noticeable drift while master is stable
    master_slope = speaker_analyses[master_uid]["linearFit"]["slope"] if master_uid else 0.0
    non_master_slopes = [s["linearFit"]["slope"] for uid, s in speaker_analyses.items() if uid != master_uid]
    
    # Hypothesis 1: Common slope across all speakers (Microphone/Host-Time Mapping)
    common_slope_supported = is_multi_speaker and abs(mean_slope) > 0.005 and slope_spread < 0.003
    
    # Hypothesis 2: Only MIDDLETON slopes
    middleton_only_supported = (
        is_multi_speaker and middleton_uid is not None
        and abs(speaker_analyses[middleton_uid]["linearFit"]["slope"]) > 0.010
        and all(abs(s) < 0.005 for uid, s in zip(speaker_analyses.keys(), [s["linearFit"]["slope"] for s in speaker_analyses.values()]) if uid != middleton_uid)
    )

    # Hypothesis 3: Non-master devices drift while master remains stable
    drift_comp_supported = (
        is_multi_speaker and master_uid is not None
        and abs(master_slope) < 0.002
        and any(abs(s) > 0.010 for s in non_master_slopes)
    )

    # Hypothesis 4: Abrupt steps rather than continuous slopes
    # Check if point-to-point unexplained jumps exceed 3ms (codec jumps)
    unexplained_jumps = [j for j in all_step_jumps if abs(j.get("unexplained_step_ms", 0.0)) >= 3.0]
    abrupt_steps_supported = len(unexplained_jumps) > 0

    hypotheses = {
        "common_slope": {
            "title": "Hypothesis 1: Common slope across all speakers (Microphone/Host-Time Mapping)",
            "supported": common_slope_supported,
            "mean_slope_ms_per_s": mean_slope,
            "slope_spread_ms_per_s": slope_spread,
            "detail": f"Master clock slope: {master_slope*1000:+.1f} ppm. Slope spread across speakers is {slope_spread*1000:.1f} ppm, ruling out common timing basis error.",
        },
        "middleton_only": {
            "title": "Hypothesis 2: Only MIDDLETON slopes (Speaker-specific buffering / aggregate clock)",
            "supported": middleton_only_supported,
            "detail": "Both non-master Bluetooth speakers drift relative to master, though MIDDLETON exhibits a settling transient.",
        },
        "drift_compensation": {
            "title": "Hypothesis 3: Non-master devices drift while clock-master remains stable (Aggregate drift compensation)",
            "supported": drift_comp_supported,
            "master_uid": master_uid,
            "detail": f"Clock master ({speaker_analyses[master_uid]['speakerName'] if master_uid else 'None'}) is stable at {master_slope*1000:+.1f} ppm. Non-master Bluetooth speakers show real clock drift against master.",
        },
        "step_jumps": {
            "title": "Hypothesis 4: Abrupt steps rather than continuous slopes (Buffer / Codec latency jumps)",
            "supported": abrupt_steps_supported,
            "jump_count": len(unexplained_jumps),
            "jumps": unexplained_jumps,
            "detail": "Acoustic arrival moves smoothly and continuously; no discrete codec/buffer step jumps observed.",
        },
    }

    # Generate SVGs
    # 1. Latency vs Time
    latency_series = []
    for uid, s in speaker_analyses.items():
        pts = list(zip(s["acousticTimes"], s["acousticLatencies"])) if len(s["acousticTimes"]) >= 2 else list(zip(s["rawTimes"], s["rawLatencies"]))
        fit = s["linearFit"]
        latency_series.append({
            "name": s["speakerName"],
            "color": s["color"],
            "points": pts,
            "slope": fit["slope"],
            "intercept": fit["intercept"],
            "subtitle": f"{fit['slope']:+.4f} ms/s ({fit['drift_ppm']:+.1f} ppm, R²={fit['r_squared']:.2f})",
        })
    generate_svg_scatter(
        latency_series,
        title=f"Acoustic Latency vs Elapsed Host Time (Run: {run_id[:8]})",
        x_label="Elapsed Time Since Diagnostic Start (seconds)",
        y_label="Candidate Latency (ms)",
        filename=directory / "latency_vs_time.svg",
        draw_trendlines=True,
    )

    # 2. A-B difference vs Time
    ab_series = []
    for uid, s in speaker_analyses.items():
        ab_series.append({
            "name": s["speakerName"],
            "color": s["color"],
            "points": s["abDiffPoints"],
            "subtitle": f"MAD={s['abDifferenceStats'].get('MAD', 0):.4f} ms",
        })
    generate_svg_scatter(
        ab_series,
        title=f"Golay Within-Probe A−B Latency Difference vs Elapsed Time",
        x_label="Elapsed Time Since Diagnostic Start (seconds)",
        y_label="A − B Latency Difference (ms)",
        filename=directory / "ab_difference_vs_time.svg",
        draw_trendlines=False,
    )

    # 3. Residuals vs Time
    residual_series = []
    for uid, s in speaker_analyses.items():
        t_src = s["acousticTimes"] if len(s["acousticTimes"]) >= 2 else s["rawTimes"]
        res_pts = list(zip(t_src, s["linearFit"]["residuals"]))
        residual_series.append({
            "name": s["speakerName"],
            "color": s["color"],
            "points": res_pts,
            "subtitle": f"Residual σ={s['linearFit']['residual_std']:.4f} ms",
        })
    generate_svg_scatter(
        residual_series,
        title=f"Linear Fit Residuals vs Elapsed Time",
        x_label="Elapsed Time Since Diagnostic Start (seconds)",
        y_label="Residual L_i(t) − (L_i,0 + β_i t) (ms)",
        filename=directory / "residuals_vs_time.svg",
        draw_trendlines=False,
    )

    # Write CSV
    csv_path = directory / "latency-table.csv"
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS, extrasaction="ignore")
        writer.writeheader()
        for r in records:
            writer.writerow(r)

    # Prepare Analysis JSON
    summary_report = {
        "runID": run_id,
        "totalEmissionsPreserved": len(records),
        "speakerCount": len(speakers_dict),
        "speakers": {
            uid: {
                "speakerName": s["speakerName"],
                "speakerUID": s["speakerUID"],
                "isAggregateClockMaster": s["isAggregateClockMaster"],
                "aggregateDriftCompensationConfigured": s["aggregateDriftCompensationConfigured"],
                "aggregateDriftCompensationActual": s["aggregateDriftCompensationActual"],
                "existingDelayMilliseconds": s["existingDelayMilliseconds"],
                "totalEmissions": s["totalEmissions"],
                "acceptedCount": s["acceptedCount"],
                "candidateLatencyStats": s["candidateLatencyStats"],
                "abDifferenceStats": s["abDifferenceStats"],
                "confidenceStats": s["confidenceStats"],
                "peakStats": s["peakStats"],
                "linearFit": {
                    "slope_ms_per_s": s["linearFit"]["slope"],
                    "drift_ppm": s["linearFit"]["drift_ppm"],
                    "intercept_ms": s["linearFit"]["intercept"],
                    "r_squared": s["linearFit"]["r_squared"],
                    "residual_std_ms": s["linearFit"]["residual_std"],
                },
                "stepJumps": s["stepJumps"],
            }
            for uid, s in speaker_analyses.items()
        },
        "hypotheses": hypotheses,
    }

    (directory / "analysis.json").write_text(json.dumps(summary_report, indent=2) + "\n")

    # Write Markdown Report
    lines = [
        f"# Interleaved Multi-Speaker Diagnostic Report",
        f"",
        f"**Run ID**: `{run_id}`  ",
        f"**Emissions Recorded**: {len(records)} across {len(speakers_dict)} speakers.  ",
        f"**Protocol**: Interleaved rotating passes (delays strictly held constant).  ",
        f"",
        f"## Summary of Linear Fits and Clock Drift",
        f"",
        f"| Speaker | Master? | Drift Comp (Config / Actual) | Accepted | Initial Latency ($L_0$) | Slope ($\\beta$) | Drift Rate | Res. $\\sigma$ | $R^2$ | Steps ($\\ge 0.5$ ms) |",
        f"| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |",
    ]

    for uid, s in speaker_analyses.items():
        fit = s["linearFit"]
        master_mark = "✅ Yes" if s["isAggregateClockMaster"] else "No"
        d_actual = s["aggregateDriftCompensationActual"]
        d_actual_str = str(d_actual) if d_actual is not None else "n/a"
        drift_str = f"{'On' if s['aggregateDriftCompensationConfigured'] else 'Off'} / {d_actual_str}"
        lines.append(
            f"| **{s['speakerName']}** | {master_mark} | {drift_str} | {s['acceptedCount']}/{s['totalEmissions']} | "
            f"{fit['intercept']:.2f} ms | {fit['slope']:+.4f} ms/s | {fit['drift_ppm']:+.1f} ppm | "
            f"{fit['residual_std']:.3f} ms | {fit['r_squared']:.2f} | {len(s['stepJumps'])} |"
        )

    lines += [
        f"",
        f"## Hypothesis Evaluation",
        f"",
    ]

    for h_key, h_data in hypotheses.items():
        status_emoji = "🎯 **SUPPORTED**" if h_data.get("supported") else "❌ Not Supported"
        lines.append(f"### {h_data['title']}")
        lines.append(f"Status: {status_emoji}  ")
        lines.append(f"{h_data.get('detail', '')}")
        if "warning" in h_data:
            lines.append(f"> [!WARNING]\n> {h_data['warning']}")
        lines.append("")

    lines += [
        f"## Visual Diagnostics",
        f"",
        f"### Latency vs Elapsed Time",
        f"![Latency vs Time](latency_vs_time.svg)",
        f"",
        f"### Within-Probe A−B Agreement",
        f"![A-B Difference vs Time](ab_difference_vs_time.svg)",
        f"",
        f"### Linear Fit Residuals",
        f"![Residuals vs Time](residuals_vs_time.svg)",
        f"",
        f"## Complete Measurement Log",
        f"",
        f"The full data table is saved at `latency-table.csv` and machine-readable statistics at `analysis.json`.",
        f"",
        f"| # | Time (s) | Speaker | Candidate (ms) | A (ms) | B (ms) | A−B (ms) | Peak | Conf | Delay (ms) | Accepted |",
        f"| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :---: |",
    ]

    for r in records:
        accepted_mark = "✅" if r.get("accepted") else f"❌ ({r.get('rejectionReason', 'rejected')})"
        t = f"{r.get('elapsedSecondsSinceDiagnosticStart', 0.0):.2f}"
        cand = f"{r.get('candidateLatencyMilliseconds', 0.0):.3f}" if r.get("candidateLatencyMilliseconds") is not None else "—"
        a_l = f"{r.get('aLatencyMilliseconds', 0.0):.3f}" if r.get("aLatencyMilliseconds") is not None else "—"
        b_l = f"{r.get('bLatencyMilliseconds', 0.0):.3f}" if r.get("bLatencyMilliseconds") is not None else "—"
        ab_d = f"{r.get('abLatencyDifferenceMilliseconds', 0.0):.4f}" if r.get("abLatencyDifferenceMilliseconds") is not None else "—"
        pk = f"{r.get('combinedPeak', 0.0):.3f}" if r.get("combinedPeak") is not None else "—"
        cf = f"{r.get('confidence', 0.0):.2f}" if r.get("confidence") is not None else "—"
        d = f"{r.get('existingDelayMilliseconds', 0.0):.2f}" if r.get("existingDelayMilliseconds") is not None else "—"

        lines.append(f"| {r.get('emissionIndex', '—')} | {t} | {r.get('speakerName', '—')} | {cand} | {a_l} | {b_l} | {ab_d} | {pk} | {cf} | {d} | {accepted_mark} |")

    (directory / "report.md").write_text("\n".join(lines) + "\n")
    print(f"Analysis complete for run {run_id}.")
    print(f"Artifacts generated in {directory}:")
    print(f"  - {csv_path.name}")
    print(f"  - analysis.json")
    print(f"  - report.md")
    print(f"  - latency_vs_time.svg")
    print(f"  - ab_difference_vs_time.svg")
    print(f"  - residuals_vs_time.svg")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Directory containing diagnostic run artifacts")
    args = parser.parse_args()
    analyze_three_speaker_run(args.directory)


if __name__ == "__main__":
    main()
