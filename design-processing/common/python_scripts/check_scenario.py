#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""
check_scenario.py -- does a scenario's taint file actually taint the secret?

Two things in every scenario drift independently:

  * the ELF's data layout, which moves whenever the sources, the linker script
    or the RISC-V toolchain change (sparc.sh records three GCC versions
    emitting three different programs from identical masked-AES source), and
  * taint_data/<scenario>/taint_data.txt, which names byte addresses in that
    layout by hand.

Nothing in the flow compared the two, and a taint file that points past the
secret does not fail: it loads, it taints whatever sits at those addresses, and
it produces a plausible t-curve. The published Kyber files did exactly that on
all three cores -- the sk taint sat 0x600 (Ibex, Proteus) or 0x80 (Rocket) away
from kyber_sk, so 96 of 1632 secret-key bytes were tainted on the 32-bit cores
and the secret vector s, which occupies the FRONT of sk, was missed entirely.

Three things are checked per scenario:

  1. every line's declared length matches its mask. The length is DECIMAL and
     counted in bytes (README Step 8). Writing it as hex is how the AES
     templates came to taint 3 of 4 key words on Ibex: '10' meant 16 to the
     author and 10 to the loader, and (10+3)/4 = 3 words = key bytes 0..11.
  2. the tainted byte set covers the secret the workload names, and
  3. nothing outside that secret is tainted.

With --write-taint the file the ELF implies is written instead. That is how
these files should be produced after any change to the sources or the
toolchain; hand-maintained addresses are what this script exists to catch.

    check_scenario.py designs/ibex/cellift --workload aes scenario_aes128_key1
    check_scenario.py designs/ibex/cellift --workload kyber --write-taint scenario_kyber_unmasked_key1
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

# Per design: the SRAM word width in bytes, and the base that the taint file's
# addresses are relative to.
#
# Both come from how src/ift_sram_mem.sv is wired in the SoC, and neither is
# guessable from the taint file:
#
#   ibex      Width 32, SRAM at 0 -- the taint address IS the ELF address.
#   proteus   Width 128 (the AXI data width), and the SoC indexes the SRAM with
#             axi_arw_payload_addr[21:4], which drops the 0x8000_0000 base, so
#             taint addresses are ELF addresses minus that base.
#   rocket    Width 64, and ift_sram_mem relocates the RUNTIME access up by
#             RelocateRequestUp (0x8000_0000 >> 3) while the preload does not,
#             so the two meet when the taint file carries the full ELF address.
#
# The word width matters because the loader rounds: a section of `len` bytes
# taints ceil(len / WidthBytes) whole words starting at addr / WidthBytes.
DESIGNS = {
    "ibex/cellift": (4, 0x00000000),
    "proteus/cellift": (16, 0x80000000),
    "chipyard/cellift-rocket": (8, 0x00000000),
    "chipyard/cellift-boom": (8, 0x00000000),
}

# The secret each workload's taint file is supposed to cover, most specific
# first: the first symbol an ELF actually carries wins.
#
# A masked scenario taints ONE share (aes_key_share0) and not aes_key_mask.
# That is deliberate and is not an oversight to "fix": tainting both shares
# marks the reconstructed key, and the taint would then arrive everywhere the
# recombination goes, which is the result the masking is supposed to prevent.
TAINT_TARGETS = {
    "aes": [("aes_key", 16), ("aes_key_share0", 16)],
    "kyber": [("kyber_sk", 1632)],
}

NM_CANDIDATES = ("riscv64-unknown-elf-nm", "riscv32-unknown-elf-nm", "nm")


def find_nm(explicit):
    for cand in ([explicit] if explicit else NM_CANDIDATES):
        if shutil.which(cand):
            return cand
    sys.exit("no nm found; pass --nm <tool>")


def elf_symbols(nm, elf):
    """{name: address} for the ELF's defined symbols."""
    out = subprocess.run([nm, str(elf)], check=True, capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1].upper() != "U":
            syms[parts[2]] = int(parts[0], 16)
    return syms


def parse_taint_file(path):
    """[(lineno, addr, declared_len, mask_hex)], skipping comments and blanks."""
    rows = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        f = s.split()
        if len(f) < 4:
            rows.append((n, None, None, None))
            continue
        rows.append((n, int(f[1], 16), int(f[2], 10), f[3]))
    return rows


def covered_bytes(rows, word_bytes):
    """(covered addresses, addresses with no mask behind them, problems).

    Models src/ift_sram_mem.sv exactly: the section starts at the word
    addr // word_bytes, runs for ceil(len / word_bytes) words, and byte j of
    word i takes mask byte i*word_bytes + j. Mask bytes past the end of the
    string are whatever the preload buffer happens to hold, which is why they
    are reported separately rather than counted as tainted.
    """
    covered, unbacked, problems = set(), set(), []
    for n, addr, declared, mask in rows:
        if addr is None:
            problems.append(f"line {n}: not a taint record (needs 4 fields)")
            continue
        if len(mask) % 2:
            problems.append(f"line {n}: mask has an odd number of hex digits")
            continue
        mask_bytes = bytes.fromhex(mask)
        if len(mask_bytes) != declared:
            hint = ""
            if int(str(declared), 16) == len(mask_bytes):
                hint = f" -- {declared} read as hex is {len(mask_bytes)}, and the length is decimal"
            problems.append(
                f"line {n}: declares {declared} bytes but the mask carries "
                f"{len(mask_bytes)}{hint}"
            )
        if addr % word_bytes:
            problems.append(
                f"line {n}: address 0x{addr:x} is not {word_bytes}-byte aligned; "
                f"the loader truncates it to 0x{addr // word_bytes * word_bytes:x}"
            )
        nwords = (declared + word_bytes - 1) // word_bytes
        base = addr // word_bytes
        for i in range(nwords):
            for j in range(word_bytes):
                k = i * word_bytes + j
                a = (base + i) * word_bytes + j
                if k < len(mask_bytes):
                    if mask_bytes[k]:
                        covered.add(a)
                else:
                    unbacked.add(a)
    return covered, unbacked, problems


