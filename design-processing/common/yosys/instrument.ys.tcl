# Copyright 2022 Flavien Solt, ETH Zurich.
# Licensed under the General Public License, Version 3.0, see LICENSE for details.
# SPDX-License-Identifier: GPL-3.0-only

if { [info exists ::env(VERILOG_INPUT)] }    { set VERILOG_INPUT $::env(VERILOG_INPUT) }       else { puts "Please set VERILOG_INPUT environment variable"; exit 1 }
if { [info exists ::env(VERILOG_OUTPUT)] }   { set VERILOG_OUTPUT $::env(VERILOG_OUTPUT) }     else { puts "Please set VERILOG_OUTPUT environment variable"; exit 1 }
if { [info exists ::env(TOP_MODULE)] }       { set TOP_MODULE $::env(TOP_MODULE) }             else { puts "Please set TOP_MODULE environment variable"; exit 1 }
if { [info exists ::env(DECOMPOSE_MEMORY)] } { set DECOMPOSE_MEMORY $::env(DECOMPOSE_MEMORY) } else { set DECOMPOSE_MEMORY 0 }
if { [info exists ::env(INSTRUMENTATION)] }      { set INSTRUMENTATION $::env(INSTRUMENTATION) }           else { puts "Please set INSTRUMENTATION environment variable"; exit 1 }
if { [info exists ::env(MUL_TO_ADDS)] }          { set MUL_TO_ADDS $::env(MUL_TO_ADDS) }                   else { set MUL_TO_ADDS 0 }
if { [info exists ::env(TRACK_POWER_LEAKAGE)] }  { set TRACK_POWER_LEAKAGE $::env(TRACK_POWER_LEAKAGE) }   else { set TRACK_POWER_LEAKAGE 1 }
# Scope of the HW/HD power counters. The cellift pass defaults to "top module
# only (backward compatible)", which silently EXCLUDES every submodule instance:
# on a core whose datapath sits in submodules that leaves the S-box, the ALU, the
# decoder and the shifter uncounted, while `_leak0` attribution signals still
# cross module boundaries, so signal attribution can name nets the counter never
# measured. Set
# POWER_LEAKAGE_SCOPE=auto to instrument every module carrying tainted signals
# and promote the counters hierarchically. Default stays "top" so other designs
# keep their existing baselines.
# Flatten before instrumenting. HD counters need a clock: the pass registers each
# net's previous value inside the module that owns it, and builds HD bits only
# `if (clk_wire)`. A purely combinational submodule has no clock port, so it can
# never contribute to HD at ANY scope setting, which structurally excludes a
# purely combinational ALU submodule -- where every software XOR/AND/OR happens. Flattening
# moves those nets into the top module, which has a clock.
if { [info exists ::env(POWER_LEAKAGE_FLATTEN)] }  { set POWER_LEAKAGE_FLATTEN $::env(POWER_LEAKAGE_FLATTEN) }   else { set POWER_LEAKAGE_FLATTEN 0 }

if { [info exists ::env(POWER_LEAKAGE_SCOPE)] }  { set POWER_LEAKAGE_SCOPE $::env(POWER_LEAKAGE_SCOPE) }   else { set POWER_LEAKAGE_SCOPE "top" }

# The opt -purge right after the cellift pass (below) folds/shares logic in the
# HW/HD popcount aggregation tree the pass just emitted, so per-net attribution
# can no longer separate a large share of the counter's own terms back to
# individual nets. POWER_LEAKAGE_SKIP_PURGE=1 skips that purge for a one-off
# diagnostic build, but it barely moves the reconciliation ceiling: the pass
# creates the per-net terms as anonymous
# (NEW_ID) wires, which write_verilog inlines whether or not the purge runs, so
# naming them in cellift.cc is the real fix. Default stays 0 so every existing
# build keeps its current tree.
if { [info exists ::env(POWER_LEAKAGE_SKIP_PURGE)] }  { set POWER_LEAKAGE_SKIP_PURGE $::env(POWER_LEAKAGE_SKIP_PURGE) }   else { set POWER_LEAKAGE_SKIP_PURGE 0 }

# The HD counter gates a transition on the taint of the CURRENT cycle:
#   hd = (data ^ data_prev) & taint
# so a tainted value overwritten by an UNTAINTED one scores exactly zero, even
# though that transition is physically key-dependent. With the taint source set
# to one share -- which is how every masked scenario in this tree is configured,
# the counterpart share being derived from the mask alone -- that is precisely
# Gigerl et al.'s C2 violation, and the model cannot see it. Measured on Ibex:
# HD is identically 0.00 in both groups over 400 traces, although the transition
# at those cycles is key-dependent by construction.
#
# POWER_LEAKAGE_HD_TAINT_PREV=1 registers the taint alongside the data and gates
# on (taint | taint_prev) instead, i.e. "a tainted value took part in this
# transition". Strictly more conservative; HW is unaffected. Costs one flop per
# instrumented wire pair.
#
# Default stays 0 because it changes every HD number published from this tree.
# It should become the default once those are re-validated.
if { [info exists ::env(POWER_LEAKAGE_HD_TAINT_PREV)] }  { set POWER_LEAKAGE_HD_TAINT_PREV $::env(POWER_LEAKAGE_HD_TAINT_PREV) }   else { set POWER_LEAKAGE_HD_TAINT_PREV 0 }

