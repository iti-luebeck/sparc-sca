# SPARC-SCA: Power Side-Channel Leakage Analysis via Cell-Level Information Flow Tracking

SPARC-SCA is a hardware security analysis framework that detects **key-dependent power side-channel leakage** in RTL processor designs. It extends [CellIFT](https://comsec.ethz.ch/research/microarch/cellift/) with a third signal layer that tracks not only which signals are influenced by a secret key (taint), but which of those signals also switch state—the physical root cause of exploitable power leakage in CMOS.

## How It Works

Standard CellIFT adds a taint shadow `X_t0` to every signal `X` and propagates taint according to the logical structure of each cell. SPARC-SCA adds a leakage shadow `X_leak0` that is asserted when a signal both carries taint and transitions state:

```
Q_leak0[i] = (Q[i] XOR Q_prev[i]) AND Q_t0[i]
```

This two-condition gate—implemented as a new Yosys pass built on top of CellIFT—captures the physical reality of CMOS dynamic power dissipation at register granularity. Aggregation counters compute the Hamming Weight and Hamming Distance of tainted switching activity each cycle, which are fed into Welch's t-test (TVLA per NIST SP 800-180) to produce a time-resolved leakage verdict.

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

## Repository Structure

```
sparc-sca/
├── tools/
│   ├── sparc-sca-yosys/       Yosys fork with CellIFT + leakage extension
│   ├── verilator/             Verilator with FST overflow fix
│   ├── sv2v/                  SystemVerilog-to-Verilog converter
│   ├── riscv-gnu-toolchain/   RISC-V bare-metal cross-compiler
│   ├── riscv-isa-sim/         Spike ISA simulator
│   ├── morty/                 SystemVerilog pickler
│   └── bender/                RTL dependency manager
├── designs/
│   ├── ibex/                  Ibex (OpenTitan) + evaluation infrastructure
│   ├── proteus/               Proteus OoO core + evaluation infrastructure
│   └── chipyard/              Chipyard (Rocket/BOOM) + evaluation infrastructure
├── design-processing/         HDL instrumentation scripts and Yosys Tcl flows
├── analysis/                  Python TVLA analysis tools (t-test, trace extraction)
├── simulation/                SystemVerilog simulation wrappers
├── python-experiments/        Power leakage analysis Python stack
├── paper/                     Evaluation figures and results
├── benchmarks/                RISC-V benchmark suite
├── Dockerfile                 Reproducible build environment
└── test_docker_eval.sh        End-to-end evaluation smoke test
```

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

## Getting Started

### Option A — Docker (recommended)

```bash
# Build the image (~40 min, all tools compiled from source)
make docker-build

# Start an interactive session with the repo mounted
make docker-run
# Inside the container:
source env.sh
cd designs/proteus/cellift
fusesoc --cores-root=. run --build run_cellift_notrace
```

### Option B — Native install

```bash
source env.sh
make installtools   # builds all tools into $PREFIX_CELLIFT (~1.5 hr)
```

### Run the end-to-end smoke test

```bash
docker run --rm \
  -v $(pwd):/workspace \
  -v /path/to/cellift-proteus/cellift/generated:/workspace/designs/proteus/cellift/generated:ro \
  -v /path/to/cellift-proteus/cellift/sw:/workspace/designs/proteus/cellift/sw \
  -v /path/to/cellift-proteus/cellift/taint_data:/workspace/designs/proteus/cellift/taint_data:ro \
  sparc-sca:latest bash /workspace/test_docker_eval.sh
```

The test script exercises all 7 stages: tool availability, CellIFT Yosys pass with `-track-power-leakage`, Verilator simulator build via FuseSoC, RISC-V firmware compilation, simulation execution, and the Python TVLA stack.

## Running an Evaluation

Each design's `cellift/` directory contains the full evaluation infrastructure.

```bash
cd designs/proteus/cellift

# 1. Build the instrumented simulator
fusesoc --cores-root=. run --build run_cellift_csvlog

# 2. Compile a scenario (e.g., one of the 200 matched-pair AES traces)
make -C sw/multi_aes_unmasked_a_000

# 3. Run TVLA across all traces (generates CSV leakage counters)
./run_multi_trace_tvla.sh

# 4. Analyse results
python3 cycle_leakage_quantifier.py
python3 generate_publication_summary.py
```

The `multi_aes_{masked,unmasked}_{a,b}_*` scenario directories contain the matched-pair key/plaintext sets used for TVLA. Groups `a` and `b` differ only in the secret key, with all other inputs held constant.

## Instrumentation Correctness Properties

| Property | Mechanism |
|----------|-----------|
| **Sound (no false negatives)** | Taint is over-approximate — all real information flows captured |
| **Conservative (may false positive)** | Combinational `leak = taint` does not verify transitions occur |
| **Compositional** | Bottom-up module processing preserves shadow hierarchy |
| **Non-intrusive** | All instrumentation is additive; original cells are unchanged |

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

Tool and design submodules carry their own licenses (see each subdirectory).
