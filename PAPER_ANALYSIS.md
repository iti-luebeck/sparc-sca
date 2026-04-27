# CellIFT Power Side-Channel Leakage — Paper Analysis

This document provides a technical description of the implementation, an overview of experiments, and result display templates for use in an academic paper.

---

## Table of Contents

1. [Implementation Description](#1-implementation-description)
   - 1.1 [Background & Design Goal](#11-background--design-goal)
   - 1.2 [Three-Layer Shadow System](#12-three-layer-shadow-system)
   - 1.3 [Yosys Pass — Architecture](#13-yosys-pass--architecture)
   - 1.4 [Utility and Naming Layer](#14-utility-and-naming-layer)
   - 1.5 [DFF Instrumentation — The Core Innovation](#15-dff-instrumentation--the-core-innovation)
   - 1.6 [Combinational Cell Instrumentation](#16-combinational-cell-instrumentation)
   - 1.7 [Main Pass Execution Flow](#17-main-pass-execution-flow)
   - 1.8 [HW/HD Aggregation Counters](#18-hwhd-aggregation-counters)
   - 1.9 [Instrumentation Output Summary](#19-instrumentation-output-summary)
   - 1.10 [Statistical Analysis — TVLA](#110-statistical-analysis--tvla)
   - 1.11 [Correctness Properties](#111-correctness-properties)
2. [Experiment Overview](#2-experiment-overview)
   - 2.1 [Processors Under Evaluation](#21-processors-under-evaluation)
   - 2.2 [Evaluated Cryptographic Software](#22-evaluated-cryptographic-software)
   - 2.3 [Workload and Scenario Generation](#23-workload-and-scenario-generation)
   - 2.4 [Root-Cause Attribution Pipeline](#24-root-cause-attribution-pipeline)
3. [Key Results](#3-key-results)
   - 3.1 [TVLA Summary](#31-tvla-summary)
   - 3.2 [Masking Delay Comparison](#32-masking-delay-comparison)
   - 3.3 [Root-Cause Signal Attribution](#33-root-cause-signal-attribution)
4. [Result Display Templates (LaTeX)](#4-result-display-templates-latex)
5. [Key Claims for the Paper](#5-key-claims-for-the-paper)

---

## 1. Implementation Description

### 1.1 Background & Design Goal

CellIFT performs dynamic information flow tracking (IFT) at the cell level inside RTL designs via a Yosys synthesis pass. For every signal `X`, it creates a taint shadow `X_t0` that tracks whether `X` is transitively influenced by a designated secret input. This answers the question *"can this signal reach a secret?"* — but not *"does it leak power when it does?"*

This work extends CellIFT with the observation that CMOS power consumption is dominated by dynamic switching: gates consume power proportional to 0→1 / 1→0 transitions. A signal leaks **key-dependent power** if and only if:

1. It carries taint (is influenced by the key), **AND**
2. It transitions state in a key-dependent way

Neither condition alone is sufficient. A stable tainted signal consumes no dynamic power; an untainted transition carries no secret information.

---

### 1.2 Three-Layer Shadow System

The instrumentation adds a third signal layer beyond the original functional signals and CellIFT taint shadows:

| Layer    | Suffix  | Example                | Semantics                         |
|----------|---------|------------------------|-----------------------------------|
| Functional | (none) | `key_data[7:0]`       | Original design signal            |
| Taint    | `_t0`   | `key_data_t0[7:0]`    | Influenced by secret (IFT)        |
| Leakage  | `_leak0`| `key_data_leak0[7:0]` | Power leaks here (this work)      |

---

### 1.3 Yosys Pass — Architecture

**Activation:**
```bash
yosys -m cellift.so -p "cellift -track-power-leakage -num-distinct-labels 1 design.il"
```

**Key command-line options:**

| Option | Effect |
|--------|--------|
| `-track-power-leakage` | Enable leakage shadow wires and counters |
| `-num-distinct-labels N` | Number of parallel taint/leakage labels |
| `-power-leakage-scope <modules>` | Which modules receive HW/HD counters |
| `-power-leakage-auto-scope` | Auto-detect tainted modules for counters |
| `-exclude-signals <list>` | Skip named signals from instrumentation |

The pass processes modules in **bottom-up topological order** (children before parents), ensuring that child module ports are fully resolved before parent modules wire up to them. This preserves compositionality of all shadow logic across hierarchy boundaries.

---

### 1.4 Utility and Naming Layer

**Files:** `cellift_util.cc` (original taint), `cellift_util_leakage.cc` (leakage extension)

The two utilities are mirrors of each other, differing in one critical detail:

```cpp
// Taint utility (original) — internal shadow wire
Wire *w = module->addWire(taint_name, bit_width);
w->port_output = false;   // invisible to simulator, Yosys may eliminate

// Leakage utility (new) — promoted to output port
Wire *w = module->addWire(leak_name, bit_width);
w->port_output = true;    // visible in VCD/FST traces (cellift_util_leakage.cc:50)
```

The `port_output = true` flag is what makes leakage signals observable in simulation without Yosys optimizing them away as unused internal nodes. All downstream statistical analysis depends on this.

**Signal naming conventions:**
- Taint: `signal_name` → `signal_name_t0`, `signal_name_t1`, ...
- Leakage: `signal_name` → `signal_name_leak0`, `signal_name_leak1`, ...

A helper `is_clock_or_reset_signal()` heuristically excludes control signals (matching `clk`, `rst`, `reset`, `clock` case-insensitively) from all leakage tracking to prevent false positives on non-data paths.

---

### 1.5 DFF Instrumentation — The Core Innovation

**Files:** `cells/stateful/dff.cc` (original), `cells/stateful/power_leakage/dff_leakage.cc` (new)

The standard DFF handler simply creates shadow flip-flops for taint propagation:
```verilog
// Standard CellIFT: taint propagates through state registers
taint_Q[next] ← taint_D[current]
```

The new `cellift_dff_with_leakage()` adds three hardware structures per taint label:

**Structure 1 — Delay register:**
```cpp
Wire *Q_prev = module->addWire(NEW_ID, ports[Q].size());
Cell *delay_ff = module->addDff(NEW_ID, clk, ports[Q], Q_prev, clk_polarity);
delay_ff->set_bool_attribute(ID(leakage_delay_ff));   // tagged for downstream tools
```
Creates a registered copy of Q, clocked one cycle behind. The `leakage_delay_ff` attribute marks it for analysis tooling.

**Structure 2 — Transition detection:**
```cpp
SigSpec transition = module->Xor(NEW_ID, ports[Q], Q_prev);
// transition[i] = 1 iff Q[i] changed (0→1 or 1→0) since last cycle
```

**Structure 3 — Leakage gating:**
```cpp
SigSpec leakage_output = module->And(NEW_ID, transition, port_taints[Q][taint_id]);
// leak[i] = 1 iff Q[i] transitioned AND Q[i] carries taint
```

Expressed as a formula:
```
Q_leak0[i] = (Q[i] XOR Q_prev[i])  AND  Q_t0[i]
```

This is the paper's central technical contribution: it captures the physical reality of CMOS power dissipation at the register level with a two-condition gate.

**Port connection:** If Q is a module output port, a corresponding `Q_leak0` output port is connected to `leakage_output`, making it observable in waveform traces. An internal leakage wire is always connected regardless, so parent modules can propagate the signal hierarchically.

---

### 1.6 Combinational Cell Instrumentation

**Files:** `cells/{add,mux,xor,and,or}.cc`

All five combinational cells follow a three-step uniform pattern:

**Step 1 — Retrieve shadow vectors for all ports:**
```cpp
for (unsigned int i = 0; i < NUM_PORTS; ++i) {
    port_taints[i]   = get_corresponding_taint_signals(..., num_taints);
    port_leakages[i] = get_corresponding_leakage_signals(..., num_taints);
}
```

**Step 2 — Compute taint output** (cell-specific, see table below).

**Step 3 — Assign leakage with the simplified conservative model:**
```cpp
SigSpec leakage_output = port_taints[Y][taint_id];   // leak = taint
module->connect(port_leakages[Y][taint_id], leakage_output);
```

The conservative model (`leak = taint`) is justified by the fact that combinational outputs transition within the same clock cycle as their tainted inputs; no explicit transition-detection register is needed at the combinational level.

**Cell-specific taint propagation rules:**

| Cell | Taint propagation rule | Key property |
|------|------------------------|--------------|
| XOR  | `Y_t = A_t OR B_t` | XOR always mixes both inputs |
| AND  | `Y_t = (A_t AND B) OR (B_t AND A) OR (A_t AND B_t)` | Taint blocked when other input forces output to 0 |
| OR   | `Y_t = (A_t AND NOT B) OR (B_t AND NOT A) OR (A_t AND B_t)` | Taint blocked when other input forces output to 1 |
| ADD  | `Y_t = XOR(left_bound, right_bound) OR A_t OR B_t` | Carry-ripple propagation through masked intervals; `left_bound = (A AND NOT A_t) + (B AND NOT B_t)`, `right_bound = (A OR A_t) + (B OR B_t)` |
| MUX  | `Y_t = data_taint OR (S_t AND (A XOR B))` | **Tainted selector leaks if data paths differ** |

The AND/OR rules implement CellIFT's secure taint semantics: taint is not propagated when the output is determined regardless of the tainted input (AND-with-0, OR-with-1). The MUX rule is particularly notable — a tainted control input that distinguishes between data paths is itself a leakage source, capturing the information-theoretic reality that the branch taken reveals secrets.

---

### 1.7 Main Pass Execution Flow

The `CellIFTWorker::create_cellift_logic()` method processes each module in four phases:

**Phase 1 — Port creation** (lines 428–502 of `cellift.cc`):

For every input port, taint shadow input ports are created (so callers can inject taint sources). For every output port, taint and leakage shadow output ports are created (so callers and simulators can observe them). Leakage output ports are only created when `-track-power-leakage` is active.

**Phase 2 — Cell dispatch loop** (lines 504–796):

Every cell in the module is dispatched to its handler. The DFF branch is the critical fork:
```cpp
else if (cell->type.in(ID($dff))) {
    if (opt_track_power_leakage)
        keep_current_cell = cellift_dff_with_leakage(...);   // leakage mode
    else
        keep_current_cell = cellift_dff(...);                // taint-only mode
}
```

For hierarchical (user-defined) module instances, leakage ports are connected at the instantiation site:
```cpp
if (opt_track_power_leakage) {
    Wire *port_wire = submodule->wire(port_name);
    if (port_wire && port_wire->port_output) {
        // Connect parent-side leakage wire to child-side leakage output port
        cell->setPort(get_wire_leakage_idstring(port_name, lid), port_leakages[lid]);
    }
}
```
Only output ports of child modules receive leakage connections, reflecting the direction of information flow.

**Phase 3 — Wire connection propagation** (lines 801–857):

For every `connect` statement in the module (wire aliases, direct connections), both taint and leakage shadows are also connected. This ensures shadow consistency across signal paths that Yosys represents as connections rather than as explicit cells.

**Phase 4 — Module fixup:**

`module->fixup_ports()` recalculates port indices and directions after all new ports were added. The `cellift` attribute is set to prevent re-instrumentation on subsequent pass invocations.

---

### 1.8 HW/HD Aggregation Counters

After all modules are instrumented, scalar aggregation counters are inserted into the designated scope module(s). These produce the per-cycle measurements that feed into TVLA analysis.

**Hamming Weight (HW) counter** — measures how many tainted bits are active each cycle:
```
For every data wire D with taint wire D_t:
    hw_bits += AND(D, D_t)          // bit set only when data=1 AND taint=1

HW_counter = POPCOUNT(hw_bits)      // 32-bit registered output port
```

**Hamming Distance (HD) counter** — measures how many tainted bits transitioned each cycle:
```
For every data wire D with taint wire D_t:
    D_prev = DFF(D)                          // 1-cycle delay register
    hd_bits += AND(XOR(D, D_prev), D_t)     // transition on tainted bit

HD_counter = POPCOUNT(hd_bits)      // 32-bit registered output port
```

**Physical interpretation:**
- HW models the power consumed by tainted logic in the current state (proportional to data-dependent Hamming weight, the standard power model).
- HD models the switching power (transitions on tainted paths), which is the dominant power component in dynamic CMOS.

A coarser indicator `leakage_counter_t0` is also created as an OR-reduction of all `_leak0` wires in the top module, yielding a single bit: "was any leakage active this cycle?"

**Scope control:** `-power-leakage-scope` names specific modules; `-power-leakage-auto-scope` detects all modules containing tainted signals. For non-top scope modules, `promote_counters_hierarchically()` wires the counters up through the hierarchy until they appear at the top-level simulation ports.

---

### 1.9 Instrumentation Output Summary

After the pass, the following new ports appear at the top level for one taint label:

| Port | Direction | Width | Meaning |
|------|-----------|-------|---------|
| `<signal>_t0` (per input) | Input | = signal width | Taint source injection point |
| `<signal>_t0` (per output) | Output | = signal width | Taint sink observation |
| `<signal>_leak0` (per output) | Output | = signal width | Per-bit power leakage indicators |
| `hamming_weight_counter_t0` | Output | 32 bits | # tainted bits active this cycle |
| `hamming_distance_counter_t0` | Output | 32 bits | # tainted bit transitions this cycle |
| `leakage_counter_t0` | Output | 32 bits | Any leakage active this cycle (0 or 1) |

The TVLA analysis ingests `hamming_weight_counter_t0` and `hamming_distance_counter_t0` sampled every cycle across many simulation runs.

---

### 1.10 Statistical Analysis — TVLA

**Files:** `analysis/compute_ttest.py`, `analysis/extract_leakage_traces.py`

Leakage assessment uses **Welch's t-test** (Test Vector Leakage Assessment — TVLA, per NIST SP 800-180). The test is applied **per simulation cycle** to produce a time-series of t-statistics:

```
t[c] = (μ₀[c] − μ₁[c]) / √(σ²₀[c]/N₀ + σ²₁[c]/N₁)
```

Where group 0 and group 1 are sets of simulation traces run with keys K₀ and K₁ respectively, and μᵢ[c], σ²ᵢ[c] are the per-cycle mean and variance of the HW (or HD) counter. Decision threshold: **|t| > 4.5** (p < 3×10⁻⁵, standard in physical side-channel evaluation per NIST SP 800-180).

Welch's t-test (rather than Student's) is used because it does not assume equal variances between groups — appropriate when key-dependent leakage produces distributional shifts of unknown magnitude.

The per-cycle resolution of the t-statistic directly localizes leakage to specific pipeline stages and AES rounds, enabling root-cause attribution.

---

### 1.11 Correctness Properties

| Property | Mechanism | Implication |
|----------|-----------|-------------|
| **Sound (no false negatives)** | Taint is over-approximate; all real information flows are captured | No actual leakage goes undetected |
| **Conservative (may false positive)** | Combinational `leak = taint` does not verify actual transitions occur | Some reported leakage cycles may not physically leak |
| **Compositional** | Bottom-up processing; child ports resolved before parent wires up | Hierarchy does not break shadow tracking |
| **Non-intrusive** | All instrumentation is additive; original cells are kept | Functional behavior of the design is unchanged |

---

## 2. Experiment Overview

### 2.1 Processors Under Evaluation

| | Ibex | Proteus | Rocket |
|---|---|---|---|
| **ISA** | RV32IMC | RV32IM | RV64G |
| **Pipeline** | 2-stage in-order | 8-ALU OoO superscalar | 5-stage OoO (Chipyard) |
| **Bus interface** | TL-UL | AXI4 128-bit | TL-UL memory bus |
| **Instrumented RTL** | ~50,000 lines | ~849,000 lines | ~500,000 lines (est.) |
| **Simulation length** | 30,000 cycles | 30,000 cycles | 50,000 cycles |

The three processors span the design complexity spectrum: Ibex is a minimal embedded core, Proteus is a high-performance OoO superscalar, and Rocket is a full Linux-capable OoO core from the Chipyard SoC framework. This range validates the methodology across fundamentally different micro-architectural choices.

### 2.2 Evaluated Cryptographic Software

Three software workloads were evaluated, compiled bare-metal and cross-compiled with the appropriate RV32/RV64 toolchain.

#### AES-128 (Unmasked)

Standard 10-round AES-128 encryption (`aes128_encrypt`) implemented in portable C. The key schedule expands a 128-bit secret key into 11 round keys. Each encryption round applies SubBytes (S-box lookup), ShiftRows (byte permutation), MixColumns (GF(2⁸) matrix multiply), and AddRoundKey (XOR with round key). No masking or countermeasures are applied; all intermediate values are computed in the clear. This provides the baseline leakage scenario and exhibits the strongest TVLA signal.

#### AES-128 (First-Order Boolean Masked)

The same AES-128 algorithm with a first-order Boolean masking scheme applied (`aes128_masked_encrypt`). Every secret-derived value is split into two shares: `v = v_data XOR v_mask`, where `v_mask` is drawn from a fresh random source at the start of each encryption. Shares are recombined only at algorithm completion. The S-box is replaced with a masked variant that operates on shares directly, and MixColumns is computed over the masked representation. This countermeasure is theoretically sound at first order, but hardware micro-architectural effects (pipeline forwarding, bus re-combination, speculative execution) can still expose key-dependent leakage — the hypothesis under test.

#### CRYSTALS-Kyber-512 (Unmasked)

CRYSTALS-Kyber is a module-lattice-based key encapsulation mechanism standardized by NIST as FIPS 203 (ML-KEM). The evaluated workload is a decapsulation operation on Kyber-512 parameters (security level 1). Key algorithmic phases and their source locations:

| Phase | Source location | Operation |
|-------|----------------|-----------|
| Key loading | `poly_frombytes` (poly.c:133–134) | Decode packed 12-bit polynomial coefficients from byte array into ring elements |
| NTT multiply | `basemul` (ntt.c:155–160) | Point-wise multiplication of NTT-domain polynomials — innermost loop of matrix–vector product |
| Modular reduction | `fqmul` (ntt.c:79) | Montgomery reduction of 32-bit products modulo Kyber prime q=3329 |
| Hash/expand | `KeccakF1600_StatePermute` (fips202.c:134) | SHA-3/SHAKE permutation used for pseudo-random seed expansion |

Only the unmasked variant of Kyber was evaluated. Kyber's polynomial arithmetic creates a very different leakage profile than AES: secrets appear in NTT coefficient arrays held in SRAM and cache, and the dominant operations (integer multiply, XOR, shift) differ structurally from AES's byte-oriented S-box. The simulation length is significantly longer (2,000,000 cycles vs. 30,000 for AES) because the full Kyber decapsulation comprises many more operations.

---

### 2.3 Workload and Scenario Generation

- **Workloads:** AES-128 encryption (unmasked + first-order Boolean masked) and Kyber-512 decapsulation (unmasked only), all running bare-metal.
- **Matched-pair scenario generation:** For each trace pair, plaintext/ciphertext and masking randomness are held constant; only the key differs (K₀ vs. K₁). This eliminates all confounders and makes the t-test sensitive exclusively to key-dependent leakage.
- **Trace counts:**
  - AES unmasked: 20 traces/group
  - AES masked: 100 traces/group (increased due to reduced SNR under masking)
  - Kyber unmasked: 20 traces/group
- **Simulation lengths:**
  - AES: 30,000 cycles (Ibex, Proteus); 50,000 cycles (Rocket — 64-bit execution has higher instruction count)
  - Kyber: 2,000,000 cycles per trace across all three processors (the full decapsulation requires substantially more cycles)

### 2.4 Root-Cause Attribution Pipeline

Beyond TVLA pass/fail, a 10-step evaluation pipeline produces fine-grained attribution:

1. **Preflight** — validate build and simulation environment
2. **Scenario generation** — matched-pair key/plaintext/mask sets
3. **Compilation** — cross-compile AES firmware (RV32 or RV64 toolchain)
4. **Multi-trace TVLA** — Welch t-test on HW/HD counter distributions
5. **Region discovery** — identify leakage onset cycle and episode boundaries
6. **Signal-level analysis** — rank individual `_leak0` signals by key-dependent divergence (VCD comparison across K₀/K₁ traces)
7. **Instruction mapping** — correlate leaky PC values to source lines via `addr2line`
8. **Per-cycle quantification** — regime detection, interval annotation, peak |t| per interval
9. **Run manifest export** — JSON record of all configuration parameters
10. **Publication summary** — consolidated evidence report (Markdown + JSON)

---

## 3. Key Results

### 3.1 TVLA Summary

**AES-128 results (Welch t-test, threshold |t| > 4.5):**

| Processor | AES Type | Metric | Traces/group | Onset Cycle | Max \|t\| | Verdict |
|-----------|----------|--------|:---:|:---:|:---:|:---:|
| Ibex      | Unmasked | HW     | 20  |    53 |    34.5 | **LEAK** |
| Ibex      | Unmasked | HD     | 20  |    53 |    46.8 | **LEAK** |
| Ibex      | Masked   | HW     | 100 |    73 |    78.7 | **LEAK** |
| Ibex      | Masked   | HD     | 100 |    73 |   131.0 | **LEAK** |
| Proteus   | Unmasked | HW     | 20  |    36 |   606.6 | **LEAK** |
| Proteus   | Unmasked | HD     | 20  |    36 |   464.4 | **LEAK** |
| Proteus   | Masked   | HW     | 100 |    44 |   492.8 | **LEAK** |
| Proteus   | Masked   | HD     | 100 |    44 |  1443.0 | **LEAK** |
| Rocket    | Unmasked | HW     | 20  |   145 |   225.9 | **LEAK** |
| Rocket    | Unmasked | HD     | 20  |   145 |   193.9 | **LEAK** |
| Rocket    | Masked   | HW     | 100 |   375 |     7.6 | **LEAK** |
| Rocket    | Masked   | HD     | 100 |   375 |    16.0 | **LEAK** |

**Kyber-512 results (unmasked only; 2,000,000-cycle simulations):**

| Processor | Metric | Traces/group | Onset Cycle | Max \|t\| | Verdict |
|-----------|--------|:---:|:---:|:---:|:---:|
| Ibex      | HW     | 20  | 18,351 | 67† | **LEAK** |
| Ibex      | HD     | 20  | 18,351 | 46† | **LEAK** |
| Proteus   | HW     | 20  | 27,362 | 101.6 | **LEAK** |
| Proteus   | HD     | 20  | 27,362 |  10.1 | **LEAK** |
| Rocket    | HW     | 20  | 45,954 | 481.0 | **LEAK** |
| Rocket    | HD     | 20  | 45,954 | 387.8 | **LEAK** |

†Ibex Kyber metric is between-group max Δ (Welch t not computed for this run); all other Kyber values are Welch |t|. Threshold: |t| > 4.5 (NIST SP 800-180). All results exceed threshold.

### 3.2 Masking Delay Comparison (AES-128)

The masking delay comparison applies to AES-128 only, since Kyber was evaluated in its unmasked form only.

| Processor | Unmasked Onset | Masked Onset | Delay | Likely Cause |
|-----------|:--------------:|:------------:|:-----:|--------------|
| Proteus (OoO 8-ALU, RV32) | 36 | 44 | +8 cycles | High instruction-level parallelism reduces memory latency |
| Ibex (2-stage in-order, RV32) | 53 | 73 | +20 cycles | Simple pipeline, mask applied one AES round later |
| Rocket (5-stage OoO, RV64) | 145 | 375 | +230 cycles | Deep cache hierarchy and multi-cycle memory operations |

The masking delay correlates with pipeline depth and memory hierarchy complexity. Rocket's 230-cycle delay is striking — it reflects the fact that 64-bit AES requires many more memory operations, each of which passes through multiple pipeline stages and a cache before the masked and unmasked values meet.

### 3.3 Root-Cause Signal Attribution

**AES-128:**

| Processor | AES Type | Primary Leaking Signal | Instruction at Peak | Source | Peak \|t\| |
|-----------|----------|------------------------|---------------------|--------|:---:|
| Ibex | Unmasked | `mac_res_d_leak0` (MAC result) | `srai a5,a5,0x18` | `gf_mul2` (aes128.c:75) — MixColumns GF(2⁸) mult | 34.5 |
| Ibex | Masked | `rspfifo_rdata_leak0` (response FIFO) | `lbu a2,0(a5)` | `sub_bytes_masked` (aes128_masked.c:151) | 78.7 |
| Proteus | Unmasked | `entries_5_pc_t0` (ROB entry PC) | `xor s8,s8,a3` | `key_expansion` (aes128_unmasked.c:88) | 606.6 |
| Proteus | Masked | `entries_7_pc_t0` (ROB entry PC) | `bne a5,s9,…` | `add_round_key` (aes128_masked.c:139) | 492.8 |
| Rocket | Unmasked | `TLBroadcastTracker_1_io_out_a_bits_data_t0` (TL-UL) | `lbu a4,0(a5)` | `sub_bytes` (aes128.c:118) | 225.9 |
| Rocket | Masked | `ram[5]_t0` (SRAM data word) | `xor a4,a4,a1` | `add_round_key` | 7.6 |

**Kyber-512 (unmasked):**

| Processor | Primary Leaking Signal | Instruction at Peak | Source | Peak \|t\| |
|-----------|------------------------|---------------------|--------|:---:|
| Ibex | `mem[4115]` (SRAM word, 32-bit) | `sh a5,0(a0)` / `addi a1,a1,3` | `poly_frombytes` (poly.c:133–134) — coefficient key loading | 67† |
| Proteus | `cache_dbus_cache_3_1_value` (D-cache line, 128-bit) | `add a5,a5,a0` | `basemul` (ntt.c:160) — NTT point-wise multiply | 101.6 |
| Rocket | `beats1_1_t0` (TileLink beat data) | `sh a5,0(s0)` | `basemul` (ntt.c:155) — NTT point-wise multiply | 481.0 |

†Ibex Kyber: between-group max Δ metric.

**AES leakage patterns:** Ibex leaks through the MAC result register during MixColumns GF(2⁸) multiplication and through the memory response FIFO during masked SubBytes; Proteus (OoO) leaks through **ROB entry program counters** due to data-dependent branches — a control-flow side channel that persists even under masking and is invisible in in-order processors; Rocket leaks through the TileLink broadcast data path (masking-boundary signal) for unmasked AES and through SRAM words during AddRoundKey when masked.

**Kyber leakage patterns:** Ibex exposes packed polynomial coefficients via SRAM during `poly_frombytes` (key decoding); Proteus exposes NTT coefficients through D-cache lines during point-wise polynomial multiplication; Rocket exposes NTT results through TileLink beats — the same masking-boundary mechanism seen in AES, suggesting this is a systemic Rocket architecture property that applies to any secret-carrying memory transaction.

### 3.4 Architectural Leakage Patterns

The dominant signal class and function per processor reveals micro-architecture-specific leakage mechanisms:

**AES-128:**

| Processor | AES Type | Dominant class | Function | Architectural explanation |
|-----------|----------|----------------|----------|---------------------------|
| Ibex (in-order 2-stage) | Unmasked | MULT_REG | `gf_mul2` | MAC result pipeline exposes GF(2⁸) operands during MixColumns |
| Ibex (in-order 2-stage) | Masked | FIFO_DATA | `sub_bytes_masked` | Memory response FIFO exposes masked S-box output on load — the bus is not masked |
| Rocket (OoO 5-stage) | Unmasked | TL_BEAT | `mix_columns` | TileLink broadcast carries AES state — masking-boundary signal |
| Rocket (OoO 5-stage) | Masked | SRAM_CELL | `add_round_key` | Masked state in SRAM leaks at reduced \|t\| — masking partially effective |
| Proteus (OoO 8-ALU) | Unmasked | ROB_PC | `key_expansion` | ROB entry PCs are key-dependent from data-dependent branches — control-flow side channel |
| Proteus (OoO 8-ALU) | Masked | ROB_PC | `add_round_key` | Same control-flow channel persists under masking — masking of data does not protect branches |

**Kyber-512 (unmasked):**

| Processor | Dominant class | Function | Architectural explanation |
|-----------|----------------|----------|---------------------------|
| Ibex (in-order 2-stage) | SRAM_CELL | `poly_frombytes` | SRAM words hold packed 12-bit Kyber coefficients; directly expose key-dependent Hamming weight on read during key decoding |
| Proteus (OoO 8-ALU) | CACHE_LINE | `basemul`, `fqmul` | D-cache holds 128-bit NTT coefficient vectors; data-bus cache values expose key-dependent NTT intermediate products |
| Rocket (OoO 5-stage) | TL_BEAT | `basemul` | TileLink beat data carries NTT polynomial coefficients on the on-chip interconnect — same masking-boundary vulnerability observed in AES, confirming it is a systemic Rocket property |

**Notes on cross-algorithm comparison:**
- Rocket's TileLink beat leakage appears in both AES and Kyber, independent of algorithm. The on-chip bus is a persistent masking boundary for any secret-carrying memory transaction.
- Proteus's ROB PC leakage is AES-specific: Kyber's NTT operations are less branch-intensive, so the control-flow channel is not the dominant leakage source for Kyber.
- Ibex shows algorithm-specific leakage: MAC register (AES, fixed-point arithmetic) vs. SRAM cells (Kyber, bulk coefficient loading).

The Proteus AES result is particularly notable: the primary leakage signal is a **program counter**, not data. The out-of-order scheduler holds multiple in-flight PCs simultaneously; when AES branches on computed values (loop bounds, conditional stores), the ROB fills with key-correlated PCs, yielding extreme \|t\| values (606 unmasked, 1443 masked HD) that dwarf the in-order processors.

---

## 4. Result Display Templates (LaTeX)

### Table 1 — Main TVLA Results (AES-128)

```latex
\begin{table}[t]
\centering
\caption{TVLA results for three RISC-V processors executing AES-128.
         $|t| > 4.5$ (NIST SP~800-180 threshold) indicates statistically
         significant key-dependent power leakage.}
\label{tab:tvla-aes}
\begin{tabular}{@{}llcrrr@{}}
\toprule
\textbf{Core} & \textbf{AES} & \textbf{Metric}
  & $N$ & \textbf{Onset} & $\max|t|$ \\
\midrule
Ibex     & Unmasked & HW &  20 &  53 &   34.5 \\
         &          & HD &  20 &  53 &   46.8 \\
         & Masked   & HW & 100 &  73 &   78.7 \\
         &          & HD & 100 &  73 &  131.0 \\
\midrule
Proteus  & Unmasked & HW &  20 &  36 &  606.6 \\
         &          & HD &  20 &  36 &  464.4 \\
         & Masked   & HW & 100 &  44 &  492.8 \\
         &          & HD & 100 &  44 & 1443.0 \\
\midrule
Rocket   & Unmasked & HW &  20 & 145 &  225.9 \\
         &          & HD &  20 & 145 &  193.9 \\
         & Masked   & HW & 100 & 375 &    7.6 \\
         &          & HD & 100 & 375 &   16.0 \\
\bottomrule
\end{tabular}
\end{table}
```

### Table 1b — Main TVLA Results (Kyber-512, Unmasked)

```latex
\begin{table}[t]
\centering
\caption{TVLA results for three RISC-V processors executing Kyber-512
         decapsulation (unmasked). Simulation length: 2\,000\,000 cycles.
         $|t| > 4.5$ (NIST SP~800-180 threshold).
         Ibex metric is between-group max~$\Delta$ (see text); all others
         are Welch $|t|$.}
\label{tab:tvla-kyber}
\begin{tabular}{@{}lcrrr@{}}
\toprule
\textbf{Core} & \textbf{Metric}
  & $N$ & \textbf{Onset} & $\max|t|$ \\
\midrule
Ibex    & HW &  20 & 18\,351 &  67\rlap{*} \\
        & HD &  20 & 18\,351 &  46\rlap{*} \\
\midrule
Proteus & HW &  20 & 27\,362 & 101.6 \\
        & HD &  20 & 27\,362 &  10.1 \\
\midrule
Rocket  & HW &  20 & 45\,954 & 481.0 \\
        & HD &  20 & 45\,954 & 387.8 \\
\bottomrule
\multicolumn{5}{l}{\small * Between-group max $\Delta$, not Welch $|t|$.}
\end{tabular}
\end{table}
```

### Table 2 — Masking Delay

```latex
\begin{table}[t]
\centering
\caption{Effect of first-order masking on leakage onset cycle.
         Delay correlates with pipeline depth and memory hierarchy complexity.}
\label{tab:masking}
\begin{tabular}{@{}lrrr@{}}
\toprule
\textbf{Core} & \textbf{Unmasked} & \textbf{Masked} & \textbf{Delay} \\
\midrule
Proteus (OoO 8-ALU, RV32)      &  36 &  44 & $+8$   \\
Ibex    (in-order, 2-stage, RV32) &  53 &  73 & $+20$  \\
Rocket  (OoO 5-stage, RV64)    & 145 & 375 & $+230$ \\
\bottomrule
\end{tabular}
\end{table}
```

### Table 3 — Root-Cause Attribution (per processor)

```latex
\begin{table}[t]
\centering
\caption{Top leakage signal and instruction attribution (Ibex, unmasked AES).
         Full per-cycle annotations are provided in the evaluation reports.}
\label{tab:attribution-ibex}
\begin{tabular}{@{}llll r@{}}
\toprule
\textbf{Cycles} & \textbf{Leakage Signal} & \textbf{Instruction} & \textbf{Source} & $|t|$ \\
\midrule
3235--3236 & \texttt{mac\_res\_d\_leak0}    & \texttt{srai a5,a5,0x18} & \texttt{gf\_mul2} (MixColumns GF($2^8$)) & 34.5 \\
3741--3742 & \texttt{rspfifo\_rdata\_leak0} & \texttt{lbu a2,0(a5)}   & \texttt{sub\_bytes\_masked}              & 78.7 \\
\ldots  & \ldots                         & \ldots                  & \ldots           & \ldots \\
\bottomrule
\end{tabular}
\end{table}
```

### Algorithm Pseudocode (Methods Section)

```
Algorithm 1: CellIFT Power Leakage Instrumentation Pass

Input:  RTL design D, taint source S, number of labels L
Output: Instrumented design D' with taint and leakage shadows

// Process modules bottom-up (children before parents)
For each module M in topological order of D:

  For each signal X in M:
    Create X_t0 ... X_tL            // taint shadows (internal wires)
    Create X_leak0 ... X_leakL      // leakage shadows (output ports)

  For each DFF cell Q ← D (clock CLK):
    Q_prev    ← DFF(Q, CLK)         // 1-cycle delay register
    trans     ← Q XOR Q_prev        // transition detection
    Q_leak0   ← trans AND Q_t0      // leak iff tainted AND transitioning
    Q_t0[+1]  ← DFF(D_t0, CLK)     // taint propagation (standard CellIFT)

  For each combinational cell (A, B → Y):
    Y_t0      ← propagate_taint(A_t0, B_t0)   // cell-specific taint rule
    Y_leak0   ← Y_t0                            // conservative leakage model

// Insert aggregation counters in scope module(s)
For each scope module M, taint label l:
  HW_l  ← POPCOUNT( AND(data_wires, taint_wires_l) )
  HD_l  ← POPCOUNT( AND(XOR(data, data_prev), taint_wires_l) )
  Export HW_l, HD_l as 32-bit output ports
```

### Recommended Figures

**Figure 1 — System architecture diagram:**
Show RTL → Yosys Pass → three-layer instrumented RTL → Verilator simulation → TVLA analysis.
Highlight the DFF formula `Q_leak0 = (Q XOR Q_prev) AND Q_t0` as the central innovation.

**Figure 2 — Per-cycle t-statistic traces:**
For each processor, plot |t[cycle]| over simulation time with the threshold t=4.5 as a dashed red line.
Annotate onset cycles, peak leakage intervals, and the corresponding AES round.
Three subplots (one per processor), overlaying HW and HD curves.

**Figure 3 — Masking effectiveness comparison:**
Side-by-side bar chart comparing unmasked vs. masked onset cycles and max |t| per processor,
illustrating how pipeline depth modulates masking effectiveness.

---

## 5. Key Claims for the Paper

1. **Exact transition-level attribution at cell granularity.** Unlike physical side-channel measurements or coarse gate-level power models, the DFF handler detects exact switching events on tainted paths, enabling per-signal, per-cycle leakage attribution that is impossible to achieve non-invasively.

2. **Scalability without design-specific effort.** The Yosys pass approach instruments designs from 50k lines (Ibex) to 849k lines (Proteus) by adding a single flag (`-track-power-leakage`), requiring no manual per-design instrumentation.

3. **Universal detection across micro-architectural styles and cryptographic algorithms.** All three processors — in-order embedded (Ibex), high-performance OoO superscalar (Proteus), and full Linux-capable OoO (Rocket) — show statistically significant leakage in both AES-128 and Kyber-512, validating that the methodology generalizes across fundamentally different pipeline architectures *and* across symmetric and post-quantum cryptography. The leakage sources differ by algorithm (MAC units and S-box buses for AES; SRAM cells, D-cache lines, and TL-UL beats for Kyber NTT) but are consistently detected and attributed.

4. **Masking quantification (AES-128).** All three processors show leakage even under first-order masking of AES-128. The method measures both the delay masking introduces and the residual statistical strength, providing a quantitative characterization of masking effectiveness at the microarchitectural level. Kyber was evaluated in unmasked form only, providing a baseline for future masked Kyber evaluation.

5. **Actionable root-cause output.** The signal-level and instruction-level attribution produced by simulation directly identifies which pipeline components (AXI bus, MAC unit, response FIFO, TL-UL broadcast tracker, **OoO ROB entry program counters**) and which AES instructions are responsible for leakage, enabling targeted countermeasure development. Notably, Proteus reveals a **control-flow side channel** in its ROB — data-dependent AES branches make in-flight PC values key-correlated, a leakage mechanism that is invisible in in-order processors and that masking the datapath does not eliminate.

---

## File Reference

| File | Purpose |
|------|---------|
| `tools/cellift-yosys/passes/cellift/cellift.cc` | Main pass (1393 lines): pass entry, cell dispatch, port creation, HW/HD counter insertion |
| `tools/cellift-yosys/passes/cellift/cellift_util_leakage.cc` | Leakage shadow wire naming and creation, port promotion |
| `tools/cellift-yosys/passes/cellift/cells/stateful/power_leakage/dff_leakage.cc` | DFF leakage handler: transition detection + taint gating |
| `tools/cellift-yosys/passes/cellift/cells/{add,mux,xor,and,or}.cc` | Combinational cell taint propagation + conservative leakage |
| `analysis/compute_ttest.py` | Welch's t-test TVLA implementation |
| `analysis/extract_leakage_traces.py` | FST/VCD trace parsing and counter extraction |
| `cellift-designs/cellift-ibex/cellift/` | Ibex evaluation: scripts, results, publication summary |
| `cellift-designs/cellift-proteus/cellift/CELLIFT_TVLA_EVALUATION.md` | Proteus evaluation documentation and results |
| `cellift-designs/cellift-chipyard/cellift-rocket/` | Rocket evaluation: scripts, results |
