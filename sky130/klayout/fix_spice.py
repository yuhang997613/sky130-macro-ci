#!/usr/bin/env python3
"""Pad P&R SPICE instances to the PDK subckt pin count.

Yosys write_spice only emits connected signal pins; the sky130 std-cell and
OpenRAM subckts carry extra power/bulk pins. This script appends the missing
pins (mapped to global power nets) so the KLayout LVS netlist reader accepts
the schematic.
"""
import sys

pdk_spice, routed, macro_spice, out = sys.argv[1:5]

subpins = {}
for path in (pdk_spice, macro_spice):
    try:
        fh = open(path, errors="ignore")
    except OSError:
        continue
    for line in fh:
        u = line.upper()
        if u.startswith(".SUBCKT"):
            t = line.split()
            if len(t) >= 2:
                subpins[t[1].lower()] = t[2:]

POWER = {
    "vdd": "VPWR", "vccd1": "vccd1",
    "vss": "VGND", "vssd1": "vssd1",
    "vpb": "VPB", "vnb": "VNB",
    "vpw": "VGND", "vssd1": "vssd1",
}

res = []
for ln in open(routed, errors="ignore").read().splitlines():
    s = ln.strip()
    if s.startswith("X") and len(s.split()) >= 3:
        t = s.split()
        sub = t[-1].lower()
        exp = subpins.get(sub)
        if exp:
            have = len(t) - 2
            if have < len(exp):
                pad = []
                for p in exp[have:]:
                    pad.append(POWER.get(p.lower(), "NC_" + p))
                t = t[:-1] + pad + [t[-1]]
                ln = " ".join(t)
    res.append(ln)

open(out, "w").write("\n".join(res) + "\n")
print("wrote", out, "instances padded")
