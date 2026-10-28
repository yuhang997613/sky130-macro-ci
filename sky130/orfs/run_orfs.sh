#!/usr/bin/env bash
# Official ORFS flow (synth -> PnR -> GDS -> LVS) for the SKY130 macro design.
set -eu

DEST=/OpenROAD-flow-scripts/flow
MACRO=/work/sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8
DESIGN_DIR="$DEST/designs/sky130hd/mlc_storage"

mkdir -p "$DEST/designs/src/mlc_storage" "$DESIGN_DIR/lef" "$DESIGN_DIR/lib" "$DESIGN_DIR/gds" "$DESIGN_DIR/cdl"

cp /work/sky130/rtl/mlc_storage_macro.v "$DEST/designs/src/mlc_storage/"
cp "$MACRO/sky130_sram_1kbyte_1rw1r_32x256_8.lef" "$DESIGN_DIR/lef/"
cp "$MACRO/sky130_sram_1kbyte_1rw1r_32x256_8_TT_1p8V_25C.lib" "$DESIGN_DIR/lib/"
cp "$MACRO/sky130_sram_1kbyte_1rw1r_32x256_8.gds" "$DESIGN_DIR/gds/"
cp "$MACRO/sky130_sram_1kbyte_1rw1r_32x256_8.sp" "$DESIGN_DIR/cdl/"

# append OpenRAM macro CDL to the platform masters CDL
cat "$MACRO/sky130_sram_1kbyte_1rw1r_32x256_8.sp" \
    >> "$DEST/platforms/sky130hd/cdl/sky130hd.cdl"

# patched std-cell LEF (RESET_B li1 widened for via access)
cp /work/sky130/pdk_fix/sky130_fd_sc_hd_merged_fix.lef \
   "$DEST/platforms/sky130hd/lef/sky130_fd_sc_hd_merged.lef"

cat > "$DESIGN_DIR/config.mk" <<'EOF'
export DESIGN_NAME = mlc_storage_macro
export PLATFORM    = sky130hd
export VERILOG_FILES = /OpenROAD-flow-scripts/flow/designs/src/mlc_storage/mlc_storage_macro.v
export SDC_FILE = /OpenROAD-flow-scripts/flow/designs/sky130hd/mlc_storage/constraint.sdc
export ADDITIONAL_LEFS = /OpenROAD-flow-scripts/flow/designs/sky130hd/mlc_storage/lef/sky130_sram_1kbyte_1rw1r_32x256_8.lef
export ADDITIONAL_LIBS = /OpenROAD-flow-scripts/flow/designs/sky130hd/mlc_storage/lib/sky130_sram_1kbyte_1rw1r_32x256_8_TT_1p8V_25C.lib
export ADDITIONAL_GDS = /OpenROAD-flow-scripts/flow/designs/sky130hd/mlc_storage/gds/sky130_sram_1kbyte_1rw1r_32x256_8.gds

export CORE_UTILIZATION = 40
export PLACE_DENSITY = 0.5
export MACRO_PLACEMENT = /OpenROAD-flow-scripts/flow/designs/sky130hd/mlc_storage/macro_placement.tcl
export PDN_TCL = /OpenROAD-flow-scripts/flow/designs/sky130hd/mlc_storage/pdn.tcl
EOF

cat > "$DESIGN_DIR/constraint.sdc" <<'EOF'
create_clock -name clk -period 20 [get_ports clk]
set_input_delay 2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold 0.1 [get_clocks clk]
EOF

cat > "$DESIGN_DIR/macro_placement.tcl" <<'EOF'
place_macro -macro_name u_sram -location {64 64} -orientation N
EOF

cp "$DEST/platforms/sky130hd/pdn.tcl" "$DESIGN_DIR/pdn.tcl"

cat >> "$DESIGN_DIR/pdn.tcl" <<'EOF'
add_global_connection -net VPWR -inst_pattern {u_sram} -pin_pattern {vccd1} -power
add_global_connection -net VGND -inst_pattern {u_sram} -pin_pattern {vssd1} -ground
EOF

python3 - "$DESIGN_DIR/pdn.tcl" <<'PYEOF'
import re
import sys

path = sys.argv[1]
s = open(path).read()

pat1 = re.compile(
    r"define_pdn_grid -name \{CORE_macro_grid_1\}.*?add_pdn_connect -grid \{CORE_macro_grid_1\} -layers \{met4 met5\}\n",
    re.S,
)
repl1 = "# macro grid disabled (macro PDN handled outside ORFS)\n"
s, n1 = pat1.subn(repl1, s, count=1)

pat2 = re.compile(
    r"define_pdn_grid -name \{CORE_macro_grid_2\}.*?add_pdn_connect -grid \{CORE_macro_grid_2\} -layers \{met4 met5\}\n",
    re.S,
)
s, n2 = pat2.subn("", s, count=1)

open(path, "w").write(s)
print("pdn patch: grid1", n1, "grid2", n2)
PYEOF

cd "$DEST"
make DESIGN_CONFIG=./designs/sky130hd/mlc_storage/config.mk
make DESIGN_CONFIG=./designs/sky130hd/mlc_storage/config.mk lvs

ls -l results/sky130hd/mlc_storage_macro/base 2>/dev/null || true
