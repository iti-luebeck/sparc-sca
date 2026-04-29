# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck

SHELL := /bin/bash

# checkout-designs and checkout-tools work without env.sh (host-side git ops).
# Docker targets never need env.sh.
# generate-rtl calls sbt/Java directly — no CellIFT env required.
EXEMPT_TARGETS := docker-build docker-run docker-run-ro checkout-designs checkout-tools generate-rtl
ifeq (,$(filter $(EXEMPT_TARGETS),$(MAKECMDGOALS)))
ifndef CELLIFT_ENV_SOURCED
$(error Please source env.sh first — see README.md)
endif
ifneq "$(CELLIFT_ENV_VERSION)" "1"
$(error env.sh is out of date — please source env.sh again)
endif
endif

DOCKER_IMAGE ?= sparc-sca
DOCKER_TAG   ?= latest

# ── Default target ────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "SPARC-SCA build targets"
	@echo ""
	@echo "  Submodule checkout (run on host, no env.sh required):"
	@echo "    make checkout-designs   init design submodules (ibex, proteus, chipyard)"
	@echo "    make checkout-tools     init tool submodules (yosys, verilator, sv2v, …)"
	@echo ""
	@echo "  RTL generation (no env.sh required; run on host or inside Docker):"
	@echo "    make generate-rtl       generate Proteus (SpinalHDL) and Rocket (Chisel)"
	@echo "                            Verilog RTL from source; requires Java 17 + sbt"
	@echo "                            Only needed when Scala/SpinalHDL sources change;"
	@echo "                            run_full_audit.sh triggers this automatically."
	@echo ""
	@echo "  Tools (requires env.sh):"
	@echo "    make installtools       build all tools into \$$(PREFIX_CELLIFT)"
	@echo "    make cleantools         delete tool build tree and \$$(PREFIX_CELLIFT)"
	@echo ""
	@echo "  Simulator builds (requires env.sh; runs RTL instrumentation + Verilator):"
	@echo "    make build-sims         build all three designs"
	@echo "    make build-ibex         build Ibex simulators only"
	@echo "    make build-proteus      build Proteus simulators only"
	@echo "    make build-rocket       build Rocket simulators only"
	@echo ""
	@echo "  Clean:"
	@echo "    make clean-designs      clean build/ results/ traces/ in each design"
	@echo ""
	@echo "  Docker:"
	@echo "    make docker-build       build the sparc-sca Docker image"
	@echo "    make docker-run         start interactive shell with repo mounted (rw)"
	@echo "    make docker-run-ro      start interactive shell with repo mounted (ro)"

# ── RTL generation (host or inside Docker, no env.sh needed) ──────────────────
# Runs SpinalHDL and Chisel/FIRRTL elaboration to produce the design Verilog.
# run_full_audit.sh triggers this automatically via Makefile dependencies, so
# you only need to call this explicitly when Scala/SpinalHDL sources change.
.PHONY: generate-rtl
generate-rtl:
	@echo "Generating Proteus RTL from SpinalHDL sources (requires Java 17 + sbt)..."
	cd designs/proteus && sbt "runMain riscv.CoreDynamicExtMem"
	@echo "Generating Rocket RTL from Chisel/FIRRTL sources (requires Java 8+ + sbt)..."
	$(MAKE) -C designs/chipyard/sims/verilator verilog CONFIG=MySmallVMRocketConfig

