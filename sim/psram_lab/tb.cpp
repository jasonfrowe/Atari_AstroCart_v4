// Verilator harness for lab/psram_lab: runs the lab against psram_ll's
// behavioural model, decodes the UART stream and checks the records with
// tools/psram_lab_read.py's parser.
#include "Vpsram_lab_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <string>

static const int CLKS_PER_BIT = 8;   // must match the -G override in the Makefile

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vpsram_lab_top *top = new Vpsram_lab_top;

    std::string out;
    int records = 0;
    const int want_records = (argc > 1) ? atoi(argv[1]) : 10;  // 9 per round, so >=1 refill

    // UART decoder state
    int prev_tx = 1, bit_ctr = -1, bitn = 0, sh = 0;

    for (long cyc = 0; cyc < 400000000L; cyc++) {
        top->clk27 = 0; top->eval();
        top->clk27 = 1; top->eval();

        int tx = top->uart_txd;
        if (bit_ctr < 0) {
            if (prev_tx == 1 && tx == 0) { bit_ctr = CLKS_PER_BIT + CLKS_PER_BIT / 2 - 1; bitn = 0; sh = 0; }
        } else if (bit_ctr == 0) {
            if (bitn < 8) { sh |= (tx << bitn); bitn++; bit_ctr = CLKS_PER_BIT - 1; }
            else {
                if (!tx) { fprintf(stderr, "framing error at cycle %ld\n", cyc); return 2; }
                out.push_back((char)sh);
                if (sh == '@') records++;
                bit_ctr = -1;
                if (records > want_records) break;
            }
        } else {
            bit_ctr--;
        }
        prev_tx = tx;
    }
    fwrite(out.data(), 1, out.size(), stdout);
    delete top;
    return records > want_records ? 0 : 1;
}
