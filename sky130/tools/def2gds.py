import klayout.db as db

ly = db.Layout()
files = [
    "sky130/pdk_fix/sky130_fd_sc_hd_tech.lef",
    "sky130/pdk_fix/sky130_fd_sc_hd_merged_fix.lef",
    "sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8/sky130_sram_1kbyte_1rw1r_32x256_8_obs.lef",
    "sky130/out/mlc_storage_macro.def",
]
for f in files:
    try:
        ly.read(f)
        print("read ok:", f, "cells:", ly.cells())
    except Exception as e:
        print("read FAIL:", f, "->", e)

top = ly.cell("mlc_storage_macro")
print("top cell found:", top is not None)
ly.write("sky130/out/mlc_storage_macro_from_klayout.gds")
print("wrote GDS")
