#!/usr/bin/env bash
set -x
pip3 install --quiet --break-system-packages klayout 2>&1 | tail -3 || pip3 install --quiet klayout 2>&1 | tail -3
python3 -c "import klayout.db as db; print('klayout module ok')" || echo "klayout import failed"
command -v klayout || echo "no klayout CLI"
