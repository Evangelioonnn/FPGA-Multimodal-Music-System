// 8N1, synchronous reset, no generated clock. CLKS_PER_BIT must be >= 8.
module bt_uart_rx #(parameter integer CLKS_PER_BIT=5208)(
    input wire clk, input wire rst, input wire rx,
    output reg [7:0] data, output reg valid, output reg error
);
    (* syn_preserve=1 *) reg rx_meta, rx_sync;
    reg [2:0] state;
    localparam integer TIMER_W=(CLKS_PER_BIT>1) ? $clog2(CLKS_PER_BIT) : 1;
    localparam integer BIT_RELOAD=CLKS_PER_BIT-1, HALF_RELOAD=CLKS_PER_BIT/2-1;
    reg [TIMER_W-1:0] timer;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk) begin
        if (rst) begin rx_meta<=1'b1; rx_sync<=1'b1; end
        else begin rx_meta<=rx; rx_sync<=rx_meta; end
    end
    always @(posedge clk) begin
        valid<=0; error<=0;
        if (rst) begin
            state<=0; timer<=0; bit_index<=0; shift<=0; data<=0;
        end else case (state)
            0: if (!rx_sync) begin state<=1; timer<=HALF_RELOAD[TIMER_W-1:0]; end
            1: if (timer!=0) timer<=timer-1'b1;
               else if (rx_sync) state<=0;
               else begin state<=2; timer<=BIT_RELOAD[TIMER_W-1:0]; bit_index<=0; end
            2: if (timer!=0) timer<=timer-1'b1;
               else begin
                   shift[bit_index]<=rx_sync; timer<=BIT_RELOAD[TIMER_W-1:0];
                   if (bit_index==7) state<=3; else bit_index<=bit_index+1'b1;
               end
            3: if (timer!=0) timer<=timer-1'b1;
               else if (rx_sync) begin data<=shift; valid<=1; state<=0; end
               else begin error<=1; state<=4; end
            // Break generates one error; require line recovery before rearming.
            4: if (rx_sync) state<=0;
            default: state<=0;
        endcase
    end
endmodule
