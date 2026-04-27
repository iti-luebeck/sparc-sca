#!/usr/bin/env python3
"""
VCD Leakage Trace Extraction Tool (Working Implementation)

Parses VCD files from BOOM leakage simulation and extracts leakage counter values.

Usage:
    python extract_vcd_leakage.py trace.vcd --output traces.npy

Input:
    - VCD file from top_tiny_soc_with_leakage simulation
    - Signal: leakage_counter_t0 (32-bit counter)

Output:
    - traces.npy: (N_cycles,) array of cumulative leakage counts
    - metadata.json: Signal info, cycle count, etc.
"""

import sys
import json
import argparse
import numpy as np
from pathlib import Path
from typing import Dict, List, Optional

try:
    from vcd import VCDParser
    HAS_PYVCD = True
except ImportError:
    HAS_PYVCD = False
    print("WARNING: pyvcd not installed. Using simple parser mode.")
    print("For full VCD support, run: pip install pyvcd")


def extract_leakage_from_vcd(vcd_file: str, signal_name: str = "leakage_counter_t0") -> np.ndarray:
    """
    Extract leakage counter signal from VCD file.

    Args:
        vcd_file: Path to VCD file
        signal_name: Name of leakage counter signal (default: leakage_counter_t0)

    Returns:
        numpy array of leakage counter values over time
    """
    vcd_path = Path(vcd_file)
    if not vcd_path.exists():
        raise FileNotFoundError(f"VCD file not found: {vcd_file}")

    print(f"Parsing VCD file: {vcd_file}")
    print(f"Looking for signal: {signal_name}")

    # Parse VCD and find the leakage counter signal
    with open(vcd_path, 'r') as f:
        vcd = VCDParser()
        vcd.parse(f)

        # Find the signal in the hierarchy
        signal_id = None
        for scope, signals in vcd.scope.walk():
            for sig in signals:
                if signal_name in sig.name:
                    signal_id = sig.ident
                    print(f"Found signal: {sig.name} (ID: {signal_id}, width: {sig.size})")
                    break
            if signal_id:
                break

        if not signal_id:
            raise ValueError(f"Signal '{signal_name}' not found in VCD file")

    # Extract signal values over time
    with open(vcd_path, 'r') as f:
        vcd = VCDParser()
        vcd.parse(f)

        # Get all value changes for this signal
        timestamps = []
        values = []

        for change in vcd:
            if hasattr(change, 'var') and change.var.ident == signal_id:
                timestamps.append(change.time)
                # Parse binary value string (e.g., "b00000000000000000000000000000101")
                value_str = change.value
                if value_str.startswith('b'):
                    value = int(value_str[1:], 2)
                else:
                    value = int(value_str, 0)
                values.append(value)

    if not values:
        raise ValueError(f"No value changes found for signal '{signal_name}'")

    print(f"Extracted {len(values)} samples")
    print(f"Time range: {timestamps[0]} to {timestamps[-1]}")
    print(f"Leakage range: {min(values)} to {max(values)}")

    return np.array(values, dtype=np.int32), np.array(timestamps, dtype=np.int64)


def extract_leakage_simple(vcd_file: str, signal_name: str = "leakage_counter_t0") -> np.ndarray:
    """
    Simplified VCD parser using grep-like approach (fallback if pyvcd has issues).

    This reads the VCD file and tracks value changes for the leakage counter.
    """
    vcd_path = Path(vcd_file)

    print(f"Parsing VCD file (simple mode): {vcd_file}")

    # Step 1: Find signal identifier in VCD header
    signal_id = None
    signal_width = 32

    with open(vcd_path, 'r') as f:
        for line in f:
            if signal_name in line and '$var' in line:
                # Format: $var wire 32 ~/M leakage_counter_t0 [31:0] $end
                parts = line.strip().split()
                if len(parts) >= 4:
                    signal_width = int(parts[2])
                    signal_id = parts[3]
                    print(f"Found signal: {signal_name} (ID: {signal_id}, width: {signal_width})")
                    break
            if line.strip() == '$enddefinitions $end':
                break

    if not signal_id:
        raise ValueError(f"Signal '{signal_name}' not found in VCD header")

    # Step 2: Extract values from data section
    timestamps = []
    values = []
    current_time = 0

    with open(vcd_path, 'r') as f:
        in_data_section = False

        for line in f:
            line = line.strip()

            if '$enddefinitions $end' in line:
                in_data_section = True
                continue

            if not in_data_section:
                continue

            # Parse timestamp
            if line.startswith('#'):
                current_time = int(line[1:])
                continue

            # Parse value change for our signal
            # Format: b<binary_value> <signal_id>
            if signal_id in line:
                if line.startswith('b'):
                    # Binary value: b00000000000000000000000000000101 ~/M
                    parts = line.split()
                    if len(parts) == 2 and parts[1] == signal_id:
                        binary_value = parts[0][1:]  # Remove 'b' prefix
                        value = int(binary_value, 2)
                        timestamps.append(current_time)
                        values.append(value)

    if not values:
        raise ValueError(f"No value changes found for signal '{signal_name}'")

    print(f"Extracted {len(values)} samples")
    print(f"Time range: {timestamps[0]} to {timestamps[-1]} cycles")
    print(f"Leakage range: {min(values)} to {max(values)}")
    print(f"Final leakage count: {values[-1]}")

    return np.array(values, dtype=np.int32), np.array(timestamps, dtype=np.int64)


def main():
    parser = argparse.ArgumentParser(
        description="Extract leakage counter traces from VCD files"
    )
    parser.add_argument(
        "vcd_file",
        type=str,
        help="Input VCD file from simulation"
    )
    parser.add_argument(
        "--signal",
        type=str,
        default="leakage_counter_t0",
        help="Signal name to extract (default: leakage_counter_t0)"
    )
    parser.add_argument(
        "--output",
        type=str,
        default="leakage_trace.npy",
        help="Output numpy file (default: leakage_trace.npy)"
    )
    parser.add_argument(
        "--simple",
        action="store_true",
        help="Use simplified parser (more robust for large VCD files)"
    )

    args = parser.parse_args()

    try:
        if args.simple or not HAS_PYVCD:
            values, timestamps = extract_leakage_simple(args.vcd_file, args.signal)
        else:
            values, timestamps = extract_leakage_from_vcd(args.vcd_file, args.signal)

        # Save as numpy array
        output_path = Path(args.output)
        np.save(output_path, values)
        print(f"\nSaved leakage trace to: {output_path}")

        # Save metadata
        metadata = {
            "vcd_file": str(args.vcd_file),
            "signal_name": args.signal,
            "n_samples": len(values),
            "time_range": [int(timestamps[0]), int(timestamps[-1])],
            "leakage_range": [int(min(values)), int(max(values))],
            "final_leakage": int(values[-1])
        }

        metadata_path = output_path.with_suffix('.json')
        with open(metadata_path, 'w') as f:
            json.dump(metadata, f, indent=2)
        print(f"Saved metadata to: {metadata_path}")

        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
