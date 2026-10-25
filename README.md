# sky130-macro-ci

Self-contained GitHub Actions repository for the SKY130 OpenRAM macro flow:

```
Yosys synth -> OpenROAD P&R (0 DRC) -> GDS -> merge macro GDS -> sky130A_mr.drc -> sky130A.lvs/Netgen
```

## Push and run

```powershell
gh auth login          # once; the existing token is invalid
cd sky130-ci-repo
git init
git add .
git commit -m "sky130 macro CI: synth -> PnR -> GDS -> DRC -> LVS"
gh repo create sky130-macro-ci --private --source=. --remote=origin --push
gh run watch
```

Or with plain git:

```bash
git init
git add .
git commit -m "sky130 macro CI"
git remote add origin git@github.com:<you>/sky130-macro-ci.git
git push -u origin main
```

## What the workflow does

1. `volare` installs the sky130A PDK (for the KLayout DRC/LVS decks and std-cell SPICE).
2. `apt` installs `klayout`, `netgen-lvs`; `pip` installs `klayout`/`volare`.
3. `yosys -s sky130/synth/synth_mlc_macro.ys` (596 cells / 5,426.45 µm² + macro blackbox).
4. `openroad -no_init -exit sky130/pnr/run_mlc_macro_route_fix.tcl` -> 0-DRC DEF, `catch {write_gds}` emits GDS in the ORFS image.
5. `merge_macro.py` merges the OpenRAM macro GDS at `(64,64) µm`.
6. `sky130A_mr.drc` -> `drc_macro.lyrdb`.
7. `sky130A.lvs` / Netgen -> `lvs_macro.rpt`.
8. Uploads `sky130/out/` as `sky130-macro-artifacts`.

## Contents

| path | purpose |
|---|---|
| `.github/workflows/sky130-macro.yml` | CI pipeline |
| `sky130/rtl/` | `mlc_storage_macro.v` + TB |
| `sky130/synth/` | Yosys script |
| `sky130/pnr/` | `run_mlc_macro_route_fix.tcl` (0 DRC) |
| `sky130/pdk_fix/` | patched std-cell LEF (RESET_B li1) + tech LEF |
| `sky130/macros/` | OpenRAM 256x32 LEF/Verilog/Liberty/GDS/SPICE (+ `_obs.lef`) |
| `sky130/klayout/` | `merge_macro.py` |
| `sky130/drc/`, `sky130/lvs/` | DRC/LVS runner scripts |
| `sky130/tools/` | KLayout helpers |
| `flow/pdk/sky130hd/` | tlef + merged LEF + Liberty used by the PnR script |
| `apps/storage/mlc_storage.v` | RTL source |
