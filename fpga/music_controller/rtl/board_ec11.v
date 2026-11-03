// Adapted from project/input/src/ec11_input.v: anchor first stable AB level, including idle11.
module board_ec11 #(parameter SAMPLE_CYCLES=2500,AB_SAMPLES=2,BUTTON_SAMPLES=60,STEPS_PER_DETENT=4,
    parameter TICK_W=(SAMPLE_CYCLES>1?$clog2(SAMPLE_CYCLES):1))(
    input wire clk,rst,a,b,button_n,
    output reg step_valid,output reg signed [1:0] step,
    output reg pressed,button_changed,invalid_transition
);
    reg [2:0] sync1,sync2;
    reg [1:0] candidate,position;
    reg button_candidate;
    reg [TICK_W-1:0] tick;
    reg [15:0] ab_count,button_count;
    reg anchored;reg signed [4:0] partial;
    reg signed [2:0] direction;
    reg signed [5:0] next_partial;
    always @* begin
        direction=0;
        case({position,candidate})
            4'b0001,4'b0111,4'b1110,4'b1000:direction=1;
            4'b0010,4'b1011,4'b1101,4'b0100:direction=-1;
            default:direction=0;
        endcase
        next_partial=partial+direction;
    end
    always @(posedge clk) begin
        if(rst) begin
            sync1<=3'b001;sync2<=3'b001;candidate<=0;position<=0;button_candidate<=0;
            anchored<=0;tick<=0;ab_count<=0;button_count<=0;partial<=0;step_valid<=0;step<=0;
            pressed<=0;button_changed<=0;invalid_transition<=0;
        end else begin
            sync1<={a,b,button_n};sync2<=sync1;
            step_valid<=0;button_changed<=0;invalid_transition<=0;
            if(tick==SAMPLE_CYCLES-1) begin
                tick<=0;
                if(sync2[2:1]!=candidate) begin candidate<=sync2[2:1];ab_count<=1;end
                else if(!anchored) begin
                    if(ab_count>=AB_SAMPLES-1) begin position<=candidate;partial<=0;anchored<=1;ab_count<=0;end
                    else ab_count<=ab_count+1'b1;
                end else if(candidate!=position) begin
                    if(ab_count>=AB_SAMPLES-1) begin
                        position<=candidate;ab_count<=0;
                        if(direction==0) begin partial<=0;invalid_transition<=1;end
                        else if(next_partial>=STEPS_PER_DETENT) begin partial<=0;step<=1;step_valid<=1;end
                        else if(next_partial<=-STEPS_PER_DETENT) begin partial<=0;step<=-1;step_valid<=1;end
                        else partial<=next_partial;
                    end else ab_count<=ab_count+1'b1;
                end
                if(!sync2[0]!=button_candidate) begin button_candidate<=!sync2[0];button_count<=1;end
                else if(button_candidate!=pressed) begin
                    if(button_count>=BUTTON_SAMPLES-1) begin pressed<=button_candidate;button_changed<=1;button_count<=0;end
                    else button_count<=button_count+1'b1;
                end
            end else tick<=tick+1'b1;
        end
    end
endmodule
