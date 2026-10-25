# SKY130 宏一体化流程

## 一条命令

```bash
bash sky130/run_all.sh
```

依次执行：

1. **Yosys** `synth_mlc_macro.ys` → `out/mlc_storage_macro_sky130.v`
2. **OpenROAD** `run_mlc_macro_route_fix.tcl` → DEF（**0 DRC**，`route_drc.rpt` 空）
3. **GDS**：TCL 内 `catch {write_gds}`；旧 OpenROAD 无此命令则跳过并提示
4. **合并宏 GDS**：`klayout/merge_macro.py`，宏放 `(64,64) µm`
5. **DRC**：`sky130A_mr.drc`
6. **LVS**：宏 `.sp` + std-cell `.spice` + 设计 `.sp` → `sky130A.lvs` / Netgen

## 已验证（本地）

| 阶段 | 结果 |
|---|---|
| TB | **95/95 PASS** |
| 综合 | **596 cells / 5,426.45 µm²** + 宏 **190,712.55 µm²** |
| P&R | **0 DRC**、DEF **1,985,265 B**、design **196,273 µm²（58%）**、setup **+8.486 ns**、hold **+0.434 ns** |
| 宏 OBS | met1/2/5 全铺；met3 留左 2 µm pin 条带；met4 留 2 µm 边距 |
| KLayout | 可读宏 GDS（161 cells、top cell、1 nm DBU） |

## 只在 CI（本地工具缺失）

- **GDS**：本地 OpenROAD `f12e2f4` 无 `write_gds`。
- **DRC/LVS**：需要 volare/open_pdks 的 `sky130A_mr.drc`、`sky130A.lvs` 与 std-cell SPICE；CI 安装。
- CI：[github-workflows/sky130-macro.yml](github-workflows/sky130-macro.yml)（9 步，YAML 通过），P&R 已用 0-DRC fix 脚本。

## CI 使用

```bash
cp sky130/github-workflows/sky130-macro.yml .github/workflows/sky130-macro.yml
git add sky130 .github/workflows/sky130-macro.yml
git commit -m "sky130 macro: integrated synth->PnR->GDS->DRC->LVS"
git push
```

产物：`drc_macro.lyrdb`、`lvs_macro.rpt`、`mlc_storage_macro_merged.gds`、DEF、日志。

## 已知边界

- LVS 的 schematic 需要设计 SPICE；`run_lvs.sh` 用 `yosys write_spice` 尽力生成，失败时依赖 KLayout deck 的 layout-vs-schematic 模式。
- 宏 SPICE（`.sp`）已随宏下载；CI 里拼接进 `lvs_schematic.sp`。
- 本地无 `write_gds`，GDS/DRC/LVS 只能 CI 跑。
