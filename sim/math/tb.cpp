// astromath.v against the reference model: random register traffic, each
// operation GAP clocks after the last (a 6502 cannot be faster than ~110;
// the trig block needs about 60).
#include "Vastromath.h"
#include "verilated.h"
#include "astromath.h"
#include <cstdio>
#include <cstdlib>
static Vastromath *top;
static long cyc = 0;
static void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cyc++; }
int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	int gap = argc > 1 ? atoi(argv[1]) : 40;
	long nops = argc > 2 ? atol(argv[2]) : 400000;
	top = new Vastromath;
	top->rst_n = 0; top->we = 0; top->rd_evt = 0; top->raddr = 0;
	for (int i = 0; i < 4; i++) tick();
	top->rst_n = 1;
	for (int i = 0; i < gap; i++) tick();
	astromath m;
	uint64_t z = 0x2545F4914F6CDD1Dull;
	auto rnd = [&]() { z ^= z << 13; z ^= z >> 7; z ^= z << 17; return uint32_t(z >> 16); };
	const uint8_t edge[] = { 0, 1, 2, 3, 4, 5, 0x7f, 0x80, 0xff, 0xfe };
	long bad = 0, reads = 0;
	for (long op = 0; op < nops && bad < 10; op++)
	{
		unsigned reg = rnd() & 31;
		if (reg < 16 && (rnd() & 1)) reg %= 8;               // (most trig traffic on the registers that exist)
		if (rnd() % 3)
		{   // a write
			uint8_t v = (rnd() & 3) ? uint8_t(rnd()) : edge[rnd() % 10];
			if (reg == 27) v = rnd() % 6;
			if (reg == 26) v = rnd() & 1;
			if ((reg == 24 || reg == 25) && rnd() % 6 == 0) v = 0;
			if (reg < 4 && rnd() % 3 == 0) v = (reg & 1) ? ((rnd() & 1) ? 0x00 : 0xff) : v;   // short vectors
			top->we = 1; top->waddr = reg; top->wdata = v;
			tick();
			top->we = 0;
			m.write(reg, v);
			for (int i = 1; i < gap; i++) tick();
		}
		else
		{   // a read: the address is on the bus for the whole cycle, the event comes at its end
			top->raddr = reg;
			for (int i = 0; i < gap - 1; i++) tick();
			uint8_t got = top->rdata, want = m.read(reg);
			reads++;
			if (got != want) { bad++; printf("FAIL op %ld: read reg %u = %02X, model %02X\n", op, reg, got, want); }
			top->rd_evt = (reg == 30); top->raddr_evt = reg & 15;
			tick();
			top->rd_evt = 0;
		}
	}
	printf("%ld operations, %ld reads, %d clocks apart: %ld wrong\n", nops, reads, gap, bad);
	printf(bad ? "ASTROMATH RTL FAILED\n" : "ASTROMATH RTL PASSED\n");
	delete top;
	return bad != 0;
}
