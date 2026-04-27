# Plan: Migrate CellIFT leakage evaluation to Verilator 5.x (from GitHub)

## Context

Current Verilator: **4.216** (2021-12-05) at `/home/andrija/prefix-cellift/bin/verilator`.
Target Verilator: **latest from GitHub** (currently v5.047, 2026-03-30).

Motivation:
- The fstapi 32-bit overflow bug (`uint32_t vchg_siz/vchg_alloc_siz`) is present in both 4.216
  and the system 5.038. It causes SIGABRT on FST traces > ~4 GB (Proteus/Rocket Kyber).
  A 2-line patch was applied to 4.216 as a workaround, but a clean solution requires either
  the bug to be fixed upstream or the patch applied to a fresh install.
- Staying on 5.x allows tracking upstream fixes and compiler improvements going forward.

## Key findings from analysis

### fstapi overflow status
- **5.038** (system, `/usr/local/`): still has `uint32_t vchg_siz / vchg_alloc_siz` — **not fixed**
- **5.047 / master**: unknown; must be checked after cloning. Same 2-line patch will be applied
  if still present.

### Breaking changes from 4.x → 5.x relevant to CellIFT

| Change | Required action | Risk |
|--------|----------------|------|
| `--trace` deprecated → `--trace-vcd` | Update all 27 `.core` files | Low (still compiles with warning) |
| `-std=c++11` min → `-std=c++14` | Update all 27 `.core` files | Low |
| `--timing` now opt-in (was off) | Add `--no-timing` to all cores | **High** if omitted — enables timing simulation overhead |
| `--assert` now ON by default | Add `--no-assert` to all cores | Medium (may slow builds or change sim behavior) |
| `vluint32_t` deprecated | Replace in 3 `testbench.h` files | Low (still compiles) |
| `Verilated::commandArgs()` → `VerilatedContext` | No change needed — static methods still delegate to context | None |
| `Verilated::gotFinish()` | Still works in 5.x | None |
| `$finish` semantics tightened in 5.047 | **Test carefully** — key1/key2 halt detection uses `Verilated::gotFinish()` | Medium |
| `Vdesign___024root.h` internal hierarchy | Likely unchanged — verify after compile | Low |

## Files to modify

### Step 1: Build and install Verilator 5.x

Install to a **new prefix** `/home/andrija/prefix-verilator5/` (keep 4.216 untouched during migration).

```bash
# Prerequisites (should already be available):
# autoconf, flex, bison, make, g++, python3

git clone https://github.com/verilator/verilator
cd verilator
git checkout $(git tag -l 'v5.*' | sort -V | tail -1)   # latest stable tag
autoconf
./configure --prefix=/home/andrija/prefix-verilator5
make -j$(nproc)
make install
```

After install, check and patch fstapi if needed:

```bash
FSTAPI=/home/andrija/prefix-verilator5/share/verilator/include/gtkwave/fstapi.c
grep "vchg_siz" "$FSTAPI"
# If output shows "uint32_t vchg_siz", apply patch:
sed -i 's/uint32_t vchg_siz;/size_t vchg_siz;/'        "$FSTAPI"
sed -i 's/uint32_t vchg_alloc_siz;/size_t vchg_alloc_siz;/' "$FSTAPI"
```

### Step 2: Update env.sh

File: `/mnt/nvme1n1p1/cellift-meta-leakage/env.sh`

Change:
```bash
export PREFIX_CELLIFT=$HOME/prefix-cellift
```
To:
```bash
export PREFIX_CELLIFT=$HOME/prefix-verilator5
```

(All other `PREFIX_CELLIFT` references — sv2v, Python venv, RISCV toolchain — stay the same path
in `prefix-cellift`; only `bin/verilator` moves. Consider splitting these if the other tools
should stay at 4.216's prefix.)

**Safer alternative**: add a separate `VERILATOR_PREFIX` variable and only change PATH to
prepend `/home/andrija/prefix-verilator5/bin` before `prefix-cellift/bin`.

### Step 3: Update all 27 `.core` files

Affected directories:
- `/mnt/nvme1n1p1/cellift-designs/cellift-ibex/cellift/` — 11 core files
- `/mnt/nvme1n1p1/cellift-designs/cellift-proteus/cellift/` — 7 core files
- `/mnt/nvme1n1p1/cellift-designs/cellift-chipyard/cellift-rocket/` — ~14 core files  (also `cellift-common.mk` area if applicable)

In every `.core` file that has `verilator_options`:

**a) Replace `--trace'` with `--trace-vcd'`** (bare VCD trace targets only;
FST targets use `--trace-fst` which is already the correct 5.x name):

```bash
# In each directory:
sed -i "s/- '--trace'$/- '--trace-vcd'/" *.core
```

