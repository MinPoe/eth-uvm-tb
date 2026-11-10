#!/usr/bin/env bash
# Build the UVM testbench with Verilator
# usage: sim/build_verilator.sh <build_dir> [BUG_NAME]     e.g. sim/build_verilator.sh build/golden
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?build dir}"
BUG="${2:-}"
: "${UVM_SRC:?set UVM_SRC to the Accellera uvm-core/src directory}"
VL_ROOT="${VERILATOR_ROOT:-$(python3 -c 'import verilator,os;print(os.path.dirname(verilator.__file__))')}"
export VERILATOR_ROOT="$VL_ROOT"
VL="$VL_ROOT/bin/verilator"

DEF=()
[ -n "$BUG" ] && DEF+=("-DBUG_$BUG")

# -MAKEFLAGS: the pip wheel of Verilator ships an empty precompiled-header include flag
mkdir -p "$OUT"
"$VL" --binary --timing --assert --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style \
  -CFLAGS "-std=c++20 -fcoroutines" -j "${VL_JOBS:-2}" \
  -MAKEFLAGS "CFG_CXXFLAGS_PCH_I=-include" \
  --top-module tb_top --Mdir "$OUT" -o sim_exe \
  +define+UVM_NO_DPI "${DEF[@]}" \
  +incdir+"$UVM_SRC" +incdir+"$ROOT/tb" \
  "$UVM_SRC/uvm_pkg.sv" \
  "$ROOT/rtl/eth_regs.sv" "$ROOT/rtl/eth_rx.sv" "$ROOT/rtl/eth_top.sv" \
  "$ROOT/tb/eth_ifs.sv" "$ROOT/tb/eth_pkg.sv" "$ROOT/tb/tb_top.sv" \
  > "$OUT/verilate.log" 2>&1 || { grep -E "%Error|error:" "$OUT/verilate.log" | head -20; exit 1; }

echo "built $OUT/sim_exe"
