#!/usr/bin/env bash
# LVS for the SKY130 macro design.
# Builds a schematic SPICE from: macro .sp + sky130 std-cell .spice + design .sp
# (design .sp is produced by Yosys write_spice when available), then runs the
# KLayout sky130A LVS deck and Netgen as an independent check.
set -euo pipefail
PDK_ROOT="${PDK_ROOT:-$HOME/.volare}"
PDK="${PDK:-sky130A}"
GDS="${1:-sky130/out/mlc_storage_macro_merged.gds}"
SCHEM_V="${2:-sky130/out/mlc_storage_macro_routed.v}"
RPT="${3:-sky130/out/lvs_macro.rpt}"
OUT="$(dirname "$RPT")"
MACRO_SP="sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8/sky130_sram_1kbyte_1rw1r_32x256_8.sp"
STD_SPICE="$PDK_ROOT/$PDK/libs.ref/sky130_fd_sc_hd/spice/sky130_fd_sc_hd.spice"
DESIGN_SP="$OUT/mlc_storage_macro_routed.sp"
SCHEM_SP="$OUT/lvs_schematic.sp"

# 1) design SPICE from the routed Verilog (best effort)
if [ ! -f "$DESIGN_SP" ] && [ -f "$SCHEM_V" ] && command -v yosys >/dev/null 2>&1; then
  yosys -p "read_verilog $SCHEM_V; write_spice $DESIGN_SP" >/dev/null 2>&1 || true
fi

# 2) concatenate macro + std cells + design
: > "$SCHEM_SP"
[ -f "$MACRO_SP" ] && cat "$MACRO_SP" >> "$SCHEM_SP"
[ -f "$STD_SPICE" ] && cat "$STD_SPICE" >> "$SCHEM_SP"
[ -f "$DESIGN_SP" ] && cat "$DESIGN_SP" >> "$SCHEM_SP"

LVS_DECK="$PDK_ROOT/$PDK/libs.tech/klayout/lvs/sky130A.lvs"
SETUP="$PDK_ROOT/$PDK/libs.tech/netgen/sky130A_setup.tcl"

if [ -f "$LVS_DECK" ]; then
  echo "== KLayout LVS =="
  klayout -b -r "$LVS_DECK" -rd input="$GDS" -rd schematic="$SCHEM_SP" \
          -rd report="$RPT" -rd topcell=mlc_storage_macro || true
fi

if [ -f "$SETUP" ] && [ -f "$SCHEM_SP" ]; then
  echo "== Netgen LVS (independent) =="
  EXTRACTED="$OUT/mlc_storage_macro_extracted.spice"
  if [ -f "$EXTRACTED" ]; then
    netgen -batch lvs "$EXTRACTED mlc_storage_macro" "$SCHEM_SP mlc_storage_macro" \
            "$SETUP" "$RPT" || true
  fi
fi
echo "LVS report: $RPT"
