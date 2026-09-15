#!/usr/bin/env python3
"""Compare two speed-matrix runs.

usage: compare-receipts.py BEFORE_DIR AFTER_DIR

A case is IDENTICAL when every route-defining field matches: status, limit, metres,
dirt percentage, the hash of the selected edge IDs, the selected route's search states,
the per-candidate summary, fuel stops and hop metres and edges.
Work (search count, total states) is reported before -> after but never decides
identity: exact speedups are expected to reduce it.
Cases whose result depends on a time limit are marked TIMED, because the work done
before the deadline legitimately varies between runs and machines.
Exit status is 1 when any untimed case differs.
"""
import json
import pathlib
import re
import sys

ROUTE = ["status", "limit", "distanceMeters", "knownDirtPercent", "edgeIDsSHA256", "pops",
         "searchSummary", "fuelStops", "hopMeters", "hopEdgeSHA256"]


def load(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def peak_mib(json_path):
    time_path = json_path.with_suffix(".time")
    if not time_path.exists():
        return None
    match = re.search(r"(\d+)\s+peak memory footprint", time_path.read_text())
    return int(match.group(1)) / 1048576 if match else None


def timed(receipt):
    return "time" in f"{receipt.get('limit')} {receipt.get('searchSummary')}"


def main():
    before_dir, after_dir = map(pathlib.Path, sys.argv[1:3])
    failures = 0
    for before_path in sorted(before_dir.glob("*.json")):
        after_path = after_dir / before_path.name
        before, after = load(before_path), load(after_path)
        name = before_path.stem
        if before is None or after is None:
            print(f"{name:32s} MISSING   before={'ok' if before else 'none'} after={'ok' if after else 'none'}")
            continue
        differences = [key for key in ROUTE if before.get(key) != after.get(key)]
        if not differences:
            verdict = "IDENTICAL"
        elif timed(before) or timed(after):
            verdict = "TIMED"
        else:
            verdict = "DIFFERENT"
            failures += 1
        b_s, a_s = before.get("seconds", 0), after.get("seconds", 0)
        b_m, a_m = peak_mib(before_path), peak_mib(after_path)
        speed = f" {b_s:6.2f}s -> {a_s:6.2f}s ({b_s / a_s:4.1f}x)" if a_s else ""
        work = f" searches {before.get('searches')}->{after.get('searches')}, states {before.get('totalPops')}->{after.get('totalPops')}"
        memory = f", peakMiB {b_m:.0f}->{a_m:.0f}" if b_m and a_m else ""
        detail = f"  differs: {', '.join(differences)}" if differences else ""
        print(f"{name:32s} {verdict:9s}{speed}{work}{memory}{detail}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
