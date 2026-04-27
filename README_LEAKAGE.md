# CellIFT with Power Side-Channel Leakage Tracking

Extended CellIFT framework that tracks both **information flow** (taint) and **power side-channel leakage** (exploitable switching activity on tainted paths).

---

## 📄 Documentation

**START HERE**: [POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md](POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md)
- Complete implementation summary (all 6 phases)
- Technical architecture and signal flow
- Integration requirements analysis
- 7-step implementation plan with validation strategy
- Proposal for target user experience

**Status Tracking**: [PROGRESS.md](PROGRESS.md)
- Current implementation status (✅ Code complete, ⚠️ Integration pending)
- Known blockers and critical path forward
- Next actions (~20 hours to completion)

---

## What This Adds to CellIFT

| Feature | Standard CellIFT | Enhanced CellIFT (This Work) |
|---------|------------------|------------------------------|
| **Tracks** | Information flow (taint) | Information flow + power leakage |
| **Question** | "Is signal influenced by secret?" | "Does signal leak power when influenced by secret?" |
| **Use Case** | Security verification | Side-channel vulnerability detection |
| **Output** | `signal_t0` (taint shadow) | `signal_leak0` (leakage shadow) |

### Key Innovation
```
Power Leakage = Taint AND Switching Activity

# A signal can be tainted but only leaks if it changes state (0→1 or 1→0)
```

---

## Implementation Status

✅ **900+ lines implemented**: C++, SystemVerilog, Python  
✅ **All 6 phases complete**: Utilities → DFF → Combinational → Integration → Wrapper → Analysis  
✅ **Compilation verified**: All object files build successfully  
⚠️ **Integration issue**: Leakage signals created but not observable (need port promotion)  
📋 **Estimated completion**: ~20 hours (see implementation plan)

---

## Project Structure

```
cellift-meta-leakage/
├── POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md  ← Complete guide (read first)
├── PROGRESS.md                               ← Status and next steps
│
├── tools/cellift-yosys/passes/cellift/
│   ├── cellift_util_leakage.cc              ← Phase 1: Utilities (70 lines)
│   ├── cellift.cc                            ← Phase 4: Modified for -track-power-leakage
│   └── cells/
│       ├── stateful/power_leakage/
│       │   └── dff_leakage.cc                ← Phase 2: DFF handler (79 lines)
│       └── {add,mux,xor,and,or}.cc           ← Phase 3: Combinational (34 lines)
│
├── simulation/wrappers/
│   └── ibex_tiny_soc_with_leakage.sv        ← Phase 5: Wrapper (270 lines)
│
├── analysis/
│   ├── extract_leakage_traces.py            ← Phase 6A: FST/VCD parsing (170 lines)
│   ├── compute_ttest.py                     ← Phase 6B: TVLA t-test (250 lines)
│   └── quantify_leakage.py                  ← Phase 6C: Orchestration
│
└── ARCHIVE_OLD_DOCS/                         ← Historical documentation (reference)
```

---

## Quick Start (Target Workflow - Once Integration Complete)

```bash
# 1. Build Yosys with power leakage support
cd cellift-meta-leakage
source env.sh
cd tools/cellift-yosys
make install PREFIX=$PREFIX_CELLIFT

# 2. Instrument cryptographic design
cd ../../design-processing
yosys -m cellift.so -p "cellift -track-power-leakage -num-distinct-labels 1" my_aes.v

# 3. Simulate with tainted key
cd ../cellift-designs/cellift-ibex/cellift
make build/run_cellift_trace_0.1/default-verilator/Vibex_tiny_soc
./build/run_cellift_trace_0.1/default-verilator/Vibex_tiny_soc

# 4. Analyze leakage with TVLA
cd ../../../analysis
python quantify_leakage.py \
    --trace1 ../cellift-designs/cellift-ibex/cellift/traces/key0.vcd \
    --trace2 ../cellift-designs/cellift-ibex/cellift/traces/key1.vcd \
    --threshold 4.5 \
    --output leakage_report

# 5. View results
cat leakage_report.txt
# Expected output:
# "TVLA Analysis: |t-statistic| = 12.5 > 4.5 threshold"
# "⚠️ Key-dependent power leakage detected in cycles [3450-3480, ...]"
```

---

## Current Blocker & Solution

### Problem
Leakage signals (`*_leak0`) are created internally by CellIFT pass but not exposed as module output ports. Result: Cannot observe in VCD traces, cannot perform statistical analysis.

