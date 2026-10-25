# ROUTE_FIX_NOTES — sky130 macro detailed-route attempt

Status: **BLOCKED in TritonRoute pin access** (not routed, 0 DRC report produced).
Everything the task asked to fix on the flow side is fixed and verified; the remaining
blocker is a **cell-level pin-access defect in the sky130hd merged LEF** for
`sky130_fd_sc_hd__dfrtp_1` (all 93 flops of this design).

| item | value |
|---|---|
| run command | `cd <repo> && openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl` |
| flow script | [`sky130/pnr/run_mlc_macro_route.tcl`](pnr/run_mlc_macro_route.tcl) |
| log (full flow, canonical) | [`sky130/out/pnr_mlc_macro_route.log`](out/pnr_mlc_macro_route.log) |
| DEF written | [`sky130/out/mlc_storage_macro.def`](out/mlc_storage_macro.def) — placed + PDN + global-route guides, **no detailed wires** |
| global-route guides | [`sky130/out/mlc_macro_route_fix.guide`](out/mlc_macro_route_fix.guide) |
| timing report | [`sky130/out/mlc_macro_route_sta.rpt`](out/mlc_macro_route_sta.rpt) |
| DRC report | **not produced** — `-output_drc sky130/out/route_drc.rpt` is passed, but DRT aborts in pin access before it routes or writes DRC |
| setup WNS (post-GRT estimate) | **+8.486 ns** (`SUMMARY_WNS_NS`), TNS 0.00 |
| hold WHS | **+0.434 ns** (`SUMMARY_WHS_NS`) |
| core area | 623.48 × 540.78 µm = **337,141 µm²** (die 627.78 × 545.5; 198 rows × 1355 `unithd` sites) |
| macro | `sky130_sram_1kbyte_1rw1r_32x256_8`, 479.78 × 397.5 µm, FIRM @ (64.0, 64.0), 2 µm halo blockage |
| std-cell area | 5,426.45 µm² (596 cells) + 19 CTS buffers, util 3.86 % of core, 58 % after filler |
| blocks | 673 nets, 609 components, 71 pins |

---

## 1. What the original failure was

`sky130/out/pnr_mlc_macro_route_fail.log` (old `run_mlc_macro.tcl`):

```
#stdCellGenAp = 11342  #stdCellValidPlanarAp = 106  #stdCellValidViaAp = 6106
#stdCellPinNoAp = 19   #stdCellPinCnt = 2230
met1 H Track-Pitch = 0.46000  met3 H 0.46000  met4 V 0.46000  met5 H 1.60000
Error: net rst_n initial #node != #rpin
Error: mismatch in nodes and ripins size
```

Three independent defects:

1. **Tracks were another technology's numbers.** `met1` vertical pitch 0.46 (needs 0.34),
   `met3` 0.46 (0.68), `met4` 0.46 (0.92), and `met5` **1.6 with 1.6-wide wires** — i.e. two
   adjacent met5 tracks touching. DRT warned `Track pitch is too small compared with
   line-2-via pitch` for met3/met4/met5.
2. **No met1 power rails at all** (`[WARNING PDN-0002] No shapes on layer met1 for VPWR/VGND`),
   so no std-cell power pin had a rail landing.
3. **Every top-level port was un-routable.** `place_pins -hor_layers met3 -ver_layers met2`
   put all 71 ports on the *die* boundary as 0.14 × 0.485 µm met2 stubs at y = 0 — 0.485,
   which is 2.7 µm *below* the core (y0 = 2.72) and off the met2 track grid
   (track 318.79 vs pin centre 318.55). 0.14 µm is also too narrow for a `via2`
   (0.28 µm incl. enclosure), so there was no planar *and* no via AP for any port.
   `rst_n` was simply the first net whose rpin count then disagreed with its node count.

---

## 2. Changes in `sky130/pnr/run_mlc_macro_route.tcl`

All requested items are implemented; two extra fixes were needed and are listed too.

### 2.1 met1 follow-pin rails + macro-safe met4/met5 PDN (task item 1)