def pick_target(workload, syms):
    for name, size in TAINT_TARGETS[workload]:
        if name in syms:
            return name, size, syms[name]
    wanted = " or ".join(n for n, _ in TAINT_TARGETS[workload])
    return None, None, f"ELF carries none of {wanted}"


def fmt_ranges(addrs, limit=4):
    """Compress a set of addresses into readable ranges."""
    if not addrs:
        return "none"
    out, s = [], sorted(addrs)
    start = prev = s[0]
    for a in s[1:]:
        if a == prev + 1:
            prev = a
            continue
        out.append((start, prev))
        start = prev = a
    out.append((start, prev))
    txt = ", ".join(f"0x{a:x}-0x{b:x}" for a, b in out[:limit])
    return txt + (f", ... ({len(out)} ranges)" if len(out) > limit else "")


def check_one(cellift, scenario, workload, word_bytes, base, nm, write):
    elf = cellift / "sw" / scenario / "build" / "app.elf"
    taint = cellift / "taint_data" / scenario / "taint_data.txt"
    print(f"\n{scenario}")
    if not elf.is_file():
        print(f"  SKIP no ELF at {elf.relative_to(cellift)} -- build it first")
        return None
    if not taint.is_file():
        print(f"  FAIL no taint file at {taint.relative_to(cellift)}")
        return False

    syms = elf_symbols(nm, elf)
    name, size, addr = pick_target(workload, syms)
    if name is None:
        print(f"  FAIL {addr}")
        return False
    taddr = addr - base
    print(f"  {name}: ELF 0x{addr:x} -> taint address 0x{taddr:x}, {size} bytes")

    if write:
        taint.parent.mkdir(parents=True, exist_ok=True)
        taint.write_text(
            f"# Generated by check_scenario.py from {elf.name}: {name}\n"
            f"# <taint_id> <addr_hex> <length_bytes_decimal> <mask_hex>\n"
            f"0 {taddr:x} {size} {'ff' * size}\n"
        )
        print(f"  wrote {taint.relative_to(cellift)}")
        return True

    rows = parse_taint_file(taint)
    covered, unbacked, problems = covered_bytes(rows, word_bytes)
    target = set(range(taddr, taddr + size))
    missing = target - covered
    outside = covered - target

    ok = not problems and not missing and not outside and not unbacked
    for p in problems:
        print(f"  FAIL {p}")
    print(f"  tainted {len(covered & target)}/{size} bytes of {name}")
    if missing:
        print(f"  FAIL {len(missing)} secret bytes NOT tainted: {fmt_ranges(missing)}")
    if outside:
        print(f"  FAIL {len(outside)} tainted bytes outside {name}: {fmt_ranges(outside)}")
    if unbacked:
        print(f"  FAIL {len(unbacked)} bytes declared but not backed by the mask: "
              f"{fmt_ranges(unbacked)}")
    if ok:
        print("  ok")
    return ok


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cellift", type=Path, help="a design's cellift directory")
    ap.add_argument("scenarios", nargs="+")
    ap.add_argument("--workload", required=True, choices=sorted(TAINT_TARGETS))
    ap.add_argument("--write-taint", action="store_true",
                    help="write the taint file the ELF implies instead of checking it")
    ap.add_argument("--word-bytes", type=int, default=None,
                    help="SRAM word width in bytes (overrides the built-in table)")
    ap.add_argument("--sram-base", type=lambda s: int(s, 0), default=None,
                    help="base subtracted from ELF addresses (overrides the table)")
    ap.add_argument("--nm", default=None)
    a = ap.parse_args()

    cellift = a.cellift.resolve()
    key = "/".join(cellift.parts[-2:])
    if key in DESIGNS:
        word_bytes, base = DESIGNS[key]
    else:
        word_bytes, base = a.word_bytes, a.sram_base
        if word_bytes is None or base is None:
            sys.exit(f"unknown design '{key}': pass --word-bytes and --sram-base, "
                     f"or add it to DESIGNS in {Path(__file__).name}")
    if a.word_bytes is not None:
        word_bytes = a.word_bytes
    if a.sram_base is not None:
        base = a.sram_base

    nm = find_nm(a.nm)
    print(f"{key}: {word_bytes}-byte SRAM words, taint base 0x{base:x}, nm={nm}")

    results = [check_one(cellift, s, a.workload, word_bytes, base, nm, a.write_taint)
               for s in a.scenarios]
    checked = [r for r in results if r is not None]
    if not checked:
        print("\nNOTHING CHECKED -- no scenario had a built ELF")
        return 2
    if all(checked):
        print("\nALL CHECKS PASSED" if not a.write_taint else "\nALL TAINT FILES WRITTEN")
        return 0
    print(f"\n{sum(1 for r in checked if not r)} of {len(checked)} scenarios FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