Note: FST targets have both `--trace` and `--trace-fst` — replace `--trace'` with `--trace-vcd'`
and leave `--trace-fst'` unchanged. In Verilator 5.x `--trace-fst` alone is sufficient
(implies tracing enabled), so the `--trace-vcd` line can be removed from FST cores entirely.

**b) Replace `-std=c++11` with `-std=c++14`** in all `-CFLAGS` entries:

```bash
sed -i 's/-std=c++11/-std=c++14/g' *.core
```

**c) Add `--no-timing` and `--no-assert`** to each core's `verilator_options` block.
These must be added as new list entries. Use a script or manual edit per core.

Example result for a trace core's `verilator_options`:
```yaml
verilator_options:
  - '--trace-vcd'
  - '--trace-max-array 1024'
  - '--no-timing'
  - '--no-assert'
  - '-CFLAGS "-std=c++14 -Wall -DTOPLEVEL_NAME=ibex_tiny_soc -O2"'
  - '-LDFLAGS "-pthread -lutil"'
  - '-Wall'
  - '-Wno-PINCONNECTEMPTY'
  - '-Wno-fatal'
```

### Step 4: Update testbench C++ files (3 files, 1 line each)

Replace deprecated `vluint32_t` with `uint32_t`:

| File | Line | Change |
|------|------|--------|
| `cellift-ibex/cellift/dv/testbench.h` | 99 | `vluint32_t tick_count_` → `uint32_t tick_count_` |
| `cellift-proteus/cellift/dv/testbench.h` | 93 | same |
| `cellift-chipyard/cellift-rocket/dv/testbench.h` | 100 | same |

No other API changes required — `Verilated::commandArgs()`, `traceEverOn()`, `gotFinish()`,
`VerilatedVcdC`, `VerilatedFstC`, `trace_->dump/flush/open/close`, `module_->trace()` all
remain the same in 5.x.

## Rebuild and test strategy

Rebuild Ibex first (smallest, fastest iteration):

```bash
source /mnt/nvme1n1p1/cellift-meta-leakage/env.sh  # now points to prefix-verilator5
cd /mnt/nvme1n1p1/cellift-designs/cellift-ibex/cellift

# Rebuild one target as smoke test:
make prepare_cellift_csvlog_notrace  # simplest build, no trace
# If OK:
make prepare_cellift_csvlog          # adds CSV trace
make prepare_vanilla_trace_fst       # tests FST path with patched fstapi
```

Run AES sanity evaluation:
```bash
cd /mnt/nvme1n1p1/cellift-meta-leakage
./run_full_audit.sh --only-ibex --only-aes --skip-build
```

If Ibex passes, rebuild Proteus then Rocket:
```bash
# Proteus (via fusesoc directly):
cd /mnt/nvme1n1p1/cellift-designs/cellift-proteus/cellift
fusesoc --cores-root=. run --build run_cellift_csvlog
fusesoc --cores-root=. run --build run_vanilla_trace_fst
# ...

# Rocket:
cd /mnt/nvme1n1p1/cellift-designs/cellift-chipyard/cellift-rocket
make prepare_cellift_csvlog
make prepare_vanilla_trace_fst
```

Full audit:
```bash
./run_full_audit.sh --skip-build  # if binaries already built
```

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| fstapi still `uint32_t` in 5.047 | High (not fixed in 5.038) | Apply same 2-line patch post-install |
| `$finish` semantic change breaks halt detection | Medium | Test key1 vs key2 trace lengths after migration; compare with 4.216 baseline |
| `Vdesign___024root.h` name changes | Low | If compile fails, check generated header name in build dir |
| `-Wno-PINCONNECTEMPTY` removed in 5.x | Low | Swap for `-Wno-UNOPTFLAT` or remove; use `--no-fatal` equivalent |
| FuseSoC version incompatibility with 5.x Verilator | Low | Check FuseSoC docs; may need `--no-timing` in verilator_options |
| sv2v / Yosys outputs incompatible with 5.x parser | Medium | The generated RTL is Verilog-2005 style; 5.x should be more permissive, not less |

## Verification

1. `verilator --version` → shows new 5.x version
2. `grep "vchg_siz" .../prefix-verilator5/.../fstapi.c` → shows `size_t`
3. Ibex csvlog binary builds without error
4. Ibex AES evaluation produces expected TVLA results (t-stat > threshold for unmasked)
5. Proteus Kyber key2 FST simulation completes without SIGABRT and FST is readable by `fst2vcd`
6. Compare `Verilated::gotFinish()` halt cycles between 4.216 and 5.x for both key1 and key2 scenarios

## Notes

- The `prefix-cellift` directory (sv2v, Python venv, RISCV toolchain, etc.) remains **unchanged**.
  Only the Verilator binary and its share/ directory move to `prefix-verilator5`.
- If the migration reveals other 5.x compatibility issues, the 4.216 setup remains intact at
  `prefix-cellift/bin/verilator` for rollback.
- The fstapi patch documented in `fstapi_overflow_bug.md` applies identically to the new install.
