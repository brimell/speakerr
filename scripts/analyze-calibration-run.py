#!/usr/bin/env python3
"""Summarize one Debug ×20 run. No audio or calibration settings are changed.

Usage: python3 scripts/analyze-calibration-run.py /tmp/speakerr-calibration-diagnostics/RUN_UUID
Optional --plots requires matplotlib and writes signed full-search and peak-detail PNGs.
"""
import argparse
import csv
import json
import math
from pathlib import Path
from statistics import median, stdev

FIELDS = [
    "attempt", "candidateLatencyMilliseconds", "aLatencyMilliseconds", "bLatencyMilliseconds",
    "abLatencyDifferenceMilliseconds", "aPeak", "bPeak", "combinedPeak", "secondBestPeak",
    "prominence", "confidence", "rmsA", "rmsB", "noiseRMS", "diagnosticSNRdB", "accepted",
]


def stats(values):
    if not values:
        return {"count": 0}
    center = median(values)
    return dict(count=len(values), median=center, MAD=median(abs(x - center) for x in values),
                standardDeviation=stdev(values) if len(values) > 1 else None,
                minimum=min(values), maximum=max(values), range=max(values) - min(values))


def largest_cluster(values, diameter=3.0):
    """Largest interval of maximum diameter 3 ms. No single-link chaining."""
    ordered = sorted(values)
    clusters = [[x for x in ordered[i:] if x - lower <= diameter] for i, lower in enumerate(ordered)]
    return max(clusters, key=lambda c: (len(c), -(max(c) - min(c))), default=[])


def percentile(values, proportion):
    ordered = sorted(values)
    position = (len(ordered) - 1) * proportion
    lo, hi = math.floor(position), math.ceil(position)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (position - lo)


def fmt(value):
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "accepted" if value else "rejected"
    return f"{value:.4f}" if isinstance(value, float) else str(value)


def plot_examples(records, directory):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ordered = sorted((r for r in records if r.get("abLatencyDifferenceMilliseconds") is not None),
                     key=lambda r: (abs(r["abLatencyDifferenceMilliseconds"]), -r.get("combinedPeak", 0)))
    if not ordered:
        return []
    outputs = []
    for label, record in [("most-consistent", ordered[0]), ("least-consistent", ordered[-1])]:
        source = Path(record["sourceMetadata"])
        stem = source.name.removesuffix("_metadata.json")
        fig, axes = plt.subplots(2, 1, figsize=(12, 7), layout="constrained")
        for name in ["A", "B", "combined"]:
            with (source.parent / f"{stem}_correlation_{name}_signed.csv").open() as handle:
                curve = list(csv.DictReader(handle))
            x = [float(row["acousticLatencyMilliseconds"]) for row in curve]
            y = [float(row["signedNCC"]) for row in curve]
            for ax in axes:
                ax.plot(x, y, label=name, linewidth=0.8, alpha=0.8)
        center = record["candidateLatencyMilliseconds"]
        axes[1].set_xlim(min(center, record["aLatencyMilliseconds"], record["bLatencyMilliseconds"]) - 1,
                         max(center, record["aLatencyMilliseconds"], record["bLatencyMilliseconds"]) + 1)
        for ax in axes:
            ax.axhline(0, color="gray", linewidth=0.5)
            ax.set(xlabel="Acoustic arrival coordinate (ms); intentional B spacing removed", ylabel="Signed NCC")
            ax.legend()
        fig.suptitle(f"Attempt {record['attempt']} — {label} A/B timing (not an acceptance claim)")
        output = directory / f"{label}-signed-curves.png"
        fig.savefig(output, dpi=160)
        plt.close(fig)
        outputs.append(output.name)
    return outputs


