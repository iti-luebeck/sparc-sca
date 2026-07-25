# SPARC-SCA: Power Side-Channel Leakage Analysis via Cell-Level Information Flow Tracking

SPARC-SCA is a framework that detects key-dependent power side-channel leakage in RTL processors by combining taint tracking with signal-switching analysis.

Evaluated on three RISC-V processors (Ibex, Proteus, Rocket) running AES-128 and CRYSTALS-Kyber-512. All configurations exceed the NIST TVLA leakage threshold.

## Paper

SPARC-SCA is the artifact accompanying our paper, accepted at **ICCAD 2026**:

> Andrija Nešković, Christian Ewert, Mladen Berekovic, and Saleh Mulhem.
> **SPARC: Automated Root-Cause Analysis of Pre-Silicon Power Side-Channel Leakage in the Processor Design Flow.**
> In *IEEE/ACM International Conference on Computer-Aided Design (ICCAD '26)*, November 8–12, 2026, San Jose, CA, USA.

The official proceeding is not yet live; a pre-print link will be provided here shortly. However, we were given a DOI and metadata:

```bibtex
@inproceedings{neskovic2026sparc,
  author    = {Ne\v{s}kovi\'{c}, Andrija and Ewert, Christian and Berekovic, Mladen and Mulhem, Saleh},
  title     = {SPARC: Automated Root-Cause Analysis of Pre-Silicon Power Side-Channel Leakage in the Processor Design Flow},
  booktitle = {IEEE/ACM International Conference on Computer-Aided Design (ICCAD '26)},
  year      = {2026},
  address   = {San Jose, CA, USA},
  publisher = {Association for Computing Machinery},
  isbn      = {979-8-4007-2873-0},
  doi       = {10.1145/3831252.3834007},
}
```

## Repository Structure

```
sparc-sca/
├── tools/
│   ├── sparc-sca-yosys/       Yosys fork with CellIFT + leakage shadow extension
│   ├── verilator/             Verilator with FST integer-overflow fix
│   ├── sv2v/                  SystemVerilog-to-Verilog converter
│   ├── riscv-gnu-toolchain/   RISC-V bare-metal cross-compiler (RV32/RV64) [local builds only]
│   ├── riscv-isa-sim/         Spike ISA reference simulator
│   ├── morty/                 SystemVerilog hierarchy flattener
│   └── bender/                RTL dependency manager
├── designs/
│   ├── ibex/                  Ibex (OpenTitan, RV32, in-order) + evaluation infrastructure
│   ├── proteus/               Proteus (OoO 8-ALU, RV32) + evaluation infrastructure
│   └── chipyard/              Chipyard with Rocket (RV64, OoO) + evaluation infrastructure
├── design-processing/         Yosys Tcl instrumentation flow and HDL helper scripts
│   ├── common/yosys/          instrument.ys.tcl — main CellIFT + leakage Yosys pass
│   └── common/python_scripts/ RTL transformation utilities (morty post-processing)
├── analysis/                  Python TVLA analysis tools (t-test, FST/VCD trace extraction)
├── simulation/                SystemVerilog simulation wrappers
├── benchmarks/                RISC-V benchmark suite (ISA tests, dhrystone, matmul, AES, Kyber)
├── python-experiments/        Standalone power leakage analysis Python stack
├── env.sh                     Environment setup (tool paths, RISCV, PREFIX_CELLIFT)
├── Makefile                   Top-level: docker-build, installtools, generate-rtl, clean-designs
├── Dockerfile                 Two-stage reproducible build (Ubuntu 22.04, ~2 hr with toolchain)
└── run_full_audit.sh          Batch evaluation: all three processors × AES + Kyber
```

Each processor's `cellift/` directory is self-contained and follows an identical layout:

```
designs/<cpu>/cellift/
├── src/                       SystemVerilog SoC wrappers (vanilla + taints)
├── dv/                        Verilator C++ testbench (CSV logger + VCD trace)
├── sw/                        RISC-V firmware scenarios and matched-pair sets
├── taint_data/                Taint configuration (byte offset + length per secret)
├── generated/out/cellift.sv   Yosys-instrumented RTL (produced by design-processing)
├── build/                     Compiled Verilator simulators
├── results/                   Evaluation artifacts (CSV traces, JSON, PNG plots)
├── *.core                     FuseSoC simulation targets
└── run_full_evaluation.sh     10-step evaluation orchestrator
```

## Getting Started

### Option A — Docker (recommended)

**Fastest — pull the prebuilt image** (all tools + RISC-V toolchain already compiled):

```bash
# Get the repository (no --recurse-submodules — the prebuilt image already
# ships every tool, so only the design sources need to be checked out below)
git clone https://github.com/iti-luebeck/sparc-sca.git
cd sparc-sca

# Initialise design submodules only (ibex, proteus, chipyard, cellift-opentitan).
# Tool submodules (yosys, verilator, riscv-gnu-toolchain, ...) aren't needed —
# they're already compiled into the prebuilt image.
make checkout-designs

# Pull the prebuilt image (~13 GB) and start an interactive session with the
# repository mounted. The image already has env vars baked in — no need to
# source env.sh inside the container.
make docker-pull
make docker-run
# Inside the container:
make generate-rtl          # Generate Proteus + Rocket Verilog (~10 min, once)
make build-sims            # Compile Verilator simulators for all three designs
```

**Or build the image yourself** (~2 hr — all tools compiled from source):

```bash
# Initialise design and tool submodules (except riscv-gnu-toolchain, cloned inside Docker)
make checkout-tools
make checkout-designs

# Build the image — all tools compiled from source inside the container (~2 hr)
# The RISC-V GNU toolchain is cloned and compiled during docker build; no host checkout needed.
make docker-build

# Start an interactive session with the repository mounted
make docker-run
# Inside the container (env vars are already baked into the image):
make generate-rtl          # Generate Proteus + Rocket Verilog (~10 min, once)
make build-sims            # Compile Verilator simulators for all three designs
```

### Option B — Native install

```bash
source env.sh
make checkout-tools    # Initialises all tool submodules including riscv-gnu-toolchain
make checkout-designs  # Initialises ibex, proteus, chipyard
make installtools      # Builds all tools into $PREFIX_CELLIFT (~1.5 hr)
make generate-rtl      # Generates Proteus + Rocket Verilog (~10 min, once)
make build-sims        # Compiles Verilator simulators for all three designs
```

Customise `PREFIX_CELLIFT`, `CELLIFT_JOBS`, and `RISCV` in `env.sh` before running. The file includes a per-user override section at the bottom.

### End-to-end smoke test

```bash
cd designs/proteus/cellift
./run_full_evaluation.sh --n-unmasked 2 --n-masked 2 --simlen 3000 --plot
```

This exercises all 10 pipeline steps with minimal data (~5 min). Check `results/unmasked/welch_summary.txt` for a `first_leaky_cycle` value to confirm end-to-end correctness.

## Running an Evaluation

Each design's `cellift/` directory contains the complete evaluation infrastructure. The four core commands are:

```bash
cd designs/proteus/cellift   # or ibex, chipyard/cellift-rocket

# 1. Build the instrumented Verilator simulator
fusesoc --cores-root=. run --build run_cellift_csvlog

# 2. Compile a matched-pair scenario (e.g. one of the 200 AES trace pairs)
make -C sw/multi_aes_unmasked_a_000

# 3. Run TVLA across all traces (produces per-cycle leakage CSV files)
./run_multi_trace_tvla.sh

# 4. Analyse results and generate publication summary
python3 cycle_leakage_quantifier.py
python3 generate_publication_summary.py
```

Or run the full 10-step pipeline in one command:

```bash
./run_full_evaluation.sh [options]
```

**Key options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--workload NAME` | `aes` | Workload profile (`aes`, `kyber`) |
| `--n-unmasked N` | `20` | Traces per group for unmasked run |
| `--n-masked N` | `100` | Traces per group for masked run |
| `--simlen N` | `30000` | Simulation cycles per trace |
| `--jobs N` | CPU count | Parallel simulation workers |
| `--threshold T` | `4.5` | Welch \|t\| detection threshold |
| `--plot` | off | Enable annotated interval plots |
| `--skip-gen` | — | Skip scenario generation |
| `--skip-compile` | — | Skip firmware compilation |

Per-design detailed references: [`designs/ibex/cellift/IBEX_TVLA_EVALUATION.md`](designs/ibex/cellift/IBEX_TVLA_EVALUATION.md), [`designs/proteus/cellift/CELLIFT_TVLA_EVALUATION.md`](designs/proteus/cellift/CELLIFT_TVLA_EVALUATION.md).

## Evaluation Pipeline

`run_full_evaluation.sh` executes these 10 steps in order:

| Step | Script | Input → Output |
|------|--------|----------------|
| 1. Preflight | `run_eval_preflight.sh` | Validates simulator binary, scenario dirs, Python deps |
| 2. Scenario generation | `gen_scenarios.py` | Templates → `sw/multi_aes_{u,m}_{a,b}_NNN/` directories |
| 3. Firmware compilation | `compile_scenarios.sh` | Scenario dirs → `build/app.elf` per scenario |
| 4. Parallel simulation | `run_multi_trace_tvla.sh` | ELF + taint → `results/{unmasked,masked}/group_{a,b}_NNN.csv` |
| 5. TVLA analysis | `multi_tvla_driver.py` | All group CSVs → `welch_summary.txt`, `leakage_regions.json` |
| 6. Root-cause signals (unmasked) | `run_signal_correlation.sh` → `leakage_signals.py` | CellIFT VCDs → `signals_refined_signals.json` |
| 7. Root-cause signals (masked) | same | same for masked group |
| 8. Quantification + plots | `cycle_leakage_quantifier.py` | Welch summary → annotated `leakage_*_interval_*_annotated.png` |
| 9. Run manifest | — | All artifacts → `run_manifest_refined.json` |
| 10. Report | `generate_root_cause_report.py` + `generate_publication_summary.py` | Consolidated → `root_cause_report_refined.{md,json}`, `publication_summary_refined.{md,json}` |

**CSV format** (per-cycle, one row per simulation tick):
```
cycle,leakage_counter_t0,hamming_weight_counter_t0,hamming_distance_counter_t0
```

**TVLA matched-pair protocol**: Groups `a` and `b` differ only in the secret key; all other inputs (plaintext, timing) are identical. Welch's t-test flags cycles where `|t| > 4.5` as key-dependent leakage (NIST SP 800-180).

## Integrating a New CPU

The three existing integrations (Ibex, Proteus, Rocket) follow a common 10-step pattern. Use **Ibex** (`designs/ibex/cellift/`) as the template for simpler in-order or TL-UL bus designs, and **Proteus** (`designs/proteus/cellift/`) for OoO or wide-bus (AXI 128-bit) designs.

**Per-CPU decision table** (fill this in before starting):

| Decision | Ibex | Proteus | Your CPU |
|----------|------|---------|----------|
| ISA | RV32IMC | RV32IM | ? |
| Pipeline | 2-stage in-order | 8-ALU dynamic OoO | ? |
| Bus interface | TL-UL (32-bit) | AXI4 (128-bit) | ? |
| Clock/reset signals | `clk_i` / `rst_ni` | `clk_i` / `rst_ni` (wrapped) | ? |
| HDL source language | SystemVerilog | SpinalHDL → Verilog | ? |
| Boot address | `0x00100000` | `0x80000000` | ? |
| `DECOMPOSE_MEMORY` | 0 | 1 (write-back cache) | ? |
| Fetch PC signal path | `u_ibex_core.pc_id_o` | `Core.PcManager_0.pc` | ? |

---

### Step 1 — Prepare the RTL

Get the processor RTL into a single flattened Verilog file:

- **SystemVerilog**: Run `morty` to flatten the hierarchy, then `sv2v` to convert to Verilog:
  ```bash
  morty -o flat.sv -I include/ top.sv
  sv2v flat.sv -w flat.v
  ```
- **Chisel**: Generate Verilog via `sbt "runMain <MainClass> --target-dir generated"`
- **SpinalHDL**: Call `SpinalVerilog(new MyCpu(...))` to emit `MyCpu.v`
- **VHDL**: Not supported natively; use an external tool to convert to Verilog first

Place the result at `designs/<cpu>/Core.v` (or similar; the path is referenced in `Bender.yml`).

---

### Step 2 — Instrument the RTL with CellIFT + leakage extension

```bash
source env.sh

export VERILOG_INPUT=designs/<cpu>/Core.v
export VERILOG_OUTPUT=designs/<cpu>/cellift/generated/out/cellift.sv
export TOP_MODULE=MyCpu
export INSTRUMENTATION=cellift
export DECOMPOSE_MEMORY=0    # set to 1 for designs with write-back caches

mkdir -p designs/<cpu>/cellift/generated/out
yosys -c $CELLIFT_YS/instrument.ys.tcl
```

The output `cellift.sv` size scales with design complexity: ~50k lines for Ibex, ~849k for Proteus. If `yosys` runs out of memory, try `DECOMPOSE_MEMORY=1` or `MUL_TO_ADDS=1`.

---

### Step 3 — Create the `cellift/` directory skeleton

```
designs/<cpu>/cellift/
├── src/
│   ├── <cpu>_tiny_soc.sv          # Vanilla wrapper (clock, reset, CPU + SRAM)
│   └── <cpu>_tiny_soc_taints.sv   # CellIFT wrapper (_t0 ports + ift_sram_mem)
├── dv/
│   ├── testbench.h                # Clock/reset driver (copy verbatim from ibex)
│   ├── toplevel.cc                # Standard driver (prints final counter values)
│   └── toplevel_csv.cc            # CSV logger (per-cycle leakage counters)
├── sw/                            # Firmware scenarios (Step 6)
├── taint_data/                    # Taint configuration (Step 7)
├── Bender.yml                     # RTL dependency manifest
├── fusesoc.conf
├── run_cellift_csvlog.core
├── run_cellift_fasttrace.core
└── run_vanilla_trace.core
```

Copy the `Bender.yml` and `fusesoc.conf` from `designs/ibex/cellift/` as a starting point.

---

### Step 4 — Write the SystemVerilog SoC wrappers

Two wrappers are needed. Key points:

**Vanilla wrapper** (`<cpu>_tiny_soc.sv`):
- Instantiate the CPU top module and a plain SRAM
- Wire clock (`clk_i` or `clock`), active-low or active-high reset
- Expose `leakage_counter_t0`, `hamming_weight_counter_t0`, `hamming_distance_counter_t0` as 32-bit outputs (they will be zero in vanilla mode, but the ports must exist so the same testbench compiles for both modes)
- Set boot address to SRAM base in the CPU parameter or tie the reset vector

**CellIFT (taints) wrapper** (`<cpu>_tiny_soc_taints.sv`):
- Replace the plain SRAM with `ift_sram_mem` (from `simulation/wrappers/`) — choose the width that matches your bus
- Propagate `_t0` shadow ports for all CPU inputs/outputs (CellIFT mirrors port direction)
- The three leakage counter outputs must be driven by the instrumented design's internal counter signals

**Bus width decisions**:
- 32-bit AXI or TL-UL → use `ift_sram_mem` as-is
- 64-bit AXI (Rocket) → use the 64-bit variant
- 128-bit AXI (Proteus) → adapt `ift_sram_mem` for 128-bit data width

---

### Step 5 — Write the C++ testbench

Copy `dv/toplevel_csv.cc` from `designs/ibex/cellift/dv/` and make these substitutions:

1. Verilator model class name: `Vibex_tiny_soc` → `V<cpu>_tiny_soc`
2. ELF loading: Ibex uses two ELF variables (`SIMROMELF` + `SIMSRAMELF`); Proteus and Rocket use only `SIMSRAMELF`. Match the memory map of your design.
3. Counter signal paths: confirm `top->leakage_counter_t0`, `->hamming_weight_counter_t0`, `->hamming_distance_counter_t0` match the hierarchy in your wrapper.
4. Copy `testbench.h` verbatim (the clock/reset driver is design-agnostic).

---

### Step 6 — Write the FuseSoC `.core` files

Three cores are required. Copy from `designs/proteus/cellift/` and substitute:
- All occurrences of `proteus_tiny_soc` → `<cpu>_tiny_soc`
- `Core.v` path → your RTL source path
- Verilator top module name

**Compiler flags** (important for performance):
- `run_cellift_fasttrace.core`: `-O2`, no `-g`, `--trace` (produces a 10–20 MB binary, ~75k cycles/min)
- `run_cellift_csvlog.core`: same flags as fasttrace, but links `toplevel_csv.cc`
- `run_vanilla_trace.core`: same flags, omits the instrumented RTL file

---

### Step 7 — Create firmware scenarios

Each scenario is a directory under `sw/` with:

```
sw/scenario_aes128_key1/
├── aes128_unmasked.c    # AES implementation
├── main.S               # Entry point, key loading, AES call
├── link.ld              # Linker script — place key at a fixed, known offset
├── Makefile             # Uses $(CELLIFT_GCC)
└── build/app.elf        # Compiled output
```

**Makefile flags for RV32**:
```makefile
CFLAGS = -march=rv32im -mabi=ilp32 -O2 -mcmodel=medany
```

**Makefile flags for RV64**:
```makefile
CFLAGS = -march=rv64imac -mabi=lp64 -O2 -mcmodel=medany
```

Minimum scenario set: `scenario_aes128_key1/` and `scenario_aes128_key2/` (different keys, same plaintext structure). Add `_masked_key1/` and `_masked_key2/` for the masked evaluation.

Find the taint offset after compilation:
```bash
nm build/app.elf | grep aes_key
# Subtract SRAM base (e.g. 0x80000000) to get the byte offset
```

---

### Step 8 — Configure taint data

Create `taint_data/<scenario>/taint_data.txt`. Format — one line per tainted region, no comments:

```
<taint_id> <offset_hex> <length_bytes_hex> <taint_mask_hex>
```

Example for 16-byte AES key at offset `0x900`:
```
0 900 10 FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
```

For first-order Boolean masking (key XOR mask), add a second line for the mask share:
```
0 900 10 FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
0 B00 10 FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
```

> **Note**: The parser treats `#` as the start of an address, not a comment. Do not add comment lines.

---

### Step 9 — Adapt `pc_at_leakage.py` for the new CPU

`pc_at_leakage.py` extracts the program counter from the vanilla VCD to map leakage cycles to instructions. It needs the VCD signal path for the fetch PC (and optionally retire PC):

```python
# Near the top of pc_at_leakage.py — update for your CPU:
FETCH_PC_SIGNAL = "toplevel_soc.<cpu_hierarchy>.pc_id_o"
RETIRE_PC_SIGNAL = "toplevel_soc.<cpu_hierarchy>.pc_wb_o"  # if available
```

Reference paths:
- Ibex: `toplevel_soc.u_ibex_top.u_ibex_core.pc_id_o`
- Proteus: `toplevel_soc.Core.PcManager_0.pc`

**Timing formula** (CSV cycle N → VCD posedge time): `VCD_time = 5 × (7 + N)`. This assumes 6 pre-loop reset ticks and a 10-unit clock period (posedge at 5, 15, 25, …). Verify against your testbench if you change `kResetLength` in `testbench.h`.

---

### Step 10 — Copy and adapt the evaluation scripts

Copy all shell and Python scripts from `designs/ibex/cellift/` or `designs/proteus/cellift/`. Scripts that require CPU-specific edits:

| Script | What to change |
|--------|----------------|
| `build_csvlog_sim.sh` | Simulator binary name (`Vibex_tiny_soc` → `V<cpu>_tiny_soc`) |
| `run_cellift_sim.sh` | Binary path; ELF environment variable names |
| `run_vanilla_sim.sh` | Same as above |
| `run_full_evaluation.sh` | Simulator binary path |

Scripts that can be copied verbatim (they operate only on CSVs and JSON files):
- `multi_tvla_driver.py`, `tvla_analysis.py`
- `cycle_leakage_quantifier.py`, `generate_root_cause_report.py`, `generate_publication_summary.py`
- `gen_scenarios.py`, `compile_scenarios.sh`, `run_multi_trace_tvla.sh`

---

### Step 11 — Register and verify

1. Add to `design-processing/design_repos.json`:
   ```json
   "mycpu": "../../designs/mycpu/cellift"
   ```

2. Add the design as a git submodule if it lives in a separate repository:
   ```bash
   git submodule add <url> designs/mycpu
   ```

3. Run the smoke test:
   ```bash
   cd designs/mycpu/cellift
   ./run_full_evaluation.sh --n-unmasked 2 --n-masked 2 --simlen 3000 --plot
   ```

4. Confirm success: `results/unmasked/welch_summary.txt` must exist and contain a `first_leaky_cycle` entry. If the value is `null`, no leakage was detected at this sample count — increase `--n-unmasked` or `--simlen`.

---

### Common integration bugs

The following issues arose during the Proteus and Rocket integrations and are worth checking proactively:

| # | Symptom | Fix |
|---|---------|-----|
| 1 | Yosys syntax error in generated Verilog | Bit-replicate syntax: `{8{x}, 8{y}}` → `{{8{x}}, {8{y}}}` |
| 2 | `_t0` port direction errors from CellIFT | CellIFT mirrors original port direction — fix direction in wrapper, not in generated RTL |
| 3 | SRAM writes not executing | Set `req_i` for both reads and writes, not only reads |
| 4 | AXI `rdata` always zero | Connect `rdata_o` to the AXI response bus (can be left unconnected in plain-memory models) |
| 5 | Stack overlapping tainted key data | Reorder linker sections so key region is isolated; verify with `nm` |
| 6 | Taint file parse errors | Remove all `#`-prefixed lines; the parser interprets `#` as a hex address |
| 7 | CellIFT binary 200+ MB, 50 cycles/min | Missing `-O2` in FuseSoC `.core`; add `-O2 -CFLAGS "-O2"`, drop `-O0 -g` |
| 8 | Verilator `rootp->` signal errors | `--trace` must be present in all `.core` files; use `TRACEFILE=/dev/null` to suppress VCD output |
| 9 | `pc_at_leakage.py` reports wrong instruction | VCD timing offset wrong; re-check `kResetLength` in `testbench.h` and update the timing formula |

---

## How It Works

Standard CellIFT adds a taint shadow `X_t0` to every signal `X` and propagates taint according to the logical structure of each cell. SPARC-SCA adds a leakage shadow `X_leak0` that is asserted when a signal both carries taint and transitions state:

```
Q_leak0[i] = (Q[i] XOR Q_prev[i]) AND Q_t0[i]
```

This two-condition gate—implemented as a new Yosys pass built on top of CellIFT—captures the physical reality of CMOS dynamic power dissipation at register granularity. Aggregation counters compute the Hamming Weight and Hamming Distance of tainted switching activity each cycle, which are fed into Welch's t-test (TVLA per NIST SP 800-180) to produce a time-resolved leakage verdict.

## Instrumentation Architecture

The Yosys pass (`tools/sparc-sca-yosys/passes/cellift/`) adds three signal layers:

| Layer | Suffix | Semantics |
|-------|--------|-----------|
| Functional | _(none)_ | Original design signal |
| Taint | `_t0` | Influenced by secret input (standard CellIFT IFT) |
| Leakage | `_leak0` | Power leaks here: tainted AND transitioning |

**DFF handler** (`cells/stateful/power_leakage/dff_leakage.cc`): adds a one-cycle delay register, XOR-based transition detector, and AND gate with the taint shadow.

**Combinational cells** (`cells/{add,and,mux,or,xor}.cc`): use the conservative model `leak = taint`, which is sound (no false negatives) because combinational transitions occur within the same cycle as their tainted inputs.

**Aggregation counters**: `hamming_weight_counter_t0` (popcount of active tainted bits) and `hamming_distance_counter_t0` (popcount of tainted transitions) are inserted as 32-bit output ports at the designated scope module.

## Instrumentation Correctness Properties

| Property | Mechanism |
|----------|-----------|
| **Sound (no false negatives)** | Taint is over-approximate — all real information flows captured |
| **Conservative (may false positive)** | Combinational `leak = taint` does not verify transitions occur |
| **Compositional** | Bottom-up module processing preserves shadow hierarchy |
| **Non-intrusive** | All instrumentation is additive; original cells are unchanged |

## Results

Evaluated on three RISC-V processors executing AES-128 (unmasked and first-order Boolean masked) and CRYSTALS-Kyber-512 (unmasked). All configurations exceed the |t| > 4.5 leakage threshold.

**AES-128 — Welch t-test results (threshold |t| > 4.5):**

| Core | AES Type | Metric | N | Onset cycle | max\|t\| |
|------|----------|--------|---|-------------|---------|
| Ibex (in-order, 2-stage, RV32) | Unmasked | HW | 20 | 53 | 34.5 |
| | | HD | 20 | 53 | 46.8 |
| | Masked | HW | 100 | 73 | 78.7 |
| | | HD | 100 | 73 | 131.0 |
| Proteus (OoO 8-ALU, RV32) | Unmasked | HW | 20 | 36 | 606.6 |
| | | HD | 20 | 36 | 464.4 |
| | Masked | HW | 100 | 44 | 492.8 |
| | | HD | 100 | 44 | 1443.0 |
| Rocket (OoO 5-stage, RV64) | Unmasked | HW | 20 | 145 | 225.9 |
| | | HD | 20 | 145 | 193.9 |
| | Masked | HW | 100 | 375 | 7.6 |
| | | HD | 100 | 375 | 16.0 |

**Key findings:** Proteus leaks through ROB entry program counters (a control-flow side channel invisible in in-order processors that persists under data masking); Rocket leaks through TileLink broadcast data in both AES and Kyber, identifying the on-chip bus as a systemic masking boundary; Ibex leaks through the MAC result register (AES) and SRAM response FIFO (masked AES).

## Dependencies

All tools are git submodules and are built either via `make installtools` or inside the Docker image.

| Tool | Role |
|------|------|
| [sparc-sca-yosys](https://github.com/aneskovic/sparc-sca-yosys) | RTL instrumentation (CellIFT + leakage extension) |
| [Verilator](https://github.com/aneskovic/sparc-sca-verilator) | Cycle-accurate RTL simulation |
| [sv2v](https://github.com/zachjs/sv2v) | SystemVerilog to Verilog conversion |
| [riscv-gnu-toolchain](https://github.com/riscv/riscv-gnu-toolchain) | Cross-compiler for AES/Kyber firmware |
| [riscv-isa-sim](https://github.com/riscv-software-src/riscv-isa-sim) | RISC-V ISA reference simulator (Spike) |
| [morty](https://github.com/zarubaf/morty) | SV hierarchy flattening |
| [bender](https://github.com/pulp-platform/bender) | RTL dependency management |

## Acknowledgements

This work builds on [CellIFT](https://comsec.ethz.ch/research/microarch/cellift/) by Flavien Solt and Kaveh Razavi (ETH Zurich). The evaluated processor designs are [Ibex](https://github.com/lowRISC/ibex) (lowRISC / OpenTitan), [Proteus](https://github.com/proteus-core/proteus) (proteus-core), and [Rocket Chip](https://github.com/chipsalliance/rocket-chip) via [Chipyard](https://github.com/ucb-bar/chipyard) (UC Berkeley).

## License

The SPARC-SCA framework is licensed under **GPL-3.0-only**.
Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck.

The framework incorporates GPL-3.0-only code from the
[CellIFT project](https://github.com/comsec-group/cellift-meta)
(Copyright 2022 Flavien Solt, ETH Zurich).

The Yosys instrumentation pass (`tools/sparc-sca-yosys/passes/cellift/`)
is licensed under the **ISC License**, derived from the CellIFT Yosys pass
(Copyright 2020 Alberto Gonzalez & Flavien Solt).

The simulation wrapper (`simulation/wrappers/ibex_tiny_soc_with_leakage.sv`)
is licensed under **Apache-2.0** (Copyright lowRISC contributors).

The following original tooling — with no CellIFT lineage — is licensed
under **MIT** instead (see `LICENSE-MIT`):
`Makefile`, `Dockerfile`, `env.sh`, `run_full_audit.sh`, `resourcewrapper`,
and `analysis/tvla_analysis.py`, `compute_ttest.py`, `extract_vcd_leakage.py`,
`extract_leakage_traces.py`, `detect_computation_end.py`.

Tool and design submodules carry their own licenses (see each subdirectory).
