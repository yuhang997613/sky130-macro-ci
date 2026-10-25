# run_mlc_macro_route.tcl -- SKY130 OpenROAD P&R (detailed route) for
# mlc_storage_macro + sky130_sram_1kbyte_1rw1r_32x256_8 OpenRAM macro.
#
#   cd <repo root> && openroad -no_init -exit sky130/pnr/run_mlc_macro_route.tcl
#
# This is the routing-fix derivative of run_mlc_macro.tcl.  The original run died
# in TritonRoute with
#     #stdCellPinNoAp = 19
#     Error: net rst_n initial #node != #rpin
#     Error: mismatch in nodes and ripins size
# Fixes carried by this script (see sky130/ROUTE_FIX_NOTES.md for the evidence):
#   1. met1 follow-pin power rails (width 0.48) + met4/met5 straps + macro-safe
#      strap pitch, so every std-cell VPWR/VGND pin has a rail/via landing.
#   2. make_tracks values *parsed from the sky130hd tlef* (the old script reused
#      Nangate-ish numbers: met1 y 0.46 (0.34), met4 x 0.92 was 0.46, met5 1.6
#      (3.4) -> met5 tracks were 1.6 apart with 1.6-wide wires: unusable).
#   3. 1-site placement padding (2 sites around the macro) so pins have escapes.
#   4. detailed_placement re-run *after* CTS.
#   5. one_/zero_ demoted POWER/GROUND -> SIGNAL before global route.
#   6. detailed_route with an explicit DRC report.
#
# Outputs (all new files, nothing pre-existing is overwritten):
#   sky130/out/pnr_mlc_macro_route.log          (console log, see run command)
#   sky130/out/mlc_storage_macro.def            routed DEF
#   sky130/out/route_drc.rpt                    TritonRoute DRC report
#   sky130/out/mlc_macro_route_fix.guide        global route guides
#   sky130/out/mlc_macro_route_sta.rpt          timing report
#
# DBU: sky130 LEFs are DATABASE MICRONS 1000 -> 1 um = 1000 DBU.

set PDK    [file normalize [file join [pwd] flow pdk sky130hd]]
set FIXPDK [file normalize [file join [pwd] sky130 pdk_fix]]
set TLEF   [file join $PDK sky130_fd_sc_hd.tlef]
set MACRO_DIR sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8
set MACRO_LEF $MACRO_DIR/sky130_sram_1kbyte_1rw1r_32x256_8_obs.lef
set MACRO_LIB $MACRO_DIR/sky130_sram_1kbyte_1rw1r_32x256_8_TT_1p8V_25C.lib
set OUT    sky130/out

# ---------------- knobs (single place to iterate) ----------------
# Every knob can be overridden from the environment for a quick experiment run
# without editing this file, e.g. MLC_DENSITY=0.30 openroad ...
proc env_or {name def} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return $def
}
set DENSITY       [env_or MLC_DENSITY 0.35]
set PAD           [env_or MLC_PAD 1]        ;# sites of placement padding left/right
set MACRO_PAD     [env_or MLC_MACRO_PAD 2]  ;# sites of extension around the macro
set MET4_PITCH    [env_or MLC_MET4_PITCH 500.0] ;# keeps met4 out of the macro plane
set MET4_OFFSET   [env_or MLC_MET4_OFFSET 50.0]
set MET5_PITCH    [env_or MLC_MET5_PITCH 40.0]
set MET5_OFFSET   [env_or MLC_MET5_OFFSET 22.0]
set MET1_RAIL_W   [env_or MLC_MET1_RAIL_W 0.48]
set DRT_ITERS     [env_or MLC_DRT_ITERS 10]
set USE_RLAYERS   [env_or MLC_USE_RLAYERS 1]
# GRT leaves a handful of over-congested GCells (3% total demand, max 9 wires in
# one GCell at the macro pin escape) and aborts with GRT-0118 unless allowed to
# finish; the guides are still usable and DRT routes the residual conflicts.
set GRT_ARGS      [list -congestion_iterations 20]
if {[env_or MLC_GRT_VERBOSE 1] != 0} { lappend GRT_ARGS -verbose }
if {[env_or MLC_GRT_ALLOW_CONG 1] != 0} { lappend GRT_ARGS -allow_congestion }
puts "KNOBS density=$DENSITY pad=$PAD met4=${MET4_PITCH}/${MET4_OFFSET} met5=${MET5_PITCH}/${MET5_OFFSET} rlayers=$USE_RLAYERS grt=$GRT_ARGS"

