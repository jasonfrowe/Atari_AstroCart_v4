// ============================================================================
// uart_rx -- 8N1 receiver (FPGA pin 18 <- BL702 USB bridge).
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module uart_rx #(
    parameter CLKS_PER_BIT = 352      // 81 MHz / 230400
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg        valid,          // 1-cycle pulse with data
    output reg  [7:0] data
);
    localparam CW = $clog2(CLKS_PER_BIT + 1);
    localparam integer LAST_I = CLKS_PER_BIT - 1;
    localparam integer HALF_I = CLKS_PER_BIT / 2;
    localparam [CW-1:0] LAST = LAST_I[CW-1:0];
    localparam [CW-1:0] HALF = HALF_I[CW-1:0];

    reg [2:0]    rx_s;
    reg [CW-1:0] cnt;
    reg [3:0]    bitn;        // 0 idle, 1 start, 2..9 data, 10 stop
    reg [7:0]    sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s  <= 3'b111;
            cnt   <= {CW{1'b0}};
            bitn  <= 4'd0;
            sh    <= 8'd0;
            valid <= 1'b0;
            data  <= 8'd0;
        end else begin
            rx_s  <= {rx_s[1:0], rx};
            valid <= 1'b0;
            if (bitn == 4'd0) begin
                if (rx_s[2] && !rx_s[1]) begin     // falling edge: start bit
                    bitn <= 4'd1;
                    cnt  <= {CW{1'b0}};
                end
            end else if (bitn == 4'd1 ? (cnt == HALF) : (cnt == LAST)) begin
                cnt <= {CW{1'b0}};
                if (bitn == 4'd1) begin
                    bitn <= rx_s[1] ? 4'd0 : 4'd2; // false start -> idle
                end else if (bitn == 4'd10) begin
                    bitn <= 4'd0;
                    if (rx_s[1]) begin             // good stop bit
                        valid <= 1'b1;
                        data  <= sh;
                    end
                end else begin
                    sh   <= {rx_s[1], sh[7:1]};
                    bitn <= bitn + 4'd1;
                end
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
