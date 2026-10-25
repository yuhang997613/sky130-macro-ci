#!/usr/bin/env bash
# One-command SKY130 macro flow: synth -> P&R (0 DRC) -> GDS -> merge -> DRC -> LVS.
# Run from the repo root or anywhere (script cds to the repo root).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p sky130/out

echo "== 1/6 Yosys synthesis =="
yosys -s sky130/synth/synth_mlc_macro.ys 2>&1 | tee sky130/out/synth_mlc_macro.log

echo "== 2/6 OpenROAD P&R (0-DRC fix flow) =="
openroad -no_init -exit sky130/pnr/run_mlc_macro_route_fix.tcl 2>&1 | tee sky130/out/pnr_mlc_macro_route.log
test -f sky130/out/mlc_storage_macro.def
if [ -s sky130/out/route_drc.rpt ]; then
  echo "router DRC report is not empty"; exit 1
fi

if [ ! -f sky130/out/mlc_storage_macro.gds ]; then
  echo "== 3/6 GDS missing (this OpenROAD build has no write_gds) =="
  echo "Run this step in CI (openroad/orfs image) or with a write_gds-capable OpenROAD."
  exit 0
fi

echo "== 3/6 merge OpenRAM macro GDS =="
python3 sky130/klayout/merge_macro.py \
  sky130/out/mlc_storage_macro.gds \
  sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8/sky130_sram_1kbyte_1rw1r_32x256_8.gds \
  sky130/out/mlc_storage_macro_merged.gds 64 64

echo "== 4/6 KLayout DRC =="
bash sky130/drc/run_drc.sh sky130/out/mlc_storage_macro_merged.gds sky130/out/drc_macro.lyrdb

echo "== 5/6 KLayout LVS / Netgen =="
bash sky130/lvs/run_lvs.sh sky130/out/mlc_storage_macro_merged.gds \
     sky130/out/mlc_storage_macro_routed.v sky130/out/lvs_macro.rpt

echo "== 6/6 artifacts under sky130/out =="
ls -la sky130/out
