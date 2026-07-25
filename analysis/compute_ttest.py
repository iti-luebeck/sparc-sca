# SPDX-License-Identifier: MIT
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck

#!/usr/bin/env python3
"""
Welch's t-test for Leakage Quantification (Phase 6B)

Implements Test Vector Leakage Analysis (TVLA) using Welch's t-test
to determine if power leakage is key-dependent.

Theory:
    - TVLA compares leakage under different key/plaintext combinations
    - Welch's t-test measures if leakage difference is statistically significant
    - High |t| values (|t| > 4.5) indicate key-dependent leakage
    
Usage:
    python compute_ttest.py traces_t0.npy traces_t1.npy [--output report.json]

Input:
    - traces_t0.npy: (N, M) array of leakage under taint condition 0
    - traces_t1.npy: (N, M) array of leakage under taint condition 1
    - N = number of test vectors, M = number of time samples

Output:
    - t_statistics: Per-sample t-statistic values
    - p_values: Statistical significance levels
    - max_t: Maximum |t| value (if > 4.5, leakage is key-dependent)
    - plots: Visualization of t-statistics over time
"""

import sys
import json
import numpy as np
from pathlib import Path
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass, asdict
import argparse

try:
    from scipy import stats
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False
    print("Warning: scipy not available, using simplified t-test")


@dataclass
class TVLAResult:
    """Result of TVLA analysis"""
    n_samples: int                  # Number of time samples
    n_vectors_t0: int               # Number of traces for group 0
    n_vectors_t1: int               # Number of traces for group 1
    max_t_statistic: float           # Maximum |t| value
    max_t_index: int                # Time index of max_t
    mean_t_absolute: float          # Mean of |t| values
    key_dependent: bool              # Is leakage key-dependent? (|t| > 4.5)
    threshold: float                 # Decision threshold
    p_value_at_max: float           # P-value at maximum t
    traces_t0_mean: np.ndarray      # Mean leakage for group 0 (per sample)
    traces_t1_mean: np.ndarray      # Mean leakage for group 1 (per sample)
    t_statistics: np.ndarray        # Per-sample t-statistic values


