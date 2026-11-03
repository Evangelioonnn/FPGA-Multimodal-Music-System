// Current-board adapter. Physical controls submit requests to the same state
// service as host and ADC; they never keep private absolute audio parameters.
module audio_panel #(
    parameter BUTTON_CYCLES=150000, LONG_CYCLES=50000000,
    parameter LW=(LONG_CYCLES>1?$clog2(LONG_CYCLES):1)
)(
    input wire clk,rst,input wire [2:0] button_n,
    input wire step_valid,input wire signed [1:0] step,
    input wire [2:0] preset,input wire [16:0] master,
    input wire [6:0] left_base,right_base,
    input wire sustain,sostenuto,input wire [2:0] release_index,glide_index,
    input wire signed [4:0] bend_index,input wire [1:0] attack_index,
    input wire [6:0] vibrato_depth,input wire [2:0] vibrato_speed,
    input wire effect_enable,input wire [7:0] effect_mix,
    input wire [15:0] adsr_a,adsr_d,adsr_s,adsr_r,
    input wire envelope_override,custom_hold,
    input wire [11:0] raw1,raw2,raw3,raw4,
    output reg request_valid,input wire request_ready,
    output reg [4:0] request_addr,output reg [31:0] request_value,
    output reg [4:0] mode,output reg overflow
);
    wire [2:0] down,press,up;
    genvar b;
    generate for(b=0;b<3;b=b+1) begin: buttons
        playable_button #(.DEBOUNCE_CYCLES(BUTTON_CYCLES)) f(
            clk,rst,button_n[b],down[b],press[b],up[b]);
    end endgenerate
    reg [LW-1:0] held0,held1,held2;
    reg fired0,fired1,fired2;
    reg [2:0] prior_preset;
    reg command;
    reg [4:0] addr;
    reg [31:0] value;
    reg [11:0] raw;
    reg [4:0] volume_index;
    integer i;

    function [16:0] volume_code;
        input integer index;
        begin case(index)
            0:volume_code=0;1:volume_code=22;2:volume_code=32;
            3:volume_code=45;4:volume_code=65;5:volume_code=92;
            6:volume_code=130;7:volume_code=184;8:volume_code=260;
            9:volume_code=368;10:volume_code=520;11:volume_code=734;
            12:volume_code=1038;13:volume_code=1466;14:volume_code=2071;
            15:volume_code=2926;16:volume_code=4134;17:volume_code=5840;
            18:volume_code=8249;19:volume_code=11653;20:volume_code=16461;
            21:volume_code=23252;22:volume_code=32845;23:volume_code=46395;
            default:volume_code=65536;
        endcase end
    endfunction
    function [31:0] add_saturated;
        input [31:0] current,amount,low,high;
        input increase;
        begin
            if(increase) add_saturated=current>=high-amount ? high : current+amount;
            else add_saturated=current<=low+amount ? low : current-amount;
        end
    endfunction
    always @* begin
        volume_index=0;
        for(i=0;i<24;i=i+1)
            if(master>((volume_code(i)+volume_code(i+1))>>1)) volume_index=i+1;
        raw=mode==1 ? raw1 : mode==2 ? raw2 : mode==3 ? raw3 : raw4;
        command=0;addr=0;value=0;
        if(down[0] && !fired0 && held0==LONG_CYCLES-1) begin
            command=1;addr=30;value=1;
        end else if(down[2] && !fired2 && held2==LONG_CYCLES-1) begin
            command=1;addr=31;value=1;
        end else if(up[2] && !fired2) begin
            command=1;addr=0;
            case(preset) 0:value=3;2:value=3;3:value=4;4:value=5;default:value=0;endcase
        end else if(down[1] && !fired1 && held1==LONG_CYCLES-1) begin
            command=1;addr=6;value=!sostenuto;
        end else if(up[1] && !fired1) begin
            command=1;addr=5;value=!sustain;
        end else if(up[0] && !fired0 && preset!=5 && mode==5) begin
            command=1;addr=9;value=0;
        end else if(step_valid && step!=0) begin
            command=1;
            if(mode==0) begin
                addr=1;
                value=volume_code(step>0 ? (volume_index<24 ? volume_index+1 : 24) :
                    (volume_index>0 ? volume_index-1 : 0));
            end else if(preset==5) begin
                addr=19+mode;value=add_saturated(raw,64,0,4095,step>0);
            end else case(mode)
                1:begin addr=3;value=add_saturated(left_base,12,36,72,step>0);end
                2:begin addr=4;value=add_saturated(right_base,12,36,72,step>0);end
                3:begin addr=7;value=add_saturated(release_index,1,0,7,step>0);end
                4:begin addr=8;value=add_saturated(glide_index,1,0,4,step>0);end
                5:begin addr=9;value=step>0 ? (bend_index<8 ? $signed(bend_index)+1 : 8) :
                    (bend_index> -8 ? $signed(bend_index)-1 : -8);end
                6:begin addr=10;value=add_saturated(attack_index,1,0,3,step>0);end
                7:begin addr=16;value=add_saturated(vibrato_depth,4,0,64,step>0);end
                8:begin addr=17;value=add_saturated(vibrato_speed,1,0,7,step>0);end
                9:begin addr=18;value=step>0;end
                10:begin addr=19;value=add_saturated(effect_mix,8,0,128,step>0);end
                11:begin addr=11;value=add_saturated(adsr_a,32,1,65535,step>0);end
                12:begin addr=12;value=add_saturated(adsr_d,2,1,65535,step>0);end
                13:begin addr=13;value=add_saturated(adsr_s,4096,0,65535,step>0);end
                14:begin addr=14;value=add_saturated(adsr_r,2,1,65535,step>0);end
                15:begin addr=24;value=step>0;end
                16:begin addr=15;value=step>0;end
                default:command=0;
            endcase
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            request_valid<=0;request_addr<=0;request_value<=0;mode<=0;overflow<=0;
            held0<=0;held1<=0;held2<=0;fired0<=0;fired1<=0;fired2<=0;prior_preset<=0;
        end else begin
            prior_preset<=preset;
            if(preset!=prior_preset) mode<=0;
            if(down[2] && !fired2 && held2==LONG_CYCLES-1) mode<=0;
            if(request_valid && request_ready) request_valid<=0;
            if(command) begin
                if(!request_valid || request_ready) begin
                    request_valid<=1;request_addr<=addr;request_value<=value;
                end else overflow<=1;
            end
            if(down[0] && !fired0) begin
                if(held0==LONG_CYCLES-1) fired0<=1;else held0<=held0+1'b1;
            end
            if(down[1] && !fired1) begin
                if(held1==LONG_CYCLES-1) fired1<=1;else held1<=held1+1'b1;
            end
            if(down[2] && !fired2) begin
                if(held2==LONG_CYCLES-1) fired2<=1;else held2<=held2+1'b1;
            end
            if(up[0]) begin
                held0<=0;fired0<=0;
                if(!fired0) mode<=mode==(preset==5 ? 4 : 16) ? 0 : mode+1'b1;
            end
            if(up[1]) begin held1<=0;fired1<=0;end
            if(up[2]) begin held2<=0;fired2<=0;end
        end
    end
endmodule