# Restrict which wires feed the HW/HD counters, as a comma-separated list of
# name substrings. Taint propagation is unaffected; only the aggregation narrows.
#
# This is the escape hatch from the cost of a flattened build. The counters sum
# the tainted bits with one 32-bit adder per bit, CHAINED, so simulation time
# scales with the instrumented bit count. Unflattened, POWER_LEAKAGE_SCOPE=top
# instruments only the top wrapper -- on Ibex that is 31 memory-boundary wires
# and nothing inside the CPU. POWER_LEAKAGE_FLATTEN=1 exposes the core's
# internals (466 wires) but takes the bit count to 16029 and a single 30k-cycle
# trace past 17 minutes. Flatten AND name the nets under investigation and both
# problems go away:
#
#   POWER_LEAKAGE_FLATTEN=1 POWER_LEAKAGE_INCLUDE_SIGNALS=register_file_i
#
# Empty (the default) keeps the historical behaviour: every instrumented wire in
# the scope contributes.
if { [info exists ::env(POWER_LEAKAGE_INCLUDE_SIGNALS)] }  { set POWER_LEAKAGE_INCLUDE_SIGNALS $::env(POWER_LEAKAGE_INCLUDE_SIGNALS) }   else { set POWER_LEAKAGE_INCLUDE_SIGNALS "" }

yosys read_verilog -defer -sv $VERILOG_INPUT
yosys hierarchy -top $TOP_MODULE -check
yosys timestamp hierarchy
yosys proc
yosys timestamp proc
yosys opt -purge
yosys timestamp opt

if {$DECOMPOSE_MEMORY == 1} {
    yosys memory
    yosys timestamp memory
    yosys proc
    yosys timestamp proc
    yosys opt -purge
    yosys timestamp opt
}

if {[string equal $INSTRUMENTATION "glift"]} {
    yosys techmap
    yosys timestamp techmap
    yosys breakdown_glift -exclude-mux
    yosys timestamp breakdown_glift
}

if { [string equal $INSTRUMENTATION "glift"] || [string equal $INSTRUMENTATION "cellift"] } {
    yosys pmuxtree
    yosys timestamp pmuxtree

    if {$MUL_TO_ADDS == 1} {
        yosys mul_to_adds
        yosys timestamp mul_to_adds
    }

    yosys opt -purge
    yosys timestamp opt
    if {$POWER_LEAKAGE_FLATTEN == 1} {
        yosys flatten
        yosys opt -purge
        yosys timestamp flatten
    }
    if {$TRACK_POWER_LEAKAGE == 1} {
        set HD_PREV_FLAG ""
        if {$POWER_LEAKAGE_HD_TAINT_PREV == 1} { set HD_PREV_FLAG "-hd-taint-prev" }
        set CNT_INCL_FLAG ""
        if { ! [string equal $POWER_LEAKAGE_INCLUDE_SIGNALS ""] } {
            set CNT_INCL_FLAG [list -power-leakage-include-signals $POWER_LEAKAGE_INCLUDE_SIGNALS]
        }
        # POWER_LEAKAGE_SCOPE: "top" (the default) instruments the top module
        # only, "auto" every module carrying taint, and anything else is a
        # comma-separated list of module base names handed to
        # -power-leakage-scope. That last path existed in the pass all along but
        # was unreachable from here: the dispatch below only tested for "auto",
        # so a module name silently fell through to top-module-only and the
        # requested scope was never instrumented. find_modules_by_name resolves
        # $paramod$HASH\\<base> forms, so a plain base name is enough.
        set SCOPE_FLAG ""
        if { ![string equal $POWER_LEAKAGE_SCOPE "auto"] && ![string equal $POWER_LEAKAGE_SCOPE "top"] } {
            set SCOPE_FLAG [list -power-leakage-scope $POWER_LEAKAGE_SCOPE]
        }
        if { [string equal $POWER_LEAKAGE_SCOPE "auto"] } {
            yosys cellift -exclude-signals clk_i,rst_ni,clock,reset,reset_wire_reset,g_clk,g_resetn,resetn,rstz,vdd,vd,gnd,gd,vcs,vc,RW0_clk,taint_meta_reset,meta_reset,metareset -imprecise-shl-sshl -imprecise-shr-sshr -track-power-leakage -power-leakage-auto-scope {*}$HD_PREV_FLAG {*}$CNT_INCL_FLAG -verbose
        } else {
        yosys cellift -exclude-signals clk_i,rst_ni,clock,reset,reset_wire_reset,g_clk,g_resetn,resetn,rstz,vdd,vd,gnd,gd,vcs,vc,RW0_clk,taint_meta_reset,meta_reset,metareset -imprecise-shl-sshl -imprecise-shr-sshr -track-power-leakage {*}$SCOPE_FLAG {*}$HD_PREV_FLAG {*}$CNT_INCL_FLAG -verbose
        }
    } else {
        yosys cellift -exclude-signals clk_i,rst_ni,clock,reset,reset_wire_reset,g_clk,g_resetn,resetn,rstz,vdd,vd,gnd,gd,vcs,vc,RW0_clk,taint_meta_reset,meta_reset,metareset -imprecise-shl-sshl -imprecise-shr-sshr -verbose
    }
    if {[string equal $INSTRUMENTATION "glift"]} {
        yosys breakdown_glift -exclude-mux
    }
    yosys timestamp cellift
    if {$POWER_LEAKAGE_SKIP_PURGE == 0} {
        yosys opt -purge
        yosys timestamp opt
    }
} elseif { ![string equal $INSTRUMENTATION "vanilla"] && ![string equal $INSTRUMENTATION "passthrough"] && [info exists INSTRUMENTATION] } {
    puts [format "Please unset INSTRUMENTATION environment variable, or set it either to cellift or to glift or vanilla (is currently: %s)" $INSTRUMENTATION]
    exit 1
}

yosys list_state_elements
yosys timestamp list_state_elements
yosys write_verilog -sv -noattr $VERILOG_OUTPUT
yosys timestamp write_verilog
yosys timestamp end
