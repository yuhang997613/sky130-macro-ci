# SKY130 OpenRAM 宏移植状态 / Macro port status

## 状态 / Status

- **RTL + TB + 综合通过**；P&R 完成 floorplan → 宏放置 → PDN → place/CTS/legalize → global route，**TritonRoute 因 19 个标准单元 pin 无 access point 而中止**。
- **无 GDS**：该 OpenROAD 二进制未编译 `write_gds`（`invalid command name write_gds`），因此 KLayout DRC/LVS 尚未运行。

## 数字 / Numbers

| 项 | 值 |
|---|---|
| TB | **PASS 95/95** |
| 综合 | **596 cells / 5,426.45 µm²**（std）+ 宏 Liberty **190,712.55 µm²** |
| 对比行为版 | 2,572 cells / 20,739.9 µm²（逻辑面积 −73.8%） |
| core | **623.48 × 540.78 µm = 337,141 µm²**，util 58% |
| die | 627.78 × 545.5 µm |
| Setup WNS @20 ns | **+6.28 ns**（最差 u_sram/dout1[0] → _0991_/D） |
| Hold WNS | **−0.22 ns**（未做 hold repair） |
| 宏 | `FIXED ( 64000 64000 ) N`（DBU 1000/µm） |
| DRC / GDS | n/a（route 未完成、无 write_gds） |

## 精确错误 / Exact errors

1. `#stdCellPinNoAp = 19` → `Error: net rst_n initial #node != #rpin` / `Error: mismatch in nodes and ripins size`。已试 met4 1.0 µm/60 pitch + met5 1.6 µm/120 pitch、density 0.35、60 µm 通道、`set_placement_padding left/right 1`，仍是 19；宏侧 AP 正常（`#macroNoAp=0`，238 planar）。下一步：sky130hd met1 `-follow_pin` rail straps 或 ORFS sky130hd PDN 配置。
2. `write_gds` 不在该 OpenROAD build：需用 KLayout DEF+LEF stream out。
3. pdngen：`No macro grid specifications found - no straps added`；宏 `vccd1/vssd1` 已全局连到 VPWR/VGND，但没有专用 strap landing。

## 移植陷阱 / Porting traps

- site 是 **`unithd`**（不是 `sky130_fd_sc_hd`）。
- `create_placement_blockage` 不存在，用 `odb::dbBlockage_create`（DBU）。
- **CTS 会把 clock buffer 放到宏顶**：CTS 后必须重跑 `detailed_placement`，否则 DRT-0073 pin-access。
- `link_design` 会把 `one_`/`zero_` 建成 POWER/GROUND 网，TritonRoute 拒绝 → 降为 SIGNAL。
- iverilog `-g2012` 不接受 `reg dist`（改名 delta）；Yosys 0.33 无 `set` 命令（.ys 不能用变量）。

## 语义 / Semantics

- 读延迟从 ~7 拍变 ~12 拍；写新增 `S_W_COMMIT`。
- `inj_en` 变为 3 拍 RMW，只在 FSM idle 生效（存储内容不变）。
- SRAM 上电内容未定义（原行为数组靠 `initial mem=0`）；固件需先清零，TB 预加载 `u_dut.u_sram.mem`。

## 下一步 / Next

1. 修 19 个 std-cell AP：引入 sky130hd 的 met1 follow-pin rail / PDN 配置，或调整 floorplan 密度与通道。
2. 出 GDS：KLayout 读 DEF+LEF 流片，或换带 `write_gds` 的 OpenROAD。
3. DRC：`sky130A_mr.drc`（需合并宏 GDS）。
4. LVS：综合网表 + 宏 `.sp` vs 提取网表（`sky130A.lvs` / Netgen）。
