#!/usr/bin/env bash
# Run the official ORFS flow (synth -> PnR -> GDS -> LVS) inside the ORFS image.
set -euo pipefail

DEST=/OpenROAD-flow-scripts/flow
MACRO=/work/sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8

mkdir -p "$DEST/designs/src/mlc_storage"
mkdir -p "$DEST/designs/sky130hd/mlc_storage/lef" "$DEST/designs/sky130hd/mlc_storage/lib"

cp /work/sky130/rtl/mlc_storage_macro.v "$DEST/designs/src/mlc_storage/"
cp "$MACRO/sky130_sram_1kbyte_1rw1r_32x256_8.lef" "$DEST/designs/sky130hd/mlc_storage/lef/"
cp "$MACRO/sky130_sram_1kbyte_1rw1r_32x256_8_TT_1p8V_25C.lib" "$DEST/designs/sky130hd/mlc_storage/lib/"

# patched std-cell LEF: RESET_B li1 pin widened for via access
cp /work/sky130/pdk_fix/sky130_fd_sc_hd_merged_fix.lef \
   "$DEST/platforms/sky130hd/lef/sky130_fd_sc_hd_merged.lef"

cat > "$DEST/designs/sky130hd/mlc_storage/config.mk" <<'EOF'
export DESIGN_NAME = mlc_storage_macro
export PLATFORM    = sky130hd
export VERILOG_FILES = $(DESIGNS)/src/mlc_storage/mlc_storage_macro.v
export SDC_FILE = $(DESIGNS)/sky130hd/mlc_storage/constraint.sdc
export ADDITIONAL_LEFS = $(DESIGNS)/sky130hd/mlc_storage/lef/sky130_sram_1kbyte_1rw1r_32x256_8.lef
export ADDITIONAL_LIBS = $(DESIGNS)/sky130hd/mlc_storage/lib/sky130_sram_1kbyte_1rw1r_32x256_8_TT_1p8V_25C.lib
export CORE_UTILIZATION = 40
export PLACE_DENSITY = 0.5
export MACRO_PLACEMENT = $(DESIGNS)/sky130hd/mlc_storage/macro_placement.tcl
EOF

cat > "$DEST/designs/sky130hd/mlc_storage/constraint.sdc" <<'EOF'
create_clock -name clk -period 20 [get_ports clk]
set_input_delay 2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold 0.1 [get_clocks clk]
EOF

cat > "$DEST/designs/sky130hd/mlc_storage/macro_placement.tcl" <<'EOF'
place_macro -macro_name u_sram -location {64 64} -orientation N
EOF

cd "$DEST"
make DESIGN_CONFIG=./designs/sky130hd/mlc_storage/config.mk
make DESIGN_CONFIG=./designs/sky130hd/mlc_storage/config.mk lvs

ls -l flow/results/sky130hd/mlc_storage/base 2>/dev/null || true
