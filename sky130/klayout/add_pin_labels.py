"""Add net labels taken from DEF routing (ROUTED) to the merged GDS for LVS.

Labels are placed on the first routed point of each net, on the label layers
used by the sky130 LVS deck (metN datatype 5).
"""
import re

import pya

LAYERS = {
    "li1": (67, 5),
    "met1": (68, 5),
    "met2": (69, 5),
    "met3": (70, 5),
    "met4": (71, 5),
    "met5": (72, 5),
}


def add_text(cell, layer_name, name, x, y):
    key = LAYERS.get(layer_name)
    if not key:
        return False
    li = cell.layout().layer(*key)
    t = pya.Text(name, pya.Trans(int(x), int(y)))
    t.size = 1000
    cell.shapes(li).insert(t)
    return True


def main(in_def, in_gds, out_gds, topcell):
    src = open(in_def, errors="ignore").read()

    labels = []
    m = re.search(r"^\s*NETS\s+\d+\s*;(.*?)^\s*END NETS", src, re.S | re.M)
    if m:
        body = m.group(1)
        for blk in re.split(r"\n\s*-\s+", "\n" + body):
            if not blk.strip():
                continue
            name = blk.split()[0]
            mm = re.search(r"\+ ROUTED\s+(\w+)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)", blk)
            if mm:
                labels.append((name, mm.group(1), int(mm.group(2)), int(mm.group(3))))

    ly = pya.Layout()
    ly.read(in_gds)
    cell = ly.cell(topcell) or ly.top_cell()

    n = 0
    for name, layer, x, y in labels:
        if add_text(cell, layer, name, x, y):
            n += 1

    ly.write(out_gds)
    print("added net labels:", n, "->", out_gds)


main(in_def, in_gds, out_gds, topcell)
