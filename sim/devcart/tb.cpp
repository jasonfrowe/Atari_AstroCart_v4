// Verilator testbench for rtl/dev/devcart_top: UART load + verify, mapper
// configuration, then CPU and MARIA-style bus traffic checked against a C++
// model of the SuperGame (sg9 / "EXROM") mapper, as used by Atari Gamma Force.
//
// One eval() pair = one 81 MHz clock (12.35 ns). The PLL is a pass-through in
// simulation, so clk27 *is* the cart clock here.
#include "Vdevcart_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const int BAUD = 8;          // clocks per UART bit (-GBAUD_DIV=8)
static Vdevcart_top *top;
static long cyc = 0;
static std::string rx_text;         // everything the FPGA sent

// UART decoder state
static int rx_prev = 1, rx_ctr = -1, rx_bit = 0, rx_sh = 0;

static void tick() {
    top->clk27 = 0; top->eval();
    top->clk27 = 1; top->eval();
    cyc++;
    int tx = top->uart_txd;
    if (rx_ctr < 0) {
        if (rx_prev == 1 && tx == 0) { rx_ctr = BAUD + BAUD / 2 - 1; rx_bit = 0; rx_sh = 0; }
    } else if (rx_ctr == 0) {
        if (rx_bit < 8) { rx_sh |= tx << rx_bit; rx_bit++; rx_ctr = BAUD - 1; }
        else { rx_text.push_back((char)rx_sh); rx_ctr = -1; }
    } else rx_ctr--;
    rx_prev = tx;
}
static void ticks(int n) { while (n--) tick(); }

static void uart_send(uint8_t b) {
    top->uart_rxd = 0; ticks(BAUD);
    for (int i = 0; i < 8; i++) { top->uart_rxd = (b >> i) & 1; ticks(BAUD); }
    top->uart_rxd = 1; ticks(BAUD * 2);
}
static void uart_send(const std::vector<uint8_t> &v) { for (uint8_t b : v) uart_send(b); }

// wait for a line starting at offset `from` in rx_text
static std::string wait_line(size_t &from, long max_cycles = 20000000) {
    long t0 = cyc;
    while (cyc - t0 < max_cycles) {
        size_t nl = rx_text.find('\n', from);
        if (nl != std::string::npos && nl > from) {
            std::string l = rx_text.substr(from, nl - from);
            from = nl + 1;
            return l;
        }
        if (nl != std::string::npos) from = nl + 1;   // skip empty lines
        tick();
    }
    fprintf(stderr, "timeout waiting for UART reply\n");
    exit(2);
}

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; if (fails < 20) { fprintf(stderr, "FAIL @%ld: ", cyc); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } } while (0)

// ---------------- cart model (sg9: 17 banks, POKEY at $450) ----------------
static const int NBANKS = 17;
static std::vector<uint8_t> rom;
static int bank8000 = 1;
static uint8_t expect(uint16_t a) {
    int bank = (a >= 0xC000) ? NBANKS - 1 : (a >= 0x8000) ? bank8000 : 0;
    return rom[bank * 0x4000 + (a & 0x3FFF)];
}

// ---------------- bus drivers ----------------
// Present an address; with skew, A14/A15 arrive one clock after A0-A13.
static void set_addr(uint16_t a, bool skew) {
    if (skew) {
        top->a = (top->a & 0xC000) | (a & 0x3FFF);
        tick();
    }
    top->a = a;
}

static int max_lat = 0, lat_hist[64];
static long halted_clocks = 0;
static int glitch = 0;           // GLITCH=1: random 1-clock PHI2 spikes (the console is noisy)
static int rwglitch = 0;         // RWGLITCH=1: a 1-clock R/W-low spike at the end of read cycles
static int aglitch = 0;          // AGLITCH=1: a 1-clock A15 spike just before the CPU latches read data
static void spike(int level) { int keep = top->phi2; top->phi2 = level; tick(); top->phi2 = keep; }

// MARIA-style read: address held `hold` clocks, data must be right by `deadline`.
static void dma_read(uint16_t a, int hold, int deadline, bool skew) {
    top->rw = 1; top->halt = 0;
    set_addr(a, skew);
    int first_ok = -1;
    uint8_t exp = expect(a);
    for (int t = 0; t < hold; t++) {
        tick();
        bool ok = top->buf_dir && top->d__en == 0xFF && top->d__out == exp;
        if (ok && first_ok < 0) first_ok = t + 1;
        if (!ok) first_ok = -1;                    // must stay valid once valid
    }
    CHECK(first_ok >= 0 && first_ok <= deadline,
          "DMA read $%04X: valid from clock %d (deadline %d), got %02X exp %02X",
          a, first_ok, deadline, top->d__out, exp);
    if (first_ok > max_lat) max_lat = first_ok;
    if (first_ok >= 0 && first_ok < 64) lat_hist[first_ok]++;
}