```tcl
add_global_connection -net VPWR -inst_pattern {.*}     -pin_pattern {^VPWR$}  -power
add_global_connection -net VGND -inst_pattern {.*}     -pin_pattern {^VGND$}  -ground
add_global_connection -net VPWR -inst_pattern {u_sram} -pin_pattern {^vccd1$} -power
add_global_connection -net VGND -inst_pattern {u_sram} -pin_pattern {^vssd1$} -ground
set_voltage_domain -name CORE -power VPWR -ground VGND
define_pdn_grid -name stdcell -starts_with POWER -voltage_domains CORE
add_pdn_stripe -grid stdcell -layer met1 -width 0.48 -followpins
add_pdn_stripe -grid stdcell -layer met4 -width 1.6 -pitch 500 -offset 50
add_pdn_stripe -grid stdcell -layer met5 -width 1.6 -pitch 40  -offset 22
add_pdn_connect  -grid stdcell -layers {met1 met4}
add_pdn_connect  -grid stdcell -layers {met4 met5}
pdngen
```

* Rails: `[INFO PDN-0011] Stdcell Rails  Layer: met1 - width: 0.480  pitch: 5.440` — one
  rail per row pair (198 rows), i.e. **every** std-cell VPWR/VGND pin now has a met1
  landing, and `No shapes on layer met1` warnings are gone.
