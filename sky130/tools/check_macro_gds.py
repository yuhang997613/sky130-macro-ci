import klayout.db as db

path = "sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8/sky130_sram_1kbyte_1rw1r_32x256_8.gds"
ly = db.Layout()
ly.read(path)
print("dbu", ly.dbu, "cells", ly.cells(), "top", ly.top_cell().name)
