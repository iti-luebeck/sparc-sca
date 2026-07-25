#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck

# run_full_audit.sh — Full SPARC leakage audit: inventory, cleanup, simulator
# rebuild, and evaluation re-run for Ibex, Proteus, and Rocket.
#
# Phases:
#   0) Audit  — inventory scripts, binaries and existing results (read-only, never aborts)
#   1) Clean  — delete build/, results, traces and sw/multi_* per processor
#               (keeps generated/ Yosys .sv files, sw/scenario_*, taint_data/)
#   2) Build  — rebuild all Verilator simulators (each timed separately)
#   3) Eval   — run AES (unmasked + masked) and Kyber (unmasked) per processor
#
# Usage:
#   ./run_full_audit.sh [options]
#
# Options:
#   --skip-audit      Skip Phase 0 (audit inventory)
#   --skip-clean      Skip Phase 1 (cleanup)
#   --skip-build      Skip Phase 2 (simulator build)
#   --skip-eval       Skip Phase 3 (evaluations)
#   --only-ibex       Run Ibex-only (build/eval); skip Proteus and Rocket
#   --skip-kyber      Skip all Kyber evaluations (run AES only)
#   --skip-aes        Skip all AES evaluations (run Kyber only)
#   --only-aes        Run AES evaluations only (alias for --skip-kyber)
#   --only-kyber      Run Kyber evaluations only (alias for --skip-aes)
#   --jobs N          Parallel simulation workers per evaluation (default: 8)
#   -h, --help        Show this help and exit
#
# Processor order: Ibex → Rocket → Proteus (sequential; Proteus last because it has the longest Kyber eval).
# Within each evaluation, --jobs workers run simulations in parallel.
# Simlens: AES = 30 000 cycles; Kyber = 2 000 000 cycles.
#
# Evaluation order: Phase 3a runs AES (unmasked + masked) on ALL processors
# before Phase 3b runs Kyber (unmasked) on all processors.
#
# Output is tee'd to run_full_audit_<timestamp>.log next to this script.
# A machine-readable timing table is written to run_full_audit_timing.tsv.
# Workload-specific timing tables: run_full_audit_timing_aes.tsv and
# run_full_audit_timing_kyber.tsv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_SH="${SCRIPT_DIR}/env.sh"

# Design directories — default to repo-relative paths (correct for Docker and
# for the unified sparc-sca repo layout).  Override by exporting IBEX_DIR,
# PROTEUS_DIR, or ROCKET_DIR before invoking this script (or via env.sh).
: "${IBEX_DIR:=${SCRIPT_DIR}/designs/ibex/cellift}"
: "${PROTEUS_DIR:=${SCRIPT_DIR}/designs/proteus/cellift}"
: "${ROCKET_DIR:=${SCRIPT_DIR}/designs/chipyard/cellift-rocket}"

JOBS=8
AES_SIMLEN=30000
AES_N_UNMASKED=20
AES_N_MASKED=100
KYBER_SIMLEN=2000000
KYBER_N_UNMASKED=20

SKIP_AUDIT=0
SKIP_CLEAN=0
SKIP_BUILD=0
SKIP_EVAL=0
ONLY_IBEX=0
SKIP_KYBER=0
SKIP_AES=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-audit) SKIP_AUDIT=1; shift ;;
        --skip-clean) SKIP_CLEAN=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-eval)  SKIP_EVAL=1;  shift ;;
        --only-ibex)  ONLY_IBEX=1;  shift ;;
        --skip-kyber) SKIP_KYBER=1; shift ;;
        --skip-aes)   SKIP_AES=1;   shift ;;
        --only-aes)   SKIP_KYBER=1; shift ;;
        --only-kyber) SKIP_AES=1;   shift ;;
        --jobs)
            JOBS="$2"; shift 2
            if ! [[ "$JOBS" =~ ^[0-9]+$ ]] || [[ "$JOBS" -lt 1 ]]; then
                echo "ERROR: --jobs must be a positive integer"; exit 1
            fi ;;
        -h|--help)
            sed -n '/^# run_full_audit/,/^[^#]/{ /^#/{ s/^# \?//; p } }' "$0"
            exit 0 ;;
        *) echo "ERROR: unknown option: $1"; exit 1 ;;
    esac
done

# ── Logging ───────────────────────────────────────────────────────────────────
BUILD_EVAL_DIR="${SCRIPT_DIR}/paper/build_evaluation"
mkdir -p "$BUILD_EVAL_DIR"
LOGFILE="${BUILD_EVAL_DIR}/run_full_audit_$(date +%Y%m%d_%H%M%S).log"
TIMING_TSV="${BUILD_EVAL_DIR}/run_full_audit_timing.tsv"
AES_TIMING_TSV="${BUILD_EVAL_DIR}/run_full_audit_timing_aes.tsv"
KYBER_TIMING_TSV="${BUILD_EVAL_DIR}/run_full_audit_timing_kyber.tsv"
CURRENT_WORKLOAD_TSV=""   # set to AES_TIMING_TSV or KYBER_TIMING_TSV during eval phases

