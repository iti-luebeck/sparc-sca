# SPDX-License-Identifier: MIT
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck

#!/usr/bin/env python3
"""
Detect computation end cycle from CellIFT leakage CSV traces.

After a workload completes, the processor enters an idle loop with a constant,
deterministic HW switching rate. This script finds the last cycle where the
per-cycle HW rate is significantly above that idle rate.

Usage:
  python3 detect_computation_end.py <csv_path> [cumulative|per_cycle]

  cumulative : hamming_weight_counter_t0 is a running sum (Ibex, Rocket)
  per_cycle  : hamming_weight_counter_t0 is the per-cycle value (Proteus)
  Default    : auto-detect based on monotonicity
"""

import csv
import statistics
import sys


def detect_computation_end(csv_path, fmt="auto", window=200, threshold_factor=1.5):
    with open(csv_path) as fp:
        rows = list(csv.DictReader(fp))

    raw = [int(r["hamming_weight_counter_t0"]) for r in rows]

    if fmt == "auto":
        decreases = sum(1 for i in range(1, len(raw)) if raw[i] < raw[i - 1])
        fmt = "cumulative" if decreases < len(raw) * 0.01 else "per_cycle"
        print(f"  Auto-detected format: {fmt} ({decreases} decreases in {len(raw)} rows)")

    if fmt == "cumulative":
        vals = [raw[i] - raw[i - 1] for i in range(1, len(raw))]
    else:
        vals = raw

    # Idle rate: median of last 3000 samples (post-computation idle loop)
    idle = statistics.median(vals[-3000:])
    threshold = idle * threshold_factor

    # Find last window of size `window` where mean > threshold
    last_active = 0
    for i in range(0, len(vals) - window, 5):
        if sum(vals[i : i + window]) / window > threshold:
            last_active = i

    end_cycle = last_active + window

    # Warn if computation may not have finished
    within_simlen = end_cycle < len(vals) - 500
    status = "OK" if within_simlen else "WARNING: may not have finished within SIMLEN"

    return end_cycle, idle, threshold, status


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    csv_path = sys.argv[1]
    fmt = sys.argv[2] if len(sys.argv) > 2 else "auto"

    print(f"Analyzing: {csv_path}")
    end_cycle, idle, threshold, status = detect_computation_end(csv_path, fmt)
    print(f"  idle rate: {idle:.1f} HW/cycle, threshold: {threshold:.1f}")
    print(f"  Estimated computation end: ~cycle {end_cycle}")
    print(f"  Status: {status}")


if __name__ == "__main__":
    main()
