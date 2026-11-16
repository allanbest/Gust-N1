# Verilator build of the N1 system test bench.
#   make TAG=c1 PARAMS="-GNCORES=1 -GLAT=2 -GICACHE=1"
RTL    := $(abspath ../../rtl)
TAG    ?= default
PARAMS ?= -GNCORES=1
obj_$(TAG)/sim_soc: ../soc/tb_n1_soc.v $(wildcard $(RTL)/*.v) sim_soc.cpp
	verilator --cc --exe --build -j 2 -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH \
	    -Wno-UNUSED -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-PINCONNECTEMPTY \
	    -DGUST_SIM -I$(RTL) $(PARAMS) --top-module tb_n1_soc --Mdir obj_$(TAG) -o sim_soc \
	    ../soc/tb_n1_soc.v $(wildcard $(RTL)/*.v) sim_soc.cpp > obj_$(TAG).log 2>&1 || (tail -20 obj_$(TAG).log; false)
