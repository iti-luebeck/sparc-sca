#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck
#
# sparc.sh — run a command inside the SPARC-SCA toolchain container.
#
# The container image carries the pinned RISC-V toolchain, the CellIFT Yosys
# fork, Verilator and the Python environment, and already exports
# CELLIFT_ENV_SOURCED=yes / RISCV / PATH, so `env.sh` must NOT be sourced inside
# it.  This wrapper is the host-side launcher: it is the scripted counterpart of
# `make docker-run`, which hardcodes `-it` and therefore dies with "the input
# device is not a TTY" in any non-interactive context.
#
# It mounts the repo read-write and runs as the host UID/GID, so nothing it
# creates is left root-owned — a container started without --user leaves build
# outputs that the host user can then neither overwrite nor delete.
#
# Usage:
#   ./sparc.sh <command> [args...]      run a command (cwd is preserved)
#   ./sparc.sh shell                   interactive shell, if a TTY is present
#
# Examples:
#   ./sparc.sh make build-ibex
#   ./sparc.sh ./run_full_audit.sh --help
#   cd designs/proteus/cellift && \
#       ../../../sparc.sh ./run_full_evaluation.sh --n-unmasked 2 --n-masked 2 --simlen 3000
#
# A target ending in .sh or .py that lacks the execute bit is invoked through
# its interpreter rather than failing with "Permission denied": several scripts
# in this tree are checked in non-executable.
#
# Image: DOCKER_IMAGE / DOCKER_TAG. By default the local sparc-sca:latest that
# `make docker-build` and `make docker-pull` produce, and the published
# ghcr.io/iti-luebeck/sparc-sca:latest when there is no local one.
#
# SPARC_SCA_TOOLCHAIN overrides the RISC-V toolchain the container compiles
# firmware with. Each GCC version emits a DIFFERENT program from identical
# source, which re-bases every cycle count, so comparing against results built
# elsewhere means compiling with the toolchain they were built with:
#
#   SPARC_SCA_TOOLCHAIN=/path/to/riscv-toolchain ./sparc.sh make build-ibex
#
# The directory must contain bin/riscv64-unknown-elf-gcc; it is mounted
# read-only and exported as $RISCV.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER_TAG="${DOCKER_TAG:-latest}"
if [[ -z "${DOCKER_IMAGE:-}" ]]; then
    if docker image inspect "sparc-sca:${DOCKER_TAG}" >/dev/null 2>&1; then
        DOCKER_IMAGE=sparc-sca
    else
        DOCKER_IMAGE=ghcr.io/iti-luebeck/sparc-sca
    fi
fi

if [[ -f /.dockerenv ]]; then
    echo "sparc.sh: already inside a container — run the command directly." >&2
    exit 1
fi

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '/^# sparc.sh/,/^$/{ /^#/{ s/^# \?//; p } }' "${BASH_SOURCE[0]}"
    exit 0
fi

# Preserve the caller's directory inside the container, so a relative command
# such as ./run_full_evaluation.sh works from any design directory.
HOST_PWD="$(pwd -P)"
case "$HOST_PWD" in
    "$REPO_ROOT"|"$REPO_ROOT"/*) ;;
    *) echo "sparc.sh: must be run from inside $REPO_ROOT (cwd: $HOST_PWD)" >&2; exit 1 ;;
esac
REL_PWD="$(realpath --relative-to="$REPO_ROOT" "$HOST_PWD")"
[[ "$REL_PWD" == "." ]] && WORKDIR="/workspace" || WORKDIR="/workspace/$REL_PWD"

TTY_FLAGS=(-i)
if [[ "$1" == "shell" ]]; then
    shift
    set -- bash "$@"
    [[ -t 0 && -t 1 ]] && TTY_FLAGS=(-i -t)
fi

# Checked-in scripts without the execute bit: call the interpreter explicitly.
TARGET="$1"
if [[ "$TARGET" == */* || -e "$TARGET" ]] && [[ ! -x "$TARGET" ]] && [[ -f "$TARGET" ]]; then
    case "$TARGET" in
        *.sh) set -- bash "$@" ;;
        *.py) set -- python3 "$@" ;;
    esac
fi

# sbt/ivy/coursier caches are mounted because Rocket and Proteus RTL generation
# needs them; they are harmless for every other command.
mkdir -p ~/.sbt ~/.ivy2 ~/.cache/coursier ~/.cache/sbt

# An explicitly pinned toolchain, mounted read-only and exported as $RISCV so
# the scenario Makefiles pick it up ahead of the image's own.
TOOLCHAIN_ARGS=()
if [[ -n "${SPARC_SCA_TOOLCHAIN:-}" ]]; then
    if [[ ! -x "${SPARC_SCA_TOOLCHAIN}/bin/riscv64-unknown-elf-gcc" ]]; then
        echo "sparc.sh: SPARC_SCA_TOOLCHAIN=${SPARC_SCA_TOOLCHAIN} has no" \
             "bin/riscv64-unknown-elf-gcc" >&2
        exit 1
    fi
    TOOLCHAIN_ARGS=(
        -v "${SPARC_SCA_TOOLCHAIN}:/opt/riscv-pinned:ro"
        -e RISCV=/opt/riscv-pinned
        -e SPARC_SCA_RISCV_BIN=/opt/riscv-pinned/bin
    )
fi

# -Duser.home is required because the container runs as the host UID and no
# /etc/passwd entry exists for it. getpwuid() then fails and the JVM falls back
# to the literal string "?" for user.home; chipyard invokes sbt as
# `java -jar sbt-launch.jar`, whose boot properties build a repository URL from
# ${user.home} -- yielding file:////?/.sbt/..., which sbt rejects with "URI has
# a query component". $HOME does not help: the JVM reads user.home from the
# passwd database, not the environment. The image pre-creates /sbt-home
# world-writable for exactly this.
exec docker run "${TTY_FLAGS[@]}" --rm \
    "${TOOLCHAIN_ARGS[@]+"${TOOLCHAIN_ARGS[@]}"}" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/sbt-home \
    -e JAVA_TOOL_OPTIONS="-Xmx8G -Xss8M -Duser.home=/sbt-home" \
    -e MPLCONFIGDIR=/workspace/.matplotlib \
    -e CELLIFT_JOBS="${CELLIFT_JOBS:-$(nproc)}" \
    -v "$REPO_ROOT:/workspace" \
    -v "$HOME/.sbt:/sbt-home/.sbt" \
    -v "$HOME/.ivy2:/sbt-home/.ivy2" \
    -v "$HOME/.cache/coursier:/sbt-home/.cache/coursier" \
    -v "$HOME/.cache/sbt:/sbt-home/.cache/sbt" \
    -w "$WORKDIR" \
    "${DOCKER_IMAGE}:${DOCKER_TAG}" \
    "$@"
