#!/usr/bin/env python3
"""Patch ORFS def2stream.py so KLayout emits pin/net names (needed by LVS)."""
import sys

path = sys.argv[1]
src = open(path).read()
anchor = "    layout_options = tech.load_layout_options"
addition = anchor + """
    try:
        layout_options.lefdef_config.produce_pin_names = True
        layout_options.lefdef_config.produce_net_names = True
    except Exception:
        pass"""

if anchor not in src:
    raise SystemExit("anchor not found in " + path)
if "produce_pin_names" not in src:
    src = src.replace(anchor, addition, 1)
open(path, "w").write(src)
print("patched", path)
