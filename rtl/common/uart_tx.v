// ============================================================================
// uart_tx -- 8N1 transmitter. Tang Nano 9K: FPGA pin 17 goes to the BL702
// USB bridge, which shows up on the host as the second usbserial port.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module uart_tx #(
    parameter CLKS_PER_BIT = 703      // 81 MHz / 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,          // 1-cycle request (only while !busy)
    input  wire [7:0] data,
    output wire       busy,
    output reg        tx
);
    localparam CW = $clog2(CLKS_PER_BIT + 1);
    localparam integer LAST_I = CLKS_PER_BIT - 1;
    localparam [CW-1:0] LAST = LAST_I[CW-1:0];

    reg [CW-1:0] cnt;
    reg [3:0]    bitn;       // 0 = idle, 1..10 = start, d0..d7, stop
    reg [8:0]    sh;

    assign busy = (bitn != 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx   <= 1'b1;
            bitn <= 4'd0;
            cnt  <= {CW{1'b0}};
            sh   <= 9'h1FF;
        end else if (bitn == 4'd0) begin
            tx <= 1'b1;
            if (start) begin
                sh   <= {1'b1, data};
                tx   <= 1'b0;                 // start bit
                bitn <= 4'd1;
                cnt  <= {CW{1'b0}};
            end
        end else if (cnt == LAST) begin
            cnt <= {CW{1'b0}};
            if (bitn == 4'd10) begin
                bitn <= 4'd0;
                tx   <= 1'b1;
            end else begin
                tx   <= sh[0];
                sh   <= {1'b1, sh[8:1]};
                bitn <= bitn + 4'd1;
            end
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule

`default_nettype wire
