# fstapi.c — 32-bit overflow in large FST trace writes

## Summary

When a Verilator-compiled simulation writes a very large FST trace (>~2 GB of in-memory
change data), the simulation crashes with `SIGABRT` due to a 32-bit integer overflow in
`fstapi.c`. This was observed during the **Proteus Kyber key2** vanilla trace simulation,
which runs 1,592,664 cycles with no early software halt and produces ~4.6 GB of FST block
data before aborting.

## Affected files

| File | Verilator version |
|------|------------------|
| `/home/andrija/prefix-cellift/share/verilator/include/gtkwave/fstapi.c` | 4.216 (cellift) |
| `/usr/local/share/verilator/include/gtkwave/fstapi.c` | 5.038 (system) |

Both versions contain the same bug.

## Root cause

Inside `struct fstWriterContext` (around line 741 in the cellift fstapi.c):

```c
// BEFORE (buggy):
uint32_t vchg_siz;        // current fill level of vchg_mem (bytes)
uint32_t vchg_alloc_siz;  // allocated size of vchg_mem (bytes)
```

`vchg_mem` is the in-memory buffer that accumulates signal change records between FST block
flushes. The flush is triggered when `vchg_siz >= fst_break_size`, where `fst_break_size`
is a `size_t` that starts at 128 MB (`1UL << 27`) and grows by 128 MB for every 1 M signals
defined, up to a maximum of 2 GB (`1UL << 31 = FST_BREAK_SIZE_MAX`).

The critical overflow occurs in two places:

### 1. Signal registration (line ~2681)

```c
xc->fst_break_size    += xc->fst_orig_break_size;     // size_t grows
xc->fst_break_add_size += xc->fst_orig_break_add_size; // size_t grows (uncapped!)

xc->vchg_alloc_siz = xc->fst_break_size + xc->fst_break_add_size; // size_t → uint32_t !!
if (xc->vchg_mem)
    xc->vchg_mem = (unsigned char *)realloc(xc->vchg_mem, xc->vchg_alloc_siz);
```

`fst_break_size` is capped at 2 GB, but `fst_break_add_size` is **uncapped** and grows by
4 MB per 1 M signals. With a large design (e.g., Proteus with many signals) the sum can
exceed 4 GB, truncating silently when assigned to `uint32_t vchg_alloc_siz`. `realloc` is
then called with the truncated (tiny) size.

### 2. Runtime buffer growth (lines ~2960, ~3195)

```c
xc->vchg_alloc_siz += (xc->fst_break_add_size + len);  // size_t + size_t assigned to uint32_t
xc->vchg_mem = realloc(xc->vchg_mem, xc->vchg_alloc_siz);
```

When `vchg_alloc_siz` wraps, `realloc` returns a tiny or misaligned buffer. Subsequent
writes beyond the actual allocation cause a heap corruption → `SIGABRT`.

## Observed failure

```
Proteus Kyber eval — Step 5 (key2 vanilla FST simulation):
  SIMLEN = 2 000 000
  Scenario B: scenario_kyber_unmasked_key2
  Simulation ran for ~56 minutes
  Temp FST file reached ~4.6 GB before SIGABRT
  awk (inside run_with_stdout_mode pipeline) reported:
      awk: write error: No space left on device   ← gawk EPIPE→ENOSPC quirk
  Script exited with rc=1 under set -euo pipefail
  Total elapsed: 580 min 16 s
```

The "No space left on device" is **not** a real disk-full error. Under `pipefail`, when
the simulation binary exits abnormally (SIGABRT), the awk process on the read end of the
pipe gets EPIPE on its next write, which gawk reports as ENOSPC. Disk space was not the issue.

## Key1 vs Key2 asymmetry

Key1 and Key2 ELFs should theoretically run for the same number of cycles. The asymmetry
is caused by `Verilated::gotFinish()` detection in `tb_run_ticks()` (in
`design-processing/common/dv/ticks.h`):

```c
for (int i = 0; i < simlen; i++) {
    tb->tick(1);
    if (Verilated::gotFinish()) {   // triggered by RISC-V ecall/ebreak in ELF
        halt_cycle = i + 1;
        break;
    }
}
```

- **Key1 ELF** triggers `Verilated::gotFinish()` early → tiny trace (~40 MB VCD)
- **Key2 ELF** never triggers it → runs all 1,592,664 cycles → ~4.6 GB FST

This should be investigated: the two ELFs should be symmetric. If key2 lacks the halt
instruction, it may produce traces that extend past the meaningful computation window,
which can skew TVLA results.

## Applied fix

Changed both fields in `struct fstWriterContext` from `uint32_t` to `size_t`:

```c
// AFTER (fixed):
size_t vchg_siz;        // line 776
size_t vchg_alloc_siz;  // line 777
```

Applied to:
- `/home/andrija/prefix-cellift/share/verilator/include/gtkwave/fstapi.c` (lines 776–777)

The system Verilator 5.038 (`/usr/local/share/verilator/include/gtkwave/fstapi.c`) has the
same bug but was **not** patched because:
1. CellIFT simulation binaries are compiled with the cellift Verilator 4.216 at
   `/home/andrija/prefix-cellift/bin/verilator`
2. Verilator 4.x → 5.x has breaking changes that could affect CellIFT design compilation

## What to do after the patch

After patching fstapi.c, all FST-trace simulation binaries must be **recompiled** to pick
up the fix (fstapi.c is `#include`d into `verilated_fst_c.cpp` at build time):

```bash
# Proteus (the failing processor):
cd /mnt/nvme1n1p1/cellift-designs/cellift-proteus/cellift
source /mnt/nvme1n1p1/cellift-meta-leakage/env.sh
make prepare_vanilla_trace_fst    # rebuild vanilla FST binary
make prepare_cellift_fasttrace_fst  # rebuild fasttrace FST binary (optional, same bug)

# Ibex:
cd /mnt/nvme1n1p1/cellift-designs/cellift-ibex/cellift
make prepare_vanilla_trace_fst

# Rocket:
cd /mnt/nvme1n1p1/cellift-designs/cellift-chipyard/cellift-rocket
make prepare_vanilla_trace_fst
```

## Verification

After rebuilding, run the Proteus Kyber evaluation and check that:
1. The key2 vanilla FST simulation completes without SIGABRT
2. The resulting `.fst` file is readable by `fst2vcd`
3. The resulting VCD has the expected number of cycles (~1,592,664)

```bash
cd /mnt/nvme1n1p1/cellift-designs/cellift-proteus/cellift
source /mnt/nvme1n1p1/cellift-meta-leakage/env.sh
SIMLEN=2000000 \
TRACEFILE=/tmp/test_kyber_key2.fst \
SIMSRAMELF=sw/scenario_kyber_unmasked_key2/build/app.elf \
  ./build/run_vanilla_trace_fst_0.1/default-verilator/Vproteus_tiny_soc
fst2vcd /tmp/test_kyber_key2.fst | tail -5
```

## Alternative: compile Verilator from source

If the patch proves insufficient (e.g., further overflow in a different field), compiling
a fresh Verilator from source with a newer bundled GTKWave fstapi.c would be the next step.
Risks:
- Verilator 5.x breaking changes may require updates to the CellIFT FuseSoC core files
- Full rebuild of all simulation targets across all three processors
- The system Verilator 5.038 was verified to have the same bug; a version newer than 5.038
  would be needed, or the source patch applied before building