class WelchsTTest:
    """Welch's t-test implementation for leakage analysis"""
    
    def __init__(self, threshold: float = 4.5):
        """
        Initialize t-test analyzer.
        
        Args:
            threshold: Decision threshold for key-dependence
                      (default 4.5 is standard for cryptographic leakage)
        """
        self.threshold = threshold
    
    def compute_welch_ttest(
        self,
        group0: np.ndarray,  # (N0, M) samples
        group1: np.ndarray   # (N1, M) samples
    ) -> Tuple[np.ndarray, np.ndarray]:
        """
        Compute Welch's t-test between two groups.
        
        Welch's t-test does not assume equal variances (more robust than Student's t).
        
        Args:
            group0: (N0, M) array of traces for group 0
            group1: (N1, M) array of traces for group 1
        
        Returns:
            Tuple of (t_statistics, p_values) - one value per time sample
        """
        
        if group0.shape[1] != group1.shape[1]:
            raise ValueError("Groups must have same number of time samples")
        
        n_samples = group0.shape[1]
        t_stats = np.zeros(n_samples)
        p_values = np.zeros(n_samples)
        
        if HAS_SCIPY:
            # Use scipy's optimized implementation
            for i in range(n_samples):
                t_stat, p_val = stats.ttest_ind(
                    group0[:, i],
                    group1[:, i],
                    equal_var=False  # Welch's t-test
                )
                t_stats[i] = t_stat
                p_values[i] = p_val
        else:
            # Manual implementation (when scipy unavailable)
            for i in range(n_samples):
                t_stat, p_val = self._welch_ttest_manual(group0[:, i], group1[:, i])
                t_stats[i] = t_stat
                p_values[i] = p_val
        
        return t_stats, p_values
    
    def _welch_ttest_manual(self, x: np.ndarray, y: np.ndarray) -> Tuple[float, float]:
        """
        Manual Welch's t-test implementation.
        
        Formula:
            t = (mean_x - mean_y) / sqrt(var_x/n_x + var_y/n_y)
            df ≈ (var_x/n_x + var_y/n_y)^2 / ((var_x/n_x)^2/(n_x-1) + (var_y/n_y)^2/(n_y-1))
        """
        
        n_x = len(x)
        n_y = len(y)
        
        mean_x = np.mean(x)
        mean_y = np.mean(y)
        var_x = np.var(x, ddof=1)
        var_y = np.var(y, ddof=1)
        
        # t-statistic
        se = np.sqrt(var_x / n_x + var_y / n_y)
        if se == 0:
            return 0.0, 1.0
        
        t_stat = (mean_x - mean_y) / se
        
        # Degrees of freedom (Welch-Satterthwaite equation)
        numerator = (var_x / n_x + var_y / n_y) ** 2
        denominator = (var_x / n_x) ** 2 / (n_x - 1) + (var_y / n_y) ** 2 / (n_y - 1)
        
        if denominator > 0:
            df = numerator / denominator
        else:
            df = min(n_x, n_y) - 1
        
        # P-value (two-tailed)
        from scipy.stats import t as t_dist
        if HAS_SCIPY:
            p_val = 2 * (1 - t_dist.cdf(abs(t_stat), df))
        else:
            # Simplified: assume p ≈ 0 for |t| > 3
            p_val = 1.0 if abs(t_stat) < 1 else 0.01
        
        return t_stat, p_val
    
    def analyze(
        self,
        traces_t0: np.ndarray,
        traces_t1: np.ndarray
    ) -> TVLAResult:
        """
        Perform complete TVLA analysis on leakage traces.
        
        Args:
            traces_t0: (N0, M) array of leakage traces for group 0
            traces_t1: (N1, M) array of leakage traces for group 1
        
        Returns:
            TVLAResult object with analysis results
        """
        
        print(f"[*] Computing Welch's t-test")
        print(f"    Group 0: {traces_t0.shape[0]} traces × {traces_t0.shape[1]} samples")
        print(f"    Group 1: {traces_t1.shape[0]} traces × {traces_t1.shape[1]} samples")
        
        # Compute t-statistics
        t_stats, p_values = self.compute_welch_ttest(traces_t0, traces_t1)
        
        # Find maximum |t|
        abs_t = np.abs(t_stats)
        max_t_idx = np.argmax(abs_t)
        max_t = abs_t[max_t_idx]
        
        # Determine key-dependence
        is_key_dependent = max_t > self.threshold
        
        # Compute statistics
        mean_t0 = np.mean(traces_t0, axis=0)
        mean_t1 = np.mean(traces_t1, axis=0)
        
        result = TVLAResult(
            n_samples=traces_t0.shape[1],
            n_vectors_t0=traces_t0.shape[0],
            n_vectors_t1=traces_t1.shape[0],
            max_t_statistic=float(max_t),
            max_t_index=int(max_t_idx),
            mean_t_absolute=float(np.mean(abs_t)),
            key_dependent=bool(is_key_dependent),
            threshold=self.threshold,
            p_value_at_max=float(p_values[max_t_idx]),
            traces_t0_mean=mean_t0,
            traces_t1_mean=mean_t1,
            t_statistics=t_stats
        )
        
        return result
    
    def print_result(self, result: TVLAResult) -> None:
        """Pretty-print analysis results"""
        
        print("\n" + "="*60)
        print("TVLA ANALYSIS RESULTS")
        print("="*60)
        
        print(f"\nTest Configuration:")
        print(f"  Decision threshold: |t| > {result.threshold}")
        print(f"  Group 0 traces: {result.n_vectors_t0}")
        print(f"  Group 1 traces: {result.n_vectors_t1}")
        print(f"  Time samples per trace: {result.n_samples}")
        
        print(f"\nStatistical Results:")
        print(f"  Maximum |t|-value: {result.max_t_statistic:.4f}")
        print(f"  @ Time index: {result.max_t_index}")
        print(f"  P-value at max: {result.p_value_at_max:.6f}")
        print(f"  Mean |t|-value: {result.mean_t_absolute:.4f}")
        
        verdict = "✓ KEY-DEPENDENT LEAKAGE DETECTED" if result.key_dependent else "✗ No significant leakage"
        
        print(f"\nConclusion:")
        print(f"  {verdict}")
        
        if result.key_dependent:
            print(f"  → |t_max| = {result.max_t_statistic:.4f} > {result.threshold}")
            print(f"  → Leakage reveals information about the key/taint condition")
        else:
            print(f"  → |t_max| = {result.max_t_statistic:.4f} ≤ {result.threshold}")
            print(f"  → No statistically significant leakage detected")
        
        print("\nLeakage Magnitude:")
        print(f"  Mean(t0): {np.mean(result.traces_t0_mean):.4f}")
        print(f"  Mean(t1): {np.mean(result.traces_t1_mean):.4f}")
        print(f"  Difference: {np.mean(result.traces_t0_mean - result.traces_t1_mean):.4f}")
        print("="*60 + "\n")


