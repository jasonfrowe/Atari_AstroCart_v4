// Verilator testbench for the multicart path of rtl/dev/devcart_top:
//
//   * the bitstream's slot BRAMs hold a 6502 program (harness.asm + the menu's
//     menu/fat.asm) which a 6502 core (fake6502) executes; every memory access
//     is a real bus cycle against the RTL;
//   * an SD card model (SPI mode) serves a FAT32 image built by tools/mkfat32.py;
//   * the program finds the .a78 files, loads one into PSRAM, sets the mapper
//     up and launches it; the testbench then compares everything the Atari
//     can see (all banks) with the .a78 file, using its own model of the mapper.
//
//   Vdevcart_top IMAGE HC(0|1) GAME_INDEX FILE.a78...   (files in directory order)
#include "Vdevcart_top.h"
#include "verilated.h"
#include "Vdevcart_top___024root.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
#include <algorithm>
#include <functional>

extern "C" {
void reset6502(uint8_t cmos);
void step6502();
extern uint16_t pc;
uint8_t read6502(uint16_t address);
void write6502(uint16_t address, uint8_t value);
}

static Vdevcart_top *top;
static long cyc = 0;
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; if (fails < 20) { fprintf(stderr, "FAIL @%ld: ", cyc); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } } while (0)

// ---------------------------------------------------------------- SD card
struct SDCard {
    FILE *img = nullptr;
    bool hc = true, idle = true, appcmd = false;
    int acmd_left = 3;
    int prev_sck = 0, bitn = 0, cn = 0, miso = 1;
    uint8_t rxsh = 0, txb = 0xFF, cmd[6];
    std::deque<uint8_t> txq;
    long reads = 0, writes = 0, fast_edges = 0;
    int wstate = 0, wcount = 0;      // CMD24: 1 waiting for the data token, 2 taking 512 + 2 bytes
    uint32_t wlba = 0;
    uint8_t wbuf[514];

    void process() {
        int idx = cmd[0] & 0x3F;
        uint32_t arg = (cmd[1] << 24) | (cmd[2] << 16) | (cmd[3] << 8) | cmd[4];
        txq.push_back(0xFF);
        uint8_t i = idle ? 1 : 0;
        bool app = appcmd;
        appcmd = false;
        switch (idx) {
        case 0: idle = true; txq.push_back(1); break;
        case 8: txq.push_back(i); txq.push_back(0); txq.push_back(0); txq.push_back(1); txq.push_back(0xAA); break;
        case 55: appcmd = true; txq.push_back(i); break;
        case 41:
            if (app && --acmd_left <= 0) idle = false;
            txq.push_back(idle ? 1 : 0);
            break;
        case 58:
            txq.push_back(i);
            txq.push_back(hc ? 0xC0 : 0x80); txq.push_back(0xFF); txq.push_back(0x80); txq.push_back(0);
            break;
        case 16: txq.push_back(i); break;
        case 17: {
            if (idle || (!hc && (arg & 511))) { txq.push_back(0x04 | i); break; }
            uint32_t lba = hc ? arg : arg / 512;
            uint8_t buf[512];
            memset(buf, 0, sizeof buf);
            fseek(img, (long)lba * 512, SEEK_SET);
            size_t got = fread(buf, 1, 512, img);
            (void)got;
            txq.push_back(0);
            for (int k = 2 + rand() % 30; k > 0; k--) txq.push_back(0xFF);
            txq.push_back(0xFE);
            for (int k = 0; k < 512; k++) txq.push_back(buf[k]);
            txq.push_back(0x12); txq.push_back(0x34);
            reads++;
            break;
        }
        case 24: {
            if (idle || (!hc && (arg & 511))) { txq.push_back(0x04 | i); break; }
            wlba = hc ? arg : arg / 512;
            txq.push_back(0);
            wstate = 1;
            break;
        }
        default: txq.push_back(0x04 | i); break;
        }
    }
    void tick(int cs, int sck, int mosi) {
        if (cs) { cn = 0; txq.clear(); wstate = 0; }
        if (sck && !prev_sck) {
            rxsh = (uint8_t)((rxsh << 1) | (mosi & 1));
            if (++bitn == 8) {
                bitn = 0;
                if (!cs && wstate == 1) {
                    if (rxsh == 0xFE) { wstate = 2; wcount = 0; }
                } else if (!cs && wstate == 2) {
                    wbuf[wcount++] = rxsh;
                    if (wcount == 514) {
                        fseek(img, (long)wlba * 512, SEEK_SET);
                        fwrite(wbuf, 1, 512, img);
                        fflush(img);
                        writes++;
                        wstate = 0;
                        txq.push_back(0xE5);                                  // data accepted
                        for (int k = 20 + rand() % 60; k > 0; k--) txq.push_back(0x00);   // busy
                    }
                } else if (!cs && (cn || (rxsh & 0xC0) == 0x40)) {
                    cmd[cn++] = rxsh;
                    if (cn == 6) { cn = 0; process(); }
                }
            }
        } else if (!sck && prev_sck) {
            if (bitn == 0) {
                txb = 0xFF;
                if (!txq.empty()) { txb = txq.front(); txq.pop_front(); }
            }
            miso = (txb >> (7 - bitn)) & 1;
        }
        prev_sck = sck;
    }
};
static SDCard sd;

static int dbg_hsc = -1, dbg_last = -1;
static bool dbg_math = false;
static void tick() {
    top->clk27 = 0; top->eval();
    top->clk27 = 1; top->eval();
    cyc++;
    sd.tick(top->sd_cs, top->sd_sck, top->sd_mosi);
    top->sd_miso = sd.miso;
    if (dbg_math) {
        auto r = top->rootp;
        if (r->devcart_top__DOT__mt_we) fprintf(stderr, "  @%ld math write %X <- %02X\n", cyc, r->devcart_top__DOT__pk_waddr, r->devcart_top__DOT__pk_wdata);
        if (r->devcart_top__DOT__mt_rd) fprintf(stderr, "  @%ld math read  %X (bus %02X, a=%04X)\n", cyc, r->devcart_top__DOT__mt_ra, top->d__out, top->a);
    }
    if (dbg_hsc >= 0) {
        auto r = top->rootp;
        if (r->devcart_top__DOT__hw_we && r->devcart_top__DOT__hw_addr == dbg_hsc)
            fprintf(stderr, "  @%ld hw_we $%03X <- %02X  (queue %X, halted_cycle %d, cpu_cyc %d, a=%04X rw=%d halt=%d)\n", cyc, dbg_hsc,
                    r->devcart_top__DOT__hw_data, r->devcart_top__DOT__hq_v, r->devcart_top__DOT__u_bus__DOT__halted_cycle,
                    r->devcart_top__DOT__u_bus__DOT__cpu_cyc, top->a, top->rw, top->halt);
        if (r->devcart_top__DOT__x_write)
            { if ((int)(r->devcart_top__DOT__x_addr & 0x7FF) == dbg_hsc) fprintf(stderr, "  @%ld x_write %06X <- %02X (queue %X, busy1 %d)\n", cyc, r->devcart_top__DOT__x_addr, r->devcart_top__DOT__x_wd, r->devcart_top__DOT__hq_v, (int)r->devcart_top__DOT__m_busy1); }
        if ((top->a & 0x7FF) == dbg_hsc && (top->a >> 11) == 2 && top->a != dbg_last) fprintf(stderr, "  @%ld bus $%04X rw=%d halt=%d\n", cyc, top->a, top->rw, top->halt);
        dbg_last = top->a;
    }
}
static void ticks(int n) { while (n--) tick(); }

