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

# The RISC-V GNU toolchain is cloned inside the build rather than copied from
# tools/riscv-gnu-toolchain (see the builder stage), so it is pinned here and
# this ref must equal that submodule's commit. It decides the GCC every scenario
# is compiled with, and a different GCC emits a different program from the same
# source -- every cycle count moves. A full commit SHA, not a tag, so it cannot
# move and `make check-toolchain-pin` can compare it with the submodule offline.
# 33eb59a = release 2026.10.26: GCC 16.1.0, binutils 2.47, newlib 4.6.0.
ARG RISCV_GNU_TOOLCHAIN_REF=33eb59addcd65b8fd71f69fb42ccd2ea31bcbaf1

# Rust builds morty and bender. Pinned for the same reason as the RISC-V
# toolchain: `stable` is whatever rustup serves on the day, and morty's
# Cargo.lock pins time 0.3.30, which no longer compiles from Rust 1.100 on
# (E0282). 1.99.1 is the release the 2026-10-27 image was built with.
ARG RUST_VERSION=1.99.1

# Second, independent toolchain: CURRENT UPSTREAM Yosys and Verilator, installed
# beside the CellIFT fork rather than replacing it.
#
# Why both: the SPARC flow depends on the forked Yosys in tools/sparc-sca-yosys
# (the cellift pass is compiled into the binary, not loaded as a plugin) and on
# the patched Verilator in tools/verilator. Neither can be swapped for upstream.
# But upstream brings things the fork does not have -- notably the slang
# SystemVerilog frontend, which reads heavily parameterised SV directly and can
# stand in for the morty + sv2v stages.
#
# The two never collide: PATH keeps resolving `yosys`/`verilator` to the SPARC
# toolchain, and the upstream pair is reached only through $UPSTREAM_YOSYS /
# $UPSTREAM_VERILATOR.
ARG UPSTREAM_PREFIX=/opt/upstream
ARG UPSTREAM_YOSYS_TAG=v0.70
ARG UPSTREAM_VERILATOR_TAG=v5.052

# Source commit of this build, recorded as an OCI label so a published image
# names the tree it came from. `make docker-build` passes it.
ARG VCS_REF=unknown

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
ARG RUST_VERSION
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain ${RUST_VERSION} --no-modify-path
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

# ── Verilator (with FST integer-overflow fix) ─────────────────────────────────
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
# Cloned at RISCV_GNU_TOOLCHAIN_REF, the same commit tools/riscv-gnu-toolchain
# pins. It used to clone master, so the GCC in the image was whatever upstream
# had on the day of the build and silently differed from the pinned one.
ARG RISCV_GNU_TOOLCHAIN_REF
RUN git init -q /build/riscv-gnu-toolchain && \
    cd /build/riscv-gnu-toolchain && \
    git remote add origin https://github.com/riscv/riscv-gnu-toolchain.git && \
    git fetch -q --depth 1 origin ${RISCV_GNU_TOOLCHAIN_REF} && \
    git checkout -q FETCH_HEAD && \
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
# STAGE 1b — upstream-builder: current Yosys (with slang) and Verilator 5
#
# Deliberately a SEPARATE stage from the builder above. That one compiles the
# CellIFT Yosys and the patched Verilator with the distro's default gcc-11;
# upstream Yosys needs C++20, CMake >= 3.28 and Python >= 3.11, and setting
# CC/CXX to gcc-12 for those would silently change how the SPARC tools are
# built too. Isolating it keeps the SPARC toolchain unaffected by this addition.
#
# Stays on the same Ubuntu release as the runtime so the glibc matches.
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:${UBUNTU_VERSION} AS upstream-builder

