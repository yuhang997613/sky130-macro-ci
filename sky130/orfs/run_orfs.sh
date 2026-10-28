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
export KLAYOUT_LVS_FILE = /OpenROAD-flow-scripts/flow/designs/sky130hd/mlc_storage/sky130hd.lylvs
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

{
  echo 'add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {vccd1} -power'
  echo 'add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {vssd1} -ground'
  cat "$DEST/platforms/sky130hd/pdn.tcl"
} > "$DESIGN_DIR/pdn.tcl"

python3 - "$DESIGN_DIR/pdn.tcl" <<'PYEOF'
import re
import sys

path = sys.argv[1]
s = open(path).read()

pat1 = re.compile(
    r"define_pdn_grid -name \{CORE_macro_grid_1\}.*?add_pdn_connect -grid \{CORE_macro_grid_1\} -layers \{met4 met5\}\n",
    re.S,
)
repl1 = """define_pdn_grid -name {CORE_macro_grid_1} -voltage_domains {CORE} -macro \\
  -cells {sky130_sram_1kbyte_1rw1r_32x256_8} \\
  -orient {R0 R180 MX MY} -halo {2.0 2.0 2.0 2.0} -grid_over_boundary
add_pdn_stripe -grid {CORE_macro_grid_1} -layer {met4} -width {0.28} -pitch {4.48} -offset {5.04}
add_pdn_connect -grid {CORE_macro_grid_1} -layers {met4 met5}
"""
s, n1 = s, 0

pat2 = re.compile(
    r"define_pdn_grid -name \{CORE_macro_grid_2\}.*?add_pdn_connect -grid \{CORE_macro_grid_2\} -layers \{met4 met5\}\n",
    re.S,
)
s, n2 = s, 0

open(path, "w").write(s)
print("pdn patch: grid1", n1, "grid2", n2)
PYEOF

cp "$DEST/platforms/sky130hd/lvs/sky130hd.lylvs" "$DESIGN_DIR/sky130hd.lylvs"

python3 - "$DESIGN_DIR/sky130hd.lylvs" <<'PYEOF'
import sys

p = sys.argv[1]
s = open(p).read()
marker = 'connect_global(SUB, "VNB")'
add = '''connect_global(SUB, "VNB")

n_vdd  = find_net_by_name_component(c, "VDD")
n_vccd = find_net_by_name_component(c, "vccd1")
c.join_nets(n_vdd, n_vccd) if n_vdd && n_vccd && n_vdd.name != n_vccd.name
n_vss  = find_net_by_name_component(c, "VSS")
n_vssd = find_net_by_name_component(c, "vssd1")
c.join_nets(n_vss, n_vssd) if n_vss && n_vssd && n_vss.name != n_vssd.name'''
if marker in s:
    s = s.replace(marker, add, 1)
    print("lvs deck patched: vccd1/vssd1 -> VDD/VSS")
else:
    print("lvs deck marker not found")
open(p, "w").write(s)
PYEOF

cd "$DEST"
make DESIGN_CONFIG=./designs/sky130hd/mlc_storage/config.mk
make DESIGN_CONFIG=./designs/sky130hd/mlc_storage/config.mk lvs

ls -l results/sky130hd/mlc_storage_macro/base 2>/dev/null || true

# export ORFS results for artifact upload
mkdir -p /work/sky130/out/orfs_results
cp -r results/sky130hd/mlc_storage_macro/base/* /work/sky130/out/orfs_results/ 2>/dev/null || true
