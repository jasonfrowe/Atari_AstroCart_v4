// ============================================================================
// astromath -- the AstroCart math unit, version 2 (docs/MATHUNIT.md; the
// reference model is sim/math/astromath.h).
//
// Addresses 0-31 = $0420-$043F: the trig block (rotate a vector; angle and
// length of a vector) at 0-15, the version 1 registers at 16-31.
//
// Version 1 registers ($0430-$043F). Results are functions of the operand
// registers: a write restarts whatever depends on it, and the answer is there
// long before the 6502 can read it --
//   product      2 clocks after A, B or CTRL changes (one hardware multiplier)
//   Q, R         36 clocks after N, D or CTRL changes (one bit per clock)
//   square root  18 clocks after N changes
// against the ~110 clocks (three bus cycles) between a write and the next
// instruction's read.
//
// Trig block ($0420-$042F): one CORDIC datapath (18 steps of two clocks)
// does two jobs after any write to X, Y or T, one behind the other: the
// angle and length of (X, Y), and (X, Y) turned by T. About 45 clocks, up to
// 16 more for a vector only a few units long, and the length 3-19 after
// that. Hardware multipliers do the shifts and the scaling (the chip has
// them to spare; logic is what is short).
//
// we / waddr / wdata: one clock per 6502 write. rd_evt: one clock at the end
// of each 6502 read cycle (raddr_evt = its register): a read of RND steps the
// generator, once.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module astromath (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [7:0]  wdata,
    input  wire        rd_evt,
    input  wire [3:0]  raddr_evt,
    input  wire [4:0]  raddr,        // the register on the bus now
    output reg  [7:0]  rdata         // (combinational)
);
    reg [15:0] ra, rb, rd;
    reg [31:0] rn, acc, rx;
    reg        sg;

    // ---- product: 17 x 17 signed, the operands sign- or zero-extended ----
    reg  signed [16:0] ma, mb;
    reg  signed [33:0] mp;
    always @(posedge clk) begin
        ma <= {sg & ra[15], ra};
        mb <= {sg & rb[15], rb};
        mp <= ma * mb;
    end
    wire [31:0] p = mp[31:0];

    // ---- registers ----
    reg go_div, go_sqrt;             // 1 clock: N / D / CTRL changed
    reg [15:0] tx, ty, tt;           // trig block: X, Y, T
    reg go_t;                        // 1 clock: one of them changed
    wire [3:0] wa = waddr[3:0];
    wire [31:0] xn1 = rx  ^ (rx  << 13);
    wire [31:0] xn2 = xn1 ^ (xn1 >> 17);
    wire [31:0] xn  = xn2 ^ (xn2 << 5);          // the generator's next state
    wire [31:0] xs  = {rx[23:0], wdata};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ra <= 16'd0; rb <= 16'd0; rd <= 16'd0; rn <= 32'd0; acc <= 32'd0; rx <= 32'd1; sg <= 1'b0;
            go_div <= 1'b1; go_sqrt <= 1'b1;
            tx <= 16'd0; ty <= 16'd0; tt <= 16'd0; go_t <= 1'b0;
        end else begin
            go_div <= 1'b0; go_sqrt <= 1'b0; go_t <= 1'b0;
            if (rd_evt && raddr_evt == 4'hE) rx <= xn;
            if (we && !waddr[4]) begin
                case (wa)
                    4'h0: tx[7:0]  <= wdata;
                    4'h1: tx[15:8] <= wdata;
                    4'h2: ty[7:0]  <= wdata;
                    4'h3: ty[15:8] <= wdata;
                    4'h4: tt[7:0]  <= wdata;
                    4'h5: tt[15:8] <= wdata;
                    default: ;
                endcase
                if (wa <= 4'h5) go_t <= 1'b1;
            end
            if (we && waddr[4]) begin
                case (wa)
                    4'h0: ra[7:0]   <= wdata;
                    4'h1: ra[15:8]  <= wdata;
                    4'h2: rb[7:0]   <= wdata;
                    4'h3: rb[15:8]  <= wdata;
                    4'h4: rn[7:0]   <= wdata;
                    4'h5: rn[15:8]  <= wdata;
                    4'h6: rn[23:16] <= wdata;
                    4'h7: rn[31:24] <= wdata;
                    4'h8: rd[7:0]   <= wdata;
                    4'h9: rd[15:8]  <= wdata;
                    4'hA: sg        <= wdata[0];
                    4'hB: case (wdata)
                              8'd1: acc <= 32'd0;
                              8'd2: acc <= acc + p;
                              8'd3: acc <= acc - p;
                              8'd4: rn  <= acc;
                              default: ;
                          endcase
                    4'hE: rx <= (xs == 32'd0) ? 32'd1 : xs;
                    default: ;
                endcase
                if (wa[3:2] == 2'b01 || wa == 4'h8 || wa == 4'h9 || wa == 4'hA ||
                    (wa == 4'hB && wdata == 8'd4)) go_div <= 1'b1;
                if (wa[3:2] == 2'b01 || (wa == 4'hB && wdata == 8'd4)) go_sqrt <= 1'b1;
            end
        end
    end

    // ---- divide: restoring, on magnitudes, one quotient bit per clock ----
    wire        n_neg = sg && rn[31];
    wire        d_neg = sg && rd[15];
    reg  [31:0] dq;                  // dividend shifting out / quotient shifting in
    reg  [16:0] drem;
    reg  [15:0] dden;
    reg  [5:0]  dcnt;
    reg         drun, dfix;
    reg         dqneg, drneg;
    reg  [31:0] q;
    reg  [15:0] r;
    wire [17:0] dtry = {drem, dq[31]} - {2'b00, dden};      // 18 bits: bit 17 = borrow
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dq <= 32'd0; drem <= 17'd0; dden <= 16'd0; dcnt <= 6'd0; drun <= 1'b0; dfix <= 1'b0;
            dqneg <= 1'b0; drneg <= 1'b0; q <= 32'hFFFFFFFF; r <= 16'd0;
        end else if (go_div) begin
            dq    <= n_neg ? (~rn + 32'd1) : rn;
            dden  <= d_neg ? (~rd + 16'd1) : rd;
            drem  <= 17'd0;
            dcnt  <= 6'd0;
            drun  <= 1'b1;
            dfix  <= 1'b0;
            dqneg <= n_neg ^ d_neg;
            drneg <= n_neg;
        end else if (drun) begin
            if (dtry[17]) begin
                drem <= {drem[15:0], dq[31]};
                dq   <= {dq[30:0], 1'b0};
            end else begin
                drem <= dtry[16:0];
                dq   <= {dq[30:0], 1'b1};
            end
            dcnt <= dcnt + 6'd1;
            if (dcnt == 6'd31) begin drun <= 1'b0; dfix <= 1'b1; end
        end else if (dfix) begin
            dfix <= 1'b0;
            if (rd == 16'd0) begin
                q <= 32'hFFFFFFFF;
                r <= rn[15:0];
            end else begin
                q <= dqneg ? (~dq + 32'd1) : dq;
                r <= drneg ? (~drem[15:0] + 16'd1) : drem[15:0];
            end
        end
    end

    // ---- square root of N (unsigned), one result bit per clock ----
    reg  [31:0] sv;
    reg  [16:0] srem;                // (at most twice the root so far)
    reg  [15:0] sroot, s;
    reg  [4:0]  scnt;
    reg         srun;
    wire [18:0] sin  = {srem, sv[31:30]};
    wire [18:0] stst = {1'b0, sroot, 2'b01};
    wire [18:0] ssub = sin - stst;
    wire        sge  = (sin >= stst);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sv <= 32'd0; srem <= 17'd0; sroot <= 16'd0; s <= 16'd0; scnt <= 5'd0; srun <= 1'b0;
        end else if (go_sqrt) begin
            sv <= rn; srem <= 17'd0; sroot <= 16'd0; scnt <= 5'd0; srun <= 1'b1;
        end else if (srun) begin
            sv    <= {sv[29:0], 2'b00};
            srem  <= sge ? ssub[16:0] : sin[16:0];
            sroot <= {sroot[14:0], sge};
            scnt  <= scnt + 5'd1;
            if (scnt == 5'd15) begin
                srun <= 1'b0;
                s    <= {sroot[14:0], sge};
            end
        end
    end

    // ------------------------------------------------------------------
    // Trig block. The arithmetic is that of astromath::rotate() and
    // ::vector() in the reference model, bit for bit.
    //
    // One CORDIC step takes two clocks (shift, then add / subtract), so the
    // datapath is a ring of two register stages and the two jobs go round it
    // one behind the other: the vector job (angle and length of X, Y) in one
    // stage while the rotation is in the other.
    //
    //   go_t  W1  W2  NLOAD  NORM...  J1  J2  J3      (the control states)
    //   two multipliers: (X, Y) x +-8 for the vector job, then (X, Y) or
    //   (Y, X) x +-16 / gain for the rotation (the quarter turns are the swap
    //   and the signs; x +-16 exactly when T is a whole number of them)
    //   NLOAD   the vector job's start into nx, ny
    //   NORM    a small vector is scaled up, one bit per clock; then into the ring
    //   J2      the rotation's start into nx, ny;  J3: into the ring
    // ------------------------------------------------------------------
    function [18:0] atan_i;                              // atan(2^-i), 2^21 = a full turn
        input [4:0] i;
        case (i)
            5'd0:  atan_i = 19'd262144;  5'd1:  atan_i = 19'd154753;  5'd2:  atan_i = 19'd81767;
            5'd3:  atan_i = 19'd41506;   5'd4:  atan_i = 19'd20834;   5'd5:  atan_i = 19'd10427;
            5'd6:  atan_i = 19'd5215;    5'd7:  atan_i = 19'd2608;    5'd8:  atan_i = 19'd1304;
            5'd9:  atan_i = 19'd652;     5'd10: atan_i = 19'd326;     5'd11: atan_i = 19'd163;
            5'd12: atan_i = 19'd81;      5'd13: atan_i = 19'd41;      5'd14: atan_i = 19'd20;
            5'd15: atan_i = 19'd10;      5'd16: atan_i = 19'd5;       5'd17: atan_i = 19'd3;
            default: atan_i = 19'd0;
        endcase
    endfunction

    localparam [2:0] T_IDLE = 3'd0, T_W1 = 3'd1, T_W2 = 3'd2, T_NLOAD = 3'd3,
                     T_NORM = 3'd4, T_J1 = 3'd5, T_J2 = 3'd6, T_J3 = 3'd7;
    reg  [2:0]         tst;
    reg                mrot;                             // the multipliers: 0 vector job, 1 rotation
    reg  signed [21:0] nx, ny;                           // a job's start (4 guard bits)
    reg  [4:0]         cn;                               // how far a small vector was scaled up
    reg                cneg, czero;
    reg  [15:0]        xr, yr, ang, len;

    // ---- the two multipliers ----
    wire [1:0]         qt    = tt[15:14] + {1'b0, tt[13]};        // the nearest quarter turn
    wire               remz  = (tt[13:0] == 14'd0);               // ... and nothing left over
    wire               swp   = mrot && qt[0];
    wire               sgn1  = mrot ? (qt == 2'd1 || qt == 2'd2) : tx[15];
    wire               sgn2  = mrot ? (qt == 2'd2 || qt == 2'd3) : tx[15];
    wire signed [17:0] mag   = !mrot ? 18'sd32768 : remz ? 18'sd65536 : 18'sd39797;   // 39797 = 2^16 / 1.646760
    reg  signed [15:0] m1a, m2a;
    reg  signed [17:0] m1b, m2b;
    reg  signed [33:0] m1p, m2p;
    reg  [17:0]        m3a;                              // (unsigned: up to 1.16 x 2^17)
    reg  [35:0]        m3p;
    wire               vfin;                             // the vector job has just come out of the ring
    always @(posedge clk) begin
        m1a <= swp ? ty : tx;
        m2a <= swp ? tx : ty;
        m1b <= sgn1 ? -mag : mag;
        m2b <= sgn2 ? -mag : mag;
        m1p <= m1a * m1b;
        m2p <= m2a * m2b;
        if (vfin) m3a <= x1[20:3];                       // (never negative, below 2^21)
        m3p <= m3a * 18'd79594;                          // 2^17 / gain: the length
    end
    wire signed [21:0] ldx = m1p[33:12];
    wire signed [21:0] ldy = m2p[33:12];
    wire               vsmall = (nx[21:18] == 4'h0 || nx[21:18] == 4'hF) && (ny[21:18] == 4'h0 || ny[21:18] == 4'hF);

    // ---- the ring ----
    reg  signed [21:0] x1, y1, x2, y2, sx2, sy2;
    reg  signed [20:0] z1, z2;
    reg  [4:0]         i1, i2;                           // step
    reg                v1, v2;                           // a job is in this stage
    reg                r1, r2;                           // ... and it is the rotation
    reg                fin1;                             // stage 1 holds a finished job
    assign             vfin = v1 && fin1 && !r1;
    wire               rfin = v1 && fin1 && r1;
    wire               pos  = r2 ? !z2[20] : y2[21];     // turn towards z = 0 (rotation) or y = 0 (vector)
    wire signed [20:0] at   = {2'b00, atan_i(i2)};
    wire               inj_v = (tst == T_NORM) && !(vsmall && !czero);
    wire               inj_r = (tst == T_J3);

    // the shifts, done by two hardware multipliers: v >>> i = (v * 2^(17-i)) >>> 17
    wire        [17:0] sh1  = 18'd131072 >> i1;
    wire signed [40:0] shx  = x1 * $signed({1'b0, sh1});
    wire signed [40:0] shy  = y1 * $signed({1'b0, sh1});

    // the end of the rotation: round, clamp
    wire signed [21:0] x1r  = x1 + 22'sd8;
    wire signed [21:0] y1r  = y1 + 22'sd8;
    function [15:0] sat16;
        input signed [17:0] v;
        sat16 = (v > 18'sd32767) ? 16'h7FFF : (v < -18'sd32768) ? 16'h8000 : v[15:0];
    endfunction
    wire signed [20:0] z1r  = z1 + 21'sd16;

    // the length: (final x / 8) * (2^17 / gain) / 2^14, then back down by the scaling, rounded
    reg  [1:0]  lst;                 // 0 idle, 1 / 2 the multiplier, 3 shifting
    reg  [21:0] lr;
    reg  [4:0]  ln;
    wire [21:0] lrr = lr + 22'd4;

    always @(posedge clk) begin      // (no reset: v1 / v2 say what is real)
        // stage 1 -> stage 2: the shifts
        x2 <= x1; y2 <= y1; z2 <= z1; i2 <= i1; r2 <= r1;
        if (r1 && remz) begin sx2 <= 22'sd0; sy2 <= 22'sd0; end       // whole quarter turns: no steps
        else            begin sx2 <= shy[38:17]; sy2 <= shx[38:17]; end
        // stage 2 -> stage 1: add / subtract; or a job comes in
        if (inj_v || inj_r) begin
            x1 <= nx; y1 <= ny; i1 <= 5'd0; r1 <= inj_r;
            z1 <= inj_r ? {{2{tt[13]}}, tt[13:0], 5'b00000} : 21'sd0;
        end else begin
            x1 <= pos ? x2 - sx2 : x2 + sx2;
            y1 <= pos ? y2 + sy2 : y2 - sy2;
            z1 <= pos ? z2 - at  : z2 + at;
            i1 <= i2 + 5'd1; r1 <= r2;
        end
        // a job's start
        if (tst == T_NLOAD || tst == T_J2) begin nx <= ldx; ny <= ldy; end
        else if (tst == T_NORM)            begin nx <= nx <<< 1; ny <= ny <<< 1; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tst <= T_IDLE; mrot <= 1'b0; cn <= 5'd0; cneg <= 1'b0; czero <= 1'b1;
            v1 <= 1'b0; v2 <= 1'b0; fin1 <= 1'b0;
            xr <= 16'd0; yr <= 16'd0; ang <= 16'd0; len <= 16'd0;
            lst <= 2'd0; lr <= 22'd0; ln <= 5'd0;
        end else if (go_t) begin
            tst <= T_W1; mrot <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; fin1 <= 1'b0; lst <= 2'd0;
        end else begin
            // the ring's bookkeeping
            v2   <= v1 && !fin1;
            v1   <= v2 || inj_v || inj_r;
            fin1 <= v2 && (i2 == 5'd17);
            case (tst)
                T_W1:    tst <= T_W2;
                T_W2:    tst <= T_NLOAD;
                T_NLOAD: begin
                    cn <= 5'd0; cneg <= tx[15]; czero <= (tx == 16'd0) && (ty == 16'd0);
                    mrot <= 1'b1;
                    tst  <= T_NORM;
                end
                T_NORM:  if (vsmall && !czero) cn <= cn + 5'd1; else tst <= T_J1;
                T_J1:    tst <= T_J2;
                T_J2:    tst <= T_J3;
                T_J3:    tst <= T_IDLE;
                default: ;
            endcase
            if (rfin) begin
                xr <= sat16(x1r[21:4]); yr <= sat16(y1r[21:4]);
            end
            if (vfin) begin          // (m3a takes x1 on this edge)
                ang <= czero ? 16'd0 : (z1r[20:5] ^ {cneg, 15'd0});
                lst <= 2'd1;
            end
            case (lst)
                2'd1: lst <= 2'd2;                           // m3p <= m3a * ...
                2'd2: begin lr <= m3p[35:14]; ln <= cn; lst <= 2'd3; end
                2'd3: if (ln != 5'd0) begin lr <= {1'b0, lr[21:1]}; ln <= ln - 5'd1; end
                      else begin len <= czero ? 16'd0 : lrr[18:3]; lst <= 2'd0; end
                default: ;
            endcase
        end
    end

    // (registered copies of two read values that are otherwise logic deep:
    // both change only with a write or a read event, a clock earlier)
    reg       dz;
    reg [7:0] xnr;
    always @(posedge clk) begin dz <= (rd == 16'd0); xnr <= xn[7:0]; end

    // ---- read: combinational from raddr, like the menu registers. cart_bus
    // registers it and ignores it while the address is unsettled; a slower
    // answer here would slip past that filter (a one-clock disturbance on an
    // address line would put a neighbouring register on the bus) ----
    always @(*) begin
        case (raddr)
            5'h00: rdata = xr[7:0];
            5'h01: rdata = xr[15:8];
            5'h02: rdata = yr[7:0];
            5'h03: rdata = yr[15:8];
            5'h04: rdata = ang[7:0];
            5'h05: rdata = ang[15:8];
            5'h06: rdata = len[7:0];
            5'h07: rdata = len[15:8];
            5'h0F: rdata = 8'hA2;
            5'h10: rdata = p[7:0];
            5'h11: rdata = p[15:8];
            5'h12: rdata = p[23:16];
            5'h13: rdata = p[31:24];
            5'h14: rdata = q[7:0];
            5'h15: rdata = q[15:8];
            5'h16: rdata = q[23:16];
            5'h17: rdata = q[31:24];
            5'h18: rdata = r[7:0];
            5'h19: rdata = r[15:8];
            5'h1A: rdata = s[7:0];
            5'h1B: rdata = s[15:8];
            5'h1C: rdata = {7'd0, sg};
            5'h1D: rdata = {7'd0, dz};
            5'h1E: rdata = xnr;
            5'h1F: rdata = 8'hA1;
            default: rdata = 8'h00;
        endcase
    end
endmodule

`default_nettype wire