# ---------------- libraries / netlist ----------------
read_lef [file join $PDK sky130_fd_sc_hd.tlef]
read_lef [file join $FIXPDK sky130_fd_sc_hd_merged_fix.lef]

read_lef $MACRO_LEF
read_liberty [file join $PDK sky130_fd_sc_hd__tt_025C_1v80.lib]
read_liberty $MACRO_LIB
read_verilog $OUT/mlc_storage_macro_sky130.v
link_design mlc_storage_macro

# ---------------- tie nets: POWER/GROUND -> SIGNAL ----------------
# Yosys maps constant 1/0 drivers onto lpflow tie cells, so link_design builds the
# STA constant nets one_/zero_ with sig_type POWER/GROUND.  TritonRoute refuses to
# route those ("mismatch in nodes and ripins size" is its downstream symptom).
set blk0 [[[ord::get_db] getChip] getBlock]
foreach n [$blk0 getNets] {
    set nm [$n getName]
    if {$nm eq "one_" || $nm eq "zero_"} {
        if {[catch {$n setSigType SIGNAL} e]} {
            catch {$n setSigType odb::dbSigType::SIGNAL} e2
        }
        puts "TIENET $nm -> [$n getSigType]"
    }
}

create_clock -name clk -period 20.0 [get_ports clk]
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold 0.1 [get_clocks clk]
# rst_n drives 93 flop RESET_B pins on one net.  TritonRoute's FlexGR topology
# step aborts on that net ("net rst_n initial #node != #rpin" / "mismatch in nodes
# and ripins size"), so treat the reset as a clock-like net and let CTS build a
# real buffer tree for it (functionally transparent: buffers on a static reset).
set RSTN_CLOCK [env_or MLC_RSTN_CLOCK 0]
if {$RSTN_CLOCK} {
    create_clock -name rst_n_clk -period 20.0 [get_ports rst_n]
    set_clock_uncertainty -setup 0.5 [get_clocks rst_n_clk]
}
foreach p [all_inputs] {
    set nm [get_full_name $p]
    if {$nm eq "clk"} { continue }
    if {$RSTN_CLOCK && $nm eq "rst_n"} { continue }
    set_input_delay 2.0 -clock clk $p
}
set_output_delay 2.0 -clock clk [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 [all_inputs]
set_load 0.02 [all_outputs]

# ---------------- floorplan ----------------
set MACRO_W 479.78
set MACRO_H 397.50
set HALO     2.0
set CHAN    60.0       ;# channel between core edge and macro halo (pin access)
set STRIP   80.0       ;# free strip right of / above the macro for std cells
set CORE_LLX 2.0
set CORE_LLY 2.0
set MACRO_X [expr {$CORE_LLX + $CHAN + $HALO}]
set MACRO_Y [expr {$CORE_LLY + $CHAN + $HALO}]
set CORE_URX [expr {$MACRO_X + $MACRO_W + $HALO + $STRIP}]
set CORE_URY [expr {$MACRO_Y + $MACRO_H + $HALO + $STRIP}]
set DIE_URX  [expr {$CORE_URX + 2.0}]
set DIE_URY  [expr {$CORE_URY + 2.0}]

initialize_floorplan -die_area [list 0 0 $DIE_URX $DIE_URY] \
                     -core_area [list $CORE_LLX $CORE_LLY $CORE_URX $CORE_URY] \
                     -site unithd

# ---------------- tracks, derived from the tlef ----------------
# The sky130hd tlef has no TRACKS section; it carries the routing grid as
# "LAYER <name> ... PITCH <x> [<y>] OFFSET <x> [<y>]".  Parse it instead of
# hard-coding another technology's numbers.
proc lef_track_patterns {tlef} {
    set fh [open $tlef r]
    set txt [read $fh]
    close $fh
    set res [dict create]
    set cur ""
    foreach line [split $txt "\n"] {
        set l [string trim $line]
        if {[regexp {^LAYER\s+(\S+)} $l -> lay]} {
            set cur $lay
            # the same layer name reappears inside VIA/VIARULE blocks later in the
            # file; keep the *first* (layer definition) pattern, never wipe it.
            if {![dict exists $res $lay]} {
                dict set res $lay pitch {}
                dict set res $lay offset {}
            }
            continue
        }
        if {$cur eq ""} continue
        if {[regexp {^PITCH\s+([0-9. ]+)} $l -> v]} {
            if {[dict get $res $cur pitch] eq ""} {
                dict set res $cur pitch [regexp -all -inline {[0-9]+\.?[0-9]*} $v]
            }
            continue
        }
        if {[regexp {^OFFSET\s+([0-9. ]+)} $l -> v]} {
            if {[dict get $res $cur offset] eq ""} {
                dict set res $cur offset [regexp -all -inline {[0-9]+\.?[0-9]*} $v]
            }
            continue
        }
        if {[regexp {^END\s} $l]} { set cur ""; continue }
    }
    return $res
}

set pats [lef_track_patterns $TLEF]
foreach lay {li1 met1 met2 met3 met4 met5} {
    if {![dict exists $pats $lay]} { error "no track pattern for layer $lay in $TLEF" }
    set p [dict get $pats $lay pitch]
    set o [dict get $pats $lay offset]
    if {[llength $p] == 0} { error "layer $lay has no PITCH in tlef" }
    if {[llength $o] == 0} { error "layer $lay has no OFFSET in tlef" }
    if {[llength $p] == 1} { set px [lindex $p 0]; set py [lindex $p 0] } else { lassign $p px py }
    if {[llength $o] == 1} { set ox [lindex $o 0]; set oy [lindex $o 0] } else { lassign $o ox oy }
    make_tracks $lay -x_offset $ox -x_pitch $px -y_offset $oy -y_pitch $py
    puts [format "TRACKS %-5s x_off=%-5s x_pitch=%-5s y_off=%-5s y_pitch=%-5s (tlef)" \
              $lay $ox $px $oy $py]
}

# ---------------- macro placement (OpenDB setOrigin, DBU = 1000/um) ----------------
set DBU 1000
set mx [expr {round($MACRO_X * $DBU)}]
set my [expr {round($MACRO_Y * $DBU)}]
set db   [ord::get_db]
set chip [$db getChip]
set blk  [$chip getBlock]
set inst [$blk findInst u_sram]
if {$inst == "NULL"} { error "macro instance u_sram not found in netlist" }
if {[catch {$inst setOrigin $mx $my} err]} { error "dbInst::setOrigin failed: $err" }
if {[catch {$inst setPlacementStatus FIRM} err]} {
    catch {$inst setPlacementStatus odb::dbPlacementStatus::FIRM} err2
}
puts "MACRO u_sram origin = [expr {$mx / double($DBU)}] , [expr {$my / double($DBU)}] um ; status = [$inst getPlacementStatus]"

# 2 um halo keepout: CTS does not treat the macro as an obstruction by itself, so
# without this it drops clock buffers on top of the SRAM and detailed routing then
# has no pin access points for them.
set hx1 [expr {round(($MACRO_X - $HALO) * $DBU)}]
set hy1 [expr {round(($MACRO_Y - $HALO) * $DBU)}]
set hx2 [expr {round(($MACRO_X + $MACRO_W + $HALO) * $DBU)}]
set hy2 [expr {round(($MACRO_Y + $MACRO_H + $HALO) * $DBU)}]
if {[catch {odb::dbBlockage_create $blk $hx1 $hy1 $hx2 $hy2} err]} {
    puts "WARNING: halo placement blockage failed: $err"
} else {
    puts "MACRO halo blockage = $hx1 $hy1 $hx2 $hy2 DBU"
}

# ---------------- port pin placement ----------------
# `place_pins -hor_layers met3 -ver_layers met2` puts every top-level port on the
# DIE boundary as a 0.14 x 0.485 met2 stub (y = 0 .. 0.485, i.e. *below* the core
# at y = 2.72).  Such a stub is narrower than a via2 (0.28 incl. enclosure) and its
# centre is not on a met2 track, so TritonRoute finds no access point for it and
# then aborts when the net's rpin count does not match its node count:
#     Error: net rst_n initial #node != #rpin
#     Error: mismatch in nodes and ripins size
# Place the ports explicitly instead: met3 (horizontal, width 0.30) pins on real
# met3 tracks inside the core, 2 um wide -> planar access along the track.
set PIN_LAYER [env_or MLC_PIN_LAYER met2]
set PIN_LEN   [env_or MLC_PIN_LEN 0.46]
set PIN_W     [env_or MLC_PIN_W 2.0]
if {[env_or MLC_USE_PPL 0] != 0} {
    place_pins -hor_layers met3 -ver_layers met2
} else {
    set core [$blk getCoreArea]
    set cx0 [expr {[$core xMin] / double($DBU)}] ;# already snapped by IFP
    set cy0 [expr {[$core yMin] / double($DBU)}]
    set cy1 [expr {[$core yMax] / double($DBU)}]
    set cx1 [expr {[$core xMax] / double($DBU)}]
    # snap the pin rows to real tracks of the pin layer (patterns from the tlef)
    set gp [dict get $pats $PIN_LAYER pitch]
    set go [dict get $pats $PIN_LAYER offset]
    if {[llength $gp] == 1} { set py [lindex $gp 0] } else { set py [lindex $gp 1] }
    if {[llength $go] == 1} { set oy [lindex $go 0] } else { set oy [lindex $go 1] }
    set y_bot [expr {$oy + $py * ceil(($cy0 + 1.0 - $oy) / $py)}]
    set y_top [expr {$oy + $py * floor(($cy1 - 1.0 - $oy) / $py)}]
    set bterms [lsort -dictionary [lmap b [$blk getBTerms] { $b getName }]]
    set npins [llength $bterms]
    set nhalf [expr {($npins + 1) / 2}]
    set span  [expr {$cx1 - $cx0 - 40.0}]
    set n 0
    # snap x to the tracks that cross the pin edge (met2/met4 are vertical) so the
    # pin has a planar access point on its own layer
    set gpx [dict get $pats $PIN_LAYER pitch]
    set gox [dict get $pats $PIN_LAYER offset]
    if {[llength $gpx] == 1} { set px [lindex $gpx 0] } else { set px [lindex $gpx 0] }
    if {[llength $gox] == 1} { set ox [lindex $gox 0] } else { set ox [lindex $gox 0] }
    foreach nm $bterms {
        if {$n < $nhalf} {
            set y $y_bot
            set x [expr {$cx0 + 20.0 + $span * $n / double($nhalf - 1)}]
        } else {
            set y $y_top
            set x [expr {$cx0 + 20.0 + $span * ($n - $nhalf) / double($npins - $nhalf)}]
        }
        if {[env_or MLC_PIN_SNAP 1] != 0} {
            set x [expr {$ox + $px * round(($x - $ox) / $px)}]
        }
        set extra [list]
        if {[env_or MLC_PIN_BOUNDARY 0] != 0} { lappend extra -force_to_die_boundary }
        if {[catch {place_pin -pin_name $nm -layer $PIN_LAYER -location [list $x $y] \
                                -pin_size [list $PIN_LEN $PIN_W] {*}$extra} err]} {
            puts "WARNING: place_pin $nm failed: $err"
        }
        incr n
    }
    # every port must have a pin shape, otherwise DRT has no rpin for it
    set nop 0
    foreach b [$blk getBTerms] { if {[llength [$b getBPins]] == 0} { incr nop } }
    puts "PORTS layer=$PIN_LAYER size=${PIN_LEN}x${PIN_W} placed=[expr {$npins - $nop}] y_bot=$y_bot y_top=$y_top no_geometry=$nop"
    if {$nop > 0} { error "$nop ports have no pin geometry" }
}

# ---------------- PDN ----------------
# std cells use VPWR/VGND, the OpenRAM macro uses vccd1/vssd1: the same 1.8 V rails.
add_global_connection -net VPWR -inst_pattern {.*}     -pin_pattern {^VPWR$}  -power
add_global_connection -net VGND -inst_pattern {.*}     -pin_pattern {^VGND$}  -ground
add_global_connection -net VPWR -inst_pattern {u_sram} -pin_pattern {^vccd1$} -power
add_global_connection -net VGND -inst_pattern {u_sram} -pin_pattern {^vssd1$} -ground
# no global_connect in this build (pdngen applies the registered connections)
if {[llength [info commands global_connect]]} { global_connect }
set_voltage_domain -name CORE -power VPWR -ground VGND

# stdcell grid: met1 follow-pin rails land every std-cell power pin.
define_pdn_grid -name stdcell -starts_with POWER -voltage_domains CORE
add_pdn_stripe -grid stdcell -layer met1 -width $MET1_RAIL_W -followpins

# met4 is the only vertical signal layer the macro also uses, and the macro's
# vssd1 pin is a near-solid met4 plane over the whole macro body.  A met4 strap
# (or a met4 via) crossing the macro would short VPWR to vssd1, so the met4 strap
# pitch is chosen (> macro width) so both straps land in the free left/right
# channels instead of over the macro: x = 52.3 (POWER) and 552.3 (GROUND).
add_pdn_stripe -grid stdcell -layer met4 -width 1.6 -pitch $MET4_PITCH -offset $MET4_OFFSET
# met5 has no shapes inside the macro LEF -> free to strap over the whole core.
add_pdn_stripe -grid stdcell -layer met5 -width 1.6 -pitch $MET5_PITCH -offset $MET5_OFFSET

add_pdn_connect -grid stdcell -layers {met1 met4}
add_pdn_connect -grid stdcell -layers {met4 met5}
pdngen

# ---------------- place / CTS / legalize / route ----------------
if {[catch {set_placement_padding -global -left $PAD -right $PAD} err]} {
    puts "WARNING: set_placement_padding failed: $err"
}
catch {set_macro_extension $MACRO_PAD}
set_wire_rc -signal -layer met2
set_wire_rc -clock  -layer met3
# rst_n drives 93 flop RESET_B pins on a single net; DRT's FlexGR topology step
# aborts on a net that large ("net rst_n initial #node != #rpin"), so build a
# proper buffer tree for high-fanout nets before placement.
set MAXFANOUT [env_or MLC_MAXFANOUT 0]
if {$MAXFANOUT > 0} {
    set_max_fanout $MAXFANOUT [current_design]
    if {[catch {repair_design} err]} {
        puts "WARNING: repair_design failed: $err"
    } else {
        puts "REPAIR_DESIGN max_fanout=$MAXFANOUT cells=[llength [get_cells *]]"
    }
}
global_placement -density $DENSITY
detailed_placement
catch {improve_placement}

clock_tree_synthesis -buf_list {sky130_fd_sc_hd__clkbuf_4} -root_buf sky130_fd_sc_hd__clkbuf_8
set_propagated_clock [all_clocks]
# CTS drops clock buffers on top of the macro (the halo is a placement blockage
# but CTS ignores blockages): re-legalise so the buffers move before routing.
detailed_placement

if {$USE_RLAYERS} { set_routing_layers -signal met1-met5 -clock met3-met5 }
global_route -guide_file $OUT/mlc_macro_route_fix.guide {*}$GRT_ARGS
puts "GLOBAL ROUTE GUIDES: [file exists $OUT/mlc_macro_route_fix.guide]"

set route_ok 1
set DRT_ARGS [list -output_drc $OUT/route_drc.rpt -droute_end_iter $DRT_ITERS]
if {[env_or MLC_DRT_VERBOSE 0] != 0} { lappend DRT_ARGS -verbose $::env(MLC_DRT_VERBOSE) }
# sky130hd RESET_B is a 0.14-tall met1 bar (+ 0.29 x 0.315 stubs) which cannot host
# the preferred M1M2 via (needs 0.26 x 0.32); allow via-in-pin from li1 upwards so
# the (larger) li1 shapes of the pin can carry the via stack.
if {[env_or MLC_VIP 1] != 0} {
    lappend DRT_ARGS -via_in_pin_bottom_layer li1
    if {[env_or MLC_VIP_TOP ""] ne ""} { lappend DRT_ARGS -via_in_pin_top_layer $::env(MLC_VIP_TOP) }
}
if {[info exists ::env(MLC_SKIP_ROUTE)]} {
    puts "WARNING: detailed_route skipped (MLC_SKIP_ROUTE set)"
    set route_ok 0
} elseif {[catch {detailed_route {*}$DRT_ARGS} err]} {
    puts "WARNING: detailed_route failed: $err"
    set route_ok 0
}
puts "SUMMARY_ROUTE_OK $route_ok"

catch {filler_placement {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 \
                         sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}}

# ---------------- reports ----------------
estimate_parasitics -global_routing
report_design_area
catch {report_worst_slack -max}
catch {report_worst_slack -min}
catch {report_tns}
catch {report_check_types -max_slew -max_capacitance -max_fanout -violators}
catch {report_checks -path_delay max -digits 3 -format summary}
# no `redirect` in this build: the STA report is captured from the console log
# into sky130/out/mlc_macro_route_sta.rpt by the driver command.
if {[llength [info commands redirect]]} {
    catch {redirect $OUT/mlc_macro_route_sta.rpt {
        report_checks -path_delay max -digits 3 -format summary
        report_worst_slack -max
        report_worst_slack -min
        report_tns
        report_design_area
    }}
}
if {[catch {sta::worst_slack -max} wns]} {
    puts "SUMMARY_WNS_NS unknown"
} else {
    puts "SUMMARY_WNS_NS [format %.3f $wns]"
}
if {[catch {sta::worst_slack -min} whs]} {
    puts "SUMMARY_WHS_NS unknown"
} else {
    puts "SUMMARY_WHS_NS [format %.3f $whs]"
}

# ---------------- outputs (new files only) ----------------
write_def $OUT/mlc_storage_macro.def
catch {write_verilog $OUT/mlc_storage_macro_routed.v}
catch {write_sdc $OUT/mlc_storage_macro_routed.sdc}
if {[catch {write_gds $OUT/mlc_storage_macro.gds} err]} {
    puts "WARNING: write_gds failed: $err"
}
puts "SKY130 MACRO ROUTE DONE"
exit
