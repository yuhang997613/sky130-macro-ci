# SKY130 port: first-cut OpenROAD P&R (mlc_storage)
# Run from repo root:  openroad -no_init -exit sky130/pnr/run_sky130.tcl
set PDK [file normalize [file join [pwd] flow pdk sky130hd]]
foreach f [list sky130_fd_sc_hd.tlef sky130_fd_sc_hd_merged.lef] {
    read_lef [file join $PDK $f]
}
read_liberty [file join $PDK sky130_fd_sc_hd__tt_025C_1v80.lib]
read_verilog sky130/out/mlc_storage_sky130.v
link_design mlc_storage

create_clock -name clk -period 20.0 [get_ports clk]
set_clock_uncertainty -setup 0.5 [get_clocks clk]
set_clock_uncertainty -hold 0.1 [get_clocks clk]
set_input_delay 2.0 -clock clk [all_inputs]
set_output_delay 2.0 -clock clk [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 [all_inputs]
set_load 0.02 [all_outputs]

initialize_floorplan -utilization 40 -aspect_ratio 1.0 -core_space 2.0 -site sky130_fd_sc_hd
# sky130 track patterns (li1/met1..met5); tune offsets on first CI run if needed
make_tracks li1  -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.34
make_tracks met1 -x_offset 0.17 -x_pitch 0.34 -y_offset 0.23 -y_pitch 0.46
make_tracks met2 -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.34
make_tracks met3 -x_offset 0.17 -x_pitch 0.68 -y_offset 0.23 -y_pitch 0.46
make_tracks met4 -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.68
make_tracks met5 -x_offset 0.17 -x_pitch 1.60 -y_offset 0.23 -y_pitch 1.60

place_pins -hor_layers met3 -ver_layers met2
global_placement -density 0.50
detailed_placement
improve_placement
clock_tree_synthesis -buf_list {sky130_fd_sc_hd__clkbuf_4} -root_buf sky130_fd_sc_hd__clkbuf_8
set_propagated_clock [all_clocks]
global_route
detailed_route -output_drc sky130/out/route_drc.rpt
filler_placement {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}

report_design_area
write_def sky130/out/mlc_storage_sky130.def
write_gds sky130/out/mlc_storage_sky130.gds
write_verilog sky130/out/mlc_storage_sky130_pnr.v
write_sdc sky130/out/mlc_storage_sky130.sdc
puts "SKY130 PNR DONE"
exit