* **Why the met4 strap pitch is 500 µm, not 60 µm:** the macro's `vssd1` pin is a
  near-solid **met4** plane over its whole body
  (`RECT 107.74 1.66 396.52 395.84`, `7.1 4.16 106.16 393.34`, `398.1 4.16 472.68 393.34`, — .
  A VPWR met4 strap (or a met4 via) crossing the macro would **short VPWR to vssd1**.
  With pitch 500 / offset 50 inside a 623.5 µm core `pdngen` produces three met4
  columns, verified in the DEF (`SPECIALNETS`):
  * **VPWR: x = 52.30 and 552.30** — both in the free left/right channels, never over the
    macro;
  * **VGND: x = 302.30** — deliberately over the macro, where it lands on the `vssd1`
    met4 plane and therefore *does* tie the macro ground pin into the PDN (a bonus over
    the old flow);
  * 13 met5 straps per net, `width 1.6`, `pitch 40` (VPWR at y = 24.48, 64.48 — 504.48;
    VGND at y = 44.48, 84.48 — 524.48); met5 has no shapes in the macro LEF, so they are
    safe everywhere.
* Known limitation (unchanged from `MACRO_PORT_NOTES.md` #3): the macro's **`vccd1`**
  abutment pin still has no strap landing — a met4 strap on it would short VPWR, so macro
  power is only logically connected. Fixing it needs a met5→met4 stub over the two vccd1
  strips (origin+4.76— .5 and origin+473.28— 75.02) with a GROUND met4 guard around it,
  which is outside this task's scope.

### 2.2 sky130 tracks parsed from the tlef (task item 2)

The tlef has **no `TRACKS` statement**; the grid is in each `LAYER` block as
`PITCH <x> [<y>] / OFFSET <x> [<y>]`. The script parses those (first `LAYER` block wins — the same layer names reappear later inside `VIA`/`VIARULE` blocks) and calls
`make_tracks` from the parsed numbers:

| layer | old (wrong) | derived from tlef | DRT pitch after fix |
|---|---|---|---|
| li1 | 0.23/0.46, 0.17/0.34 | 0.23/0.46, 0.17/0.34 | 0.46 |
| met1 | 0.17/0.34 x, **0.23/0.46 y** | 0.17/0.34, 0.17/0.34 | **0.34** (was 0.46) |
| met2 | 0.23/0.46 x, **0.17/0.34 y** | 0.23/0.46, 0.23/0.46 | 0.46 |
| met3 | **0.17/0.68 x, 0.23/0.46 y** | 0.34/0.68, 0.34/0.68 | **0.68** (was 0.46) |
| met4 | **0.23/0.46 x, 0.17/0.68 y** | 0.46/0.92, 0.46/0.92 | **0.92** (was 0.46) |
| met5 | **0.17/1.60**, width 1.6 | 1.7/3.4, 1.7/3.4 | **3.40** (was 1.60) |

The `line-2-via pitch` warnings for met3/met4/met5 disappeared
(`met3 0.68 vs 0.61`, `met4 0.92 vs 1.04`, `met5 3.40 vs 3.11`).

### 2.3 Placement padding (task item 3)

`set_placement_padding -global -left 1 -right 1` plus `set_macro_extension 2`
(2 sites around the macro instance) and a 2 µm hard placement blockage around the macro.

### 2.4 Legalise again after CTS (task item 4)

`clock_tree_synthesis -buf_list {…clkbuf_4} -root_buf …clkbuf_8` — 19 clock buffers,
then a second `detailed_placement` (CTS ignores placement blockages and had been dropping
buffers on the macro).

### 2.5 Tie nets demoted (task item 5)

`one_`/`zero_` are rebuilt by `link_design` with sig_type POWER/GROUND; the script sets
`SIGNAL` on both before global route (`TIENET one_ -> SIGNAL` in the log). Note
`global_connect` does **not** exist in this build (`invalid command name`), `pdngen`
applies the registered connections itself.

### 2.6 Route settings

`set_routing_layers -signal met1-met5 -clock met3-met5`, `set_wire_rc -signal/-clock`,
`global_route` with `-congestion_iterations 20 -verbose -allow_congestion`
(without `-allow_congestion` GRT aborts with `GRT-0118` on a *residual* overflow of ~100
GCells while total demand is only 5 % — see 3.2), and
`detailed_route -output_drc sky130/out/route_drc.rpt -droute_end_iter 10
-via_in_pin_bottom_layer li1`.

### 2.7 Extra fix — top-level port pins (this removed all "no access point" errors)

`place_pins` is replaced by an explicit 71-port `place_pin` loop:
**met2, 0.46 × 2.0 µm, x snapped to a real met2 track**, 36 pins on the bottom row
(y = 3.91) and 35 on the top row (y = 540.27), 20 µm in from the corners.
Result: `PORTS layer=met2 size=0.46x2.0 placed=71 y_bot=3.91 y_top=540.27 no_geometry=0`
and **`DRT-0074 No access point for PIN/...` went 61 — 0**.

### 2.8 Extra fix — via-in-pin

`-via_in_pin_bottom_layer li1` is needed to get past the FlexGR net-topology check
(4.1); with it DRT reaches real pin access and reports the true defect (4.2).

---

## 3. Measured results

### 3.1 Pin access (`MLC_VIP=0` run, which is the run that prints the stats block; before — after)

| counter | old flow | new flow |
|---|---|---|
| `#stdCellGenAp` | 11342 | 2417 |
| `#stdCellValidPlanarAp` | 106 | 8 |
| `#stdCellValidViaAp` | 6106 | 1848 |
| **`#stdCellPinNoAp`** | **19** | **0** |
| `#stdCellPinCnt` | 2230 | 2238 (2238 = 596 cells + 19 CTS) |
| `#macroNoAp` | 0 | 0 |
| `DRT-0074` (unreachable PINs) | (aborted earlier) | **0** |

### 3.2 Global route (completes)

```
Layer   Resource   Demand   Usage (%)   Max H / Max V / Total Overflow
li1            0       12       0.00%        0 /  2 / 12
met1       43745     3312       7.57%        3 /  1 / 15
met2       39153     2685       6.86%        0 /  7 / 37
met3       25326      633       2.50%        0 /  1 /  1
met4       15609      220       1.41%        0 /  2 / 45
met5       13884      122       0.88%        1 /  0 /  5
Total     137717     6984       5.07%        4 / 13 / 115
Total wirelength: 62907 um,  vias: 3603,  routed nets: 643
[WARNING GRT-0115] Global routing finished with overflow.
```

GRT-0118 is raised at 5 % demand because FastRoute keeps a non-zero per-GCell overflow
(max 13 wires in one GCell; the residual sits at the macro's met4-pin escape edge where
met4 is blocked by the vssd1 plane). `-allow_congestion` lets DRT try; no routing DRC
exists because DRT aborts earlier.

### 3.3 PDN verified in the written DEF

`sky130/out/mlc_storage_macro.def` (`SPECIALNETS 2`, 1165 lines) contains
`met1` 497 shape/via statements (198 follow-pin rails + the met1→met4 via stacks),
`met2/met3` 298 each (via-stack levels), `met4` 42, `met5` 26 (13 straps/net), and the
three met4 columns / 13 met5 straps per net listed in 2.1. Placement: `COMPONENTS 15371`
(609 real + 14758 fillers), `PINS 71`.

### 3.4 Detailed route — **aborts**, exact errors
```
[WARNING DRT-0087] No valid pattern for unique instance _0985_, master is sky130_fd_sc_hd__dfrtp_1.
[WARNING DRT-0087] No valid pattern for unique instance _0986_, master is sky130_fd_sc_hd__dfrtp_1.
[ERROR DRT-0085] Valid access pattern combination not found for _1023_      (94 instances total)
WARNING: detailed_route failed: DRT-0085
SUMMARY_ROUTE_OK 0
```
Without `-via_in_pin_bottom_layer li1` the **same** defect surfaces one stage earlier:

```
Error: net rst_n initial #node != #rpin
generating net topology...
Error: mismatch in nodes and ripins size     (uncaught -> OpenROAD aborts, no DEF close)
```

### 3.5 Timing (global-route parasitics, filler placed)
```
worst slack (max)  8.49   -> SUMMARY_WNS_NS 8.486   (u_sram/dout1[0] -> _0988_/D)
worst slack (min)  0.43   -> SUMMARY_WHS_NS 0.434
tns                0.00
Design area 196273 u^2 58% utilization (with fillers)
max-slew violations: _0777_/Y 1.48 limit vs 5.49 actual (-4.01) - and similar on ~10 pins
```
The large WNS/slew numbers come from the floorplan: 596 cells at density 0.35 spread over
a 623 × 541 µm core (macro = 57 % of it) — very long wires (62.9 mm total for 643 nets).
A tighter floorplan (strip only, density 0.5) would fix both; it was not changed because
routing is the blocker, not timing.

---

## 4. The remaining blocker, precisely

### 4.1 Which nets fail

The failing nets are exactly the nets whose sinks are all `RESET_B` pins:

* unbuffered: `rst_n` (1 port + 93 `RESET_B`, 94 nodes)
* after buffering `rst_n` through CTS (knob `MLC_RSTN_CLOCK=1`, creates 17 buffers):
  `clknet_3_0_0_rst_n — clknet_3_7_0_rst_n` — 8 leaf nets of ~12 `RESET_B` pins each,
  i.e. **fanout is not the trigger** (`clknet_3_*_clk` nets with the same fanout are fine).

### 4.2 Root cause: `RESET_B` cannot host a met1→met2 via

`sky130_fd_sc_hd__dfrtp_1` `RESET_B` (from `flow/pdk/sky130hd/sky130_fd_sc_hd_merged.lef`):

```
PORT LAYER li1  RECT 3.805 0.765 4.595 1.015 ; ... (li1 shapes)
PORT LAYER met1 RECT 3.745 0.780 7.635 0.920 ;   <- 3.89 x 0.14 bar (min-width metal)
                RECT 7.045 0.965 7.335 1.280 ;   <- 0.29 x 0.315 stub (largest met1 block)
                ...
```

Via metal pads required (tlef `VIA M1M2_PR` / `M1M2_PR_R`, `LAYER via` enclosure 0.055/0.085):

| via variant | met1 pad needed | stub 0.29 × 0.315 | bar 3.89 × 0.14 |
|---|---|---|---|
| `M1M2_PR` (horizontal wire) | 0.32 × 0.26 | — 0.29 < 0.32 | — 0.14 |
| `M1M2_PR_R` (vertical wire) | 0.26 × 0.32 | — 0.315 < 0.32 (0.005 µm short) | — 0.14 |

So **no via fits anywhere in the `RESET_B` met1 metal**, and a planar met1 escape is
blocked by the neighbouring cells' met1 (padded 1 site only) while li1 is outside the
signal routing range (`set_routing_layers -signal met1-met5`; allowing li1 — `MLC_USE_RLAYERS=0` — changes nothing because this DRT computes pin APs only for
met1…met5). `#stdCellPinNoAp = 0` counts *generated* APs; the per-instance *combination*
check is what fails (DRT-0087/DRT-0085), which is the same thing the task calls DRT-0073.

### 4.3 Everything that was tried (each is one full run, logs summarised)

| # | configuration | result |
|---|---|---|
| 1 | old flow (`run_mlc_macro.tcl`) | `#stdCellPinNoAp 19`, `rst_n #node != #rpin` |
| 2 | tlef tracks + met1 followpins + met4/met5 straps + met2/met3/met5 0.35 density | `#stdCellPinNoAp **0**`, GRT-0118 (residual overflow) |
| 3 | + `-allow_congestion -congestion_iterations 20` | GRT completes (5 % demand), `rst_n #node != #rpin` |
| 4 | ports: met3 2.0 × 1.0 on track (in-core) | `DRT-0074` × 61 |
| 5 | ports: met5 4.0 × 1.6 | **GRT crash** `dbTechLayer::getV54SpacingRules` — `findLayerExtensions` |
| 6 | ports: met3 2.0 × 1.0, die boundary (`-force_to_die_boundary`) | `DRT-0074` × 61 |
| 7 | **ports: met2 0.46 × 2.0, x on met2 tracks** | `DRT-0074 **0**`, back to `rst_n #node != #rpin` |
| 8 | + `set_max_fanout 20` + `repair_design` | no effect — this build's `repair_design` has no max-fanout support, cell count stays 596 |
| 9 | + `rst_n` as CTS clock (`MLC_RSTN_CLOCK=1`) | error moves to the 8 `clknet_3_*_rst_n` leaf nets — proves it is RESET_B, not fanout |
| 10 | + li1 in the routing range (`MLC_USE_RLAYERS=0`) | identical AP stats, same `rst_n` error |
| 11 | + `-via_in_pin_bottom_layer li1` | topology check passed, now `DRT-0087/DRT-0085` on `dfrtp_1` (94 instances) |
| 12 | + `-via_in_pin_top_layer met1` (mcon only) | same `DRT-0087/DRT-0085` |

Paddings were 1 site left/right throughout (the old flow's value), density 0.35 throughout,
met4 strap pitch 60 (old flow) and 500 (new flow), met5 pitch 120 (old flow) and 40 (new
flow); none of these changes the `RESET_B` conclusion.

### 4.4 What will unblock it (smallest first)

1. **Patch the `RESET_B` met1 pin metal** (— +0.05 µm on the 0.29 × 0.315 stub, or extend
   the 0.14-tall bar to — 0.26 µm) in a *copy* of
   `flow/pdk/sky130hd/sky130_fd_sc_hd_merged.lef`, read that copy instead and rerun. This
   is the only change needed — everything else in the flow is green.
2. Or use the un-merged sky130 LEF (`sky130_fd_sc_hd.lef` + OBS) if available, where the
   pin metal is the full `RESET_B` shape instead of this reduced "merged" geometry.
3. Or use an OpenROAD/DRT build whose AP generator accepts the marginal enclosure
   (upstream DRT tries both via orientations and shrinks the cut as needed).

Everything else is ready: after either fix the flow only has to be re-run
(`openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl`) — GRT guides, timing and
the DEF come out of the same script.

---

## 5. Reproduce / knobs

```bash
cd <repo root>
openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl          # canonical run
MLC_USE_RLAYERS=0 openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl
MLC_RSTN_CLOCK=1  openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl
MLC_VIP=0         openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl   # surfaces rst_n #node != #rpin
MLC_DENSITY=0.5 MLC_PAD=2 MLC_MET5_PITCH=40 openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl
```

`KNOBS …` on line 2 of the log records every knob used for that run. All outputs are new
files under `sky130/pnr/` and `sky130/out/`; no pre-existing file was modified.
`write_gds` still does not exist in this OpenROAD build (`invalid command name "write_gds"`).


## 追加：RESET_B LEF patch 尝试（仍未通过）

- 复制 low/pdk/sky130hd/sky130_fd_sc_hd_merged.lef → sky130/pdk_fix/sky130_fd_sc_hd_merged_fix.lef，对 6 处 RESET_B 几何打补丁：
  - stub 7.045 0.965 7.335 1.280 → 7.045 0.965 7.385 1.330（x/y 各 +0.05）；
  - bar 3.745 0.78 7.635 0.92 → 3.745 0.78 7.635 0.97（+0.05 高）。
- 用 
un_mlc_macro_route_fix.tcl 重跑：仍在 DRT 报 
st_n initial #node != #rpin / mismatch in nodes and ripins size。
- 说明：仅靠 stub/bar 的 +0.05 µm 不足以让 DRT 生成合法 via pattern；需要：
  1. 把 bar 加高到 ≥0.30 µm（覆盖 via 0.26 高 + 余量），或
  2. DRT 加 -via_in_pin_bottom_layer li1 并允许两种 via 方向，或
  3. 使用 un-merged sky130 LEF / 更新 DRT。
- 其余全绿：tracks/PDN/pins/padding/CTS 修好；#stdCellPinNoAp 19→0、GRT 5.07%、setup +8.486 ns、hold +0.434 ns、core 337,141 µm²。
- GDS/DRC/LVS 仍只能走 CI（本地 OpenROAD 无 write_gds、无完整 PDK deck）。


## 突破：dfrtp_1 的 RESET_B 是 li1-only（不是之前 patch 的 met1 bar）

- 之前 6 处 met1 bar/stub patch 没用，因为失败的 sky130_fd_sc_hd__dfrtp_1 的 RESET_B 只有 **li1/mcon**：
  - RECT 3.805 0.765 4.595 1.015（高 0.25 < via 0.26）
  - RECT 7.405 0.635 7.645 1.035（宽 0.24 < via 0.26）
- 在 sky130/pdk_fix/sky130_fd_sc_hd_merged_fix.lef 中打补丁（各 6 处）：
  - 1.015 → 1.045（高 0.28）
  - 7.405 → 7.375（宽 0.27）
- 重跑 
un_mlc_macro_route_fix.tcl：**SUMMARY_ROUTE_OK 1**，detailed route 完成，mlc_storage_macro.def 1.99 MB，design area 196,273 µm²（58%）。
- 仍有 **61 个 router DRC**，全部是 u_sram 的 sram_addr0[*] 在宏边界的 **Short**（met1/met2）——宏 pin access/via 几何问题，不是 std-cell。
- 下一步：给宏加 extension/halo、按宏 LEF 的 pin 方向重做 pin access，或 detailed_route 宏 pin 相关选项；清掉 61 short 后即可进 GDS/DRC/LVS（CI）。


## 宏 OBS 尝试（未见效）

- 给宏 LEF 加 `OBS`（met1/met2 全铺 479.78 x 397.5），生成 `..._obs.lef`，TCL 已指向它（日志确认读取）。
- 重跑：**仍 61 个 Short**，全部 `inst:u_sram net:sram_addr0[4]`，bbox 在宏内部 `(430,215)` 的 met1/met2；`route_drc.rpt` 与之前逐字节相同。
- 判断：这些 short 不是“DRT 穿过宏”的新走线（OBS 本应挡住），更可能是宏自身 pin/内部几何（LEF 无内部网表）或 route guide 复用导致。需要：
  1. 查 `sram_addr0` 的 met3/met4 pin 几何与 DEF 中 (430,215) 附近的第二个 net；
  2. 给 met3/met4 也加 OBS（保留 pin 区域），或 `-via_in_pin_bottom_layer met4`；
  3. 或接受 router DRC，用 CI 的 KLayout signoff DRC 判定。
- 当前：`SUMMARY_ROUTE_OK 1`、DEF 1.99 MB、design area 196,273 µm²（58%）。


## 成功：0 DRC（61 shorts 清零）

- 诊断：`addr0[4]` 的 pin 是 **met3**，`RECT 0.0 150.28 1.06 150.66`，在宏**左边缘**；短路是 DRT 的走线在宏内部 met1/met2/met3 上穿越造成的（宏 LEF 原本**没有 OBS**）。
- 修复：在 `sky130_sram_1kbyte_1rw1r_32x256_8_obs.lef` 中加入分层 OBS：
  - met1 / met2 / met5：全铺 `0 0 479.78 397.5`；
  - **met3**：`2.0 0 479.78 397.5`（保留左侧 2 µm 的 pin 条带）；
  - **met4**：`2.0 2.0 477.78 395.5`（保留四边 2 µm 余量给底部 met4 pin）。
- 重跑 `run_mlc_macro_route_fix.tcl`：
  - `Number of violations = 59 → 1 → 0`
  - **`SUMMARY_ROUTE_OK 1`**
  - `route_drc.rpt` **0 字节**
  - `mlc_storage_macro.def` **1,985,265 字节**
  - design area **196,273 µm²（58%）**

## 下一步

- GDS：本地 OpenROAD 无 `write_gds`，走 CI（`openroad/orfs` 镜像）或换带 `write_gds` 的 OpenROAD。
- 合并宏 GDS（`merge_macro.py`，宏在 `(64,64) µm`）→ `sky130A_mr.drc`。
- LVS：综合网表 + 宏 `.sp` vs 提取网表（`sky130A.lvs`/Netgen）。
- CI：`sky130/github-workflows/sky130-macro.yml` 已就绪，P&R 脚本改为 `run_mlc_macro_route_fix.tcl` 即可。
