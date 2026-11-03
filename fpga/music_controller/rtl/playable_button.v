// Independent asynchronous button synchronizer and stable-level debounce.
module playable_button #(parameter DEBOUNCE_CYCLES=150000,
    parameter CW=(DEBOUNCE_CYCLES>1?$clog2(DEBOUNCE_CYCLES):1))(
    input wire clk,rst,button_n,
    output reg down,pressed,released
);
    reg sync1,sync2;
    reg [CW-1:0] count;
    always @(posedge clk) begin
        if(rst) begin sync1<=1;sync2<=1;down<=0;count<=0;pressed<=0;released<=0;end
        else begin
            sync1<=button_n;sync2<=sync1;pressed<=0;released<=0;
            if(!sync2==down) count<=0;
            else if(count==DEBOUNCE_CYCLES-1) begin
                down<=!sync2;pressed<=!sync2;released<=sync2;count<=0;
            end else count<=count+1'b1;
        end
    end
endmodule
