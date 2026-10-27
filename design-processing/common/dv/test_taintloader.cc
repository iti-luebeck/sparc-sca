// SPDX-License-Identifier: GPL-3.0-only
//
// Regression test for taintloader.cc's line parsing.
//
// read_taints() once declared taint_id / region_offset / num_bytes OUTSIDE the
// parse loop and ignored whether the stream extractions succeeded. Any line
// that failed them -- a '#' comment, a blank line, a truncated record -- was
// still pushed as a taint section, carrying whatever happened to be on the
// stack, INCLUDING ITS LENGTH. ift_rom_mem.sv then iterates
// (section_len + WidthBytes-1)/WidthBytes writing an associative array, which
// on a stale length reached 110M+ iterations and 45 GiB resident.
//
// The failure depended on stack layout, so it is not reproducible by feeding
// comments alone -- a bogus index may land harmlessly. What IS deterministic is
// the section COUNT: every wrongly accepted line adds a section somewhere. This
// test therefore counts sections across all taint ids and requires exactly the
// number of valid records in the file.
//
// Build and run (inside the container, from the repo root):
//   make check-taintloader
#include <cstdio>
#include <cstdlib>
#include <svdpi.h>

// Verilator supplies this at link time in a real simulation. read_taint_section
// is not exercised here, so a stub is enough to link the translation unit.
extern "C" void *svGetArrayPtr(const svOpenArrayHandle) { return nullptr; }

extern "C" void init_taint_vectors(long long num_taints);
extern "C" void read_taints(const char *filename);
extern "C" char get_taint_section(long long taint_id, long long *address,
                                  long long *len);

static const long long kNumTaints = 4;
static const long long kMaxPlausibleLen = 1LL << 20;

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <taint-file> <expected-sections>\n", argv[0]);
    return 2;
  }
  const int expected = std::atoi(argv[2]);

  init_taint_vectors(kNumTaints);
  read_taints(argv[1]);

  int total = 0, implausible = 0;
  for (long long id = 0; id < kNumTaints; ++id) {
    long long addr = 0, len = 0;
    int guard = 0;
    while (get_taint_section(id, &addr, &len)) {
      const bool bad = (len < 0 || len > kMaxPlausibleLen);
      std::printf("  id=%lld addr=0x%llx len=%lld%s\n", id,
                  (unsigned long long)addr, len, bad ? "   <-- IMPLAUSIBLE" : "");
      if (bad) ++implausible;
      ++total;
      if (++guard > 64) break;  // a corrupt length can make this unbounded
    }
  }

  std::printf("  sections=%d expected=%d implausible=%d\n", total, expected,
              implausible);
  if (total != expected) {
    std::printf("  FAIL: wrong section count -- a non-record line was accepted\n");
    return 1;
  }
  if (implausible) {
    std::printf("  FAIL: a section carries a stale length\n");
    return 1;
  }
  std::printf("  PASS\n");
  return 0;
}
