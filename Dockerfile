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
COPY tools/bender/ /build/bender/
RUN LIBGIT2_SYS_USE_PKG_CONFIG=1 \
    cargo install --path /build/bender --root ${PREFIX} && \
    rm -rf /build/bender ~/.cargo/registry ~/.cargo/git

# ── Python virtual environment ───────────────────────────────────────────────
COPY design-processing/python-requirements.txt /build/dp-req.txt
COPY python-experiments/power_leakage_analysis/requirements.txt /build/power-req.txt

RUN python3 -m venv ${PREFIX}/python-venv && \
    ${PREFIX}/python-venv/bin/pip install --upgrade pip --quiet && \
    # Core tooling
    ${PREFIX}/python-venv/bin/pip install --quiet \
        fusesoc==1.12.0 \
        ninja==1.10.2 \
        edalize && \
    # Design-processing helpers
    ${PREFIX}/python-venv/bin/pip install --quiet -r /build/dp-req.txt && \
    # Power-leakage analysis stack
    ${PREFIX}/python-venv/bin/pip install --quiet -r /build/power-req.txt && \
    rm -f /build/*.txt


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 2 — runtime: lean image with pre-built tools only
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG PREFIX=/opt/sparc-sca

# ── Runtime libraries only ───────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Yosys runtime deps
    libreadline8 libffi8 zlib1g tcl8.6 libtinfo6 \
    # Spike runtime deps
    libboost-regex1.74.0 libboost-system1.74.0 \
    # Python (required by venv symlinks + pip-installed scripts)
    python3 python3-dev python3-venv \
    # RISC-V bare-metal toolchain (covers both RV32 and RV64 targets)
    gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
    # Build infrastructure needed when running experiments
    make ninja-build git curl wget perl \
    # Misc utilities
    ca-certificates unzip \
  && rm -rf /var/lib/apt/lists/*

# ── Copy the installed tool prefix from the builder ──────────────────────────
COPY --from=builder ${PREFIX} ${PREFIX}

# ── RV32 compatibility symlinks ───────────────────────────────────────────────
# The design Makefiles call riscv32-unknown-elf-{gcc,objdump,...}.
# The Ubuntu package ships riscv64-unknown-elf-* which compiles RV32 code
# correctly when the Makefiles pass -march=rv32imc -mabi=ilp32.
RUN for t in gcc cpp ld ar nm as objcopy objdump strip readelf size; do \
      src="/usr/bin/riscv64-unknown-elf-${t}"; \
      [ -f "$src" ] && ln -sf "$src" "/usr/local/bin/riscv32-unknown-elf-${t}"; \
    done

# ── Environment ───────────────────────────────────────────────────────────────
ENV PREFIX_CELLIFT=${PREFIX} \
    CELLIFT_META_ROOT=/workspace \
    SPARC_SCA_ROOT=/workspace \
    RISCV=${PREFIX}/riscv \
    CELLIFT_PYTHON_VENV=${PREFIX}/python-venv \
    CARGO_HOME=${PREFIX}/.cargo \
    RUSTUP_HOME=${PREFIX}/.rustup \
    CELLIFT_GCC=riscv64-unknown-elf-gcc \
    CELLIFT_OBJDUMP=riscv64-unknown-elf-objdump \
    CELLIFT_JOBS=4 \
    CELLIFT_ENV_SOURCED=yes \
    CELLIFT_ENV_VERSION=1 \
    CELLIFT_DESIGN_PROCESSING_ROOT=/workspace/design-processing \
    CELLIFT_PYTHON_COMMON=/workspace/design-processing/common/python_scripts \
    CELLIFT_YS=/workspace/design-processing/common/yosys \
    MPLCONFIGDIR=${PREFIX}/matplotlib

ENV PATH=${PREFIX}/python-venv/bin:${PREFIX}/bin:${PREFIX}/riscv/bin:/usr/local/bin:${PATH}

RUN mkdir -p ${MPLCONFIGDIR} /workspace

# ── Smoke test ────────────────────────────────────────────────────────────────
RUN yosys --version && \
    verilator --version && \
    sv2v --version && \
    spike --version 2>&1 | head -1 && \
    morty --help > /dev/null 2>&1 && \
    riscv64-unknown-elf-gcc --version | head -1 && \
    python3 -c "import fusesoc; print('fusesoc ok')"

WORKDIR /workspace
CMD ["/bin/bash"]
