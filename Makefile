# SPDX-License-Identifier: MIT
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck

SHELL := /bin/bash

# checkout-designs and checkout-tools work without env.sh (host-side git ops).
# Docker targets never need env.sh.
# generate-rtl calls sbt/Java directly — no CellIFT env required.
# help must work on a fresh clone — it is what tells you to source env.sh.
# check-no-host-paths and check-csvlog-notrace are pure greps over the tree, so
# they must work on a bare clone -- they are the pre-publication checks.
# `check` itself is not exempt: it also runs check-taintloader, which compiles
# against the container/native toolchain and so needs the environment.
EXEMPT_TARGETS := help docker-pull docker-build docker-push docker-run docker-run-ro checkout-designs checkout-tools generate-rtl check-no-host-paths check-csvlog-notrace
# An empty MAKECMDGOALS means the default goal (help), which is also exempt.
ifneq (,$(MAKECMDGOALS))
ifeq (,$(filter $(EXEMPT_TARGETS),$(MAKECMDGOALS)))
ifndef CELLIFT_ENV_SOURCED
$(error Please source env.sh first — see README.md)
endif
ifneq "$(CELLIFT_ENV_VERSION)" "1"
$(error env.sh is out of date — please source env.sh again)
endif
endif
endif

DOCKER_IMAGE ?= sparc-sca
DOCKER_TAG   ?= latest
GHCR_IMAGE   ?= ghcr.io/iti-luebeck/sparc-sca

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
	@echo "    make docker-pull        pull the prebuilt image from GHCR and tag it locally"
	@echo "    make docker-build       build the sparc-sca Docker image from source"
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
	# sourceware.org rate-limits anonymous HTTPS *clones* with HTTP 429 (binutils,
	# newlib).  Its ref advertisement keeps answering, so the host looks healthy
	# while clones fail.  Retry over the git:// daemon, which is not behind that
	# throttle.  HTTPS stays the default because port 9418 is blocked on many
	# networks; the commits are pinned by SHA, so the unauthenticated transport
	# does not weaken integrity.
	git -C tools/riscv-gnu-toolchain submodule update --init --depth 1 binutils gcc newlib \
	  || git -C tools/riscv-gnu-toolchain \
	       -c url."git://sourceware.org/git/".insteadOf=https://sourceware.org/git/ \
	       submodule update --init --depth 1 binutils gcc newlib

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
.PHONY: installtools cleantools install_yosys
installtools:
	$(MAKE) -C tools installtools

# Rebuild ONLY Yosys. It is the one tool whose source this repo changes --
# tools/sparc-sca-yosys/passes/cellift/ is the instrumentation pass -- and the
# pass is compiled INTO yosys rather than loaded as a plugin, so editing it has
# no effect until yosys is rebuilt. `installtools` would rebuild the RISC-V
# toolchain too (~1.5 h); this is the targeted version.
install_yosys:
	$(MAKE) -C tools install_yosys

cleantools:
	$(MAKE) -C tools cleantools

# ── Checks ────────────────────────────────────────────────────────────────────
# Two defects that were silent in the flow and are cheap to assert against.
.PHONY: check check-taintloader check-csvlog-notrace
check: check-csvlog-notrace check-taintloader check-no-host-paths

# Absolute paths from a developer's machine must never reach a published tree:
# they break on every other clone and leak the author's directory layout. Before
# this check existed the artifact shipped ~40 of them -- a NAS trace archive, a
# personal tool under /home/..., and a Chipyard conda toolchain -- including one
# that made the evaluation die with "mkdir: cannot create directory".
#
# Vendored upstream files are exempt: coremark's build logs and Proteus's logo
# SVGs carry their original authors' paths and are not ours to rewrite.
HOST_PATH_RE ?= (/home/[a-z][a-z0-9_-]+|/mnt/[a-z0-9_-]+)/
# Pathspecs are relative to whichever repo git runs in, so these are
# repo-relative and simply match nothing in the repos that lack them.
HOST_PATH_EXCLUDES ?= \
  :!examples \
  :!docs/logo \
  :!**/coremark.map \
  :!**/run[0-9].log \
  :!**/*.svg
check-no-host-paths:
	@fail=0; \
	for r in . designs/ibex designs/proteus designs/chipyard; do \
	  hits=$$(git -C $$r grep -I -n -E '$(HOST_PATH_RE)' -- . $(HOST_PATH_EXCLUDES) 2>/dev/null) || true; \
	  if [ -n "$$hits" ]; then \
	    echo "FAIL absolute host paths in $$r:"; \
	    echo "$$hits" | sed 's/^/    /'; fail=1; \
	  else echo "ok   $$r"; fi; \
	done; \
	exit $$fail


# A csvlog target must never pass --trace. toplevel_csv.cc has no dump call of
# its own, so the flag is invisible at the call site: the tracing comes from the
# shared dv/testbench.h under #if VM_TRACE, which --trace defines, and the
# runners point TRACEFILE at /dev/null -- so a full waveform was generated every
# cycle and discarded at the device. ~6x per trace, and OOM on a flattened build.
check-csvlog-notrace:
	@fail=0; \
	for f in designs/*/cellift/run_cellift_csvlog*.core \
	         designs/*/cellift-rocket/run_cellift_csvlog*.core; do \
	  [ -e "$$f" ] || continue; \
	  if grep -qE "^[[:space:]]*- '--trace" "$$f"; then \
	    echo "FAIL $$f carries --trace"; fail=1; \
	  else echo "ok   $$f"; fi; \
	done; \
	exit $$fail

# taintloader.cc must reject non-records instead of pushing them with whatever
# is on the stack. Needs the container toolchain for svdpi.h.
check-taintloader:
	@svdpi=$$(dirname $$(find $(PREFIX_CELLIFT) -name svdpi.h 2>/dev/null | head -1)); \
	test -n "$$svdpi" || { echo "svdpi.h not found under $(PREFIX_CELLIFT)"; exit 1; }; \
	g++ -O1 -I"$$svdpi" -o /tmp/test_taintloader \
	    design-processing/common/dv/test_taintloader.cc \
	    design-processing/common/dv/taintloader.cc && \
	/tmp/test_taintloader design-processing/common/dv/testdata/taints_commented.txt 2

# ── Docker ────────────────────────────────────────────────────────────────────
.PHONY: docker-pull docker-build docker-push docker-run docker-run-ro
docker-pull:
	docker pull $(GHCR_IMAGE):$(DOCKER_TAG)
	docker tag $(GHCR_IMAGE):$(DOCKER_TAG) $(DOCKER_IMAGE):$(DOCKER_TAG)

# Publish to GHCR. Needs `docker login ghcr.io` with a token carrying
# write:packages -- see README.md. Pushes the dated tag first so the previous
# image stays reachable if the new one has to be rolled back.
docker-push:
	docker tag $(DOCKER_IMAGE):$(DOCKER_TAG) $(GHCR_IMAGE):$(DOCKER_TAG)
	docker push $(GHCR_IMAGE):$(DOCKER_TAG)

docker-build:
	docker build \
	  --build-arg JOBS=$$(nproc) \
	  -t $(DOCKER_IMAGE):$(DOCKER_TAG) \
	  .

docker-run:
	@touch ~/.bash_history
	docker run -it --rm \
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