# ── Submodule checkout (host-only, no env.sh needed) ─────────────────────────
.PHONY: checkout-designs checkout-tools
checkout-designs:
	git submodule update --init --recursive designs/ibex
	git submodule update --init --depth 1 external-dependencies/cellift-opentitan
	git submodule update --init --recursive designs/proteus
	# Init chipyard top-level and all generator submodules needed to compile the Scala.
	# Toolchains, VLSI plugins, FireSim, and FPGA targets are skipped (not needed for RTL gen).
	git submodule update --init designs/chipyard
	# rocket-chip is initialized recursively (hardfloat, macros, api-config-chipsalliance).
	git -C designs/chipyard submodule update --init --recursive generators/rocket-chip
	git -C designs/chipyard submodule update --init --force generators/testchipip
	git -C designs/chipyard submodule update --init --force generators/sifive-blocks
	git -C designs/chipyard submodule update --init --force tools/barstools
	git -C designs/chipyard submodule update --init --force tools/api-config-chipsalliance
	# All generator submodules referenced in chipyard Scala sources.
	git -C designs/chipyard submodule update --init generators/boom
	git -C designs/chipyard submodule update --init generators/hwacha
	git -C designs/chipyard submodule update --init generators/icenet
	git -C designs/chipyard submodule update --init generators/sifive-cache
	# gemmini and sha3 are intentionally NOT initialised: their Scala sources
	# import midas.targetutils (FireSim/MIDAS), which is not available without
	# the full FireSim submodule tree.  MySmallVMRocketConfig does not use
	# either accelerator; leaving the directories empty lets SBT compile them
	# as zero-source projects without errors.
	git -C designs/chipyard submodule update --init generators/fft-generator
	git -C designs/chipyard submodule update --init generators/riscv-sodor
	git -C designs/chipyard submodule update --init generators/ibex
	git -C designs/chipyard submodule update --init generators/nvdla
	git -C designs/chipyard submodule update --init generators/cva6
	git -C designs/chipyard submodule update --init --force tools/dsptools
	git -C designs/chipyard submodule update --init --force tools/rocket-dsp-utils

checkout-tools:
	git submodule update --init --recursive tools/sparc-sca-yosys
	git submodule update --init --recursive tools/verilator
	git submodule update --init --recursive tools/sv2v
	git submodule update --init --recursive tools/morty
	git submodule update --init --recursive tools/bender
	git submodule update --init --recursive tools/riscv-isa-sim
	git submodule update --init tools/riscv-gnu-toolchain
	git -C tools/riscv-gnu-toolchain submodule update --init --depth 1 binutils gcc newlib

# ── Simulator builds ──────────────────────────────────────────────────────────
# Each design's Makefile resolves the full dependency chain:
#   preprocessing → Yosys instrumentation → Verilator + FuseSoC compilation
.PHONY: build-sims build-ibex build-proteus build-rocket
build-sims: build-ibex build-proteus build-rocket

build-ibex:
	$(MAKE) -C designs/ibex/cellift build-eval-sims

build-proteus:
	$(MAKE) -C designs/proteus/cellift build-eval-sims

build-rocket:
	$(MAKE) -C designs/chipyard/cellift-rocket build-eval-sims

# ── Clean ─────────────────────────────────────────────────────────────────────
.PHONY: clean-designs
clean-designs:
	$(MAKE) -C designs/ibex/cellift clean
	$(MAKE) -C designs/proteus/cellift clean
	$(MAKE) -C designs/chipyard/cellift-rocket clean

# ── Tools ─────────────────────────────────────────────────────────────────────
.PHONY: installtools cleantools
installtools:
	$(MAKE) -C tools installtools

cleantools:
	$(MAKE) -C tools cleantools

# ── Docker ────────────────────────────────────────────────────────────────────
.PHONY: docker-build docker-run docker-run-ro
docker-build:
	docker build \
	  --build-arg JOBS=$$(nproc) \
	  -t $(DOCKER_IMAGE):$(DOCKER_TAG) \
	  .

docker-run:
	@touch ~/.bash_history
	docker run -it --rm \
	  -e HOST_UID=$$(id -u) \
	  -e HOST_GID=$$(id -g) \
	  -v $$(pwd):/workspace \
	  -v sparc-sca-sbt-cache:/root/.sbt \
	  -v sparc-sca-ivy2-cache:/root/.ivy2 \
	  -v sparc-sca-coursier-cache:/root/.cache/coursier \
	  -v ~/.bash_history:/root/.bash_history \
	  -e CELLIFT_JOBS=$$(nproc) \
	  $(DOCKER_IMAGE):$(DOCKER_TAG)

docker-run-ro:
	docker run -it --rm \
	  -v $$(pwd):/workspace:ro \
	  $(DOCKER_IMAGE):$(DOCKER_TAG)
