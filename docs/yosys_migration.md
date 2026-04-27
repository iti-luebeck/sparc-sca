# Yosys Migration Plan: cellift-yosys 0.22 → Yosys 0.64+

## Context

CellIFT instrumentation (taint-tracking RTL generation) requires a custom Yosys fork
(`tools/cellift-yosys/`) that embeds five proprietary passes into the Yosys binary.
The fork is based on Yosys **0.22+29** (~2022) — 41 minor versions behind the latest release.

The pre-compiled binary at `tools/cellift-yosys/yosys` currently **cannot run**:
```
GLIBCXX_3.4.29 not found (required by .../cellift-yosys/yosys)
```
It was compiled on a newer glibc than Ubuntu 20.04 provides.

The system Yosys at `/usr/local/bin/yosys` is already **0.63+85** (March 6, 2026 — very
recent, one release behind the latest stable 0.64) but contains **none** of the custom passes.

**Good news**: The instrumented RTL is already pre-generated in each design's
`generated/out/` (`cellift.sv`, `glift.sv`, `passthrough.sv`, `vanilla.sv`), so the
evaluation pipeline does not need to re-run Yosys immediately. Instrumentation only
needs to work for future design changes or new processors.

---

## Custom passes that need porting

All source files live under `tools/cellift-yosys/passes/`:

| Pass | Source file | Lines | Role |
|------|------------|-------|------|
| `cellift` | `passes/cellift/cellift.cc` + `cellift_util*.cc` + `cells/` | ~1400 + ~50 cell files | Core taint instrumentation of each cell type |
| `breakdown_glift` | `passes/cmds/breakdown_glift.cc` | ~300 | Decompose GLIFT cells |
| `list_state_elements` | `passes/cmds/list_state_elements.cc` | ~200 | Enumerate FFs/latches |
| `mul_to_adds` | `passes/cmds/mul_to_adds.cc` | ~150 | Replace multipliers with adders |
| `pmuxtree` | `passes/techmap/pmuxtree.cc` | ~200 | Synthesize parallel-mux trees |
| `meta_reset` | (location TBD — possibly built-in or generated) | — | Inject meta-reset signal |

---

## Two-phase migration strategy

### Phase 1 (Immediate): Rebuild cellift-yosys 0.22 locally

Recompile the existing fork with the system's g++ (10.5.0, Ubuntu 20.04) to fix the
GLIBCXX issue. This is the fastest path to a working binary without any API porting.

```bash
cd /mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys

# Verify current build config
cat Makefile.conf

# Update CONFIG to gcc (should already be set to gcc in Makefile.conf)
# Build with all CPUs:
make -j$(nproc) 2>&1 | tee build_phase1.log

# Smoke test:
./yosys --version
./yosys -p "help cellift" 2>&1 | head -5
```

Expected version string: `Yosys 0.22+29 ...` with custom passes available.

If the build fails due to C++ compatibility issues, see *C++ porting notes* below.

**After successful build:**
Update `env.sh` (or add a line) so `PATH` resolves to this binary before the system Yosys:

```bash
# In env.sh, before the existing PATH line:
export PATH="/mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys:$PATH"
```

**Verify instrumentation works end-to-end on one design:**
```bash
source /mnt/nvme1n1p1/cellift-meta-leakage/env.sh
cd /mnt/nvme1n1p1/cellift-designs/cellift-ibex/cellift
rm -f generated/out/cellift.sv
make generated/out/cellift.sv
# Compare with existing file using diff
```

---

### Phase 2 (Migration): Port custom passes to Yosys 0.64

Rebase the five custom passes onto the latest stable Yosys release.

#### Step 1: Set up the new base

```bash
git clone https://github.com/YosysHQ/yosys.git yosys-0.64
cd yosys-0.64
git checkout $(git tag -l 'yosys-*' | sort -V | tail -1)  # latest stable tag
```

#### Step 2: Copy custom pass sources

```bash
# From cellift-yosys, copy the custom passes into the new tree:
cp -r /mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys/passes/cellift   passes/
cp    /mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys/passes/cmds/breakdown_glift.cc  passes/cmds/
cp    /mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys/passes/cmds/list_state_elements.cc  passes/cmds/
cp    /mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys/passes/cmds/mul_to_adds.cc   passes/cmds/
cp    /mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys/passes/techmap/pmuxtree.cc   passes/techmap/
# meta_reset: locate source first (possibly a tcl-generated pass or built into older Yosys)
```

Add the new cellift pass directory to Yosys Makefile:
```makefile
# In Makefile, add to OBJS:
OBJS += passes/cellift/cellift.o
OBJS += passes/cellift/cellift_util.o
OBJS += passes/cellift/cellift_util_leakage.o
# + all cell/*.o files
```

#### Step 3: Port C++ API changes (0.22 → 0.64)

The Yosys C++ kernel API changed significantly over 41 versions. Key areas to audit:

