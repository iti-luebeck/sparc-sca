# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck

PYTHON   ?= python3
LOGFILES  = log

RUSTEXEC   = $(CARGO_HOME)/bin/rustc
RUSTUPEXEC = $(CARGO_HOME)/bin/rustup
CARGOEXEC  = $(CARGO_HOME)/bin/cargo

# Build and install all tools into $(PREFIX_CELLIFT).
# gtkwave is excluded from the default set (GUI tool, not needed for headless eval).
.PHONY: installtools
installtools: install_rust install_morty install_bender install_fusesoc \
              install_toolchain install_spike install_verilator install_yosys \
              install_sv2v install_python

$(LOGFILES):
	mkdir -p $@

# ── Rust (required by morty and bender) ──────────────────────────────────────
.PHONY: install_rust
install_rust: $(RUSTEXEC)

$(RUSTEXEC): | $(LOGFILES)
	( CARGO_HOME=$(CARGO_HOME) RUSTUP_HOME=$(RUSTUP_HOME) \
	  ./rustup-init -y --default-toolchain 1.83.0 ) \
	  >$(LOGFILES)/rust.log 2>&1
	$(RUSTUPEXEC) install 1.83.0 >>$(LOGFILES)/rust.log 2>&1

# ── morty — SystemVerilog hierarchy flattener ─────────────────────────────────
.PHONY: install_morty
install_morty: $(RUSTEXEC) | $(LOGFILES)
	$(CARGOEXEC) install --path morty --root $(PREFIX_CELLIFT) \
	  >$(LOGFILES)/morty.log 2>&1

# ── bender — RTL dependency manager ──────────────────────────────────────────
.PHONY: install_bender
install_bender: $(RUSTEXEC) | $(LOGFILES)
	$(CARGOEXEC) install --path bender --root $(PREFIX_CELLIFT) \
	  >$(LOGFILES)/bender.log 2>&1

# ── FuseSoC — hardware build system ──────────────────────────────────────────
.PHONY: install_fusesoc
install_fusesoc: $(CELLIFT_PYTHON_VENV) | $(LOGFILES)
	$(CELLIFT_PYTHON_VENV)/bin/pip install fusesoc==1.12.0 \
	  >$(LOGFILES)/fusesoc.log 2>&1

# ── RISC-V GNU toolchain (RV32 + RV64 multilib) ───────────────────────────────
.PHONY: install_toolchain
install_toolchain: $(PREFIX_CELLIFT)/riscv | $(LOGFILES)
	( cd riscv-gnu-toolchain && \
	  ./configure --prefix=$(PREFIX_CELLIFT)/riscv \
	              --with-arch=rv64gc --enable-multilib && \
	  make -j$(CELLIFT_JOBS) ) \
	  >$(LOGFILES)/toolchain.log 2>&1

# ── Spike — RISC-V ISA simulator ─────────────────────────────────────────────
.PHONY: install_spike
install_spike: $(PREFIX_CELLIFT)/riscv | $(LOGFILES)
	( cd riscv-isa-sim && mkdir -p build && cd build && \
	  ../configure --prefix=$(PREFIX_CELLIFT)/riscv && \
	  make -j$(CELLIFT_JOBS) && make install ) \
	  >$(LOGFILES)/spike.log 2>&1

# ── Verilator (with FST integer-overflow fix) ─────────────────────────────────
.PHONY: install_verilator
install_verilator: | $(LOGFILES)
	( cd verilator && autoconf && \
	  ./configure --prefix=$(PREFIX_CELLIFT) && \
	  make -j$(CELLIFT_JOBS) && make install ) \
	  >$(LOGFILES)/verilator.log 2>&1

# ── Yosys with CellIFT + power-leakage extension ─────────────────────────────
.PHONY: install_yosys
install_yosys: | $(LOGFILES)
	( cd sparc-sca-yosys && make config-gcc && \
	  make PREFIX=$(PREFIX_CELLIFT) -j$(CELLIFT_JOBS) && \
	  make PREFIX=$(PREFIX_CELLIFT) install ) \
	  >$(LOGFILES)/yosys.log 2>&1

# ── sv2v — SystemVerilog-to-Verilog converter (pre-built binary) ──────────────
# Downloads the pinned release binary; avoids a multi-GB GHC/Haskell installation.
SV2V_VERSION ?= v0.0.13
.PHONY: install_sv2v
install_sv2v: | $(LOGFILES)
	( curl -fsSL \
	    https://github.com/zachjs/sv2v/releases/download/$(SV2V_VERSION)/sv2v-Linux.zip \
	    -o /tmp/sv2v.zip && \
	  unzip -j /tmp/sv2v.zip -d /tmp/sv2v-bin && \
	  install -m 755 /tmp/sv2v-bin/sv2v $(PREFIX_CELLIFT)/bin/sv2v && \
	  rm -rf /tmp/sv2v.zip /tmp/sv2v-bin ) \
	  >$(LOGFILES)/sv2v.log 2>&1

# ── Python virtual environment ────────────────────────────────────────────────
.PHONY: install_python
install_python: $(CELLIFT_PYTHON_VENV) | $(LOGFILES)
	( set -e; \
	  $(CELLIFT_PYTHON_VENV)/bin/pip install --upgrade pip --quiet; \
	  $(CELLIFT_PYTHON_VENV)/bin/pip install "edalize<0.5" ninja==1.10.2 --quiet; \
	  $(CELLIFT_PYTHON_VENV)/bin/pip install -r ../design-processing/python-requirements.txt; \
	  $(CELLIFT_PYTHON_VENV)/bin/pip install \
	    -r ../python-experiments/power_leakage_analysis/requirements.txt ) \
	  >$(LOGFILES)/python.log 2>&1

$(CELLIFT_PYTHON_VENV):
	$(PYTHON) -m venv $(CELLIFT_PYTHON_VENV)

# ── GTKWave (optional — GUI waveform viewer) ──────────────────────────────────
.PHONY: install_gtkwave
install_gtkwave: | $(LOGFILES)
	( cd gtkwave/gtkwave3 && \
	  ./configure --with-tk=/usr/lib/tk8.6/ --disable-xz \
	              --prefix=$(PREFIX_CELLIFT) && \
	  make -j$(CELLIFT_JOBS) && make install ) \
	  >$(LOGFILES)/gtkwave.log 2>&1

# ── Directory prerequisites ───────────────────────────────────────────────────
$(PREFIX_CELLIFT)/riscv:
	mkdir -p $@

# ── Clean ─────────────────────────────────────────────────────────────────────
.PHONY: cleantools
cleantools:
	@echo "This will delete the tool build trees and $(PREFIX_CELLIFT)."
	@echo "Press Enter to continue, Ctrl-C to abort."
	@read _confirm
	set -x; \
	for x in riscv-isa-sim bender morty riscv-gnu-toolchain sv2v verilator sparc-sca-yosys; do \
	  ( cd $$x && git clean -xfd ); \
	done
	rm -rf $(PREFIX_CELLIFT)
	rm -f $(LOGFILES)/*.log
