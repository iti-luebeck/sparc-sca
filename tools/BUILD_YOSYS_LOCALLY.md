# Rebuilding Yosys after changing the CellIFT pass

`tools/sparc-sca-yosys/passes/cellift/` is the one tool source this project
actually edits, and the pass is **compiled into the yosys binary** rather than
loaded as a plugin. So a change there has no effect until yosys is rebuilt — and
nothing warns you, because the stock binary keeps producing a perfectly valid
`generated/out/cellift.sv`, just without your change in it.

Use the project's own target. Do not hand-roll a `docker run` around the Yosys
Makefile; `installtools` would work too but also rebuilds the RISC-V toolchain
(~1.5 h).

## Native install

`PREFIX_CELLIFT` is already yours (`$HOME/prefix-cellift` by default), so:

```bash
source env.sh
make install_yosys
```

## Inside the container

`PREFIX_CELLIFT` is `/opt/sparc-sca` there and is root-owned, while `sparc.sh`
runs the container as your own user on purpose (otherwise it leaves root-owned
build outputs in the repo). Override the prefix:

```bash
./sparc.sh make -C tools install_yosys \
    PREFIX_CELLIFT=/workspace/tools/_yosys-local YOSYS_ENABLE_ABC=0
```

The runtime image carries Yosys's build dependencies (`bison flex pkg-config
tcl-dev libffi-dev libreadline-dev zlib1g-dev`) precisely so this target works.
TCL is **not** optional: the instrumentation entry point is
`yosys -c instrument.ys.tcl`, so an `ENABLE_TCL=0` build cannot run the flow.
`YOSYS_ENABLE_ABC=0` is safe and saves build time — nothing in
`design-processing/common/yosys/` calls `abc`. Leave it at the default for a
real install.

An image older than 2026-10-27 lacks those build dependencies. Against one of
those, install them first; that needs root, so not through `sparc.sh`:

```bash
docker run -i --rm -v "$PWD:/workspace" -w /workspace \
    ghcr.io/iti-luebeck/sparc-sca:v1.0 bash -c '
    apt-get update -qq && apt-get install -y -qq \
        bison flex pkg-config tcl-dev libffi-dev libreadline-dev zlib1g-dev
    make -C tools install_yosys PREFIX_CELLIFT=/workspace/tools/_yosys-local \
                                YOSYS_ENABLE_ABC=0
    chown -R '"$(id -u):$(id -g)"' /workspace/tools/_yosys-local \
                                   /workspace/tools/sparc-sca-yosys'
```

The build log is `tools/log/yosys.log`, as for every other tool.

## Using a prefix-overridden build

`resourcewrapper` ends in `exec "$@"`, so the flow takes `yosys` from `PATH`.
Prepend the local prefix — prepend, do not replace, or `fusesoc` disappears and
the Verilator step dies with `make: fusesoc: No such file or directory`:

```bash
./sparc.sh bash -c 'export PATH=/workspace/tools/_yosys-local/bin:$PATH
                    export POWER_LEAKAGE_HD_TAINT_PREV=1
                    make -C designs/ibex/cellift build-eval-sims'
```

## Verify it took effect

The failure mode is silent, so check rather than assume. Pick something your
change emits and count it in the netlist. For the `-hd-taint-prev` example
above:

```bash
grep -c '_t0_prev_hw_hd' designs/ibex/cellift/generated/out/cellift.sv
```

Zero means the stock pass ran. Note also that `make` will not re-run the
instrumentation just because the yosys binary changed — the target depends on
`instrument.ys.tcl` and `generated/sv2v_out.v`, not on the tool. Delete
`generated/out/cellift.sv` to force it.

To check that a given yosys supports an option before a long run, rather than
discovering it mid-flow:

```bash
yosys -p 'help cellift' | grep -- -hd-taint-prev
```

`instrument.ys.tcl` passes such options explicitly, so a binary that lacks one
fails loudly (`ERROR: Command syntax error: Unknown option`) — but only once the
flow reaches the instrumentation step.

`tools/_yosys-local/` is gitignored.

## Or just rebuild the image

Everything above is for the edit / rebuild / re-run loop on the pass itself,
where a full image build per edit is absurd. The Dockerfile builds yosys from
`tools/sparc-sca-yosys/` (`COPY tools/sparc-sca-yosys/ /build/yosys/`), so a
plain

```bash
make docker-build
```

produces an image whose `yosys` already has whatever is in the tree — no prefix
override, no `PATH` juggling, no `chown` afterwards.

The image's smoke test **fails the build** unless the `PATH` yosys reports
`-track-power-leakage`, `-hd-taint-prev` and `-power-leakage-include-signals`
under `help cellift`. That closes the gap this document opens with: a stale
binary would otherwise produce a perfectly valid `cellift.sv` with the feature
silently missing.

## A second toolchain: `/opt/upstream`

The image also carries **current upstream Yosys (with the slang SystemVerilog
frontend) and Verilator 5**, installed to `/opt/upstream` and reached only
through `$UPSTREAM_YOSYS`, `$UPSTREAM_VERILATOR` and `$UPSTREAM_YOSYS_CONFIG`.
The versions are the `UPSTREAM_*_TAG` build arguments in the `Dockerfile`.

`PATH` is unchanged: `yosys` and `verilator` still resolve to the SPARC
toolchain, and the image's smoke test fails the build if they do not. That is
deliberate. Neither upstream tool can replace what the flow depends on — the
CellIFT pass is compiled into the forked yosys, and the Verilator in
`tools/verilator/` carries an FST integer-overflow fix — so the two sets coexist
rather than one shadowing the other.

What upstream is for: reading heavily parameterised SystemVerilog that the
morty + sv2v front end struggles with. `read_slang` can elaborate such a design
directly and write a netlist the forked yosys can then instrument:

```bash
./sparc.sh bash -c '$UPSTREAM_YOSYS -p "read_slang top.sv --top top; \
                    proc; write_verilog -noattr top_flat.v"'
```

None of the shipped designs uses this path; the evaluation flow is unchanged.