// ---------------------------------------------------------------- bus
static uint8_t ram[0x4000];          // console RAM / registers below $4000 (a flat model)
static bool last_driven = false;
static int aglitch = 1;           // AGLITCH=0 turns the address disturbances off
static int cpu_hi = 21;           // PHI2-high clocks of a 6502 cycle (CPUHI=n shortens it to find the margin)
static long halt_clocks = 0;      // clocks the cart held HALT
static int late_phi2 = 0;         // clocks by which the cart sees PHI2 fall after the write data has gone
static bool dma_on = false;       // model MARIA's DMA starting at the end of random cycles

// One 6502 cycle (45 clocks, PHI2 high for the second half). A14/A15 arrive a
// clock late now and then, as on the board.
static uint8_t bus_cycle(uint16_t a, bool write, uint8_t wdata) {
    top->halt = 1;
    top->phi2 = 0;
    top->rw = write ? 0 : 1;
    if (rand() % 4 == 0) { top->a = (top->a & 0xC000) | (a & 0x3FFF); tick(); }
    top->a = a;
    // MARIA's DMA (console capture build2h_hsdll_03, the last cycle of an INC):
    // HALT falls at the START of the 6502's last cycle (0-3 clocks after the
    // address changes), and the 6502 still completes that cycle -- a write in it
    // is a real write. After it the bus is MARIA's: her addresses, R/W still low
    // for a while if that last cycle was a write, PHI2 pulsing. None of that may
    // be taken as a write (to RAM, to a register, as a bank switch).
    bool dma = dma_on && rand() % (write ? 3 : 40) == 0;
    bool dma_a = dma;
    // 559 ns = 37.7 clocks: 17 low, 21 high (the cart has to answer a read from
    // PSRAM inside one of these during a HALT-free bank switch)
    if (dma_a) { ticks(rand() % 4); top->halt = 0; ticks(5); }
    else ticks(7);
    while (top->halt_pull) { top->halt = 0; tick(); halt_clocks++; }
    if (!dma_a) top->halt = 1;
    ticks(9);
    top->phi2 = 1;
    int glitch_at = (aglitch && !write && (dma_a || rand() % 8 == 0)) ? 8 + rand() % 9 : -1;
    for (int t = 0; t < cpu_hi; t++) {
        // a one-sample disturbance on an address line late in the cycle (seen on the
        // console: e.g. when the cart's own data pins switch). Must not change what
        // the cart puts on the bus -- in particular not in the 6502's last cycle
        // before DMA, when HALT is already low.
        if (t == glitch_at) {
            uint16_t keep = top->a; top->a = keep ^ 0x0004; tick(); top->a = keep; continue;
        }
        if (write) {
            if (t >= 8) top->d = wdata;
            CHECK(!top->buf_dir, "cart drove the bus during a write to $%04X", a);
        }
        tick();
    }
    last_driven = top->buf_dir && top->d__en == 0xFF;
    uint8_t v = last_driven ? top->d__out : 0xFF;
    if (dbg_math && (a & 0xFFF0) == 0x0430 && !write) fprintf(stderr, "  @%ld cycle read $%04X -> %02X (glitch at %d, dma %d)\n", cyc, a, v, glitch_at, (int)dma);
    // The 6502 holds write data only briefly after PHI2 falls, and PHI2 reaches
    // the FPGA later than the data does (slower level shifter): by the time the
    // cart sees PHI2 low the data bus -- and the low address bits -- have moved on.
    if (write && !dma && late_phi2) { top->d = (uint8_t)rand(); top->a = (uint16_t)(a ^ (rand() & 0x3FFF)); ticks(late_phi2 - 1); }
    top->phi2 = 0;
    tick();
    if (dma) {
        for (int k = 0; k < 3; k++) {                                        // MARIA's addresses, R/W floating
            top->a = (uint16_t)(0x4000 + (rand() & 0x3FFF));
            if (write) top->d = (uint8_t)rand();
            ticks(9); top->phi2 = 1; ticks(9); top->phi2 = 0; tick();
        }
        top->rw = 1; top->d = 0xFF;
        for (int k = 0; k < 6; k++) { top->a = (uint16_t)(0x1800 + (rand() & 0x7FF)); ticks(11); }
        top->a = a; ticks(12);
        top->halt = 1; ticks(32);            // capture: the 6502's next cycle starts 32 clocks after HALT rises
    }
    top->d = 0xFF;
    return v;
}

static int marker = 0;
static bool launched = false;

// ---- just enough console for the real (7800basic) menu: MARIA's frame and
// display-list interrupts, the joystick. One bus cycle counts as one CPU cycle.
static bool real_menu = false;
static bool run_game = false;         // MATHTEST: the 6502 runs the launched game (MSTAT modelled)
static long cpu_cyc = 0, frame_no = 0;
static int joy = 0xFF;               // SWCHA (active low: bit 4 up, 5 down, 6 left, 7 right)
static bool fire = false;
static std::vector<long> nmi_at;     // CPU cycle (within the frame) of each display-list interrupt
static size_t nmi_next = 0;
static const long LINE_CYC = 114, FRAME_LINES = 263, VIS0 = 16;
static long vis_lines = 243;
extern "C" void nmi6502();
static void frame_start() {
    nmi_at.clear(); nmi_next = 0; frame_no++;
    if ((ram[0x3C] & 0x60) != 0x40) return;                  // DMA off
    uint16_t p = (uint16_t)((ram[0x2C] << 8) | ram[0x30]);   // DPPH / DPPL
    long line = VIS0;
    for (int k = 0; k < 64 && line < VIS0 + 243 && p < 0x3FFD; k++, p += 3) {
        if (ram[p] & 0x80) nmi_at.push_back(line * LINE_CYC);
        line += (ram[p] & 0x0F) + 1;
    }
}
static void console_step() {
    long f = cpu_cyc % (LINE_CYC * FRAME_LINES);
    static long last_f = -1;
    if (f < last_f) frame_start();
    last_f = f;
    if (nmi_next < nmi_at.size() && f >= nmi_at[nmi_next]) {
        nmi_next++;
        if ((ram[0x3C] & 0x60) == 0x40) nmi6502();           // no display, no display-list interrupts
    }
}
uint8_t read6502(uint16_t a) {
    uint8_t v = bus_cycle(a, false, 0);
    cpu_cyc++;
    if (a < 0x4000 && !last_driven) {
        if (real_menu || run_game) {
            long line = (cpu_cyc % (LINE_CYC * FRAME_LINES)) / LINE_CYC;
            if (a == 0x28) return (line < VIS0 || line >= VIS0 + vis_lines) ? 0x80 : 0x00;   // MSTAT
            if (a == 0x280) return (uint8_t)joy;                                             // SWCHA
            if (a == 0x282) return 0xFF;                                                     // SWCHB
            if (a == 0x08 || a == 0x09) return fire ? 0x80 : 0x00;                           // INPT0/1
            if (a == 0x0C) return fire ? 0x00 : 0x80;                                        // INPT4
            if (a >= 0x0A && a <= 0x0D) return 0x80;
        }
        return ram[a];
    }
    return v;
}
void write6502(uint16_t a, uint8_t v) {
    bus_cycle(a, true, v);
    cpu_cyc++;
    if (a < 0x4000) ram[a] = v;
    if (a == 0x1FFF) marker = v;
    if (a == 0x0460 && v == 5) launched = true;
}

