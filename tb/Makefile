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
.PHONY: all prepare core_isa core_isa_cg clean
all: core_isa core_isa_cg
prepare:
	@mkdir -p $(BUILD)/isa
	riscv64-unknown-elf-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -O1 -ffreestanding -Wall \
	    -mcmodel=medany -static -nostdlib -nostartfiles -T sw/link.ld \
	    sw/n1_priv.c sw/crt0.S sw/lib.c -o $(BUILD)/n1_priv.elf
	python3 isa/build_isa.py --riscv-tests $(RISCV_TESTS) --out $(BUILD)/isa \
	    --extra n1-directed-priv=$(BUILD)/n1_priv.elf
define run_test
	@mkdir -p results
	@$(MAKE) --no-print-directory -f $(COCOTB_MK) SIM=$(SIM) TOPLEVEL_LANG=verilog \
	    COCOTB_TOPLEVEL=tb_core COCOTB_TEST_MODULES=test_core_isa VERILOG_SOURCES="$(SRCS)" \
	    SIM_BUILD=sim_build/$(1) COCOTB_RESULTS_FILE=results/$(1).xml \
	    COMPILE_ARGS="-f sim_build/$(1)/cmds.f -g2005 -I$(RTL) -DGUST_SIM $(2) $(VFLAGS)" > results/$(1).log 2>&1; \
	 printf "%-12s %s\n" "$(1)" "$$(grep -a -o 'TESTS=[0-9]* PASS=[0-9]* FAIL=[0-9]* SKIP=[0-9]*' results/$(1).log | tail -1)"; \
	 grep -a -q "FAIL=0 " results/$(1).log
endef
core_isa:
	$(call run_test,core_isa,)
core_isa_cg:
	$(call run_test,core_isa_cg,-Ptb_core.CLOCK_GATE=1)
clean:
	rm -rf sim_build results
