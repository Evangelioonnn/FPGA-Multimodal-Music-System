module bt_uart_tx #(parameter integer CLKS_PER_BIT=5208)(
    input wire clk, input wire rst,
    input wire [7:0] data, input wire valid, output wire ready,
    output wire tx
);
    reg busy;
    reg [9:0] shift;
    reg [3:0] bit_index;
    localparam integer TIMER_W=(CLKS_PER_BIT>1) ? $clog2(CLKS_PER_BIT) : 1;
    localparam integer BIT_RELOAD=CLKS_PER_BIT-1, HALF_RELOAD=CLKS_PER_BIT/2-1;
    reg [TIMER_W-1:0] timer;
    assign ready=!busy;
    assign tx=busy ? shift[0] : 1'b1;
    always @(posedge clk) begin
        if (rst) begin busy<=0; shift<=10'h3ff; bit_index<=0; timer<=0; end
        else if (!busy) begin
            if (valid) begin
                shift<={1'b1,data,1'b0}; busy<=1; timer<=BIT_RELOAD[TIMER_W-1:0]; bit_index<=0;
            end
        end else if (timer!=0) timer<=timer-1'b1;
        else if (bit_index==9) busy<=0;
        else begin
            shift<={1'b1,shift[9:1]}; timer<=BIT_RELOAD[TIMER_W-1:0]; bit_index<=bit_index+1'b1;
        end
    end
endmodule