static bool run_until_marker(int m, long max_instr) {
    for (long i = 0; i < max_instr; i++) {
        if (marker == m) return true;
        step6502();
    }
    return marker == m;
}

// ---------------------------------------------------------------- mapper model
struct Game {
    std::string path, title;
    std::vector<uint8_t> rom;
    bool is_a78 = false, supported = false;
    int nb = 0, win = 0, b4 = 0, sg = 0, mask = 0, add = 0, b8 = 0, bC = 0, pokey = 0;
    bool abs = false, mram = false, act = false, hflip = false, math = false;
    // Activision: what address a reads with bank sw selected (8K pieces; see cart_bus.v)
    int act_at(uint16_t a, int sw) const {
        int r = (a >> 13) & 7;
        int bank = r < 4 ? 6 : (r == 4 || r == 7) ? 7 : sw;
        int half = ((a >> 13) & 1) ^ (hflip ? 1 : 0);
        return at(bank, (half << 13) | (a & 0x1FFF));
    }
    long off = 0;                    // PSRAM address of rom[0]
    // byte of bank `bank` at offset `o`; -1 where the image has nothing
    int at(int bank, int o) const {
        long p = (long)bank * 0x4000 + o - off;
        if (p >= 0 && p < (long)rom.size()) return rom[p];
        if (rom.size() <= 0x2000 && p + (long)rom.size() >= 0 && p < 0) return rom[p + rom.size()];
        return -1;
    }
};

static Game load_game(const char *path) {
    Game g;
    g.path = path;
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    std::vector<uint8_t> d;
    uint8_t buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
    fclose(f);
    if (d.size() < 256 || memcmp(&d[1], "ATARI7800", 9)) return g;
    g.is_a78 = true;
    g.math = !memcmp(&d[59], "ACM", 3);
    g.title.assign((const char *)&d[17], 32);
    g.rom.assign(d.begin() + 128, d.end());
    int tl = d[54], th = d[53], ver = d[0];
    if (ver >= 4) {
        if (d[64] == 1) tl |= 2; else if (d[64] == 3) th |= 2; else if (d[64] == 2) th |= 1; else if (d[64]) return g;
        if (d[65] & 0x80) return g;
        switch (d[65] & 7) { case 0: break; case 1: tl |= 4; break; case 2: tl |= 0x80; break; case 4: tl |= 8; break; case 5: tl |= 16; break; default: return g; }
    }
    if ((th & 0x70) || (tl & 0x20)) return g;
    if (tl & 0x80) tl |= 4;                          // mirror RAM: RAM at $4000 without A8
    if (tl & 1) g.pokey = 1;
    if (tl & 0x40) g.pokey = 2;
    if (th & 0x04) g.pokey = g.pokey == 2 ? 5 : 4;
    if (th & 0x80) g.pokey = 3;
    if (ver >= 4) {
        switch (d[67] & 7) { case 0: break; case 1: g.pokey = 4; break; case 2: g.pokey = 2; break; case 3: g.pokey = 5; break; case 4: g.pokey = 3; break; case 5: g.pokey = 1; break; default: return g; }
    }
    g.nb = (int)((g.rom.size() + 0x3FFF) / 0x4000);
    if (g.nb < 1 || g.nb > 255) return g;
    g.off = (long)g.nb * 0x4000 - (long)g.rom.size();
    g.bC = g.nb - 1;
    if (th & 1) {                                    // Activision
        if (g.nb != 8) return g;
        g.act = true; g.win = 1; g.b4 = 6; g.b8 = 0;
        g.hflip = (g.rom[0x1FFF9] & 0x0F) != 7;      // "AM" dump (an "OM" one ends with the cart's last 8K)
    } else if (th & 2) {                             // Absolute
        if (g.nb != 4) return g;
        g.abs = true; g.win = 1; g.b8 = 2;
    } else if (tl & 2) {
        if (g.nb < 2) return g;
        g.sg = 1;
        if ((tl & 8) || (g.nb & 1)) { g.win = 1; g.add = 1; g.mask = g.nb - 2; }
        else if (tl & 4) { g.win = 2; g.mask = g.nb - 1; }
        else { g.win = 1; g.b4 = g.nb - 2; g.mask = g.nb - 1; }
    } else {
        if (g.nb > 3) return g;
        if (g.nb == 3) { g.win = 1; g.b8 = 1; }
        else g.win = (tl & 4) ? 2 : 0;
    }
    g.mram = (tl & 0x80) && g.win == 2;
    g.supported = true;
    return g;
}

// ---- what the menu should list: the rules of menu/fat.asm, written again ----
struct Ent { int cls; std::string title, key; int game; };       // cls: 0 "..", 1 directory, 2 game
static Ent make_ent(int cls, const std::string &name, int game) {
    std::string t = cls == 0 ? ".." : name;
    if (cls == 2 && t.size() > 4) t.resize(t.size() - 4);        // ".a78"
    if (t.size() > 32) t.resize(32);
    for (auto &c : t) if ((uint8_t)c < 32 || (uint8_t)c > 122) c = ' ';
    if (cls == 1) { if (t.size() < 32) t += '/'; else t[31] = '/'; }
    t.resize(32, ' ');
    Ent e{cls, t, t, game};
    for (auto &c : e.key) if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return e;
}
static std::vector<Ent> sorted_list(std::vector<Ent> v) {        // v: in directory order
    if (v.size() > 255) v.resize(255);
    std::stable_sort(v.begin(), v.end(), [](const Ent &a, const Ent &b) {
        return a.cls != b.cls ? a.cls < b.cls : a.key < b.key; });
    return v;
}
static std::string base_name(const std::string &p) { size_t k = p.rfind('/'); return k == std::string::npos ? p : p.substr(k + 1); }

