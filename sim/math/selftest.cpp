// Checks the reference model against plain arithmetic. c++ -std=c++11 -O2 selftest.cpp && ./a.out
#include "astromath.h"
#include <cstdio>
#include <cmath>
#include <cstdlib>
static int bad = 0;
#define CHECK(c, ...) do { if (!(c)) { if (bad++ < 10) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)
static uint32_t rd32(astromath &m, int o) { uint32_t v = 0; for (int i = 0; i < 4; i++) v |= uint32_t(m.read(16 + o + i)) << (8 * i); return v; }
static uint16_t rd16(astromath &m, int o) { return m.read(16 + o) | (m.read(16 + o + 1) << 8); }
static uint16_t tr16(astromath &m, int o) { return m.read(o) | (m.read(o + 1) << 8); }
static void wr(astromath &m, int o, uint32_t v, int nb) { for (int i = 0; i < nb; i++) m.write(16 + o + i, v >> (8 * i)); }
static void tw(astromath &m, int o, uint32_t v) { m.write(o, v); m.write(o + 1, v >> 8); }
int main()
{
	astromath m;
	CHECK(m.read(31) == 0xa1, "ID");
	uint64_t z = 88172645463325252ull;
	auto rnd = [&]() { z ^= z << 13; z ^= z >> 7; z ^= z << 17; return uint32_t(z >> 16); };
	const uint32_t edge[] = { 0, 1, 2, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xffff, 0x10000, 0x7fffffff, 0x80000000u, 0xffffffffu, 0xfffe0001u };
	for (int it = 0; it < 2000000; it++)
	{
		uint32_t a = rnd(), b = rnd(), n = rnd(), d = rnd();
		if (it % 7 == 0) { a = edge[rnd() % 15]; b = edge[rnd() % 15]; n = edge[rnd() % 15]; d = edge[rnd() % 15]; }
		if (it % 5 == 0) n >>= (rnd() % 32);
		if (it % 3 == 0) d >>= (rnd() % 16);
		a &= 0xffff; b &= 0xffff; d &= 0xffff;
		int sg = it & 1;
		m.write(26, sg); wr(m, 0, a, 2); wr(m, 2, b, 2); wr(m, 4, n, 4); wr(m, 8, d, 2);
		CHECK(m.read(28) == sg, "ctrl readback");
		uint32_t p = sg ? uint32_t(int32_t(int16_t(a)) * int32_t(int16_t(b))) : a * b;
		CHECK(rd32(m, 0) == p, "P %x*%x sg%d", a, b, sg);
		uint32_t q; uint16_t r;
		if (d == 0) { q = 0xffffffffu; r = uint16_t(n); }
		else if (sg) { int64_t nn = int32_t(n), dd = int16_t(d); q = uint32_t(nn / dd); r = uint16_t(nn % dd);
		               CHECK(int64_t(int32_t(q)) * dd + int16_t(r) == nn || (n == 0x80000000u && d == 0xffff), "signed identity"); }
		else { q = n / d; r = n % d; }
		CHECK(rd32(m, 4) == q && rd16(m, 8) == r, "Q/R %x/%x sg%d: %x %x", n, d, sg, rd32(m, 4), rd16(m, 8));
		CHECK(m.read(29) == (d == 0), "DIVZERO");
		uint32_t s = uint32_t(sqrtl((long double)n));
		while (uint64_t(s) * s > n) s--;
		while (uint64_t(s + 1) * (s + 1) <= n) s++;
		CHECK(rd16(m, 10) == s, "sqrt %x: %x want %x", n, rd16(m, 10), s);
	}
	// accumulator: 3*4 + 5*5 - 2*6 = 25; sqrt = 5; value through Q with D = 1
	m.reset(); m.write(27, 1);
	wr(m, 0, 3, 2); wr(m, 2, 4, 2); m.write(27, 2);
	wr(m, 0, 5, 2); wr(m, 2, 5, 2); m.write(27, 2);
	wr(m, 0, 2, 2); wr(m, 2, 6, 2); m.write(27, 3);
	m.write(27, 4); wr(m, 8, 1, 2);
	CHECK(rd32(m, 4) == 25 && rd16(m, 10) == 5, "accumulator");
	// random: first bytes from X = 1, and the seed
	m.reset();
	uint32_t x = 1; for (int i = 0; i < 1000; i++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; CHECK(m.read(30) == uint8_t(x), "rnd"); }
	for (int i = 0; i < 4; i++) m.write(30, 0); CHECK(m.x == 1, "zero seed");
	m.write(30, 0x78); m.write(30, 0x56); m.write(30, 0x34); m.write(30, 0x12); CHECK(m.x == 0x78563412, "seed %x", m.x);
	int cnt[256] = {0}; for (int i = 0; i < 256000; i++) cnt[m.read(30)]++;
	int lo = 1 << 30, hi = 0; for (int i = 0; i < 256; i++) { if (cnt[i] < lo) lo = cnt[i]; if (cnt[i] > hi) hi = cnt[i]; }
	printf("random byte counts over 256000 reads: %d..%d (expect about 1000)\n", lo, hi);
	CHECK(lo > 850 && hi < 1150, "random bytes not uniform");
	// ---- trig block ----
	m.reset();
	CHECK(m.read(15) == 0xa2, "trig version");
	for (int o = 8; o < 15; o++) CHECK(m.read(o) == 0, "reserved read");
	CHECK(tr16(m, 4) == 0 && tr16(m, 6) == 0, "zero vector");
	const double PI = 3.14159265358979323846;
	double mr = 0, ml = 0, ma = 0, sr = 0; long nr = 0;
	for (int it = 0; it < 3000000; it++)
	{
		uint16_t x = rnd(), y = rnd(), t = rnd();
		if (it % 3 == 0) { int sh = rnd() % 16; x = uint16_t(int16_t(x) >> sh); y = uint16_t(int16_t(y) >> sh); }
		if (it % 7 == 0) y = 0;
		if (it % 11 == 0) { x = edge[rnd() % 10]; y = edge[rnd() % 10]; }
		if (it % 13 == 0) t = (rnd() & 3) << 14;
		tw(m, 0, x); tw(m, 2, y); tw(m, 4, t);
		double fx = int16_t(x), fy = int16_t(y), a = t * 2 * PI / 65536;
		double ex = fx * cos(a) - fy * sin(a), ey = fx * sin(a) + fy * cos(a);
		int xr = int16_t(tr16(m, 0)), yr = int16_t(tr16(m, 2));
		if (!(t & 0x3fff))
		{   // quarter turns are exact (saturated)
			int qx = int(lround(ex)), qy = int(lround(ey));
			if (qx > 32767) qx = 32767;
			if (qy > 32767) qy = 32767;
			CHECK(xr == qx && yr == qy, "quarter turn %04x (%d,%d): %d,%d", t, int(fx), int(fy), xr, yr);
		}
		if (fabs(ex) < 32766 && fabs(ey) < 32766)
		{
			double e = fabs(xr - ex), f = fabs(yr - ey);
			if (e > mr) mr = e; if (f > mr) mr = f; sr += e + f; nr += 2;
		}
		else
		{   // saturation: clamped, never wrapped
			if (ex > 32768) CHECK(xr == 32767, "saturate x+"); if (ex < -32769) CHECK(xr == -32768, "saturate x-");
			if (ey > 32768) CHECK(yr == 32767, "saturate y+"); if (ey < -32769) CHECK(yr == -32768, "saturate y-");
		}
		if (fx != 0 || fy != 0)
		{
			double tl = sqrt(fx * fx + fy * fy), ta = atan2(fy, fx) / (2 * PI) * 65536;
			double e = fabs(tr16(m, 6) - tl); if (e > ml) ml = e;
			double d = tr16(m, 4) - ta; d -= 65536 * floor(d / 65536 + 0.5);
			double dd = fabs(d) * tl * 2 * PI / 65536;   // as a distance at the vector's tip
			d = fabs(d) < dd ? fabs(d) : dd;             // (short vectors: the distance; long ones: angle units)
			if (d > ma) ma = d;
		}
	}
	printf("trig: rotate max error %.3f (mean %.3f), length max error %.3f, angle max error %.3f (angle units, or distance at the vector's tip if that is less)\n", mr, sr / nr, ml, ma);
	CHECK(mr < 1.5, "rotate error"); CHECK(ml < 1.0, "length error"); CHECK(ma < 1.0, "angle error");
	// exact cases
	tw(m, 0, 1); tw(m, 2, 1); CHECK(tr16(m, 4) == 0x2000, "angle of (1,1)");
	tw(m, 0, 0); tw(m, 2, 5); CHECK(tr16(m, 4) == 0x4000 && tr16(m, 6) == 5, "(0,5)");
	tw(m, 0, 0xfffd); tw(m, 2, 0); CHECK(tr16(m, 4) == 0x8000 && tr16(m, 6) == 3, "(-3,0)");
	tw(m, 0, 0); tw(m, 2, 0xffff); CHECK(tr16(m, 4) == 0xc000 && tr16(m, 6) == 1, "(0,-1)");
	tw(m, 0, 3); tw(m, 2, 4); CHECK(tr16(m, 6) == 5, "3-4-5");
	tw(m, 0, 0x8000); tw(m, 2, 0x8000); CHECK(tr16(m, 4) == 0xa000 && tr16(m, 6) == 46341, "(-32768,-32768): %x %d", tr16(m, 4), tr16(m, 6));
	// T = 0 changes nothing; cos and sin: X = amplitude, Y = 0
	{ int n0 = 0; tw(m, 4, 0); for (int v = -32768; v < 32768; v++) { tw(m, 0, v); tw(m, 2, v * 7919); if (tr16(m, 0) != uint16_t(v) || tr16(m, 2) != uint16_t(v * 7919)) n0++; }
	  CHECK(n0 == 0, "T = 0 not the identity (%d)", n0); }
	{ double mc = 0; tw(m, 0, 16384); tw(m, 2, 0);
	  for (int t = 0; t < 65536; t++) { tw(m, 4, t); double a = t * 2 * PI / 65536;
	      double e = fabs(int16_t(tr16(m, 0)) - 16384 * cos(a)), f = fabs(int16_t(tr16(m, 2)) - 16384 * sin(a)); if (e > mc) mc = e; if (f > mc) mc = f; }
	  printf("trig: cos / sin at amplitude 16384, all 65536 angles: max error %.3f\n", mc); CHECK(mc < 1.5, "sin/cos error"); }
	printf(bad ? "ASTROMATH SELFTEST FAILED (%d)\n" : "ASTROMATH SELFTEST PASSED\n", bad);
	return bad != 0;
}
