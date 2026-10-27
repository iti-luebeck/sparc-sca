# SPDX-License-Identifier: MIT
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck

# SPARC-SCA Docker Image
# Two-stage build: 'builder' compiles all tools, 'runtime' ships only binaries.
#
# Build:  docker build --build-arg JOBS=$(nproc) -t sparc-sca .
# Run:    docker run -it --rm -v $(pwd):/workspace sparc-sca
#
# Note: the Yosys build clones ABC from GitHub during docker build; network
# access is required.

# ─── Build arguments ─────────────────────────────────────────────────────────
ARG UBUNTU_VERSION=22.04
ARG PREFIX=/opt/sparc-sca
ARG JOBS=4

# ══════════════════════════════════════════════════════════════════════════════
# STAGE 1 — builder: compile every tool and install to ${PREFIX}
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG PREFIX=/opt/sparc-sca
ARG JOBS=4

# ── Build-time dependencies ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core
    build-essential git ca-certificates curl wget unzip pkg-config \
    cmake make ninja-build \
    # Yosys / CellIFT
    bison flex gperf gawk \
    libffi-dev libreadline-dev tcl-dev zlib1g-dev \
    libboost-filesystem-dev libboost-thread-dev libboost-test-dev \
    libboost-program-options-dev libboost-iostreams-dev \
    # Verilator
    autoconf automake help2man perl libfl2 libfl-dev libssl-dev numactl \
    # Spike (riscv-isa-sim)
    device-tree-compiler \
    libboost-regex-dev libboost-system-dev \
    # bender — libgit2-sys uses system libgit2 when libgit2-dev is present
    libgit2-dev \
    # RISC-V GNU toolchain build deps
    texinfo libmpc-dev libmpfr-dev libgmp-dev \
    # Python (for venv + Yosys helpers)
    python3 python3-dev python3-pip python3-venv \
  && rm -rf /var/lib/apt/lists/*

# Create install prefix
RUN mkdir -p ${PREFIX}/bin ${PREFIX}/riscv

# ── Rust (for morty + bender) ────────────────────────────────────────────────
ENV CARGO_HOME=${PREFIX}/.cargo \
    RUSTUP_HOME=${PREFIX}/.rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --no-modify-path
ENV PATH=${PREFIX}/.cargo/bin:${PATH}

# ── Spike — RISC-V ISA simulator ─────────────────────────────────────────────
COPY tools/riscv-isa-sim/ /build/riscv-isa-sim/
RUN cd /build/riscv-isa-sim && \
    mkdir -p build && cd build && \
    ../configure --prefix=${PREFIX}/riscv && \
    make -j${JOBS} && make install && \
    rm -rf /build/riscv-isa-sim

# ── CellIFT Yosys (with power-leakage extension) ─────────────────────────────
# ABC is fetched from GitHub during the Yosys build (ABCPULL=1 in Yosys Makefile).
COPY tools/sparc-sca-yosys/ /build/yosys/
RUN cd /build/yosys && \
    make config-gcc && \
    make PREFIX=${PREFIX} -j${JOBS} && \
    make PREFIX=${PREFIX} install && \
    rm -rf /build/yosys

# ── Verilator (FST scratch files honour $TMPDIR) ─────────────────────────────────
COPY tools/verilator/ /build/verilator/
RUN cd /build/verilator && \
    autoconf && \
    ./configure --prefix=${PREFIX} && \
    make -j${JOBS} && make install && \
    rm -rf /build/verilator

# ── sv2v — pre-built binary (avoids a multi-GB GHC installation) ─────────────
# Binary matches the pinned submodule commit (tag v0.0.13).
RUN curl -fsSL \
      https://github.com/zachjs/sv2v/releases/download/v0.0.13/sv2v-Linux.zip \
      -o /tmp/sv2v.zip && \
    unzip -j /tmp/sv2v.zip -d /tmp/sv2v-bin && \
    install -m 755 /tmp/sv2v-bin/sv2v ${PREFIX}/bin/sv2v && \
    rm -rf /tmp/sv2v.zip /tmp/sv2v-bin

# ── morty — SystemVerilog pickler (Rust) ─────────────────────────────────────
COPY tools/morty/ /build/morty/
RUN cargo install --path /build/morty --root ${PREFIX} && \
    rm -rf /build/morty

# ── bender — RTL dependency manager (Rust) ───────────────────────────────────
# Install from crates.io at the pinned version (local submodule path triggers
# a cmake/libgit2 build-script failure that the published crate avoids).
RUN LIBGIT2_SYS_USE_PKG_CONFIG=1 \
    cargo install bender --version 0.28.2 --root ${PREFIX} && \
    rm -rf ~/.cargo/registry ~/.cargo/git

# ── RISC-V GNU toolchain (newlib, full multilib matrix) ──────────────────────
# Cloned directly inside Docker — avoids requiring the multi-GB submodule tree
# (gcc, binutils, llvm, glibc…) to be checked out on the host.
# Only the sub-submodules needed for a bare-metal newlib build are fetched.
RUN git clone --depth 1 https://github.com/riscv/riscv-gnu-toolchain.git /build/riscv-gnu-toolchain && \
    cd /build/riscv-gnu-toolchain && \
    git submodule update --init --depth 1 binutils gcc newlib && \
    ./configure \
        --prefix=${PREFIX}/riscv \
        --enable-multilib && \
    make -j${JOBS} && \
    rm -rf /build/riscv-gnu-toolchain

# ── Python virtual environment ───────────────────────────────────────────────
COPY design-processing/python-requirements.txt /build/dp-req.txt
COPY python-experiments/power_leakage_analysis/requirements.txt /build/power-req.txt

RUN python3 -m venv ${PREFIX}/python-venv && \
    ${PREFIX}/python-venv/bin/pip install --upgrade pip --quiet && \
    # Core tooling — use lowRISC forks of fusesoc/edalize required by primgen.py
    ${PREFIX}/python-venv/bin/pip install --quiet \
        "git+https://github.com/lowRISC/fusesoc.git@ot" \
        "git+https://github.com/lowRISC/edalize.git@ot" \
        ninja==1.10.2 \
        mako && \
    # Design-processing helpers
    ${PREFIX}/python-venv/bin/pip install --quiet -r /build/dp-req.txt && \
    # Power-leakage analysis stack
    ${PREFIX}/python-venv/bin/pip install --quiet -r /build/power-req.txt && \
    rm -f /build/*.txt


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 2 — runtime: lean image with pre-built tools only
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:${UBUNTU_VERSION} AS runtime

# OCI image metadata — links the GHCR package to the source repo and populates
# the package description. (Labels on the runtime stage end up in the shipped image.)
LABEL org.opencontainers.image.source="https://github.com/iti-luebeck/sparc-sca"
LABEL org.opencontainers.image.description="SPARC-SCA prebuilt environment: CellIFT Yosys, Verilator, Spike, sv2v and the RISC-V toolchain, ready to run the power side-channel leakage evaluation."
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

ARG DEBIAN_FRONTEND=noninteractive
ARG PREFIX=/opt/sparc-sca

# ── Runtime libraries only ───────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Yosys runtime deps
    libreadline8 libffi8 zlib1g tcl8.6 libtinfo6 \
    # Yosys BUILD deps, so `make install_yosys` works inside this image.
    # The cellift instrumentation pass (tools/sparc-sca-yosys/passes/cellift/)
    # is the one tool source this project edits, and it is compiled into the
    # yosys binary rather than loaded as a plugin -- so changing it means
    # rebuilding yosys, and without these the rebuild fails on a missing
    # tcl.h / readline.h / bison. tcl-dev is not optional: the instrumentation
    # entry point is `yosys -c instrument.ys.tcl`.
    bison flex pkg-config \
    libffi-dev libreadline-dev tcl-dev zlib1g-dev \
    # Spike runtime deps
    libboost-regex1.74.0 libboost-system1.74.0 \
    # Python (required by venv symlinks + pip-installed scripts)
    python3 python3-dev python3-venv \
    # C++ compiler — Verilator generates C++ and calls g++ to compile it
    g++ \
    # Build infrastructure needed when running experiments
    make ninja-build git curl wget perl \
    # Misc utilities
    ca-certificates unzip gnupg \
  && rm -rf /var/lib/apt/lists/*

# ── Java + sbt ────────────────────────────────────────────────────────────────
# Required for:
#   - Proteus: SpinalHDL elaboration  (sbt "runMain riscv.CoreDynamicExtMem")
#   - Rocket:  Chisel/FIRRTL elaboration (make verilog CONFIG=MySmallVMRocketConfig)
# Every design declares its own sbt version in project/build.properties and the
# launcher bootstraps it: chipyard pins 1.5.5, proteus pins ${SBT_VERSION}.
# Nothing inherits a version implicitly, so adding a design means adding its pin.
#
# The launcher is pinned here rather than installed from the scala-sbt Debian
# repo, which now serves only 2.0.x. That package cannot satisfy this repo: the
# 2.0.x launcher refuses to start below JDK 17, while chipyard's declared sbt
# 1.5.5 predates JDK 17 support -- so satisfying the launcher breaks the project
# it launches. Pinning makes the image reproducible regardless of what apt
# serves on the day it is built.
#
# Both JDKs are installed. JAVA_HOME defaults to 11, the stricter of the two
# constraints (sbt 1.5.5), and a build needing a newer JVM selects it per
# invocation with JAVA_HOME=${JAVA_HOME_17}.
ARG SBT_VERSION=1.10.7
RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-11-jdk \
      openjdk-17-jdk \
      # dtc: needed to compile the Chipyard bootrom during FIRRTL elaboration
      device-tree-compiler \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL "https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz" \
       -o /tmp/sbt.tgz \
  && tar -xzf /tmp/sbt.tgz -C /opt \
  && rm /tmp/sbt.tgz \
  && ln -s /opt/sbt/bin/sbt /usr/local/bin/sbt

ENV JAVA_HOME_11=/usr/lib/jvm/java-11-openjdk-amd64
ENV JAVA_HOME_17=/usr/lib/jvm/java-17-openjdk-amd64
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV PATH=/usr/lib/jvm/java-11-openjdk-amd64/bin:${PATH}

# ── Copy the installed tool prefix from the builder ──────────────────────────
COPY --from=builder ${PREFIX} ${PREFIX}
# Readable and traversable for any uid, so the image also works when run with
# --user $(id -u):$(id -g) instead of as root.
RUN chmod -R a+rX ${PREFIX}
# MPLCONFIGDIR points inside ${PREFIX}, which the line above makes readable but
# not writable. Matplotlib wants to write a font cache there on first import, so
# a non-root user gets "not a writable directory" and a fresh temporary cache per
# process -- noisy, and slower on every plot. World-writable fixes it for any uid.
RUN mkdir -p ${PREFIX}/matplotlib && chmod 1777 ${PREFIX}/matplotlib

# ── RV32 compatibility symlinks ───────────────────────────────────────────────
# Design Makefiles call riscv32-unknown-elf-* for RV32 targets.
# The custom toolchain installs as riscv64-unknown-elf-* with full multilib;
# both names resolve to the same binary.
RUN for t in gcc cpp ld ar nm as objcopy objdump strip readelf size; do \
      src="${PREFIX}/riscv/bin/riscv64-unknown-elf-${t}"; \
      if [ -f "$src" ]; then \
        ln -sf "$src" "${PREFIX}/riscv/bin/riscv32-unknown-elf-${t}"; \
      fi; \
    done

# ── Environment ───────────────────────────────────────────────────────────────
ENV PREFIX_CELLIFT=${PREFIX} \
    CELLIFT_META_ROOT=/workspace \
    SPARC_SCA_ROOT=/workspace \
    RISCV=${PREFIX}/riscv \
    CELLIFT_PYTHON_VENV=${PREFIX}/python-venv \
    CARGO_HOME=${PREFIX}/.cargo \
    RUSTUP_HOME=${PREFIX}/.rustup \
    CELLIFT_GCC=riscv32-unknown-elf-gcc \
    CELLIFT_OBJDUMP=riscv32-unknown-elf-objdump \
    CELLIFT_JOBS=4 \
    CELLIFT_ENV_SOURCED=yes \
    CELLIFT_ENV_VERSION=1 \
    CELLIFT_DESIGN_PROCESSING_ROOT=/workspace/design-processing \
    CELLIFT_PYTHON_COMMON=/workspace/design-processing/common/python_scripts \
    CELLIFT_YS=/workspace/design-processing/common/yosys \
    OPENTITAN_ROOT=/workspace/external-dependencies/cellift-opentitan \
    MPLCONFIGDIR=${PREFIX}/matplotlib

# SBT heap/stack — large Chisel designs (Rocket) need ≥4 GB heap.
# Use JAVA_TOOL_OPTIONS (picked up by all JVM invocations automatically)
# rather than SBT_OPTS: chipyard's SBT_BIN expands SBT_OPTS *after* -jar,
# turning JVM flags into sbt commands and breaking the build.
ENV JAVA_TOOL_OPTIONS="-Xmx8G -Xss8M"

ENV PATH=${PREFIX}/python-venv/bin:${PREFIX}/bin:${PREFIX}/riscv/bin:/usr/local/bin:${PATH}

RUN mkdir -p ${MPLCONFIGDIR} /workspace

# ── Shell experience ──────────────────────────────────────────────────────────
# Colored prompt: sparc-sca:/path$ — cyan label, blue path
# Persistent history: HISTFILE is set here; the host file is bind-mounted at
# runtime (see Makefile docker-run), so history survives container restarts.
RUN { \
      echo 'export PS1="\[\033[1;36m\]sparc-sca\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ "'; \
      echo 'export HISTFILE=/root/.bash_history'; \
      echo 'export HISTSIZE=10000 HISTFILESIZE=10000'; \
      echo 'shopt -s histappend'; \
      echo 'PROMPT_COMMAND="history -a"'; \
    } >> /root/.bashrc

# ── Smoke test ────────────────────────────────────────────────────────────────
RUN yosys --version && \
    verilator --version && \
    # The CellIFT pass must be present in the PATH yosys, and the options the
    # instrumentation script passes must exist in it. The pass is compiled in,
    # not loaded as a plugin, so a stale binary accepts instrument.ys.tcl and
    # silently emits a valid cellift.sv with the feature missing. Nothing warns
    # you at run time, so fail the build here instead.
    yosys -p 'help cellift' 2>/dev/null | grep -q -- '-track-power-leakage' && \
    yosys -p 'help cellift' 2>/dev/null | grep -q -- '-hd-taint-prev' && \
    yosys -p 'help cellift' 2>/dev/null | grep -q -- '-power-leakage-include-signals' && \
    sv2v --version && \
    spike --version 2>&1 | head -1 && \
    morty --help > /dev/null 2>&1 && \
    riscv64-unknown-elf-gcc --version | head -1 && \
    riscv32-unknown-elf-gcc --version | head -1 && \
    python3 -c "import fusesoc; print('fusesoc ok')" && \
    java -version 2>&1 | grep -v 'Picked up' | head -1 && \
    # sbt must actually START, not merely be on PATH: an sbt whose JDK is too
    # old installs cleanly and then fails on every invocation.
    sbt --version 2>&1 | tail -1 && \
    # Both JDKs must be present: designs select between them per build.
    ${JAVA_HOME_11}/bin/java -version 2>&1 | grep -v 'Picked up' | head -1 && \
    ${JAVA_HOME_17}/bin/java -version 2>&1 | grep -v 'Picked up' | head -1 && \
    which sbt && \
    # sbt just ran as root and left a root-owned /tmp/.sbt server directory in
    # this layer. A non-root run cannot create its socket inside it and fails
    # with AccessDeniedException before the build starts, so drop it here.
    rm -rf /tmp/.sbt

WORKDIR /workspace
CMD ["/bin/bash"]
