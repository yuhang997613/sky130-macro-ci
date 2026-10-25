# SKY130 移植：RTL → Yosys → OpenROAD → KLayout DRC → Netgen LVS（GitHub Actions）

## 目标与范围

把当前可综合的 **`mlc_storage` 存储控制器**（80×3-bit 行为存储，无宏依赖）作为 SKY130 的第一个落地目标，跑通：

```
Yosys (sky130 Liberty) → OpenROAD P&R (sky130hd) → GDS
        → KLayout DRC (sky130A_mr.drc)
        → LVS (sky130A.lvs / Netgen sky130A_setup.tcl)
```

这是“先证明工具链/PDK/DRC/LVS 能跑”的最小闭环；随后再把 `emram_ctrl_macro` + OpenRAM 256×16 宏按同一流程替换进来。

## 本地已验证

- Yosys + `sky130_fd_sc_hd__tt_025C_1v80.lib` 综合通过：
  - **2,572 cells / 20,739.9 µm²**（`sky130/out/synth_sky130.log`）。
- P&R/DRC/LVS 需要完整 PDK（volare/open_pdks）与 KLayout/Netgen，本地未装，交给 CI。

## CI（`.github/workflows/sky130.yml`）

- 容器 `openroad/orfs:latest`：自带 OpenROAD + Yosys。
- `apt` 安装 `klayout`、`netgen-lvs`；`pip install volare` 拉取 `sky130A` PDK。
- 依次执行：综合 → P&R → GDS → DRC → LVS，产物上传为 `sky130-artifacts`。
- 把 `sky130/github-workflows/sky130.yml` 复制到仓库根 `.github/workflows/sky130.yml` 即可触发。

## 文件

| 文件 | 作用 |
|---|---|
| `rtl/mlc_storage.v` | 待移植 RTL（行为存储，无宏） |
| `synth/synth_sky130.ys` | Yosys sky130 综合，输出 `out/mlc_storage_sky130.v` |
| `pnr/run_sky130.tcl` | OpenROAD sky130hd floorplan/place/CTS/route，输出 DEF/GDS |
| `drc/run_drc.sh` | KLayout `sky130A_mr.drc` |
| `lvs/run_lvs.sh` | KLayout `sky130A.lvs` + Netgen `sky130A_setup.tcl` |
| `github-workflows/sky130.yml` | GitHub Actions 全流程 |
| `Makefile` | 本地/CI 统一入口 |

## 下一步（OpenRAM 宏）

1. 用 OpenRAM 生成 `sky130` 256×16 单口 SRAM（或直接用 `sky130_sram_macros` 预生成宏）。
2. 用宏替换 `mlc_storage` 的 `mem` 数组，接口同 `fakeram45_256x16`（ce/we/addr/wd/wmask/rd）。
3. 在 OpenROAD 里 `read_lef` 宏 LEF、`place_macro`/`setOrigin`，PDN 连宏 PG pin。
4. DRC/LVS 直接复用本目录脚本（LVS 的 schematic 用综合后网表 + 宏的 SPICE 模型）。

## 已知首跑风险

- `initialize_floorplan -site sky130_fd_sc_hd` 与 `make_tracks` 的 offset/pitch 是首版估计；若 CI 报 track/site 错误，按日志调 `sky130/pnr/run_sky130.tcl` 顶部参数。
- `write_gds` 在部分 OpenROAD 版本不可用；CI 会明确报错，届时用 KLayout DEF+LEF stream out 替代。
- KLayout DRC/LVS deck 的变量名（`input`/`report`/`schematic`）随 open_pdks 版本略有差异；脚本已按 `sky130A` 标准 deck 写，必要时按 deck 头部注释调整。


## OpenRAM 宏移植（进行中）

- RTL/ TB / 综合已完成：[rtl/mlc_storage_macro.v](rtl/mlc_storage_macro.v)、[rtl/tb_mlc_macro.v](rtl/tb_mlc_macro.v) **95/95 PASS**、[synth/synth_mlc_macro.ys](synth/synth_mlc_macro.ys) → **596 cells / 5,426.45 µm²**（行为版 2,572 / 20,739.9，**−73.8%**）。
- P&R 已完成 place/CTS（`MLC_SKIP_ROUTE=1`）：core **623.48×540.78 µm = 337,141 µm²**、die 627.78×545.5、util 58%、setup **+6.28 ns**、hold **−0.22 ns**、宏 `FIXED (64000,64000)`；route 卡在 **19 个 std-cell pin-access**（`#stdCellPinNoAp=19` → `rst_n #node != #rpin`），且该 OpenROAD 无 `write_gds`。详见 [MACRO_PORT_NOTES.md](MACRO_PORT_NOTES.md)。
- CI 当前跑行为版；宏版 P&R 修好后切换并加入宏 GDS/SPICE 的 DRC/LVS。


## 宏版 CI（0-DRC 流程）

- P&R 已用 `pnr/run_mlc_macro_route_fix.tcl`（0 DRC，`route_drc.rpt` 0 字节，DEF 1,985,265 B）。
- `github-workflows/sky130-macro.yml` 已切换该脚本，步骤：
  1. `yosys -s sky130/synth/synth_mlc_macro.ys`
  2. `openroad -no_init -exit sky130/pnr/run_mlc_macro_route_fix.tcl`（TCL 内 `catch {write_gds}`，新 OpenROAD 会出 GDS）
  3. `python3 sky130/klayout/merge_macro.py ... 64 64`（宏在 (64,64) µm）
  4. `sky130A_mr.drc`
  5. `sky130A.lvs`/Netgen
  6. 上传 `sky130/out/`
- 本地 KLayout 已验证可读宏 GDS：161 cells、top `sky130_sram_1kbyte_1rw1r_32x256_8`、DBU 1 nm。
- 本地旧 OpenROAD 无 `write_gds`，GDS 步骤只在 CI（`openroad/orfs` 镜像）执行。
