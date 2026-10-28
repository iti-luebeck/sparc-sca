// Copyright 2022 Flavien Solt, ETH Zurich.
// Licensed under the General Public License, Version 3.0, see LICENSE for details.
// SPDX-License-Identifier: GPL-3.0-only

#include <svdpi.h>

#include <string>
#include <vector>
#include <map>
#include <iostream>
#include <fstream>
#include <sstream>
#include <stdint.h>

// main dimension: taint id.
// address and length.
std::vector<std::vector<std::pair<uint64_t, uint64_t>>> taint_sections;
// main dimension: taint id.
// address and taint assignment hex.
std::vector<std::map<uint64_t, std::string>> taint_assignments;

static std::vector<int> taint_section_index;

extern "C" {
  void init_taint_vectors(long long num_taints);
  char read_taint_section(long long taint_id, long long address, const svOpenArrayHandle buffer);
  void read_taints(const char* filename);
}

extern "C" void init_taint_vectors(long long num_taints) {
  taint_sections.resize(num_taints);
  taint_assignments.resize(num_taints);
  taint_section_index.resize(num_taints, 0);
}

// Communicate the section address and len
// Returns:
// 0 if there are no more sections
// 1 if there are more sections to load
extern "C" char get_taint_section(long long taint_id, long long* address, long long* len) {
  if (taint_section_index[taint_id] < taint_sections[taint_id].size()) {
    *address = taint_sections[taint_id][taint_section_index[taint_id]].first;
    *len = taint_sections[taint_id][taint_section_index[taint_id]].second;
    taint_section_index[taint_id]++;
    return 1;
  } else {
    return 0;
  }
}

static inline char char_to_hex(char c) {
  if (c >= '0' && c <= '9')
    return c-'0';
  else if (c >= 'a' && c <= 'f')
    return c-'a'+10;
  else if (c >= 'A' && c <= 'F')
    return c-'A'+10;

  std::cerr << "Error in taint assignment string. Unexpected character: " << c << std::endl;
  exit(0);
}

extern "C" char read_taint_section(long long taint_id, long long address, const svOpenArrayHandle buffer) {
  // get actual poitner
  void* buf = svGetArrayPtr(buffer);
  // interpret the taint assignment string.
  std::string taint_assignment_str = taint_assignments[taint_id][address];
  size_t num_bytes = taint_assignment_str.size() / 2;

  for (int byte_offset = 0; byte_offset < num_bytes; byte_offset++) {
    char byte_val = (char_to_hex(taint_assignment_str[2*byte_offset]) << 4) | char_to_hex(taint_assignment_str[2*byte_offset+1]); 
    *((char *) buf + byte_offset) = byte_val;
  }
  return 0;
}

extern "C" void read_taints(const char* filename) {
  std::ifstream f;
  f.open(filename);

  // Skip comments, and check every extraction.
  //
  // This loop used to declare taint_id / region_offset / num_bytes OUTSIDE it
  // and ignore whether the stream extractions succeeded. A '#' comment line
  // fails all of them, so the section pushed below kept whatever happened to
  // be on the stack -- including its LENGTH. ift_rom_mem.sv then runs
  // (section_len + WidthBytes-1)/WidthBytes iterations, each writing the
  // mem_taints associative array: measured at 110M+ iterations and 45 GiB RSS
  // on a scenario whose taint file carries the generator's own header
  // comments. Whether it manifested at all depended on stack layout, which is
  // why it sat unnoticed -- a scenario with a bare one-line taint file ran
  // fine while a commented one took down the machine. Both the comment skip
  // and the per-field validation are needed: the format is written by hand and
  // by gen_scenarios.py, and a malformed line must be reported, not guessed.
  std::string tmp_line;
  while (std::getline(f, tmp_line)) {
    size_t first = tmp_line.find_first_not_of(" \t\r");
    if (first == std::string::npos || tmp_line[first] == '#')
        continue;

    uint64_t taint_id = 0, num_bytes = 0, region_offset = 0;
    std::string region_offset_str, byte_taint_contents;

    std::istringstream isstream(tmp_line);
    if (!(isstream >> taint_id >> region_offset_str >> num_bytes >> byte_taint_contents)) {
      std::cerr << "taintloader: ignoring malformed taint line: " << tmp_line << std::endl;
      continue;
    }

    std::istringstream str_to_hex_stream(region_offset_str);
    if (!(str_to_hex_stream >> std::hex >> region_offset)) {
      std::cerr << "taintloader: ignoring bad taint address: " << tmp_line << std::endl;
      continue;
    }

    // The length is DECIMAL and counted in bytes, and the mask already states
    // it: read_taint_section writes strlen/2 bytes. When the two disagree the
    // mask is authoritative for CONTENT while the length alone decides how many
    // words get tainted, so a wrong length silently taints the wrong amount --
    // which is how the AES templates came to cover 3 of Ibex's 4 key words.
    // Their '10' meant 16 bytes to whoever wrote it and 10 to this parser, and
    // (10 + 4-1)/4 = 3 words, leaving key bytes 12..15 clean. Nothing in the
    // flow noticed for the length of a paper.
    //
    // Warn rather than exit: by the time this runs the simulation is already
    // elaborating, and a taint file is worth loading partially. Use
    // python_scripts/check_scenario.py to catch it before a run instead.
    const uint64_t mask_bytes = byte_taint_contents.size() / 2;
    if (byte_taint_contents.size() % 2 != 0) {
      std::cerr << "taintloader: warning: mask has an odd number of hex digits: "
                << tmp_line << std::endl;
    }
    if (mask_bytes != num_bytes) {
      std::cerr << "taintloader: warning: line declares " << num_bytes
                << " bytes but the mask carries " << mask_bytes
                << " (the length is decimal, in bytes): " << tmp_line << std::endl;
    }

    taint_sections[taint_id].push_back(std::make_pair(region_offset, num_bytes));
    taint_assignments[taint_id][region_offset] = byte_taint_contents;
  }

  f.close();
}
