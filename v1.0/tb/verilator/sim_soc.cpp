// Fast standalone run of the Gust N1 system test bench (tb/soc/tb_n1_soc.v).
//   sim_soc +hex=<program.hex> +tohost=<hex addr> [+max=<cycles>]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "Vtb_n1_soc.h"
#include "verilated.h"
int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    unsigned long long max_cycles = 400000000ULL, cycles = 0;
    unsigned tohost = 0;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "+tohost=", 8)) tohost = strtoul(argv[i] + 8, nullptr, 16);
        if (!strncmp(argv[i], "+max=", 5))    max_cycles = strtoull(argv[i] + 5, nullptr, 10);
    }
    Vtb_n1_soc *top = new Vtb_n1_soc;
    top->clk = 0; top->rst_n = 0; top->stall_mode = 0; top->tohost_addr = tohost;
    for (int i = 0; i < 8; i++) { top->clk = !top->clk; top->eval(); }
    top->rst_n = 1;
    int last = 0, code = -1;
    while (cycles < max_cycles) {
        top->clk = 1; top->eval(); cycles++;
        if (top->putc_strobe != last) { last = top->putc_strobe; putchar(top->putc_data); }
        if (top->tohost_valid) { code = top->tohost_data >> 1; break; }
        top->clk = 0; top->eval();
    }
    printf("EXIT code=%d cycles=%llu\n", code, cycles);
    return code == 0 ? 0 : 1;
}
