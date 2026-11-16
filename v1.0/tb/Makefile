# Gust N1 stage 1 - ISA regression (cocotb + Icarus)
#   make prepare RISCV_TESTS=<riscv-tests checkout>    build the test programs
#   make                                               core_isa, then core_isa_cg
SIM         ?= icarus
RTL         := $(abspath ../rtl)
BUILD       := $(abspath ../build)
RISCV_TESTS ?= $(abspath ../../riscv-tests)
COCOTB_MK   := $(shell cocotb-config --makefiles)/Makefile.sim
VFLAGS      ?=
export PYTHONPATH := $(abspath tests):$(PYTHONPATH)
SRCS := core/tb_core.v $(wildcard $(RTL)/*.v)
.PHONY: all prepare core_isa core_isa_cg soc_isa soc_isa_lat2 clean
all: core_isa core_isa_cg soc_isa soc_isa_lat2
prepare:
	@test -d $(RISCV_TESTS)/isa || (echo "RISCV_TESTS=$(RISCV_TESTS) is not a riscv-tests checkout"; false)
	@mkdir -p $(BUILD)/isa
	riscv64-unknown-elf-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -O1 -ffreestanding -Wall \
	    -mcmodel=medany -static -nostdlib -nostartfiles -T sw/link.ld \
	    sw/n1_priv.c sw/crt0.S sw/lib.c -o $(BUILD)/n1_priv.elf
	riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 -O1 -ffreestanding -Wall \
	    -mcmodel=medany -static -nostdlib -nostartfiles -T sw/link.ld -DASYM \
	    sw/n1_smp.c sw/crt0_smp.S sw/lib.c -o $(BUILD)/n1_smp.elf
	python3 isa/build_isa.py --riscv-tests $(RISCV_TESTS) --out $(BUILD)/isa \
	    --extra n1-directed-priv=$(BUILD)/n1_priv.elf --extra soc-smp=$(BUILD)/n1_smp.elf
comma := ,
SOC_SRCS := soc/tb_n1_soc.v $(wildcard $(RTL)/*.v)
# run_test,<name>,<iverilog args>,<toplevel>,<sources>,<GUST_TB>
define run_test
	@mkdir -p results
	@GUST_TB=$(5) $(6) $(MAKE) --no-print-directory -f $(COCOTB_MK) SIM=$(SIM) TOPLEVEL_LANG=verilog \
	    COCOTB_TOPLEVEL=$(3) COCOTB_TEST_MODULES=test_core_isa VERILOG_SOURCES="$(4)" \
	    SIM_BUILD=sim_build/$(1) COCOTB_RESULTS_FILE=results/$(1).xml \
	    COMPILE_ARGS="-f sim_build/$(1)/cmds.f -g2005 -I$(RTL) -DGUST_SIM $(2) $(VFLAGS)" > results/$(1).log 2>&1; \
	 printf "%-12s %s\n" "$(1)" "$$(grep -a -o 'TESTS=[0-9]* PASS=[0-9]* FAIL=[0-9]* SKIP=[0-9]*' results/$(1).log | tail -1)"; \
	 grep -a -q "FAIL=0 " results/$(1).log
endef
core_isa:
	$(call run_test,core_isa,,tb_core,$(SRCS),core)
core_isa_cg:
	$(call run_test,core_isa_cg,-Ptb_core.CLOCK_GATE=1,tb_core,$(SRCS),core)
# the whole suite again on the two-core system (hart 1 idles in the ISA tests,
# so they exercise the cache, the shared bus and the arbitration), plus soc-smp
soc_isa:
	$(call run_test,soc_isa,,tb_n1_soc,$(SOC_SRCS),soc)
# and a subset with a slow external RAM (2 extra cycles per access)
soc_isa_lat2:
	$(call run_test,soc_isa_lat2,-Ptb_n1_soc.LAT=2,tb_n1_soc,$(SOC_SRCS),soc,GUST_ONLY=soc-smp$(comma)directed$(comma)rv32ua$(comma)rv32si$(comma)rv32mi$(comma)rv32uc$(comma)rv32um)
clean:
	rm -rf sim_build results
