PDK_ROOT ?= $(HOME)/.volare
PDK ?= sky130A

.PHONY: all synth pnr gds drc lvs clean

all: synth pnr gds drc lvs

synth:
	mkdir -p out
	yosys -s synth/synth_sky130.ys 2>&1 | tee out/synth_sky130.log

pnr:
	openroad -no_init -exit pnr/run_sky130.tcl 2>&1 | tee out/pnr.log

gds:
	test -f out/mlc_storage_sky130.gds

drc:
	bash drc/run_drc.sh out/mlc_storage_sky130.gds out/drc.lyrdb

lvs:
	bash lvs/run_lvs.sh out/mlc_storage_sky130.gds out/mlc_storage_sky130_pnr.v out/lvs.rpt

clean:
	rm -rf out