# Tee all stdout and stderr to the log file while keeping terminal output.
exec > >(tee -a "$LOGFILE") 2>&1

printf "label\telapsed_s\tstatus\n" > "$TIMING_TSV"
[[ "$SKIP_AES"   -eq 0 ]] && printf "label\telapsed_s\tstatus\n" > "$AES_TIMING_TSV"
[[ "$SKIP_KYBER" -eq 0 ]] && printf "label\telapsed_s\tstatus\n" > "$KYBER_TIMING_TSV"

echo "==================================================================="
echo "  CellIFT Full Audit  —  $(date)"
echo "==================================================================="
echo "  env.sh       : ${ENV_SH}"
echo "  log          : ${LOGFILE}"
echo "  timing       : ${TIMING_TSV}"
echo "  timing_aes   : ${AES_TIMING_TSV}"
echo "  timing_kyber : ${KYBER_TIMING_TSV}"
echo "  jobs         : ${JOBS}"
echo "  mode    : only_ibex=${ONLY_IBEX}"
echo "  skip    : audit=${SKIP_AUDIT} clean=${SKIP_CLEAN} build=${SKIP_BUILD} eval=${SKIP_EVAL} aes=${SKIP_AES} kyber=${SKIP_KYBER}"
echo "==================================================================="
echo ""

# ── Source env.sh (native only) ───────────────────────────────────────────────
# Skip if: already sourced (user ran `source env.sh` first), or running inside
# Docker (/.dockerenv is created by the Docker runtime in every container).
if [[ "${CELLIFT_ENV_SOURCED:-}" == "yes" ]]; then
    echo "env already configured (CELLIFT_ENV_SOURCED=yes)"
elif [[ -f "/.dockerenv" ]]; then
    echo "Docker environment detected — skipping env.sh (tools pre-installed)"
