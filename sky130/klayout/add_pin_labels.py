"""Label top-level ports and power nets for sky130 LVS (metal + txt layer)."""
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
TXT = (83, 44)
PREF = ("met2", "met3", "met4", "met5")


def norm(s):
    return s.replace("\\", "")


def add_text(cell, layer_name, name, x, y):
    inserted = False
    key = LAYERS.get(layer_name)
    for lk in ([key] if key else []) + [TXT]:
        li = cell.layout().layer(*lk)
        t = pya.Text(name, pya.Trans(int(x), int(y)))
        t.size = 1000
        cell.shapes(li).insert(t)
        inserted = True
    return inserted


def pick_point(points):
    for layer, x, y in points:
        if layer in PREF:
            return layer, x, y
    return points[0] if points else None


def main(in_def, in_gds, out_gds, topcell):
    src = open(in_def, errors="ignore").read()

    ports = []
    m = re.search(r"^\s*PINS\s+\d+\s*;(.*?)^\s*END PINS", src, re.S | re.M)
    if m:
        for blk in re.split(r"\n\s*-\s+", "\n" + m.group(1)):
            if blk.strip():
                ports.append(norm(blk.split()[0]))

    net_points = {}
    m = re.search(r"^\s*NETS\s+\d+\s*;(.*?)^\s*END NETS", src, re.S | re.M)
    if m:
        for blk in re.split(r"\n\s*-\s+", "\n" + m.group(1)):
            if not blk.strip():
                continue
            name = norm(blk.split()[0])
            pts = [(l, int(x), int(y)) for l, x, y in re.findall(
                r"\+ ROUTED\s+(\w+)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)", blk)]
            if pts:
                net_points[name] = pick_point(pts)

    power = {}
    m = re.search(r"^\s*SPECIALNETS\s+\d+\s*;(.*?)^\s*END SPECIALNETS", src, re.S | re.M)
    if m:
        for blk in re.split(r"\n\s*-\s+", "\n" + m.group(1)):
            if not blk.strip():
                continue
            name = norm(blk.split()[0])
            if name not in ("VPWR", "VGND"):
                continue
            mm = re.search(r"\+ ROUTED\s+(\w+)\s*.*?\(\s*(-?\d+)\s+(-?\d+)\s*\)", blk, re.S)
            if mm:
                power[name] = (mm.group(1), int(mm.group(2)), int(mm.group(3)))

    ly = pya.Layout()
    ly.read(in_gds)
    cell = ly.cell(topcell) or ly.top_cell()

    n = 0
    for name in ports:
        pt = net_points.get(name)
        if pt and add_text(cell, pt[0], name, pt[1], pt[2]):
            n += 1

    p = 0
    for name, pt in power.items():
        if add_text(cell, pt[0], name, pt[1], pt[2]):
            p += 1

    ly.write(out_gds)
    print("added port labels:", n, "of", len(ports), "power:", p, "->", out_gds)


main(in_def, in_gds, out_gds, topcell)