def analyze(directory, plots=False):
    records = []
    for source in directory.glob("*/*_metadata.json"):
        record = json.loads(source.read_text())
        record["sourceMetadata"] = str(source.resolve())
        records.append(record)
    records.sort(key=lambda r: r["attempt"])
    identities = {(r["runID"], r["speakerUID"]) for r in records}
    if len(identities) != 1:
        raise ValueError("Select one run containing exactly one speaker; do not pool runs or speakers")
    if len({r["attempt"] for r in records}) != len(records):
        raise ValueError("Duplicate attempt identity; refusing to pool passes")
    candidates = [r["candidateLatencyMilliseconds"] for r in records if r.get("candidateLatencyMilliseconds") is not None]
    cluster = largest_cluster(candidates)
    excluded = candidates.copy()
    for value in cluster:
        excluded.remove(value)
    differences = [abs(r["abLatencyDifferenceMilliseconds"]) for r in records if r.get("abLatencyDifferenceMilliseconds") is not None]
    report = {
        "runID": records[0]["runID"], "speakerUID": records[0]["speakerUID"],
        "requestedAttempts": 20, "preservedAttempts": len(records),
        "missingAttempts": sorted(set(range(1, 21)) - {r["attempt"] for r in records}),
        "acceptedCount": sum(r["accepted"] for r in records),
        "candidateLatency": stats(candidates), "largestCluster": stats(cluster),
        "clusterDiameterLimitMilliseconds": 3, "clusterMembers": cluster,
        "outlierCount": len(excluded), "outlierLatencies": excluded,
        "abAbsoluteDifference": stats(differences),
        "abAbsoluteDifferenceP95": percentile(differences, 0.95) if differences else None,
        "withinToleranceCounts": {str(t): sum(x <= t for x in differences) for t in [0.25, 0.5, 1.0]},
        "peakStatistics": {key: stats([r[key] for r in records if r.get(key) is not None])
                           for key in ["aPeak", "bPeak", "combinedPeak", "combinedSignedPeak"]},
        "absolutePeakStatistics": {key: stats([abs(r[key]) for r in records if r.get(key) is not None])
                                   for key in ["aPeak", "bPeak"]},
        "probeLevels": sorted({r["probeLevel"] for r in records}),
        "hardwareVolumeStates": [r.get("hardwareVolume", {}) for r in records],
    }
    (directory / "analysis.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    with (directory / "latency-table.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(records)
    lines = ["# MIDDLETON controlled diagnostic", "", f"Run: `{report['runID']}`", "",
             f"Preserved {len(records)} / 20 attempts, including {20 - len(candidates)} missing or unusable candidates. "
             "Sample standard deviation uses N−1; MAD is unscaled; P95 uses linear interpolation.", "",
             "Candidate latencies include any existing route delay. A and B use the same arrival coordinate; "
             "the known emitted A-to-B spacing has been removed. SNR is diagnostic window RMS, not a calibrated acoustic SNR.", "",
             "| " + " | ".join(FIELDS) + " |", "| " + " | ".join(["---"] * len(FIELDS)) + " |"]
    lines += ["| " + " | ".join(fmt(r.get(k)) for k in FIELDS) + " |" for r in records]
    lines += ["", "## Statistics", "", "```json", json.dumps(report, indent=2), "```", "",
              "## Interpretation pending waveform review", "",
              "Compare independent A/B peaks, their signed polarity and timing, and waveform energy at both "
              "the combined candidate and each independent peak. Consistent A/B with weak combined scores "
              "warrants scoring review; within-probe disagreement warrants playback/DSP/clock investigation; "
              "A/B agreement with joint jumps warrants inter-emission latency investigation. Weak random "
              "individual peaks warrant acoustic/probe investigation. These statistics alone do not identify a cause.", ""]
    if plots:
        for name in plot_examples(records, directory):
            lines += [f"![Signed curves]({name})", ""]
    (directory / "report.md").write_text("\n".join(lines))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--plots", action="store_true")
    args = parser.parse_args()
    result = analyze(args.directory.resolve(), args.plots)
    print(json.dumps(result, indent=2))