// recent CPU cycles, printed when a check fails
struct Hist { uint16_t a; bool w; uint8_t d; int bank; };
static Hist hist_ring[8]; static int hist_pos = 0;
static void dump_hist() {
    for (int i = 0; i < 8; i++) {
        Hist &h = hist_ring[(hist_pos + i) % 8];
        fprintf(stderr, "   %s $%04X %02X (model bank8000 %d)\n", h.w ? "W" : "R", h.a, h.d, h.bank);
    }
}
// 6502 cycle at 1.79 MHz: 45 clocks, PHI2 high for the second half.
static void cpu_cycle(uint16_t a, bool write, uint8_t wdata, bool check = true) {
    hist_ring[hist_pos] = {a, write, wdata, bank8000}; hist_pos = (hist_pos + 1) % 8;
    if (!top->halt) { top->halt = 1; ticks(32); }   // after DMA the 6502's next cycle starts ~32 clocks after HALT rises (capture)
    top->halt = 1;
    top->phi2 = 0;
    top->rw = write ? 0 : 1;
    set_addr(a, (rand() % 4) == 0);
    ticks(10);
    // Sally stops while HALT is low (our copy engine pulls it via Q1)
    while (top->halt_pull) { top->halt = 0; tick(); halted_clocks++; }
    top->halt = 1;
    ticks(5);
    if (glitch && rand() % 3 == 0) spike(1);     // spike during PHI2 low
    ticks(5);
    top->phi2 = 1;
    int spike_at = (glitch && rand() % 3 == 0) ? 3 + rand() % 6 : -1;
    for (int t = 0; t < 23; t++) {
        if (t == spike_at) { spike(0); continue; } // dropout during PHI2 high
        if (rwglitch && !write && t == 22 && rand() % 2) {   // R/W spike as PHI2 is about to fall
            top->rw = 0; tick(); top->rw = 1; continue;
        }
        if (aglitch && !write && t == 19 && rand() % 2) {    // address spike, 4 clocks before the latch
            uint16_t keep = top->a; top->a = keep ^ 0x8000; tick(); top->a = keep; continue;
        }
        if (write) {
            if (t >= 8) top->d = wdata;        // data valid ~100 ns into PHI2
            CHECK(!top->buf_dir, "cart drove the bus during a write to $%04X", a);
        }
        tick();
    }
    if (!write && check) {
        uint8_t exp = expect(a);
        bool cart = a >= 0x4000;
        if (cart) {
            CHECK(top->buf_dir && top->d__out == exp, "CPU read $%04X got %02X exp %02X (dir %d)",
                  a, top->d__out, exp, top->buf_dir);
            if (!(top->buf_dir && top->d__out == exp)) dump_hist();
        }
        else CHECK(!top->buf_dir, "cart drove non-cart address $%04X", a);
    }
    top->phi2 = 0;
    tick();
    if (write && a >= 0x8000 && a < 0xC000) {
        bank8000 = (wdata & 15) + 1;
        // A real 6502 fetches the next opcode after a write: the cart's HALT pull
        // lands in that read cycle, never in another write. (The cart judges a
        // write by the HALT state before its cycle began -- see cart_bus.v.)
        cpu_cycle((uint16_t)(0xC000 + (rand() & 0x3FFF)), false, 0);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vdevcart_top;
    top->uart_rxd = 1; top->phi2 = 0; top->rw = 1; top->halt = 1; top->a = 0; top->d = 0xFF; top->sd_miso = 1;
    ticks(3000);

    // synthetic image: every byte identifies its bank and offset
    rom.resize(NBANKS * 0x4000);
    for (size_t i = 0; i < rom.size(); i++)
        rom[i] = (uint8_t)((i >> 14) * 37 + (i & 0x3FFF) * 7 + ((i >> 8) & 0x3F));

    size_t rp = 0;
    uart_send('S');
    std::string l = wait_line(rp);
    printf("S -> %s\n", l.c_str());
    CHECK(l.rfind("AC78V4 0 0", 0) == 0, "ident: %s", l.c_str());

    // load
    uint32_t sum = 0;
    for (uint8_t b : rom) sum += b;
    uint32_t n = rom.size();
    uart_send({'L', (uint8_t)n, (uint8_t)(n >> 8), (uint8_t)(n >> 16)});
    uart_send(rom);
    l = wait_line(rp);
    printf("L -> %s (expected sum %08X)\n", l.c_str(), sum);
    char exp_ok[64];
    snprintf(exp_ok, sizeof exp_ok, "OK %08X 0000 0000", sum);
    CHECK(l == exp_ok, "load reply %s", l.c_str());

    // whole-image die-to-die verify
    uart_send({'V', (uint8_t)n, (uint8_t)(n >> 8), (uint8_t)(n >> 16)});
    l = wait_line(rp, 400000000L);
    snprintf(exp_ok, sizeof exp_ok, "OK %08X 0000 0000", sum);
    printf("V -> %s\n", l.c_str());
    CHECK(l == exp_ok, "verify reply %s", l.c_str());

    // configure sg9: $4000 = bank 0, $8000 = (v & 15) + 1, $C000 = bank 16, POKEY $450
    glitch = getenv("GLITCH") ? atoi(getenv("GLITCH")) : 0;
    aglitch = getenv("AGLITCH") ? atoi(getenv("AGLITCH")) : 0;
    rwglitch = getenv("RWGLITCH") ? atoi(getenv("RWGLITCH")) : 0;
    uart_send({'C', 1, 0, 1, 15, 1, 1, 16, 2, 1});
    bank8000 = 1;
    l = wait_line(rp);
    CHECK(l == "OK", "config reply %s", l.c_str());

    // ---- CPU traffic: reads all over, bank switches ----
    for (int i = 0; i < 3000; i++) {
        int r = rand() % 10;
        if (r == 0) cpu_cycle(0x8000 + (rand() & 0x3FFF), true, rand() & 0xFF);       // bank switch
        else if (r == 1) cpu_cycle(0x0450 + (rand() & 7), true, rand() & 0xFF);       // POKEY write
        else if (r == 2) cpu_cycle(0x1800 + (rand() & 0x7FF), false, 0);              // RAM: cart quiet
        else cpu_cycle(0x4000 + (rand() % 0xC000), false, 0);
    }

    // ---- MARIA-style DMA: runs of sequential graphics bytes, 419 ns each ----
    memset(lat_hist, 0, sizeof lat_hist);
    for (int run = 0; run < 1500; run++) {
        uint16_t base = 0x4000 + (rand() % 0xBF00);
        int len = 1 + rand() % 24;
        for (int k = 0; k < len; k++) dma_read(base + k, 11, 7, (rand() % 3) == 0);
        if (run % 50 == 0) {
            cpu_cycle(0x8000, true, rand() & 0xFF);                  // bank switch between runs
            long t0 = cyc;
            ticks(8);
            while (top->halt_pull) tick();                           // copy runs; DMA would glitch
            if (cyc - t0 > 10) printf("  bank copy: %ld clocks (%.0f us)\n", cyc - t0, (cyc - t0) * 12.35e-3);
        }
    }
    printf("DMA latency (clocks from address at pins to valid data): max %d\n", max_lat);
    for (int i = 0; i < 64; i++) if (lat_hist[i]) printf("  %2d clk (%3.0f ns): %d\n", i, i * 12.35, lat_hist[i]);

    // ---- statistics dump ----
    uart_send('T');
    size_t at = rx_text.find('@', rp);
    while (at == std::string::npos) { tick(); at = rx_text.find('@', rp); }
    std::vector<unsigned> w;
    long t0 = cyc;
    while (w.size() < 8 && cyc - t0 < 5000000) {
        tick();
        w.clear();
        const char *p = rx_text.c_str() + at + 1;
        unsigned v; int nch;
        while (sscanf(p, "%x%n", &v, &nch) == 1 && w.size() < 8) {
            // only count complete 8-digit words
            if (nch < 8 || (p[nch] == 0)) break;
            w.push_back(v); p += nch;
        }
    }
    CHECK(w.size() == 8, "stats dump incomplete (%zu words)", w.size());
    if (w.size() == 8) {
        printf("stats: bankwr %u pokeywr %u ignored %u | PSRAM reads %u missed %u | flags+bank %X\n",
               w[0], w[1], w[2], w[3], w[4], w[5]);
        CHECK(w[0] > 0, "no bank writes counted");
        CHECK((w[5] & 255) == (unsigned)bank8000, "bank on show %u, model %d", w[5] & 255, bank8000);
    }

    ticks(3000);                         // let the dump's last bytes go out
    rp = rx_text.size();                 // past the statistics dump
    // ---- bus trace: arm now, make some traffic, dump ----
    uart_send({'A', 0});
    l = wait_line(rp);
    for (int k = 0; k < 600; k++) dma_read(0xC000 + k, 11, 7, false);
    uart_send('Y');
    at = rx_text.find('@', rp);
    while (at == std::string::npos) { tick(); at = rx_text.find('@', rp); }
    t0 = cyc;
    std::vector<unsigned long> tr;
    while (tr.size() < 512 && cyc - t0 < 20000000) {
        ticks(1000);
        tr.clear();
        const char *p = rx_text.c_str() + at + 1;
        unsigned long v; int nch;
        while (sscanf(p, "%lx%n", &v, &nch) == 1 && tr.size() < 512) {
            if (nch < 9 || p[nch] == 0) break;
            tr.push_back(v); p += nch;
        }
    }
    CHECK(tr.size() == 512, "trace dump incomplete (%zu)", tr.size());
    if (tr.size() == 512) {
        int seq = 0;
        for (int i = 1; i < 512; i++) {
            unsigned a0 = (tr[i - 1] >> 8) & 0xFFFF, a1 = (tr[i] >> 8) & 0xFFFF;
            if (a1 == a0 + 1) seq++;
        }
        printf("trace: first entry dt %lu addr $%04lX; %d of 511 steps are +1\n",
               tr[0] >> 27, (tr[0] >> 8) & 0xFFFF, seq);
        CHECK(seq > 400, "trace does not look like the sequential DMA we generated");
    }

    printf("CPU halted for %ld clocks in total\n", halted_clocks);
    printf(fails ? "DEVCART SIM FAILED (%d)\n" : "DEVCART SIM PASSED\n", fails);
    delete top;
    return fails ? 1 : 0;
}