ARG DEBIAN_FRONTEND=noninteractive
ARG JOBS=4
ARG UPSTREAM_PREFIX
ARG UPSTREAM_YOSYS_TAG
ARG UPSTREAM_VERILATOR_TAG

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential g++-12 gcc-12 lld bison flex gawk git ca-certificates \
      tcl-dev libreadline-dev libffi-dev zlib1g-dev pkg-config \
      python3 python3-pip python3.11 \
      autoconf help2man perl libfl-dev ccache ninja-build \
  && rm -rf /var/lib/apt/lists/* \
  && pip3 install --no-cache-dir "cmake>=3.28,<4"

ENV CC=gcc-12 CXX=g++-12

# Upstream Yosys. --recurse-submodules is what pulls in the slang frontend;
# without it the build succeeds and `read_slang` simply does not exist.
RUN git clone --depth 1 --branch ${UPSTREAM_YOSYS_TAG} \
      --recurse-submodules --shallow-submodules \
      https://github.com/YosysHQ/yosys.git /build/yosys && \
    cd /build/yosys && \
    cmake -B build -G Ninja . \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=${UPSTREAM_PREFIX} \
      -DPython3_EXECUTABLE=/usr/bin/python3.11 \
      -DYOSYS_ENABLE_UNIT_TESTS=OFF && \
    cmake --build build --parallel ${JOBS} && \
    cmake --install build --strip && \
    rm -rf /build/yosys

# Verilator 5. The SPARC simulation flow keeps using the patched Verilator 4
# from tools/verilator; this one is for host-side lint and elaboration.
RUN git clone --depth 1 --branch ${UPSTREAM_VERILATOR_TAG} \
      https://github.com/verilator/verilator.git /build/verilator && \
    cd /build/verilator && autoconf && \
    ./configure --prefix=${UPSTREAM_PREFIX} && \
    make -j${JOBS} && make install && \
    rm -rf /build/verilator


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 2 — runtime: lean image with pre-built tools only
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:${UBUNTU_VERSION} AS runtime

# OCI image metadata — links the GHCR package to the source repo and populates
# the package description. (Labels on the runtime stage end up in the shipped image.)
ARG VCS_REF
LABEL org.opencontainers.image.source="https://github.com/iti-luebeck/sparc-sca"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.description="SPARC-SCA prebuilt environment: CellIFT Yosys, Verilator, Spike, sv2v and the RISC-V toolchain, ready to run the power side-channel leakage evaluation. Also ships upstream Yosys (with slang) and Verilator 5 under /opt/upstream."
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

ARG DEBIAN_FRONTEND=noninteractive
ARG PREFIX=/opt/sparc-sca
ARG UPSTREAM_PREFIX

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
    # Upstream toolchain runtime: Verilator 5 emits C++20, so it needs a newer
    # compiler than the g++ above; gawk and ccache are on Verilator's own
    # runtime dependency list, and `time` is what the flow scripts measure with.
    g++-12 gawk ccache time \
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

# ── Copy the installed tool prefixes from the builders ───────────────────────
COPY --from=builder ${PREFIX} ${PREFIX}
COPY --from=upstream-builder ${UPSTREAM_PREFIX} ${UPSTREAM_PREFIX}
# Readable and traversable for any uid, so the image also works when run with
# --user $(id -u):$(id -g) instead of as root.
RUN chmod -R a+rX ${PREFIX} ${UPSTREAM_PREFIX}

# Upstream Yosys links shared libraries out of its own prefix. It is added to
# the loader path, NOT to PATH: `yosys` and `verilator` must keep resolving to
# the SPARC toolchain, or every existing flow silently changes tool underneath
# itself.
RUN echo ${UPSTREAM_PREFIX}/lib > /etc/ld.so.conf.d/upstream.conf && ldconfig
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
    MPLCONFIGDIR=${PREFIX}/matplotlib \
    UPSTREAM_PREFIX=${UPSTREAM_PREFIX} \
    UPSTREAM_YOSYS=${UPSTREAM_PREFIX}/bin/yosys \
    UPSTREAM_YOSYS_CONFIG=${UPSTREAM_PREFIX}/bin/yosys-config \
    UPSTREAM_VERILATOR=${UPSTREAM_PREFIX}/bin/verilator

# SBT heap/stack — large Chisel designs (Rocket) need ≥4 GB heap.
# Use JAVA_TOOL_OPTIONS (picked up by all JVM invocations automatically)
# rather than SBT_OPTS: chipyard's SBT_BIN expands SBT_OPTS *after* -jar,
# turning JVM flags into sbt commands and breaking the build.
ENV JAVA_TOOL_OPTIONS="-Xmx8G -Xss8M"

ENV PATH=${PREFIX}/python-venv/bin:${PREFIX}/bin:${PREFIX}/riscv/bin:/usr/local/bin:${PATH}

RUN mkdir -p ${MPLCONFIGDIR} /workspace

# Home for a non-root run (sparc.sh runs as the host UID with HOME=/sbt-home and
# -Duser.home=/sbt-home, then mounts the host's sbt/ivy/coursier caches beneath
# it). Docker auto-creates any missing parent of a mount point as root:root
# 0755, which that user cannot write -- sbt then fails to create .cache/sbt.
# Pre-creating both world-writable means Docker only adds the leaf mount points.
RUN mkdir -p /sbt-home/.cache && chmod 777 /sbt-home /sbt-home/.cache

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
    # Upstream pair, reached only through the UPSTREAM_* variables -- and PATH
    # must still resolve to the SPARC pair, which is what the flow runs.
    ${UPSTREAM_YOSYS} -V && \
    ${UPSTREAM_VERILATOR} --version && \
    # slang is the reason upstream Yosys is here at all; without the submodule
    # the build succeeds and read_slang simply does not exist.
    ${UPSTREAM_YOSYS} -p 'help read_slang' > /dev/null 2>&1 && \
    test "$(command -v yosys)" = "${PREFIX}/bin/yosys" && \
    test "$(command -v verilator)" = "${PREFIX}/bin/verilator" && \
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