static long cmp_n = 0;
static void check_read(const Game &g, uint16_t a, int bank, const char *what) {
    int e = g.at(bank, a & 0x3FFF);
    uint8_t v = bus_cycle(a, false, 0);
    if (e < 0) return;
    cmp_n++;
    CHECK(last_driven && v == e, "%s: $%04X (bank %d) reads %02X%s, file has %02X", what, a, bank, v,
          last_driven ? "" : " (not driven)", e);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s IMAGE HC GAME FILE.a78...\n", argv[0]); return 2; }
    sd.img = fopen(argv[1], "r+b");
    if (!sd.img) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    sd.hc = atoi(argv[2]) != 0;
    int want = atoi(argv[3]);
    // Card layout (as tools/mkfat32.py built it): the files are in /ROMS, or in
    // the root directory (ROOTDIR=1); SUB="NAME:I,J" moved files I and J into a
    // sub-directory of that directory.
    std::vector<Game> all;
    for (int i = 4; i < argc; i++) all.push_back(load_game(argv[i]));
    bool rootdir = getenv("ROOTDIR") != nullptr;
    std::string sub_name;
    std::vector<int> sub_idx;
    if (const char *sp = getenv("SUB")) {
        std::string spec = sp;
        size_t c = spec.find(':');
        sub_name = spec.substr(0, c);
        for (size_t k = c + 1; k < spec.size();) { sub_idx.push_back(atoi(spec.c_str() + k)); k = spec.find(',', k); if (k == std::string::npos) break; k++; }
    }
    auto in_sub = [&](int i) { return std::find(sub_idx.begin(), sub_idx.end(), i) != sub_idx.end(); };
    std::vector<Ent> gd, sd_, rd;
    if (!rootdir) gd.push_back(make_ent(0, "", -1));
    if (!sub_name.empty()) gd.push_back(make_ent(1, sub_name, -1));
    sd_.push_back(make_ent(0, "", -1));
    for (int i = 0; i < (int)all.size(); i++) {
        std::string b = base_name(all[i].path);
        if (b[0] == '.') continue;                       // dot files are not listed
        (in_sub(i) ? sd_ : gd).push_back(make_ent(2, b, i));
    }
    gd = sorted_list(gd); sd_ = sorted_list(sd_);
    if (rootdir) rd = gd; else rd.push_back(make_ent(1, "ROMS", -1));
    if (getenv("HSC") && !rootdir) rd.push_back(make_ent(1, "ASTROCART", -1));     // (mkfat32 --extra)
    rd = sorted_list(rd);
    int roms_pos = 0;
    for (int i = 0; i < (int)rd.size(); i++) if (rd[i].title.compare(0, 5, "ROMS/") == 0) roms_pos = i;
    std::vector<int> gpos;                               // list position of each game of the games directory
    int sub_pos = -1;
    for (int i = 0; i < (int)gd.size(); i++) { if (gd[i].cls == 2) gpos.push_back(i); if (gd[i].cls == 1) sub_pos = i; }
    if (want >= (int)gpos.size()) { fprintf(stderr, "game %d: the directory has %zu\n", want, gpos.size()); return 2; }
    const Ent *we = want >= 0 ? &gd[gpos[want]] : nullptr;
    auto read_list = [&](const std::vector<Ent> &exp, const char *what, bool show) {
        for (int i = 0; i < (int)exp.size(); i++) {
            uint8_t r = bus_cycle((uint16_t)(0x7100 + i), false, 0);
            uint8_t c = bus_cycle((uint16_t)(0x7000 + r), false, 0);
            char t[33];
            for (int k = 0; k < 32; k++) t[k] = (char)bus_cycle((uint16_t)(0x4800 + r * 32 + k), false, 0);
            t[32] = 0;
            if (show) printf("  %3d %c \"%s\"\n", i, "^dg"[c < 3 ? c : 0], t);
            CHECK(c == exp[i].cls && exp[i].title == t, "%s entry %d: class %d \"%s\", expected %d \"%s\"", what, i, c, t,
                  exp[i].cls, exp[i].title.c_str());
        }
    };
    srand(1234 + want);
    dbg_math = getenv("DBGMATH") != nullptr;
    if (getenv("DBGHSC")) dbg_hsc = (int)strtol(getenv("DBGHSC"), nullptr, 16);
    dma_on = getenv("NODMA") == nullptr;
    if (getenv("CPUHI")) cpu_hi = atoi(getenv("CPUHI"));
    if (getenv("AGLITCH")) aglitch = atoi(getenv("AGLITCH"));
    late_phi2 = getenv("LATEPHI2") ? atoi(getenv("LATEPHI2")) : 2;

    top = new Vdevcart_top;
    top->uart_rxd = 1; top->phi2 = 0; top->rw = 1; top->halt = 1; top->a = 0; top->d = 0xFF; top->sd_miso = 1;
    ticks(3000);
    memset(ram, 0, sizeof ram);

    real_menu = getenv("REALMENU") != nullptr;
    reset6502(0);
    bool ok, skip = false;
    if (real_menu) {
        // The 7800basic menu: variables a.. at $E6.. (sel, top, count); fat.asm's ac_nent at $4221.
        auto frames = [&](long n) { long f0 = frame_no; for (long i = 0; i < 30000000L && frame_no < f0 + n; i++) { step6502(); console_step(); } };
        long guard = 0;
        while (ram[0xE8] != rd.size() && guard++ < 3000) frames(1);
        CHECK(ram[0xE8] == rd.size(), "the menu never listed the root directory (count %d, err $%02X, pc $%04X)", ram[0xE8], ram[0xEA], pc);
        frames(30);
        read_list(rd, "root", false);
        if (!rootdir) {                      // fire on "ROMS/"
            for (int k = 0; k < roms_pos; k++) { joy = 0xFF & ~0x20; frames(3); joy = 0xFF; frames(12); }
            fire = true; frames(3); fire = false;
            for (guard = 0; ram[0xE8] != gd.size() && guard < 3000; guard++) frames(1);
            CHECK(ram[0xE8] == gd.size(), "/ROMS: %d entries listed, expected %zu (err $%02X)", ram[0xE8], gd.size(), ram[0xEA]);
            frames(30);
        }
        printf("menu: %d entries listed after %ld frames (%ld blocks read)\n", ram[0xE8], frame_no, sd.reads);
        read_list(gd, "games directory", want < 0);
        if (!fails && want < 0 && sub_pos >= 0) {
            // into the sub-directory and back out: the cursor returns to it
            for (int k = 0; k < sub_pos; k++) { joy = 0xFF & ~0x20; frames(3); joy = 0xFF; frames(12); }
            fire = true; frames(3); fire = false;
            for (guard = 0; ram[0xE8] != sd_.size() && guard < 3000; guard++) frames(1);
            frames(30);
            CHECK(ram[0xE8] == sd_.size() && ram[0xE6] == 0, "sub-directory: %d entries, cursor %d", ram[0xE8], ram[0xE6]);
            read_list(sd_, "sub-directory", true);
            fire = true; frames(3); fire = false;            // ".."
            for (guard = 0; ram[0xE8] != gd.size() && guard < 3000; guard++) frames(1);
            frames(30);
            CHECK(ram[0xE8] == gd.size() && ram[0xE6] == sub_pos, "back up: %d entries, cursor %d (wanted %d)", ram[0xE8], ram[0xE6], sub_pos);
            read_list(gd, "games directory again", false);
        }
        if (fails || want < 0) { printf(fails ? "MULTICART SIM FAILED (%d)\n" : "MULTICART LIST PASSED\n", fails); return fails ? 1 : 0; }
        int pos = gpos[want];
        for (int k = 0; k < pos; k++) { joy = 0xFF & ~0x20; frames(3); joy = 0xFF; frames(12); }
        CHECK(ram[0xE6] == pos, "cursor on entry %d, wanted %d", ram[0xE6], pos);
        for (int k = 0; k < 32; k++) {       // the title on the cursor's line of the display buffer
            uint8_t c = bus_cycle((uint16_t)(0x4600 + (pos % 16) * 32 + k), false, 0);
            CHECK(c == (uint8_t)we->title[k], "line buffer char %d: %02X, title has %02X", k, c, (uint8_t)we->title[k]);
        }
        const Game &g = all[we->game];
        frames(30);                          // the cursor rests: two lines from the game's header appear
        {
            char l1[33], l2[33];
            for (int k = 0; k < 32; k++) { l1[k] = (char)bus_cycle((uint16_t)(0x7380 + k), false, 0); l2[k] = (char)bus_cycle((uint16_t)(0x73A0 + k), false, 0); }
            l1[32] = l2[32] = 0;
            printf("info: \"%s\" / \"%s\"\n", l1, l2);
            std::string e = g.is_a78 ? g.title : std::string("NOT AN .A78 FILE");
            e.resize(32, ' ');
            for (auto &c : e) if ((uint8_t)c < 32 || (uint8_t)c > 122) c = ' ';
            CHECK(e == l1, "info line 1 \"%s\", expected \"%s\"", l1, e.c_str());
            char want2[40];
            snprintf(want2, sizeof want2, "%zuK", (g.rom.size() + 1023) / 1024);
            if (g.is_a78) CHECK(!strncmp(l2, want2, strlen(want2)) && (strstr(l2, "NOT SUPPORTED") != nullptr) == !g.supported &&
                                (strstr(l2, "ACTIVISION") != nullptr) == (g.supported && g.act) && (strstr(l2, "SUPERGAME") != nullptr) == (g.supported && g.sg) && (strstr(l2, "POKEY") != nullptr) == (g.supported && g.pokey != 0),
                                "info line 2 \"%s\" (expected %s...)", l2, want2);
        }
        long r0 = sd.reads, f0 = frame_no;
        fire = true; frames(3); fire = false;
        for (long i = 0; i < 400000000L && !(launched && pc >= 0x4000) && !(ram[0xEA] && ram[0xEF] == 1); i++) { step6502(); console_step(); }
        printf("load: %ld blocks in %ld frames; err $%02X\n", sd.reads - r0, frame_no - f0, ram[0xEA]);
        if (!g.supported) {
            CHECK(ram[0xEA] == (g.is_a78 ? 0x20 : 0x23), "unsupported cart was not refused ($%02X)", ram[0xEA]);
            printf(fails ? "MULTICART SIM FAILED (%d)\n" : "MULTICART SIM PASSED (cart refused)\n", fails);
            return fails ? 1 : 0;
        }
        CHECK(ram[0xEA] == 0, "load error $%02X", ram[0xEA]);
        CHECK((ram[0x3C] & 0x60) == 0x60, "MARIA DMA was not turned off before the launch (CTRL $%02X)", ram[0x3C]);
        real_menu = false;                   // the game's own console state is not modelled
        skip = true;
    }
    if (!skip) {
    ok = run_until_marker(0xA1, 40000000L);
    CHECK(ok, "the program never finished ac_init (pc $%04X)", pc);
    printf("ac_init -> $%02X, %d entries (expected %zu); %ld blocks read, %ld clocks\n",
           ram[0x1F00], ram[0x1F01], rd.size(), sd.reads, cyc);
    CHECK(ram[0x1F00] == 0, "ac_init error $%02X", ram[0x1F00]);
    if (ram[0x1F00]) {
        printf("status %02X; buffer:", bus_cycle(0x0460, false, 0));
        for (int k = 0; k < 512; k++) { if (k % 32 == 0) printf("\n %03X:", k); printf(" %02X", bus_cycle((uint16_t)(0x4000 + k), false, 0)); }
        printf("\n");
    }
    if (!getenv("WALK")) {
        CHECK(ram[0x1F01] == rd.size(), "root directory: %d entries", ram[0x1F01]);
        if (!fails) read_list(rd, "root", false);
    }
    // ac_enter through the harness: entry, expected list, expected cursor
    auto enter = [&](int idx, const std::vector<Ent> &exp, int cur, const char *what, bool show) {
        long c0 = cyc;
        ram[0x1F02] = (uint8_t)idx; ram[0x1F05] = 1; marker = 0; ram[0x1F03] = 1;
        bool done = run_until_marker(0xA3, 40000000L);
        CHECK(done && ram[0x1F04] == 0, "ac_enter(%d) for %s: $%02X", idx, what, ram[0x1F04]);
        CHECK(ram[0x1F01] == exp.size() && ram[0x1F06] == cur, "%s: %d entries (expected %zu), cursor %d (expected %d)", what,
              ram[0x1F01], exp.size(), ram[0x1F06], cur);
        printf("%s: %d entries, %.2f s of console time\n", what, ram[0x1F01], (cyc - c0) / 67.5e6);
        if (!fails) read_list(exp, what, show);
        ram[0x1F05] = 0;
    };
    if (getenv("WALK")) {
        // A card of unknown content (a copy of a real card's directories): walk it
        // three levels deep through ac_enter and print every list, for comparison
        // with the listing tools/devcart.py makes of the same card.
        struct W { static void list(int n) {
            for (int i = 0; i < n; i++) {
                uint8_t r = bus_cycle((uint16_t)(0x7100 + i), false, 0);
                uint8_t c = bus_cycle((uint16_t)(0x7000 + r), false, 0);
                char t[33];
                for (int k = 0; k < 32; k++) t[k] = (char)bus_cycle((uint16_t)(0x4800 + r * 32 + k), false, 0);
                t[32] = 0;
                printf("E %d %s|\n", c, t);
            } } };
        auto go = [&](int idx) {
            ram[0x1F02] = (uint8_t)idx; ram[0x1F05] = 1; marker = 0; ram[0x1F03] = 1;
            bool done = run_until_marker(0xA3, 40000000L);
            CHECK(done && ram[0x1F04] == 0, "ac_enter(%d): $%02X", idx, ram[0x1F04]);
        };
        std::function<void(int)> walk = [&](int depth) {
            int n = ram[0x1F01];
            printf("D %d\n", n);
            W::list(n);
            for (int i = 0; i < n && depth < 3 && !fails; i++) {
                uint8_t r = bus_cycle((uint16_t)(0x7100 + i), false, 0);
                if (bus_cycle((uint16_t)(0x7000 + r), false, 0) != 1) continue;
                go(i);
                walk(depth + 1);
                go(0);
                CHECK(ram[0x1F01] == n && ram[0x1F06] == i, "back up from entry %d: %d entries, cursor %d", i, ram[0x1F01], ram[0x1F06]);
            }
        };
        walk(0);
        printf(fails ? "WALK FAILED (%d)\n" : "WALK DONE\n", fails);
        return fails ? 1 : 0;
    }
    if (!fails && !rootdir) enter(roms_pos, gd, 0, "/ROMS", want < 0);
    if (!fails && want < 0 && sub_pos >= 0) {
        enter(sub_pos, sd_, 0, "sub-directory", true);
        if (!fails) enter(0, gd, sub_pos, "back up", false);
        if (!fails && !rootdir) {
            enter(0, rd, roms_pos, "back to the root", false);
            if (!fails) enter(roms_pos, gd, 0, "/ROMS again", false);
        }
    }
    if (want < 0 || fails) {
        printf(fails ? "MULTICART SIM FAILED (%d)\n" : "MULTICART LIST PASSED\n", fails);
        return fails ? 1 : 0;
    }

    ram[0x1F02] = (uint8_t)gpos[want];
    ram[0x1F05] = 0;
    ram[0x1F03] = 1;
    const Game &g = all[we->game];
    long r0 = sd.reads, c0 = cyc;
    ok = run_until_marker(0xA2, 400000000L);
    CHECK(ok, "the program never finished ac_load (pc $%04X)", pc);
    printf("ac_load(%d) -> $%02X; %ld blocks, %.2f s of console time\n", want, ram[0x1F04], sd.reads - r0,
           (cyc - c0) / 67.5e6);
    if (!g.supported) {
        CHECK(ram[0x1F04] == (g.is_a78 ? 0x20 : 0x23), "unsupported cart was not refused ($%02X)", ram[0x1F04]);
        printf(fails ? "MULTICART SIM FAILED (%d)\n" : "MULTICART SIM PASSED (cart refused)\n", fails);
        return fails ? 1 : 0;
    }
    CHECK(ram[0x1F04] == 0, "ac_load error $%02X", ram[0x1F04]);
    if (fails) { printf("MULTICART SIM FAILED (%d)\n", fails); return 1; }

    // the launch: the stub runs from RAM, then jumps through the game's reset vector
    for (long i = 0; i < 200000 && !(launched && pc >= 0x4000); i++) step6502();
    }
    const Game &g = all[we->game];
    int rv = g.act ? (g.act_at(0xFFFC, 0) | (g.act_at(0xFFFD, 0) << 8)) : (g.at(g.bC, 0x3FFC) | (g.at(g.bC, 0x3FFD) << 8));
    printf("launched: pc $%04X (the game's reset vector $%04X)\n", pc, rv);
    CHECK(launched && pc == rv, "launch");

    // everything the console can see, against the file
    printf("mapper: %d banks, $4000 %s, %s, POKEY %d\n", g.nb,
           g.win == 0 ? "open" : g.win == 1 ? "ROM" : g.mram ? "mirror RAM" : "RAM",
           g.sg ? "SuperGame" : g.abs ? "Absolute" : g.act ? (g.hflip ? "Activision (AM dump)" : "Activision (OM dump)") : "linear", g.pokey);
    if (g.act) {
        auto chk = [&](uint16_t a, int sw, const char *what) {
            int e = g.act_at(a, sw);
            uint8_t v = bus_cycle(a, false, 0);
            cmp_n++;
            CHECK(last_driven && v == e, "%s: $%04X (bank %d selected) reads %02X, file has %02X", what, a, sw, v, e);
        };
        for (int a = 0x4000; a < 0x10000; a++) chk((uint16_t)a, 0, "Activision, after the launch");
        static const int seq[] = {3, 0, 7, 5, 1, 2, 6, 4};
        for (int b : seq) {
            bus_cycle((uint16_t)(0xFF80 + b), true, (uint8_t)rand());
            // the 6502 reads the new bank at once (from PSRAM while the slot refills)
            for (int j = 0; j < 80; j++) chk((uint16_t)(0xA000 + (rand() & 0x3FFF)), b, "Activision bank (at once)");
            for (int j = 0; j < 30; j++) { chk((uint16_t)(0x4000 + (rand() & 0x5FFF)), b, "Activision fixed"); chk((uint16_t)(0xE000 + (rand() & 0x1FFF)), b, "Activision fixed"); }
            for (int a = 0xA000; a < 0xE000; a += (b == 4 ? 1 : 53)) chk((uint16_t)a, b, "Activision bank");
        }
        bus_cycle(0xFF90, true, 0); bus_cycle(0xFF7F, true, 0); bus_cycle(0x7F80, true, 0);     // not bank selects
        for (int a = 0x4000; a < 0x10000; a += 7) chk((uint16_t)a, 4, "Activision, after writes elsewhere");
    }
    if (!g.act) for (int a = 0xC000; a < 0x10000; a++) check_read(g, (uint16_t)a, g.bC, "$C000");
    if (g.win == 1 && g.pokey != 1 && !g.act)
        for (int a = 0x4000; a < 0x8000; a++) check_read(g, (uint16_t)a, g.b4, "$4000");
    if (g.win == 0 && g.pokey != 1) {
        for (int k = 0; k < 200; k++) {
            bus_cycle((uint16_t)(0x4000 + rand() % 0x4000), false, 0);
            CHECK(!last_driven, "cart drives $4000-$7FFF of a cart with nothing there");
        }
    }
    if (g.win == 2) {
        // (mirror RAM has no A8: an odd page is the even page below it)
        std::vector<int> model(0x4000, -1);
        int amask = g.mram ? 0x3EFF : 0x3FFF;
        for (int k = 0; k < 300; k++) {
            bus_cycle((uint16_t)(0x4000 + k * 53), true, (uint8_t)(k * 7 + 1));
            model[(k * 53) & amask] = (uint8_t)(k * 7 + 1);
        }
        for (int k = 0; k < 300; k++) {
            uint8_t v = bus_cycle((uint16_t)(0x4000 + k * 53), false, 0);
            CHECK(last_driven && v == model[(k * 53) & amask], "cart RAM $%04X reads %02X, expected %02X", 0x4000 + k * 53, v, model[(k * 53) & amask]);
        }
        if (g.mram) {
            bus_cycle(0x4234, true, 0xA5);
            uint8_t v = bus_cycle(0x4334, false, 0);
            CHECK(v == 0xA5, "mirror RAM: $4334 reads %02X after $4234 <- A5", v);
            bus_cycle(0x7F80, true, 0x3C);
            v = bus_cycle(0x7E80, false, 0);
            CHECK(v == 0x3C, "mirror RAM: $7E80 reads %02X after $7F80 <- 3C", v);
        }
    }
    if (g.abs) {
        // Absolute: $8000 <- bit 0 selects bank 0, else bit 1 bank 1, else nothing;
        // the 6502 reads the new bank at once (from PSRAM while the slot refills)
        static const int seq[][2] = {{2, 1}, {1, 0}, {0, 0}, {2, 1}, {3, 0}, {0, 0}, {2, 1}, {4, 1}, {1, 0}};
        for (auto &sv : seq) {
            bus_cycle(0x8000, true, (uint8_t)sv[0]);
            for (int j = 0; j < 60; j++) check_read(g, (uint16_t)(0x4000 + (rand() & 0x3FFF)), sv[1], "Absolute bank (at once)");
            for (int a = 0x4000; a < 0x8000; a += 61) check_read(g, (uint16_t)a, sv[1], "Absolute bank");
            for (int j = 0; j < 20; j++) check_read(g, (uint16_t)(0x8000 + (rand() & 0x3FFF)), 2, "Absolute fixed bank");
        }
        bus_cycle(0x8001, true, 2); bus_cycle(0x9000, true, 2);             // only $8000 itself switches
        for (int j = 0; j < 40; j++) check_read(g, (uint16_t)(0x4000 + (rand() & 0x3FFF)), 0, "Absolute bank after writes elsewhere");
        bus_cycle(0x8000, true, 2);
        for (int a = 0x4000; a < 0x8000; a++) check_read(g, (uint16_t)a, 1, "Absolute bank 1, in full");
    }
    // Cart RAM written while the $8000 slot is being refilled (the 6502 is not
    // halted for a bank switch any more, and games copy level data right then)
    if (g.sg && g.win == 2) {
        for (int round = 0; round < 6; round++) {
            bus_cycle(0x8000, true, (uint8_t)(round + 1)); bus_cycle(0xC000, false, 0);
            for (int k = 0; k < 120; k++) {
                uint8_t v = bus_cycle((uint16_t)(0x8000 + k * 31 + round), false, 0);       // ROM -> RAM, as a game would
                bus_cycle((uint16_t)(0x5000 + round * 256 + k), true, (uint8_t)(v ^ k));
            }
        }
        for (int round = 0; round < 6; round++)
            for (int k = 0; k < 120; k++) {
                int e = g.at(((round + 1) & g.mask) + g.add, k * 31 + round);
                uint8_t v = bus_cycle((uint16_t)(0x5000 + round * 256 + k), false, 0);
                CHECK(last_driven && v == (uint8_t)(e ^ k), "RAM written during a refill: $%04X reads %02X, expected %02X",
                      0x5000 + round * 256 + k, v, (uint8_t)(e ^ k));
            }
    }
    if (g.act) {
    } else if (!g.sg) {
        for (int a = 0x8000; a < 0xC000; a++) check_read(g, (uint16_t)a, g.b8, "$8000");
    } else {
        for (int v = g.mask; v >= 0; v--) {
            bus_cycle((uint16_t)(0x8000 + (rand() & 0x3FFF)), true, (uint8_t)(v | (g.mask < 32 ? 0xE0 : 0x80)));   // (bits above the mask are ignored)
            bus_cycle(0xC000, false, 0);
            int bank = (v & g.mask) + g.add;
            int step = (v == 0 || v == g.mask) ? 1 : 97;         // two banks in full, the rest sampled
            for (int a = 0x8000; a < 0xC000; a += step) check_read(g, (uint16_t)a, bank, "switched bank");
        }
    }
    // POKEY at $4000 leaves slot 0 idle: it is a second bank buffer. Going back and
    // forth between two banks (Commando does it every frame) must not halt the 6502.
    if (g.sg && g.pokey == 1) {
        bus_cycle(0x8000, true, 6); bus_cycle(0xC000, false, 0);
        bus_cycle(0x8000, true, 0); bus_cycle(0xC000, false, 0);
        long h0 = halt_clocks;
        for (int k = 0; k < 40; k++) {
            int v = (k & 1) ? 0 : 6;
            bus_cycle(0x8000, true, (uint8_t)v);
            bus_cycle(0xC000, false, 0);
            for (int j = 0; j < 12; j++) check_read(g, (uint16_t)(0x8000 + (rand() & 0x3FFF)), v, "buffered bank");
        }
        printf("40 switches between two buffered banks: %ld clocks of HALT\n", halt_clocks - h0);
        CHECK(halt_clocks == h0, "a switch between buffered banks pulled HALT");
        for (int v = 1; v <= 5; v++) {                   // and banks in neither buffer still arrive
            bus_cycle(0x8000, true, (uint8_t)v); bus_cycle(0xC000, false, 0);
            for (int j = 0; j < 40; j++) check_read(g, (uint16_t)(0x8000 + (rand() & 0x3FFF)), v, "copied bank");
            bus_cycle(0x8000, true, 6); bus_cycle(0xC000, false, 0);
            for (int j = 0; j < 40; j++) check_read(g, (uint16_t)(0x8000 + (rand() & 0x3FFF)), 6, "sound bank");
        }
        printf("HALT pulled for %ld clocks in all (HALT-free mode: 0 expected)\n", halt_clocks);
    }
    // POKEY: a write must not be taken as a bank switch, and the cart answers reads there
    if (g.pokey == 2) {
        bus_cycle(0x0450, true, 0x55);
        bus_cycle(0x045A, false, 0);
        CHECK(last_driven, "POKEY at $0450 does not answer");
    }
    if (g.pokey == 5) {
        // two POKEYs: each has its own registers (RANDOM, register 10, runs once SKCTL is set)
        bus_cycle(0x045F, true, 0x03);
        ticks(4000);
        uint8_t r1 = bus_cycle(0x045A, false, 0);
        CHECK(last_driven, "POKEY at $0450 does not answer");
        uint8_t r2 = bus_cycle(0x044A, false, 0);
        CHECK(last_driven, "the second POKEY at $0440 does not answer");
        ticks(4000);
        uint8_t r1b = bus_cycle(0x045A, false, 0), r2b = bus_cycle(0x044A, false, 0);
        printf("two POKEYs: RANDOM at $045A %02X -> %02X (running), at $044A %02X -> %02X (still in reset)\n", r1, r1b, r2, r2b);
        CHECK(r1 != r1b && r2 == r2b, "the two POKEYs do not have separate registers");
        bus_cycle(0x0461, false, 0);
        CHECK(!last_driven, "the cart answers at $0461");
    }
    if (g.pokey == 4) {
        bus_cycle(0x0440, true, 0x55);
        bus_cycle(0x044A, false, 0);
        CHECK(last_driven, "POKEY at $0440 does not answer");
        bus_cycle(0x045A, false, 0);
        CHECK(!last_driven, "POKEY at $0440 also answers at $0450");
    }
    // ---- High Score Cart (HSC=<its ROM as an .a78>, HSCSAV=<the card's HSC.SAV>) ----
    if (const char *hp = getenv("HSC")) {
        auto r = top->rootp;
        bool want_hsc = false;
        { FILE *f = fopen(g.path.c_str(), "rb"); uint8_t h[128]; if (f && fread(h, 1, 128, f) == 128) want_hsc = h[58] & 1; if (f) fclose(f); }
        CHECK((bool)r->devcart_top__DOT__cfg_hsc == want_hsc, "High Score Cart %s, header says %s", r->devcart_top__DOT__cfg_hsc ? "on" : "off", want_hsc ? "yes" : "no");
        if (want_hsc && r->devcart_top__DOT__cfg_hsc) {
            std::vector<uint8_t> hrom(4096), hram(2048);
            { FILE *f = fopen(hp, "rb"); fseek(f, 128, SEEK_SET); size_t n = fread(hrom.data(), 1, 4096, f); (void)n; fclose(f); }
            { FILE *f = fopen(getenv("HSCSAV"), "rb"); size_t n = fread(hram.data(), 1, 2048, f); (void)n; fclose(f); }
            long w0 = sd.writes;
            {   // the blocks the cart will write to are HSC.SAV's own
                std::vector<uint8_t> at(2048);
                fseek(sd.img, (long)r->devcart_top__DOT__hs_lba * 512, SEEK_SET);
                size_t n = fread(at.data(), 1, 2048, sd.img); (void)n;
                CHECK(at == hram, "the save address (block %u) does not hold HSC.SAV", (unsigned)r->devcart_top__DOT__hs_lba);
            }
            auto rd = [&](uint16_t a, const char *what) {
                int e = a >= 0x3000 ? hrom[a - 0x3000] : hram[a - 0x1000];
                uint8_t v = bus_cycle(a, false, 0);
                cmp_n++;
                CHECK(last_driven && v == e, "HSC %s: $%04X reads %02X%s, expected %02X", what, a, v, last_driven ? "" : " (not driven)", e);
            };
            auto wr = [&](uint16_t a, uint8_t v) { bus_cycle(a, true, v); hram[a - 0x1000] = v; };
            for (int a = 0x3000; a < 0x4000; a++) rd((uint16_t)a, "ROM");
            for (int a = 0x1000; a < 0x1800; a++) rd((uint16_t)a, "RAM as loaded");
            bus_cycle(0x1800, false, 0); CHECK(!last_driven, "the cart answers at $1800");
            bus_cycle(0x2FFF, false, 0); CHECK(!last_driven, "the cart answers at $2FFF");
            // as the HSC's own code would: fetches from its ROM around every RAM access
            for (int k = 0; k < 400; k++) {
                uint16_t a = (uint16_t)(0x1000 + (k * 37 + 5) % 0x800);
                rd((uint16_t)(0x3000 + (rand() & 0xFFF)), "ROM"); rd((uint16_t)(0x3000 + (rand() & 0xFFF)), "ROM");
                wr(a, (uint8_t)(k * 3 + 1));
                rd((uint16_t)(0x3000 + (rand() & 0xFFF)), "ROM");
                rd(a, "RAM just written");
                if (k % 5 == 0) { wr(a, (uint8_t)(k + 9)); wr(a, (uint8_t)(k + 10)); rd(a, "RAM written twice in a row"); }   // INC-style
            }
            // a fill loop: STA $1xxx,X / DEX / BNE -- every cycle but the write reads PSRAM
            for (int k = 0; k < 256; k++) {
                rd(0x3100, "ROM"); rd(0x3101, "ROM"); rd(0x3102, "ROM"); rd((uint16_t)(0x1400 + k), "RAM");
                wr((uint16_t)(0x1400 + k), (uint8_t)(255 - k));
                rd(0x3103, "ROM"); rd(0x3104, "ROM"); rd(0x3104, "ROM"); rd(0x3105, "ROM"); rd(0x3105, "ROM");
            }
            for (int a = 0x1000; a < 0x1800; a++) rd((uint16_t)a, "RAM after the writes");
            // MARIA reads the HSC's font from the ROM: 27 clocks per address, HALT low
            {
                int worst = 0, bad = 0;
                top->halt = 0; top->rw = 1; ticks(60);
                for (int k = 0; k < 300; k++) {
                    uint16_t a = (uint16_t)(0x3900 + (rand() % 0x700));
                    top->a = a;
                    int at = -1;
                    for (int t = 0; t < 27; t++) {
                        tick();
                        bool ok = top->buf_dir && top->d__en == 0xFF && top->d__out == hrom[a - 0x3000];
                        if (ok && at < 0) at = t + 1;
                        if (!ok) at = -1;
                    }
                    if (at < 0) bad++; else if (at > worst) worst = at;
                    top->a = (uint16_t)(0x2000 + (rand() & 0x7FF)); ticks(19);       // a character map byte from console RAM
                }
                top->halt = 1; ticks(40);
                printf("HSC font read by MARIA (27 clocks per address): right from clock %d at the latest; %d of 300 never right\n", worst, bad);
                CHECK(bad == 0, "%d MARIA reads of the HSC ROM never got their byte", bad);
            }
            // nothing written for a while: the RAM goes to the card
            long guard = 0;
            while (sd.writes < w0 + 4 && guard++ < 400000) { rd((uint16_t)(0x3000 + (rand() & 0xFFF)), "ROM during the save"); bus_cycle(0xC000, false, 0); bus_cycle(0x0080, false, 0); }
            for (int k = 0; k < 2000; k++) bus_cycle(0x0080, false, 0);
            unsigned lba = r->devcart_top__DOT__hs_lba;
            printf("HSC: %ld blocks written to the card at block %u; saves %u, errors %u, queue overflows %u\n", sd.writes - w0, lba,
                   (unsigned)r->devcart_top__DOT__hs_saves, (unsigned)r->devcart_top__DOT__hs_errs, (unsigned)r->devcart_top__DOT__hq_ovf);
            CHECK(sd.writes == w0 + 4 && r->devcart_top__DOT__hs_saves == 1 && r->devcart_top__DOT__hs_errs == 0, "the save");
            CHECK(r->devcart_top__DOT__hq_ovf == 0, "writes to the HSC RAM were lost");
            std::vector<uint8_t> card(2048);
            fseek(sd.img, (long)lba * 512, SEEK_SET);
            size_t n = fread(card.data(), 1, 2048, sd.img); (void)n;
            int diff = 0;
            for (int k = 0; k < 2048; k++) diff += card[k] != hram[k];
            CHECK(diff == 0, "HSC.SAV on the card differs from the RAM in %d bytes", diff);
            // and a second round of writes is saved again
            wr(0x1234, 0x5A); wr(0x17FF, 0xA5);
            guard = 0;
            while (sd.writes < w0 + 8 && guard++ < 400000) { bus_cycle(0xC000, false, 0); bus_cycle(0x0080, false, 0); }
            for (int k = 0; k < 2000; k++) bus_cycle(0x0080, false, 0);
            fseek(sd.img, (long)lba * 512, SEEK_SET);
            n = fread(card.data(), 1, 2048, sd.img);
            CHECK(card[0x234] == 0x5A && card[0x7FF] == 0xA5 && sd.writes == w0 + 8, "the second save");
        }
    }
    bus_cycle(0x0460, false, 0);
    CHECK(!last_driven, "menu registers still answer after the launch");
    {   // the math unit: there only for a game whose header has "ACM" in bytes 59-61
        bool want = g.rom.size() && g.math;
        uint8_t id = bus_cycle(0x043F, false, 0);
        CHECK(last_driven == want && (!want || id == 0xA1), "math unit %s (ID read %s, $%02X)", want ? "missing" : "answers", last_driven ? "driven" : "open", id);
    }
    if (getenv("MATHTEST")) {
        // run the game on the 6502 model: tests/mathtest reports in zero page
        run_game = true;
        ram[0x44] = 0;
        long i = 0;
        for (; i < 4000000 && ram[0x44] != 0xA5 && ram[0x44] != 0xEE; i++) { step6502(); console_step(); }
        printf("mathtest: status $%02X after %ld instructions, %d script steps; reg %d got $%02X want $%02X\n",
               ram[0x44], i, ram[0x42] | (ram[0x43] << 8), ram[0x45], ram[0x46], ram[0x47]);
        CHECK(ram[0x44] == 0xA5, "the math unit self-test did not pass");
    }
    CHECK(halt_clocks == 0, "the cart pulled HALT (%ld clocks) in HALT-free mode", halt_clocks);
    {   // the cart's own measurement of its PSRAM-served reads
        auto r = top->rootp;
        unsigned reads = r->devcart_top__DOT__u_bus__DOT__c_px_reads, miss = r->devcart_top__DOT__u_bus__DOT__c_px_miss;
        printf("6502 reads served from PSRAM: %u, byte never came: %u\n", reads, miss);
        if (g.sg || g.abs || g.act) CHECK(reads > 0, "no PSRAM-served reads counted");
        CHECK(miss == 0, "%u PSRAM-served reads never got their byte", miss);
    }
    printf("%ld bytes compared\n", cmp_n);
    printf(fails ? "MULTICART SIM FAILED (%d)\n" : "MULTICART SIM PASSED\n", fails);
    delete top;
    return fails ? 1 : 0;
}
