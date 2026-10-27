"""Add DEF pin labels (and power labels) to the merged GDS for LVS.

Run with KLayout's embedded Python:
  klayout -b -r add_pin_labels.py -rd in_def=... -rd in_gds=... -rd out_gds=... -rd topcell=...
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

    pins = []
    m = re.search(r"^\s*PINS\s+\d+\s*;(.*?)^\s*END PINS", src, re.S | re.M)
    if m:
        body = m.group(1)
        for blk in re.split(r"\n\s*-\s+", "\n" + body):
            if not blk.strip():
                continue
            name = blk.split()[0]
            layer = re.search(r"\+ LAYER\s+(\w+)", blk)
            placed = re.search(r"\+ (?:PLACED|FIXED)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)", blk)
            if not placed:
                pair = re.search(r"\(\s*(-?\d+)\s+(-?\d+)\s*\)", blk)
                placed = pair
            if layer and placed:
                pins.append((name, layer.group(1), int(placed.group(1)), int(placed.group(2))))

    power = []
    m = re.search(r"\nSPECIALNETS\s+\d+\s*;(.*?)\nEND SPECIALNETS", src, re.S)
    if m:
        body = m.group(1)
        for blk in re.split(r"\n\s*-\s+", "\n" + body):
            if not blk.strip():
                continue
            name = blk.split()[0]
            if name not in ("VPWR", "VGND"):
                continue
            layer = re.search(r"\+ (?:ROUTED|LAYER)\s+(\w+)", blk)
            pair = re.search(r"\(\s*(-?\d+)\s+(-?\d+)\s*\)", blk)
            if layer and pair:
                power.append((name, layer.group(1), int(pair.group(1)), int(pair.group(2))))

    ly = pya.Layout()
    ly.read(in_gds)
    cell = ly.cell(topcell) or ly.top_cell()

    n = 0
    for name, layer, x, y in pins:
        if add_text(cell, layer, name, x, y):
            n += 1
    p = 0
    for name, layer, x, y in power:
        if add_text(cell, layer, name, x, y):
            p += 1

    ly.write(out_gds)
    print("added pin labels:", n, "power labels:", p, "->", out_gds)


main(in_def, in_gds, out_gds, topcell)