### Root Cause
Phase 2 DFF handler creates leakage wires but doesn't mark them as `port_output = true`. Yosys optimizes away "unused" internal signals.

### Solution (Implementation Plan)
See [POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md](POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md), Section 7:
1. **Step 2 (4-6 hours)**: Modify `cellift_util_leakage.cc` to set `w->port_output = true`
2. **Step 3 (3-4 hours)**: Add hierarchical connection logic in `cellift.cc`
3. **Step 4 (4-5 hours)**: Implement top-level aggregation counter
4. **Steps 5-7 (8-10 hours)**: Validation, testing, documentation

**Critical Path**: Port promotion (Step 2) unblocks all downstream validation.

---

## Technical Highlights

### Three-Layer Shadow System
```verilog
module my_aes (
    input  [127:0] key_i,          // Layer 1: Functional (original design)
    input  [127:0] key_i_t0,       // Layer 2: Taint (standard CellIFT)
    output [127:0] key_i_leak0     // Layer 3: Leakage (this work) ← NEW!
);
```

### DFF Leakage Tracking (Phase 2)
```verilog
// For every flip-flop:
Q_prev = delay_register(Q);           // Store previous value
transition = Q XOR Q_prev;            // Detect state change
leak_Q = transition AND taint_Q;      // Power leaks when tainted signal transitions
```

### Statistical Validation (Phase 6)
```python
# Welch's t-test (TVLA - Test Vector Leakage Assessment)
t_stat = (mean_key0 - mean_key1) / sqrt(var_key0/n0 + var_key1/n1)

if |t_stat| > 4.5:  # Industry standard threshold
    print("⚠️ Exploitable power side-channel leakage detected")
```

---

## Files Inventory

### Implemented Code (Production)
- `cellift_util_leakage.cc` (70 lines) - Utility functions
- `dff_leakage.cc` (79 lines) - DFF leakage handler
- `{add,mux,xor,and,or}.cc` (34 lines total) - Combinational cell modifications
- `cellift.cc` (modifications) - Main pass integration with `-track-power-leakage` flag
- `ibex_tiny_soc_with_leakage.sv` (270 lines) - Simulation wrapper
- `extract_leakage_traces.py` (170 lines) - Trace extraction
- `compute_ttest.py` (250 lines) - Statistical analysis

### Documentation
- `POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md` - Complete implementation guide (41KB)
- `PROGRESS.md` - Status tracking
- `ARCHIVE_OLD_DOCS/` - Phase-specific design docs (historical reference)

---

## Next Steps

1. **Read**: [POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md](POWER_LEAKAGE_IMPLEMENTATION_SUMMARY.md)
2. **Study**: Section 6 (Yosys Integration Requirements)
3. **Implement**: Section 7, Step 2 (Port Promotion) - **Highest Priority**
4. **Validate**: Section 8 (Validation Strategy)
5. **Complete**: Remaining steps 3-7 (~16 hours)

---

## References

- **CellIFT Project**: https://comsec.ethz.ch/cellift
- **TVLA Standard**: NIST SP 800-180 (Test Vector Leakage Assessment)
- **Original Paper**: Differential Power Analysis (Kocher et al., 1999)
- **Side-Channel Analysis**: https://doi.org/10.1007/978-3-319-66399-9_19

---

# Original CellIFT-Meta Documentation

This repository regroups tools needed to reproduce the experiments performed in the [CellIFT paper](https://comsec.ethz.ch/cellift).

The supported designs are frozen versions of [Ibex](https://github.com/comsec-group/cellift-ibex/), [PULPissimo](https://github.com/comsec-group/cellift-pulpissimo-hdac-2018/), [CVA6](https://github.com/comsec-group/cellift-cva6/), [Rocket and BOOM](https://github.com/comsec-group/cellift-chipyard/).

## What is CellIFT?

Visit [our dedicated web page](https://comsec.ethz.ch/research/microarch/cellift/) to know more about the nature and use cases of CellIFT.

In a few words, CellIFT is a mechanism that supports dynamic information flow tracking for RTL designs.
_Dynamic information flow tracking reveals which internal and output signals (taint sinks) can be affected by changing values at designated input signals (taint sources)._

Use cases include:
- Data integrity and confidentiality verification
- Complex information leakage detection (Spectre, Meltdown)
- **[NEW] Power side-channel vulnerability detection** ← This work

CellIFT is open source and outperforms pre-existing mechanisms by 1-2 orders of magnitude in both precision and speed.

## Getting Started

See original CellIFT documentation below for installation and usage.