| Area | What likely changed | How to fix |
|------|-------------------|-----------|
| `RTLIL::IdString` | Constructor changes, string interning | Check all `IdString("\\signal")` usages |
| `RTLIL::Module::addCell()` | Signature may have changed | Check `addCell(...)` call sites |
| `RTLIL::SigSpec` | Constructor and operator changes | Compile errors will pinpoint these |
| `ModIndex` | Renamed or moved (was `SigMap`) | Replace `ModIndex` with `SigMap` if needed |
| Pass registration | `PRIVATE_NAMESPACE_BEGIN/END` macros | Match new Yosys pass registration pattern |
| `log()` / `log_error()` | Mostly stable | Should be fine |
| `MemInit` struct (in cellift.cc) | Memory inference refactored in 0.48 | Check all `MemInit` usages |

**Recommended approach**: Attempt to compile after copying, fix errors iteratively:
```bash
make -j$(nproc) 2>&1 | grep "^passes/cellift" | head -40
```

Most errors will be C++ type mismatches that are self-describing. Expect 20–60 compile errors
on first attempt; the majority will be mechanical fixes.

#### Step 4: Functional verification

After a successful build, verify each pass produces the same RTLIL output as the old binary:

```bash
cd /mnt/nvme1n1p1/cellift-designs/cellift-ibex/cellift

# Generate with old binary (Phase 1):
OLD_BIN="/mnt/nvme1n1p1/cellift-meta-leakage/tools/cellift-yosys/yosys"
DECOMPOSE_MEMORY=1 VERILOG_INPUT=generated/sv2v_out.v INSTRUMENTATION=cellift \
  VERILOG_OUTPUT=/tmp/cellift_old.sv TOP_MODULE=cellift_rv_core_ibex_mem_top \
  "$OLD_BIN" -c "$CELLIFT_YS/instrument.ys.tcl"

# Generate with new binary (Phase 2):
NEW_BIN="/path/to/yosys-0.64/yosys"
DECOMPOSE_MEMORY=1 VERILOG_INPUT=generated/sv2v_out.v INSTRUMENTATION=cellift \
  VERILOG_OUTPUT=/tmp/cellift_new.sv TOP_MODULE=cellift_rv_core_ibex_mem_top \
  "$NEW_BIN" -c "$CELLIFT_YS/instrument.ys.tcl"

# Compare (may differ in signal ordering but logic should be equivalent):
diff /tmp/cellift_old.sv /tmp/cellift_new.sv | head -50

# Build and run simulation with new instrumented RTL:
cp /tmp/cellift_new.sv generated/out/cellift.sv
make prepare_cellift_csvlog
cd /mnt/nvme1n1p1/cellift-meta-leakage
./run_full_audit.sh --only-ibex --only-aes --skip-build
```

---

## C++ porting notes (Phase 1 recompilation)

If the 0.22-era code fails to compile with g++ 10.5.0:

- **`-std=c++11` vs `-std=c++17`**: Yosys 0.22 uses C++11/14. Modern g++ defaults to C++14. Try
  adding `CXXSTD := c++17` to `Makefile.conf` if the default fails.
- **Deprecated headers**: `#include <ext/hash_map>` → replace with `#include <unordered_map>`
- **`register` keyword**: removed in C++17 — remove any `register` variable declarations
- **`std::result_of`**: removed in C++20, not an issue for C++17

---

## Breaking changes relevant to CellIFT (Yosys 0.22 → 0.64)

| Version | Change | Impact on CellIFT |
|---------|--------|-------------------|
| 0.48 | `MemInit` struct refactored; `read_ilang` removed | `cellift.cc` uses `MemInit` — check usage |
| 0.48 | `write_rtlil` no longer sorts by default | Add `-sort` flag if reproducibility needed |
| 0.48 | `qwp` pass removed | Not used by CellIFT |
| 0.60 | `cover` pass removed | Not used by CellIFT |
| 0.64 | ABC `-S` and `-fast` flags removed | Not used by CellIFT |
| All | `RTLIL` internal APIs evolve without stable ABI | Compile errors are the guide |

Standard TCL commands (`read_verilog`, `hierarchy`, `proc`, `opt`, `memory`, `write_verilog`,
`stat`, `techmap`) are **stable** across all these versions. The TCL scripts in
`design-processing/common/yosys/` require **no changes**.

---

## Key file locations

| File / Dir | Purpose |
|-----------|---------|
| `tools/cellift-yosys/` | Custom Yosys fork source + pre-compiled binary |
| `tools/cellift-yosys/yosys` | Pre-compiled binary (broken — GLIBCXX mismatch) |
| `tools/cellift-yosys/passes/cellift/` | Core taint pass (cellift.cc + 50+ cell files) |
| `tools/cellift-yosys/passes/cmds/` | breakdown_glift, list_state_elements, mul_to_adds |
| `tools/cellift-yosys/passes/techmap/pmuxtree.cc` | pmuxtree pass |
| `design-processing/common/yosys/instrument.ys.tcl` | Main instrumentation TCL script |
| `design-processing/common/yosys/statistics.ys.tcl` | Statistics TCL script |
| `cellift-designs/*/cellift/generated/out/*.sv` | Pre-generated instrumented RTL (safe to use now) |

---

## Prioritization

1. **Do first (Phase 1)**: Recompile the existing 0.22 fork with system g++ — resolves the
   GLIBCXX crash and restores the ability to re-run instrumentation at any time.

2. **Do when time allows (Phase 2)**: Port to Yosys 0.64 — gets modern Yosys fixes, better
   SystemVerilog support, and a supportable base going forward.

3. **Not urgent**: Updating the TCL scripts — they are already compatible with 0.64.
