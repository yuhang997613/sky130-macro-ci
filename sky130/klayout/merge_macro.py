#!/usr/bin/env python3
"""Merge an OpenRAM macro GDS into the design GDS at the macro placement.

Usage: python merge_macro.py design.gds macro.gds out.gds x_um y_um
Requires the `klayout` Python module (pip install klayout).
"""
import sys

import klayout.db as db

design, macro, out, x_um, y_um = sys.argv[1:6]

top = db.Layout()
top.read(design)
mac = db.Layout()
mac.read(macro)

# copy the macro hierarchy into the design layout
for cell in mac.top_cells():
    cell.copy_tree(top)

x = int(float(x_um) / top.dbu)
y = int(float(y_um) / top.dbu)
macro_top = top.cell(mac.top_cells()[0].name)
design_top = top.top_cell()
design_top.insert(db.CellInstArray(macro_top.cell_index(), db.Trans(x, y)))
top.write(out)
print(f"merged {macro} into {design} at ({x_um},{y_um}) um -> {out}")
