// POKEY regression: divider periods (N+1 / N+4 / N+7), joined pairs, the
// distortions' sequence lengths, volume-only, the high-pass filter, RANDOM.
// Every clk is a 1.79 MHz tick here (tick = 1), so periods are in POKEY cycles.
#include "Vpokey.h"
#include "verilated.h"
#include <cstdio>
#include <vector>
#include <cstdint>

static Vpokey *top;
static int fails = 0;
static void clk() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
static void wr(int a, int d) { top->we = 1; top->waddr = a; top->wdata = d; clk(); top->we = 0; }
static void reset() {
    top->rst_n = 0; top->tick = 0; top->we = 0; clk(); clk(); top->rst_n = 1; top->tick = 1;
    wr(15, 3);
}
// record the mixer output for n cycles
static std::vector<int> rec(int n) { std::vector<int> v(n); for (int i = 0; i < n; i++) { clk(); v[i] = top->audio_out; } return v; }
// smallest period of the tail of v
static long period(const std::vector<int> &v) {
    long n = v.size();
    for (long p = 1; p < n / 3; p++) {
        bool ok = true;
        for (long i = n / 3; i + p < n && ok; i++) ok = v[i] == v[i + p];
        if (ok) return p;
    }
    return -1;
}
static void expect(const char *what, long got, long want) {
    printf("  %-58s %8ld %s\n", what, got, got == want ? "ok" : "WRONG");
    if (got != want) { fails++; printf("      expected %ld\n", want); }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vpokey;

    reset(); wr(8, 0x00); wr(0, 40); wr(1, 0xA8);
    expect("ch1 64 kHz, AUDF 40: period 2*28*(N+1)", period(rec(40000)), 2 * 28 * 41);
    reset(); wr(8, 0x01); wr(4, 9); wr(5, 0xA8);
    expect("ch3 15 kHz, AUDF 9: period 2*114*(N+1)", period(rec(40000)), 2 * 114 * 10);
    reset(); wr(8, 0x40); wr(0, 100); wr(1, 0xA8);
    expect("ch1 1.79 MHz, AUDF 100: period 2*(N+4)", period(rec(4000)), 2 * 104);
    reset(); wr(8, 0x20); wr(4, 0); wr(5, 0xA8);
    expect("ch3 1.79 MHz, AUDF 0: period 2*4", period(rec(400)), 8);
    reset(); wr(8, 0x50); wr(0, 0x34); wr(2, 0x02); wr(1, 0x00); wr(3, 0xA8);
    expect("ch1+2 joined at 1.79 MHz, N=$0234: period 2*(N+7), on ch2", period(rec(20000)), 2 * (0x234 + 7));
    reset(); wr(8, 0x50); wr(0, 0x05); wr(2, 0x00); wr(1, 0x00); wr(3, 0xA8);
    expect("ch1+2 joined at 1.79 MHz, N=5: period 2*(N+7)", period(rec(2000)), 2 * 12);
    reset(); wr(8, 0x08); wr(4, 0x02); wr(6, 0x01); wr(5, 0x00); wr(7, 0xA8);
    expect("ch3+4 joined at 64 kHz, N=$0102: period 2*28*(N+1)", period(rec(200000)), 2 * 28 * 0x103);
    reset(); wr(8, 0x50); wr(0, 0x34); wr(2, 0x02); wr(1, 0xA8); wr(3, 0x00);
    expect("joined: ch1 itself pulses every 256 (period 2*256... + reload)", period(rec(20000)) > 0, 1);

    // distortions: divider period P = 28*(N+1) cycles; the output repeats after
    // lcm(P, poly length) cycles (x2 if it is a toggle)
    reset(); wr(8, 0x00); wr(0, 1); wr(1, 0xC8);        // 4-bit poly, P = 56, gcd(56,15)=1
    expect("AUDC $C8 (4-bit poly), AUDF 1: period 56*15", period(rec(20000)), 56 * 15);
    reset(); wr(8, 0x00); wr(0, 1); wr(1, 0x28);        // 5-bit poly gates a toggle
    { long p = period(rec(40000)); expect("AUDC $28 (5-bit poly gating a toggle): period 56*31 or twice", p == 56 * 31 || p == 2 * 56 * 31, 1); }
    reset(); wr(8, 0x80); wr(0, 1); wr(1, 0x88);        // 9-bit poly, gcd(56,511)=7
    expect("AUDC $88 + 9-bit poly, AUDF 1: period 56*511/7", period(rec(60000)), 56 * 511 / 7);
    reset(); wr(8, 0x00); wr(0, 1); wr(1, 0x88);        // 17-bit poly: no short period
    expect("AUDC $88, 17-bit poly: no period under 100000", period(rec(300000)), -1);

    // volume only
    reset(); wr(8, 0x00); wr(1, 0x17); wr(3, 0x13);
    { auto v = rec(200); bool ok = true; for (size_t k = 10; k < v.size(); k++) ok &= v[k] == (7 + 3) * 4;
      expect("volume-only: level = (7+3)*4, constant", ok, 1); }

    // high-pass: ch1 at 64 kHz AUDF 10, ch3 the same divider -> ch1 XOR latch is constant
    reset(); wr(8, 0x04); wr(0, 10); wr(4, 10); wr(1, 0xA8); wr(9, 0);
    { auto v = rec(20000); bool ok = true; for (size_t k = 5000; k < v.size(); k++) ok &= v[k] == v[5000];
      expect("high-pass with ch3 = ch1: output cancels", ok, 1); }
    reset(); wr(8, 0x04); wr(0, 10); wr(4, 11); wr(1, 0xA8); wr(9, 0);
    { long p = period(rec(120000)); expect("high-pass with ch3 one step off: beat, period 28*11*12", p, 28L * 11 * 12); }

    // two-tone mode: channel 2's pulse reloads channel 1 (hard sync)
    reset(); wr(8, 0x40); wr(0, 100); wr(1, 0xA8); wr(2, 9); wr(3, 0xA0);
    expect("ch1 1.79 MHz N=100, ch2 64 kHz N=9, SKCTL=$03: ch1 period 2*104", period(rec(20000)), 208);
    reset(); wr(15, 0x8B); wr(8, 0x40); wr(0, 100); wr(1, 0xA8); wr(2, 9); wr(3, 0xA0);
    expect("  ... SKCTL=$8B (two-tone): ch1 repeats with ch2, 28*10", period(rec(20000)), 280);

    // RANDOM
    reset(); wr(15, 0); clk(); clk(); top->raddr = 10; top->eval();
    expect("RANDOM in reset (SKCTL=0)", top->rdata, 0xFF);
    wr(15, 3);
    { int seen[256] = {0}, n = 0; for (int k = 0; k < 4000; k++) { clk(); top->eval(); if (!seen[top->rdata]++) n++; }
      expect("RANDOM out of reset: 256 different values seen", n, 256); }

    printf(fails ? "POKEY SIM FAILED (%d)\n" : "POKEY SIM PASSED\n", fails);
    delete top;
    return fails ? 1 : 0;
}