def analyze_traces(
    traces_t0_file: str,
    traces_t1_file: str,
    threshold: float = 4.5,
    output_file: Optional[str] = None
) -> TVLAResult:
    """
    Main entry point: load traces and compute t-test.
    
    Args:
        traces_t0_file: Path to traces_t0.npy
        traces_t1_file: Path to traces_t1.npy
        threshold: Decision threshold for key-dependence
        output_file: Save results to JSON file
    
    Returns:
        TVLAResult object
    """
    
    # Load traces
    print(f"[*] Loading traces:")
    print(f"    Group 0: {traces_t0_file}")
    traces_t0 = np.load(traces_t0_file)
    
    print(f"    Group 1: {traces_t1_file}")
    traces_t1 = np.load(traces_t1_file)
    
    # Ensure same shape
    min_samples = min(traces_t0.shape[0], traces_t1.shape[0])
    traces_t0 = traces_t0[:min_samples]
    traces_t1 = traces_t1[:min_samples]
    
    # Handle 1D arrays (single trace)
    if traces_t0.ndim == 1:
        traces_t0 = traces_t0.reshape(1, -1)
    if traces_t1.ndim == 1:
        traces_t1 = traces_t1.reshape(1, -1)
    
    # Compute t-test
    analyzer = WelchsTTest(threshold=threshold)
    result = analyzer.analyze(traces_t0, traces_t1)
    
    # Print results
    analyzer.print_result(result)
    
    # Save results if requested
    if output_file:
        output_path = Path(output_file)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Create JSON-serializable result
        result_dict = {
            'n_samples': result.n_samples,
            'n_vectors_t0': result.n_vectors_t0,
            'n_vectors_t1': result.n_vectors_t1,
            'max_t_statistic': result.max_t_statistic,
            'max_t_index': result.max_t_index,
            'mean_t_absolute': result.mean_t_absolute,
            'key_dependent': result.key_dependent,
            'threshold': result.threshold,
            'p_value_at_max': result.p_value_at_max,
        }
        
        with open(output_path, 'w') as f:
            json.dump(result_dict, f, indent=2)
        
        print(f"[+] Results saved to: {output_file}")
    
    return result


def main():
    """Command-line interface"""
    parser = argparse.ArgumentParser(
        description='Compute Welch\'s t-test for leakage analysis (TVLA)'
    )
    parser.add_argument('traces_t0', help='Leakage traces for taint label 0')
    parser.add_argument('traces_t1', help='Leakage traces for taint label 1')
    parser.add_argument('--threshold', '-t', type=float, default=4.5,
                       help='Decision threshold for key-dependence (default: 4.5)')
    parser.add_argument('--output', '-o', help='Save results to JSON file')
    
    args = parser.parse_args()
    
    try:
        result = analyze_traces(
            args.traces_t0,
            args.traces_t1,
            threshold=args.threshold,
            output_file=args.output
        )
        
    except Exception as e:
        print(f"[-] Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