elif [[ -f "$ENV_SH" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_SH"
    echo "env.sh sourced (CELLIFT_ENV_SOURCED=${CELLIFT_ENV_SOURCED:-})"
else
    echo "FATAL: env.sh not found at ${ENV_SH} and not running in Docker"
    exit 1
fi

# OPENTITAN_ROOT: needed by the Ibex Makefile (CURR_OPENTITAN_ROOT).
# env.sh sets it on native; default to the repo-relative path in Docker.
: "${OPENTITAN_ROOT:=${SCRIPT_DIR}/external-dependencies/cellift-opentitan}"
export OPENTITAN_ROOT
echo "  OPENTITAN_ROOT : ${OPENTITAN_ROOT}"
echo ""

# ── Helper functions ──────────────────────────────────────────────────────────

banner() {
    echo ""
    echo "============================================================"
    printf "  %s\n" "$1"
    echo "============================================================"
}

# skipped_step LABEL
# Records a zero-elapsed "skipped" row in TIMING_TSV without running anything.
skipped_step() {
    local label="$1"
    printf "%s\t%d\tskipped\n" "${label}" 0 >> "$TIMING_TSV"
    if [[ -n "$CURRENT_WORKLOAD_TSV" ]]; then
        printf "%s\t%d\tskipped\n" "${label}" 0 >> "$CURRENT_WORKLOAD_TSV"
    fi
}

# timed_step LABEL CMD [ARGS...]
# Runs CMD ARGS, prints wall-clock time, appends to TIMING_TSV.
# Propagates the exit code; timing is always recorded even on failure.
timed_step() {
    local label="$1"
    shift
    local t0 t1 elapsed rc mm ss
    t0=$(date +%s)
    echo ""
    echo ">>> START [$(date '+%H:%M:%S')]: ${label}"
    rc=0
    "$@" || rc=$?
    t1=$(date +%s)
    elapsed=$(( t1 - t0 ))
    mm=$(( elapsed / 60 ))
    ss=$(( elapsed % 60 ))
    if [[ $rc -eq 0 ]]; then
        echo ">>> DONE  [$(date '+%H:%M:%S')]: ${label} — ${mm}m ${ss}s (${elapsed}s total)"
        printf "%s\t%d\tok\n" "${label}" "${elapsed}" >> "$TIMING_TSV"
        if [[ -n "$CURRENT_WORKLOAD_TSV" ]]; then
            printf "%s\t%d\tok\n" "${label}" "${elapsed}" >> "$CURRENT_WORKLOAD_TSV"
        fi
    else
        echo ">>> FAIL  [$(date '+%H:%M:%S')]: ${label} — ${mm}m ${ss}s (exit rc=${rc})"
        printf "%s\t%d\tFAILED(rc=%d)\n" "${label}" "${elapsed}" "$rc" >> "$TIMING_TSV"
        if [[ -n "$CURRENT_WORKLOAD_TSV" ]]; then
            printf "%s\t%d\tFAILED(rc=%d)\n" "${label}" "${elapsed}" "$rc" >> "$CURRENT_WORKLOAD_TSV"
        fi
    fi
    return $rc
}

# timed_step_logged LABEL LOGFILE CMD [ARGS...]
# Like timed_step, but CMD's stdout+stderr go directly to LOGFILE, bypassing
# the main tee pipe.  Only the START/DONE/FAIL lines appear in the main log.
# This prevents large subprocess output (simulations, make, signal tables) from
# bloating the main log and from stalling the terminal after Ctrl+C.
timed_step_logged() {
    local label="$1"
    local logfile="$2"
    shift 2
    local t0 t1 elapsed rc mm ss
    t0=$(date +%s)
    echo ""
    echo ">>> START [$(date '+%H:%M:%S')]: ${label}"
    echo "          log: ${logfile}"
    rc=0
    "$@" >"$logfile" 2>&1 || rc=$?
    t1=$(date +%s)
    elapsed=$(( t1 - t0 ))
    mm=$(( elapsed / 60 ))
    ss=$(( elapsed % 60 ))
    if [[ $rc -eq 0 ]]; then
        echo ">>> DONE  [$(date '+%H:%M:%S')]: ${label} — ${mm}m ${ss}s (${elapsed}s total)"
        printf "%s\t%d\tok\n" "${label}" "${elapsed}" >> "$TIMING_TSV"
        if [[ -n "$CURRENT_WORKLOAD_TSV" ]]; then
            printf "%s\t%d\tok\n" "${label}" "${elapsed}" >> "$CURRENT_WORKLOAD_TSV"
        fi
    else
        echo ">>> FAIL  [$(date '+%H:%M:%S')]: ${label} — ${mm}m ${ss}s (exit rc=${rc})"
        echo "          see: ${logfile}"
        printf "%s\t%d\tFAILED(rc=%d)\n" "${label}" "${elapsed}" "$rc" >> "$TIMING_TSV"
        if [[ -n "$CURRENT_WORKLOAD_TSV" ]]; then
            printf "%s\t%d\tFAILED(rc=%d)\n" "${label}" "${elapsed}" "$rc" >> "$CURRENT_WORKLOAD_TSV"
        fi
    fi
    return $rc
}

validate_ibex_results() {
    local base="$IBEX_DIR"
    local missing=0

    local required=()
    if [[ "$SKIP_AES" -eq 0 ]]; then
        required+=(
            "results_aes/unmasked/welch_summary.txt"
            "results_aes/masked/welch_summary.txt"
            "results_aes/run_manifest_refined.json"
            "results_aes/root_cause_report_refined.md"
            "results_aes/publication_summary_refined.md"
            "results_aes/unmasked/leakage_regions.json"
            "results_aes/masked/leakage_regions.json"
        )
    fi
    if [[ "$SKIP_KYBER" -eq 0 ]]; then
        required+=(
            "results_kyber/unmasked/welch_summary.txt"
            "results_kyber/run_manifest_refined.json"
            "results_kyber/root_cause_report_refined.md"
            "results_kyber/publication_summary_refined.md"
            "results_kyber/unmasked/leakage_regions.json"
        )
    fi

    echo "  Checking required Ibex result files..."
    local rel
    for rel in "${required[@]}"; do
        if [[ -f "${base}/${rel}" ]]; then
            echo "    ok  ${rel}"
        else
            echo "    MISS ${rel}"
            missing=$((missing + 1))
        fi
    done

    echo "  Key Welch metrics (Ibex):"
    if [[ -f "${base}/results_aes/unmasked/welch_summary.txt" ]]; then
        echo "    AES unmasked:"
        grep -En "\[hamming_weight_counter_t0\]|\[hamming_distance_counter_t0\]|first_leaky_cycle|max_t" \
            "${base}/results_aes/unmasked/welch_summary.txt" | sed 's/^/      /'
    fi
    if [[ -f "${base}/results_aes/masked/welch_summary.txt" ]]; then
        echo "    AES masked:"
        grep -En "\[hamming_weight_counter_t0\]|\[hamming_distance_counter_t0\]|first_leaky_cycle|max_t" \
            "${base}/results_aes/masked/welch_summary.txt" | sed 's/^/      /'
    fi
    if [[ -f "${base}/results_kyber/unmasked/welch_summary.txt" ]]; then
        echo "    Kyber unmasked:"
        grep -En "\[hamming_weight_counter_t0\]|\[hamming_distance_counter_t0\]|first_leaky_cycle|max_t|nan" \
            "${base}/results_kyber/unmasked/welch_summary.txt" | sed 's/^/      /'
    fi

    if [[ "$missing" -gt 0 ]]; then
        echo "ERROR: Ibex validation failed: ${missing} required file(s) missing."
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0 — AUDIT (read-only inventory, never aborts the script)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_AUDIT" -eq 0 ]]; then
    banner "Phase 0 — Audit (read-only inventory)"

    # Scripts expected in every processor's cellift/ directory.
    REQUIRED_SCRIPTS=(
        gen_scenarios.py
        compile_scenarios.sh
        run_multi_trace_tvla.sh
        multi_tvla_driver.py
        run_signal_correlation.sh
        run_full_evaluation.sh
        run_eval_preflight.sh
        leakage_signals.py
        pc_at_leakage.py
        tvla_analysis.py
        cycle_leakage_quantifier.py
        generate_root_cause_report.py
        generate_publication_summary.py
    )

    # audit_processor LABEL DIR REQUIRED_SVS_COLON_SEP BIN [BIN ...]
    # REQUIRED_SVS_COLON_SEP: colon-separated list of generated/out/*.sv stems
    #   that must exist before the builds can proceed (e.g. "cellift:vanilla").
    #   glift and passthrough are never built and are NOT checked.
    audit_processor() {
        local label="$1"
        local dir="$2"
        local required_svs_raw="$3"
        shift 3
        local expected_bins=("$@")

        echo ""
        echo "  ── ${label}  (${dir})"

        # Required scripts
        echo "  Scripts:"
        local n_miss_s=0
        for s in "${REQUIRED_SCRIPTS[@]}"; do
            if [[ -f "${dir}/${s}" ]]; then
                printf "    ok  %s\n" "$s"
            else
                printf "  MISS  %s\n" "$s"
                n_miss_s=$(( n_miss_s + 1 ))
            fi
        done
        if [[ $n_miss_s -gt 0 ]]; then
            echo "  WARNING: ${n_miss_s} script(s) missing"
        fi

        # Simulator binaries
        echo "  Simulator binaries:"
        local n_miss_b=0
        for b in "${expected_bins[@]}"; do
            fp="${dir}/${b}"
            if [[ -x "$fp" ]]; then
                local sz
                sz=$(stat -c '%s' "$fp" 2>/dev/null || echo "?")
                printf "    ok  %-70s  %s B\n" "$b" "$sz"
            else
                printf "  MISS  %s\n" "$b"
                n_miss_b=$(( n_miss_b + 1 ))
            fi
        done
        if [[ $n_miss_b -gt 0 ]]; then
            echo "  NOTE: ${n_miss_b} simulator(s) missing — will be rebuilt in Phase 2."
        fi

        # Existing result directories
        echo "  Result directories:"
        local found=0
        for rdir in results results_aes results_kyber; do
            dp="${dir}/${rdir}"
            if [[ -d "$dp" ]]; then
                local sz
                sz=$(du -sh "$dp" 2>/dev/null | cut -f1 || echo "?")
                printf "    %s/  (%s)\n" "$rdir" "$sz"
                found=1
            fi
        done
        for glob in "${dir}"/results_publication_* "${dir}"/results_smoke_*; do
            if [[ -d "$glob" ]]; then
                local sz
                sz=$(du -sh "$glob" 2>/dev/null | cut -f1 || echo "?")
                printf "    %s/  (%s)\n" "$(basename "$glob")" "$sz"
                found=1
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "    (none)"
        fi

        # Generated .sv files (only the ones actually needed for the builds we run)
        # glift and passthrough are never built — not checked.
        echo "  Yosys-generated .sv needed for build:"
        local n_miss_sv=0
        local sv
        # Split colon-separated list without touching IFS
        for sv in ${required_svs_raw//:/ }; do
            fp="${dir}/generated/out/${sv}.sv"
            if [[ -f "$fp" ]]; then
                local sz
                sz=$(stat -c '%s' "$fp" 2>/dev/null || echo "?")
                printf "    ok  generated/out/%s.sv  (%s B)\n" "$sv" "$sz"
            else
                printf "  MISS  generated/out/%s.sv  ← BLOCKER for build\n" "$sv"
                n_miss_sv=$(( n_miss_sv + 1 ))
            fi
        done
        if [[ $n_miss_sv -gt 0 ]]; then
            echo "  ERROR: ${n_miss_sv} required .sv file(s) missing — re-run Yosys instrumentation before Phase 2."
        fi
    }

    # Ibex: csvlog + cellift_trace use cellift.sv; vanilla_trace uses vanilla.sv (via Makefile).
    # signal attribution uses run_cellift_fasttrace (Vibex_tiny_soc)
    IBEX_BINS=(
        "build/run_cellift_csvlog_0.1/default-verilator/Vibex_tiny_soc"
        "build/run_cellift_fasttrace_0.1/default-verilator/Vibex_tiny_soc"
        "build/run_vanilla_trace_0.1/default-verilator/Vibex_tiny_soc"
        "build/run_vanilla_trace_fst_0.1/default-verilator/Vibex_tiny_soc"
    )
    # Proteus: csvlog + fasttrace use cellift.sv; vanilla_trace uses ../Core.v directly
    # (run_vanilla_trace.core does NOT reference generated/out/vanilla.sv).
    # signal attribution uses run_cellift_fasttrace (Vproteus_tiny_soc)
    PROTEUS_BINS=(
        "build/run_cellift_csvlog_0.1/default-verilator/Vproteus_tiny_soc"
        "build/run_cellift_fasttrace_0.1/default-verilator/Vproteus_tiny_soc"
        "build/run_cellift_fasttrace_fst_0.1/default-verilator/Vproteus_tiny_soc"
        "build/run_vanilla_trace_0.1/default-verilator/Vproteus_tiny_soc"
        "build/run_vanilla_trace_fst_0.1/default-verilator/Vproteus_tiny_soc"
    )
    # Rocket: csvlog + cellift_trace use cellift.sv; vanilla_trace uses vanilla.sv (via Makefile).
    # signal attribution uses run_cellift_fasttrace (Vtop_tiny_soc)
    ROCKET_BINS=(
        "build/run_cellift_csvlog_0.1/default-verilator/Vtop_tiny_soc"
        "build/run_cellift_fasttrace_0.1/default-verilator/Vtop_tiny_soc"
        "build/run_cellift_fasttrace_fst_0.1/default-verilator/Vtop_tiny_soc"
        "build/run_vanilla_trace_0.1/default-verilator/Vtop_tiny_soc"
        "build/run_vanilla_trace_fst_0.1/default-verilator/Vtop_tiny_soc"
    )

    audit_processor "Ibex"    "$IBEX_DIR"    "cellift:vanilla"  "${IBEX_BINS[@]}"
    audit_processor "Proteus" "$PROTEUS_DIR" "cellift"          "${PROTEUS_BINS[@]}"
    audit_processor "Rocket"  "$ROCKET_DIR"  "cellift:vanilla"  "${ROCKET_BINS[@]}"

    echo ""
    echo "  Audit complete (read-only — nothing deleted or built)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_CLEAN" -eq 0 ]]; then
    banner "Phase 1 — Cleanup"
    echo "  Keeps: generated/ (Yosys .sv),  sw/scenario_*,  taint_data/"
    [[ "$SKIP_AES"   -eq 1 ]] && echo "  Keeps: results_aes/,  sw/multi_aes_*   (--only-kyber / --skip-aes)"
    [[ "$SKIP_KYBER" -eq 1 ]] && echo "  Keeps: results_kyber/, sw/multi_kyber_* (--only-aes / --skip-kyber)"
    echo ""

    clean_processor() {
        local label="$1"
        local dir="$2"
        echo "  ${label}:"

        # Verilator compiled binaries (kept when --skip-build is set)
        if [[ "$SKIP_BUILD" -eq 0 ]] && [[ -d "${dir}/build" ]]; then
            local sz
            sz=$(du -sh "${dir}/build" 2>/dev/null | cut -f1 || echo "?")
            echo "    rm -rf build/  (${sz})"
            rm -rf "${dir}/build"
        elif [[ "$SKIP_BUILD" -eq 1 ]] && [[ -d "${dir}/build" ]]; then
            echo "    keep build/  (--skip-build)"
        fi

        # Result directories
        for rdir in results; do
            if [[ -d "${dir}/${rdir}" ]]; then
                echo "    rm -rf ${rdir}/"
                rm -rf "${dir:?}/${rdir}"
            fi
        done
        if [[ "$SKIP_AES" -eq 0 ]] && [[ -d "${dir}/results_aes" ]]; then
            echo "    rm -rf results_aes/"
            rm -rf "${dir:?}/results_aes"
        fi
        if [[ "$SKIP_KYBER" -eq 0 ]] && [[ -d "${dir}/results_kyber" ]]; then
            echo "    rm -rf results_kyber/"
            rm -rf "${dir:?}/results_kyber"
        fi
        for glob in "${dir}"/results_publication_* "${dir}"/results_smoke_*; do
            if [[ -d "$glob" ]]; then
                echo "    rm -rf $(basename "$glob")/"
                rm -rf "$glob"
            fi
        done
        if [[ "$SKIP_AES" -eq 0 ]]; then
            for f in "${dir}"/results_aes_*.log; do
                if [[ -f "$f" ]]; then
                    echo "    rm $(basename "$f")"
                    rm -f "$f"
                fi
            done
        fi

        # Simulation traces
        if [[ -d "${dir}/traces" ]]; then
            local n
            n=$(find "${dir}/traces" \( -name "*.vcd" -o -name "*.fst" \) 2>/dev/null | wc -l)
            if [[ "$n" -gt 0 ]]; then
                echo "    rm traces/*.vcd/*.fst  (${n} files)"
                find "${dir}/traces" \( -name "*.vcd" -o -name "*.fst" \) -delete
            fi
        fi

        # Generated multi-trace TVLA scenario directories (filtered by active workloads)
        local n_multi_aes n_multi_kyber
        n_multi_aes=$(find "${dir}/sw" -maxdepth 1 -type d -name "multi_aes_*" 2>/dev/null | wc -l)
        n_multi_kyber=$(find "${dir}/sw" -maxdepth 1 -type d -name "multi_kyber_*" 2>/dev/null | wc -l)
        if [[ "$SKIP_AES" -eq 0 ]] && [[ "$n_multi_aes" -gt 0 ]]; then
            echo "    rm -rf sw/multi_aes_*  (${n_multi_aes} directories)"
            find "${dir}/sw" -maxdepth 1 -type d -name "multi_aes_*" | xargs -r rm -rf
        fi
        if [[ "$SKIP_KYBER" -eq 0 ]] && [[ "$n_multi_kyber" -gt 0 ]]; then
            echo "    rm -rf sw/multi_kyber_*  (${n_multi_kyber} directories)"
            find "${dir}/sw" -maxdepth 1 -type d -name "multi_kyber_*" | xargs -r rm -rf
        fi

        echo "    done."
        echo ""
    }

    clean_processor "Ibex"    "$IBEX_DIR"
    clean_processor "Proteus" "$PROTEUS_DIR"
    clean_processor "Rocket"  "$ROCKET_DIR"

    echo "  Cleanup complete."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — BUILD SIMULATORS
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    banner "Phase 2 — Build Simulators"

    # ── Ibex ──────────────────────────────────────────────────────────────────
    # Instrumentation: before_instrumentation → vanilla.sv → cellift.sv (Yosys).
    # Simulator builds: all four evaluation targets via Makefile rules.
    banner "Phase 2.1 — Ibex"
    (
        cd "$IBEX_DIR"
        timed_step_logged "ibex:instr:before"            "${BUILD_EVAL_DIR}/build--ibex--instr-before.log"        make before_instrumentation
        timed_step_logged "ibex:instr:vanilla"           "${BUILD_EVAL_DIR}/build--ibex--instr-vanilla.log"       make generated/out/vanilla.sv
        timed_step_logged "ibex:instr:cellift"           "${BUILD_EVAL_DIR}/build--ibex--instr-cellift.log"       make generated/out/cellift.sv
        timed_step_logged "ibex:build:csvlog"            "${BUILD_EVAL_DIR}/build--ibex--csvlog.log"              make build/run_cellift_csvlog_0.1/default-verilator/Vibex_tiny_soc
        timed_step_logged "ibex:build:fasttrace"         "${BUILD_EVAL_DIR}/build--ibex--fasttrace.log"           make build/run_cellift_fasttrace_0.1/default-verilator/Vibex_tiny_soc
        timed_step_logged "ibex:build:vanilla_trace"     "${BUILD_EVAL_DIR}/build--ibex--vanilla-trace.log"       make build/run_vanilla_trace_0.1/default-verilator/Vibex_tiny_soc
        timed_step_logged "ibex:build:vanilla_trace_fst" "${BUILD_EVAL_DIR}/build--ibex--vanilla-trace-fst.log"   make build/run_vanilla_trace_fst_0.1/default-verilator/Vibex_tiny_soc
    )

    # ── Proteus ───────────────────────────────────────────────────────────────
    if [[ "$ONLY_IBEX" -eq 0 ]]; then
    # Proteus: Core.v is generated from SpinalHDL if absent (requires sbt + Java 17).
    # Instrumentation: before_instrumentation -> vanilla.sv -> cellift.sv (Yosys + compaction).
    # Simulator builds: all five evaluation targets via Makefile rules.
    banner "Phase 2.2 — Proteus"
    (
        cd "$PROTEUS_DIR"
        timed_step_logged "proteus:instr:before"         "${BUILD_EVAL_DIR}/build--proteus--instr-before.log"     make before_instrumentation
        timed_step_logged "proteus:instr:cellift"        "${BUILD_EVAL_DIR}/build--proteus--instr-cellift.log"    make generated/out/cellift.sv
        timed_step_logged "proteus:build:csvlog"         "${BUILD_EVAL_DIR}/build--proteus--csvlog.log"           make build/run_cellift_csvlog_0.1/default-verilator/Vproteus_tiny_soc
        timed_step_logged "proteus:build:fasttrace"      "${BUILD_EVAL_DIR}/build--proteus--fasttrace.log"        make build/run_cellift_fasttrace_0.1/default-verilator/Vproteus_tiny_soc
        timed_step_logged "proteus:build:fasttrace_fst"  "${BUILD_EVAL_DIR}/build--proteus--fasttrace-fst.log"    make build/run_cellift_fasttrace_fst_0.1/default-verilator/Vproteus_tiny_soc
        timed_step_logged "proteus:build:vanilla_trace"  "${BUILD_EVAL_DIR}/build--proteus--vanilla-trace.log"    make build/run_vanilla_trace_0.1/default-verilator/Vproteus_tiny_soc
        timed_step_logged "proteus:build:vanilla_trace_fst" "${BUILD_EVAL_DIR}/build--proteus--vanilla-trace-fst.log" make build/run_vanilla_trace_fst_0.1/default-verilator/Vproteus_tiny_soc
    )
    fi

    # ── Rocket ────────────────────────────────────────────────────────────────
    if [[ "$ONLY_IBEX" -eq 0 ]]; then
    # Instrumentation: before_instrumentation → vanilla.sv → cellift.sv (Yosys + compaction).
    # Simulator builds: all five evaluation targets via Makefile rules.
    banner "Phase 2.3 — Rocket"
    (
        cd "$ROCKET_DIR"
        timed_step_logged "rocket:instr:before"              "${BUILD_EVAL_DIR}/build--rocket--instr-before.log"        make before_instrumentation
        timed_step_logged "rocket:instr:vanilla"             "${BUILD_EVAL_DIR}/build--rocket--instr-vanilla.log"       make generated/out/vanilla.sv
        timed_step_logged "rocket:instr:cellift"             "${BUILD_EVAL_DIR}/build--rocket--instr-cellift.log"       make generated/out/cellift.sv
        timed_step_logged "rocket:build:csvlog"              "${BUILD_EVAL_DIR}/build--rocket--csvlog.log"              make build/run_cellift_csvlog_0.1/default-verilator/Vtop_tiny_soc
        timed_step_logged "rocket:build:fasttrace"           "${BUILD_EVAL_DIR}/build--rocket--fasttrace.log"           make build/run_cellift_fasttrace_0.1/default-verilator/Vtop_tiny_soc
        timed_step_logged "rocket:build:fasttrace_fst"       "${BUILD_EVAL_DIR}/build--rocket--fasttrace-fst.log"       make build/run_cellift_fasttrace_fst_0.1/default-verilator/Vtop_tiny_soc
        timed_step_logged "rocket:build:vanilla_trace"       "${BUILD_EVAL_DIR}/build--rocket--vanilla-trace.log"       make build/run_vanilla_trace_0.1/default-verilator/Vtop_tiny_soc
        timed_step_logged "rocket:build:vanilla_trace_fst"   "${BUILD_EVAL_DIR}/build--rocket--vanilla-trace-fst.log"   make build/run_vanilla_trace_fst_0.1/default-verilator/Vtop_tiny_soc
    )
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — EVALUATIONS
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_EVAL" -eq 0 ]]; then
    banner "Phase 3 — Evaluations  (jobs=${JOBS})"
    echo "  AES:   simlen=${AES_SIMLEN}  n_unmasked=${AES_N_UNMASKED}  n_masked=${AES_N_MASKED}"
    echo "  Kyber: simlen=${KYBER_SIMLEN}  n_unmasked=${KYBER_N_UNMASKED}  (unmasked only)"
    echo ""

    # run_eval DIR LABEL WORKLOAD RESULTS_SUBDIR SIMLEN N_UNMASKED [EXTRA_ARGS...]
    # Verbose subprocess output goes to BUILD_EVAL_DIR/<label>.log (not main log).
    run_eval() {
        local dir="$1"
        local label="$2"
        local workload="$3"
        local results_subdir="$4"
        local simlen="$5"
        local n_unmasked="$6"
        shift 6
        # Remaining positional args (e.g. --n-masked N, --skip-masked) are forwarded.
        local eval_log="${BUILD_EVAL_DIR}/${label//:/--}.log"
        (
            cd "$dir"
            timed_step_logged "$label" "$eval_log" \
                ./run_full_evaluation.sh \
                    --workload   "$workload"      \
                    --simlen     "$simlen"         \
                    --n-unmasked "$n_unmasked"     \
                    --jobs       "$JOBS"           \
                    --results    "$results_subdir" \
                    "$@"
        )
    }

    # ── Phase 3a — AES Evaluations (all processors) ───────────────────────────
    if [[ "$SKIP_AES" -eq 0 ]]; then
        banner "Phase 3a — AES Evaluations (unmasked + masked, all processors)"
        CURRENT_WORKLOAD_TSV="$AES_TIMING_TSV"

        run_eval "$IBEX_DIR" "ibex:eval:aes" \
            aes results_aes "$AES_SIMLEN" "$AES_N_UNMASKED" \
            --n-masked "$AES_N_MASKED"

        if [[ "$ONLY_IBEX" -eq 0 ]]; then
            run_eval "$ROCKET_DIR" "rocket:eval:aes" \
                aes results_aes "$AES_SIMLEN" "$AES_N_UNMASKED" \
                --n-masked "$AES_N_MASKED"
            run_eval "$PROTEUS_DIR" "proteus:eval:aes" \
                aes results_aes "$AES_SIMLEN" "$AES_N_UNMASKED" \
                --n-masked "$AES_N_MASKED"
        fi

        CURRENT_WORKLOAD_TSV=""
    else
        skipped_step "ibex:eval:aes"
        if [[ "$ONLY_IBEX" -eq 0 ]]; then
            skipped_step "proteus:eval:aes"
            skipped_step "rocket:eval:aes"
        fi
    fi

    # ── Phase 3b — Kyber Evaluations (all processors) ─────────────────────────
    if [[ "$SKIP_KYBER" -eq 0 ]]; then
        banner "Phase 3b — Kyber Evaluations (unmasked, all processors)"
        CURRENT_WORKLOAD_TSV="$KYBER_TIMING_TSV"

        run_eval "$IBEX_DIR" "ibex:eval:kyber" \
            kyber results_kyber "$KYBER_SIMLEN" "$KYBER_N_UNMASKED" \
            --skip-masked

        if [[ "$ONLY_IBEX" -eq 0 ]]; then
            run_eval "$ROCKET_DIR" "rocket:eval:kyber" \
                kyber results_kyber "$KYBER_SIMLEN" "$KYBER_N_UNMASKED" \
                --skip-masked
            run_eval "$PROTEUS_DIR" "proteus:eval:kyber" \
                kyber results_kyber "$KYBER_SIMLEN" "$KYBER_N_UNMASKED" \
                --skip-masked
        fi

        CURRENT_WORKLOAD_TSV=""
    else
        skipped_step "ibex:eval:kyber"
        if [[ "$ONLY_IBEX" -eq 0 ]]; then
            skipped_step "proteus:eval:kyber"
            skipped_step "rocket:eval:kyber"
        fi
    fi

    timed_step "ibex:validate:results" validate_ibex_results

    if [[ "$ONLY_IBEX" -eq 1 ]]; then
        echo ""
        echo "Ibex-only mode enabled: skipping Proteus and Rocket evaluations."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
banner "Summary"

echo ""
echo "Timing breakdown (combined):"
echo ""
if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' "$TIMING_TSV"
else
    cat "$TIMING_TSV"
fi

if [[ "$SKIP_AES" -eq 0 ]]; then
    echo ""
    echo "AES timing:"
    echo ""
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' "$AES_TIMING_TSV"
    else
        cat "$AES_TIMING_TSV"
    fi
fi

if [[ "$SKIP_KYBER" -eq 0 ]]; then
    echo ""
    echo "Kyber timing:"
    echo ""
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' "$KYBER_TIMING_TSV"
    else
        cat "$KYBER_TIMING_TSV"
    fi
fi

if [[ "$SKIP_EVAL" -eq 0 ]]; then
    echo ""
    echo "Expected result files:"
    _summary_rpaths=()
    [[ "$SKIP_AES"   -eq 0 ]] && _summary_rpaths+=("results_aes/unmasked/welch_summary.txt" "results_aes/masked/welch_summary.txt")
    [[ "$SKIP_KYBER" -eq 0 ]] && _summary_rpaths+=("results_kyber/unmasked/welch_summary.txt")
    for entry in "${IBEX_DIR}:ibex" "${PROTEUS_DIR}:proteus" "${ROCKET_DIR}:rocket"; do
        dir="${entry%%:*}"
        lbl="${entry##*:}"
        for rpath in "${_summary_rpaths[@]}"; do
            fp="${dir}/${rpath}"
            if [[ -f "$fp" ]]; then
                printf "  ok  %-10s  %s\n" "$lbl" "$rpath"
            else
                printf "  MISS  %-10s  %s\n" "$lbl" "$rpath"
            fi
        done
    done
fi

echo ""
echo "Log          : ${LOGFILE}"
echo "Timing       : ${TIMING_TSV}"
echo "Timing AES   : ${AES_TIMING_TSV}"
echo "Timing Kyber : ${KYBER_TIMING_TSV}"
echo ""
echo "Done."
