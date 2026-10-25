#!/usr/bin/env bash
# KLayout DRC for the SKY130 port. Requires the open_pdks/volare sky130A PDK.
set -euo pipefail
PDK_ROOT="${PDK_ROOT:-$HOME/.volare}"
PDK="${PDK:-sky130A}"
GDS="${1:-sky130/out/mlc_storage_sky130.gds}"
RPT="${2:-sky130/out/drc.lyrdb}"
DECK="$PDK_ROOT/$PDK/libs.tech/klayout/drc/sky130A_mr.drc"
if [ ! -f "$DECK" ]; then
  echo "DRC deck not found: $DECK" >&2
  echo "Install the PDK with: pip install volare && volare enable --pdk sky130 <version>" >&2
  exit 2
fi
klayout -b -r "$DECK" -rd input="$GDS" -rd report="$RPT" -rd topcell=mlc_storage
echo "DRC report: $RPT"
