// Writes script.asm for mathtest.asm: a list of register writes and expected
// reads, every expected value taken from the reference model (sim/math/astromath.h).
//   op $00-$1F, value : write value to $0420 + op
//   op $20-$3F, value : read $0420 + (op & 31), must equal value
// (W / R below take version 1 register numbers 0-15 = $0430-$043F; TW / TR the
// trig block's, 0-15 = $0420-$042F)
//   $FF               : end
#include "../../sim/math/astromath.h"
#include <cstdio>
#include <cstdlib>
static astromath m;
static int nbytes = 0, col = 0;
static void emit(int v) { printf(col ? ",$%02X" : "    .byte $%02X", v & 255); if (++col == 16) { printf("\n"); col = 0; } nbytes++; }
static void W(int reg, int v) { emit(16 + reg); emit(v); m.write(16 + reg, v); }
static void R(int reg) { emit(0x20 | (16 + reg)); emit(m.read(16 + reg)); }
static void TW(int reg, int v) { emit(reg); emit(v); m.write(reg, v); }
static void TR(int reg) { emit(0x20 | reg); emit(m.read(reg)); }
static void TWn(int reg, uint32_t v) { TW(reg, v); TW(reg + 1, v >> 8); }
static void Wn(int reg, uint32_t v, int n) { for (int i = 0; i < n; i++) W(reg + i, v >> (8 * i)); }
int main(int argc, char **argv)
{
	int nvec = argc > 1 ? atoi(argv[1]) : 400;
	int ntrig = argc > 2 ? atoi(argv[2]) : 190;
	uint64_t z = 0x9E3779B97F4A7C15ull;
	auto rnd = [&]() { z ^= z << 13; z ^= z >> 7; z ^= z << 17; return uint32_t(z >> 16); };
	const uint32_t edge[] = { 0, 1, 2, 3, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0x8001, 0xffff, 0x10000, 0x7fffffff, 0x80000000u, 0xffffffffu, 0xfffe0001u, 0xfffe0000u };
	const int NE = sizeof edge / sizeof edge[0];
	R(15);                                           // ID
	R(12); R(13);                                    // power-on CTRL, STATUS (D = 0)
	for (int it = 0; it < nvec; it++)
	{
		uint32_t a = rnd(), b = rnd(), n = rnd(), d = rnd();
		if (it % 3 == 0) { a = edge[rnd() % NE]; b = edge[rnd() % NE]; n = edge[rnd() % NE]; d = edge[rnd() % NE]; }
		if (it % 4 == 1) n >>= (rnd() % 32);
		if (it % 4 == 2) d >>= (rnd() % 16);
		if (it % 16 == 5) d = 0;
		if (it == 7) { n = 0x80000000u; d = 0xffff; }
		W(10, it & 1);
		Wn(0, a, 2); Wn(2, b, 2); Wn(4, n, 4); Wn(8, d, 2);
		for (int r = 0; r < 14; r++) R(r);
	}
	// results follow single-byte changes (no stale values)
	W(10, 0); Wn(0, 0x1234, 2); Wn(2, 0x0100, 2); R(0); R(1); R(2); R(3);
	W(2, 0x02); R(0); R(1); R(2); R(3); W(10, 1); W(1, 0xff); R(0); R(1); R(2); R(3);
	// accumulator: sum and difference of products, copy to N, square root, value through Q
	W(10, 1); W(11, 1);
	for (int k = 0; k < 12; k++)
	{
		Wn(0, rnd() & 0xffff, 2); Wn(2, rnd() & 0xffff, 2); W(11, (k % 3 == 2) ? 3 : 2);
		W(11, 4); Wn(8, 1, 2); for (int r = 4; r < 12; r++) R(r);
		if (k == 5) { W(11, 0); W(11, 5); W(11, 0xff); W(11, 4); for (int r = 4; r < 8; r++) R(r); }   // other values: nothing
	}
	W(11, 1); W(11, 4); for (int r = 4; r < 12; r++) R(r);
	// 3-4-5
	W(11, 1); Wn(0, 3, 2); Wn(2, 3, 2); W(11, 2); Wn(0, 4, 2); Wn(2, 4, 2); W(11, 2); W(11, 4); R(10); R(11);
	// random: from where the seed stands, then seeded, then the zero seed
	for (int k = 0; k < 40; k++) R(14);
	W(14, 0x78); W(14, 0x56); W(14, 0x34); W(14, 0x12);
	for (int k = 0; k < 40; k++) R(14);
	W(14, 0); W(14, 0); W(14, 0); W(14, 0);
	for (int k = 0; k < 20; k++) R(14);
	R(15);
	// ---- trig block ----
	TR(15); for (int r = 0; r < 15; r++) TR(r);      // version; power-on results (all 0)
	for (int it = 0; it < ntrig; it++)
	{
		uint32_t x = rnd(), y = rnd(), t = rnd();
		if (it % 3 == 0) { int sh = rnd() % 16; x = uint16_t(int16_t(x) >> sh); y = uint16_t(int16_t(y) >> sh); }
		if (it % 5 == 1) { x = edge[rnd() % 12]; y = edge[rnd() % 12]; }
		if (it % 7 == 2) t = (rnd() & 3) << 14;
		if (it % 11 == 3) y = 0;
		TWn(0, x); TWn(2, y); TWn(4, t);
		for (int r = 0; r < 8; r++) TR(r);
	}
	// results follow single-byte changes; writes to the reserved addresses do nothing
	TWn(0, 0x4000); TWn(2, 0); TWn(4, 0x2000); for (int r = 0; r < 8; r++) TR(r);
	TW(5, 0x60); TR(0); TR(1); TR(2); TR(3); TW(1, 0xC0); for (int r = 0; r < 8; r++) TR(r);
	for (int r = 6; r < 16; r++) TW(r, 0x5a);
	for (int r = 0; r < 16; r++) TR(r);
	// 3-4-5, and the zero vector
	TWn(0, 3); TWn(2, 4); for (int r = 4; r < 8; r++) TR(r);
	TWn(0, 0); TWn(2, 0); for (int r = 0; r < 8; r++) TR(r);
	// the two blocks do not disturb each other
	Wn(0, 1234, 2); Wn(2, 567, 2); TWn(0, 0x1234); TWn(2, 0x0567); TWn(4, 0x0abc);
	for (int r = 0; r < 4; r++) R(r);
	for (int r = 0; r < 8; r++) TR(r);
	emit(0xff);
	if (col) printf("\n");
	fprintf(stderr, "script: %d bytes\n", nbytes);
	return nbytes > 0x7000 - 1;
}
