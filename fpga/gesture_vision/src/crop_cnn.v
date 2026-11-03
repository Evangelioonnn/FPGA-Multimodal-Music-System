// Fixed 32x32 RGB hand-crop diagnostic CNN. No CPU, training or threshold logic.
// Synchronous block memories, 8 output lanes, registered signed products.
// Parameter ROM layout is documented and hashed in assets/MODEL.json.
module p20_crop_cnn #(
    parameter CONV_FILE="assets/conv.mem",
    parameter FC_FILE="assets/fc.mem",
    parameter SHIFT_FILE="assets/shifts.mem"
)(
    input wire clk,input wire rst,
    input wire input_we,input wire [9:0] input_address,
    input wire [15:0] input_rgb565,input wire start,
    output reg busy,output reg done,output reg error,
    output reg signed [7:0] open_logit,output reg signed [7:0] fist_logit,
    output reg signed [7:0] reject_logit,output reg signed [7:0] accept_logit,
    output reg [31:0] cycles,output reg [31:0] input_crc,
    output reg [31:0] feature_crc,output reg [31:0] head_crc
);
    reg [15:0] input_ram [0:1023];
    reg [63:0] layer0_ram [0:1023];
    reg [63:0] layer1_ram [0:1023];
    reg [7:0] pooled_ram [0:511];
    reg [63:0] conv_rom [0:98];
    reg [31:0] fc_rom [0:511];
    `include "assets/bias_constants.vh"
    reg [7:0] shift_rom [0:5];
    initial begin
        $readmemh(CONV_FILE,conv_rom);
        $readmemh(FC_FILE,fc_rom);
        $readmemh(SHIFT_FILE,shift_rom);
    end

    localparam IDLE=0,IC_REQ=1,IC_R=2,IC_G=3,IC_B=4,
      C_INIT=5,C_REQ=6,C_MUL=7,C_ACC=8,C_STORE=9,
      P_INIT=10,P_REQ=11,P_ACC=12,P_WRITE=13,
      F_INIT=14,F_REQ=15,F_MUL=16,F_ACC=17,F_END=18,
      H_CRC=19,FINISH=20,C_PRE=21,F_PRE=22;
    reg [4:0] state;
    reg [10:0] loaded;
    reg load_fault;
    reg [31:0] running_cycles,crc_in_work,crc_feature_work,crc_head_work;
    reg [9:0] crc_pixel,pixel;
    reg layer;
    reg [6:0] tap;
    reg [3:0] ci;
    reg [1:0] kx,ky;
    reg sample_zero;
    reg [15:0] input_q;
    reg [63:0] feature_q,conv_q,pool_q,pool_word;
    reg [31:0] fc_q;
    reg [7:0] pooled_q;
    reg signed [16:0] product [0:7];
    reg [7:0] operand;reg [63:0] weight_operand;
    reg signed [31:0] accumulator [0:7];
    reg [10:0] pool_sum [0:7];
    reg [5:0] pool_tile;
    reg [3:0] pool_offset;
    reg [2:0] pool_lane;
    reg [8:0] fc_index;
    reg [1:0] head_index;
    reg signed [7:0] result_work [0:3];
    integer i;

    wire signed [6:0] src_x=$signed({2'b00,pixel[4:0]})+$signed({5'b0,kx})-7'sd1;
    wire signed [6:0] src_y=$signed({2'b00,pixel[9:5]})+$signed({5'b0,ky})-7'sd1;
    wire outside=(src_x<0)||(src_x>31)||(src_y<0)||(src_y>31);
    wire [9:0] conv_address={src_y[4:0],src_x[4:0]};
    wire [9:0] pool_address={pool_tile[5:3],pool_offset[3:2],pool_tile[2:0],pool_offset[1:0]};
    wire [6:0] weight_address=layer ? (7'd27+tap) : tap;
    wire [6:0] red_q7={input_q[15:11],input_q[15:14]};
    wire [6:0] green_q7={input_q[10:5],input_q[10]};
    wire [6:0] blue_q7={input_q[4:0],input_q[4:3]};
    wire [7:0] input_channel=ci==0 ? {1'b0,red_q7} : ci==1 ? {1'b0,green_q7} : {1'b0,blue_q7};
    wire [7:0] convolution_byte=sample_zero ? 8'd0 : layer ? feature_q[ci*8+:8] : input_channel;
    wire [7:0] multiply_input=state==F_MUL ? pooled_q : convolution_byte;
    wire [63:0] multiply_weights=state==F_MUL ? {32'd0,fc_q} : conv_q;
    wire multiply_enable=(state==C_MUL)||(state==F_MUL);
    wire [4:0] conv_shift=layer ? shift_rom[1][4:0] : shift_rom[0][4:0];
    wire [63:0] conv_word;
    wire [63:0] averaged_word;
    genvar g;
    generate for(g=0;g<8;g=g+1) begin: QUANTIZE
        wire signed [31:0] shifted=accumulator[g]>>>conv_shift;
        assign conv_word[g*8+:8]=shifted<0 ? 8'd0 : shifted>127 ? 8'd127 : shifted[7:0];
        wire [11:0] final_sum={1'b0,pool_sum[g]}+{4'b0,pool_q[g*8+:8]};
        assign averaged_word[g*8+:8]=final_sum[11:4];
    end endgenerate

    function [31:0] crc_byte;
        input [31:0] c;input [7:0] b;
        reg [31:0] v;integer k;
        begin
            v=c^{24'd0,b};
            for(k=0;k<8;k=k+1) v=v[0] ? (v>>1)^32'hedb88320 : (v>>1);
            crc_byte=v;
        end
    endfunction
    function signed [7:0] signed_clip;
        input signed [31:0] value;input [4:0] amount;
        reg signed [31:0] shifted;
        begin
            shifted=value>>>amount;
            signed_clip=shifted < -128 ? -8'sd128 : shifted > 127 ? 8'sd127 : shifted[7:0];
        end
    endfunction

    // No reset is applied to memories: every valid job requires a complete load.
    always @(posedge clk) begin
        if(input_we && !busy && !start) input_ram[input_address]<=input_rgb565;
        if(state==IC_REQ) input_q<=input_ram[crc_pixel];
        else if(state==C_REQ && !layer) input_q<=input_ram[conv_address];
        if(state==C_REQ && layer) feature_q<=layer0_ram[conv_address];
        if(state==C_REQ) conv_q<=conv_rom[weight_address];
        if(state==C_STORE) begin
            if(layer) layer1_ram[pixel]<=conv_word;
            else layer0_ram[pixel]<=conv_word;
        end
        if(state==P_REQ) pool_q<=layer1_ram[pool_address];
        if(state==P_WRITE) pooled_ram[{pool_tile,pool_lane}]<=pool_word[pool_lane*8+:8];
        if(state==F_REQ) begin
            pooled_q<=pooled_ram[fc_index];
            fc_q<=fc_rom[fc_index];
        end
    end

    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;busy<=0;done<=0;error<=0;loaded<=0;load_fault<=0;
            open_logit<=0;fist_logit<=0;reject_logit<=0;accept_logit<=0;
            cycles<=0;input_crc<=0;feature_crc<=0;head_crc<=0;
            running_cycles<=0;crc_in_work<=32'hffffffff;crc_feature_work<=32'hffffffff;crc_head_work<=32'hffffffff;
            crc_pixel<=0;pixel<=0;layer<=0;tap<=0;ci<=0;kx<=0;ky<=0;sample_zero<=0;
            pool_tile<=0;pool_offset<=0;pool_lane<=0;fc_index<=0;head_index<=0;
            for(i=0;i<8;i=i+1) begin accumulator[i]<=0;product[i]<=0;pool_sum[i]<=0;end
            for(i=0;i<4;i=i+1) result_work[i]<=0;
        end else begin
            done<=0;
            if(busy) running_cycles<=running_cycles+1'b1;
            if(multiply_enable) begin
                for(i=0;i<8;i=i+1)
                    product[i]<=$signed({1'b0,operand})*$signed(weight_operand[i*8+:8]);
            end
            case(state)
                IDLE: begin
                    if(input_we && !start) begin
                        if(input_address==0) begin loaded<=1;load_fault<=0;end
                        else if(loaded=={1'b0,input_address} && !load_fault) loaded<=loaded+1'b1;
                        else begin loaded<=0;load_fault<=1;end
                    end
                    if(start) begin
                        loaded<=0;
                        if(loaded==1024 && !load_fault) begin
                            busy<=1;running_cycles<=0;crc_pixel<=0;crc_in_work<=32'hffffffff;
                            crc_feature_work<=32'hffffffff;crc_head_work<=32'hffffffff;
                            state<=IC_REQ;
                        end else begin error<=1;done<=1;end
                    end
                end
                IC_REQ: state<=IC_R;
                IC_R: begin crc_in_work<=crc_byte(crc_in_work,{1'b0,red_q7});state<=IC_G;end
                IC_G: begin crc_in_work<=crc_byte(crc_in_work,{1'b0,green_q7});state<=IC_B;end
                IC_B: begin
                    crc_in_work<=crc_byte(crc_in_work,{1'b0,blue_q7});
                    if(crc_pixel==1023) begin layer<=0;pixel<=0;state<=C_INIT;end
                    else begin crc_pixel<=crc_pixel+1'b1;state<=IC_REQ;end
                end
                C_INIT: begin
                    for(i=0;i<8;i=i+1) accumulator[i]<=layer ? p20_bias(i+8) : p20_bias(i);
                    tap<=0;ci<=0;ky<=0;kx<=0;state<=C_REQ;
                end
                C_REQ: begin sample_zero<=outside;state<=C_PRE;end
                C_PRE:begin operand<=convolution_byte;weight_operand<=conv_q;state<=C_MUL;end
                C_MUL: state<=C_ACC;
                C_ACC: begin
                    for(i=0;i<8;i=i+1) accumulator[i]<=accumulator[i]+{{15{product[i][16]}},product[i]};
                    if(tap==(layer ? 71 : 26)) state<=C_STORE;
                    else begin
                        tap<=tap+1'b1;
                        if(kx==2) begin kx<=0;if(ky==2) begin ky<=0;ci<=ci+1'b1;end else ky<=ky+1'b1;end
                        else kx<=kx+1'b1;
                        state<=C_REQ;
                    end
                end
                C_STORE: begin
                    if(pixel==1023) begin
                        pixel<=0;
                        if(layer) begin pool_tile<=0;state<=P_INIT;end
                        else begin layer<=1;state<=C_INIT;end
                    end else begin pixel<=pixel+1'b1;state<=C_INIT;end
                end
                P_INIT: begin
                    for(i=0;i<8;i=i+1) pool_sum[i]<=0;
                    pool_offset<=0;state<=P_REQ;
                end
                P_REQ: state<=P_ACC;
                P_ACC: begin
                    if(pool_offset==15) begin pool_word<=averaged_word;pool_lane<=0;state<=P_WRITE;end
                    else begin
                        for(i=0;i<8;i=i+1) pool_sum[i]<=pool_sum[i]+{3'd0,pool_q[i*8+:8]};
                        pool_offset<=pool_offset+1'b1;state<=P_REQ;
                    end
                end
                P_WRITE: begin
                    crc_feature_work<=crc_byte(crc_feature_work,pool_word[pool_lane*8+:8]);
                    if(pool_lane==7) begin
                        if(pool_tile==63) state<=F_INIT;
                        else begin pool_tile<=pool_tile+1'b1;state<=P_INIT;end
                    end else pool_lane<=pool_lane+1'b1;
                end
                F_INIT: begin
                    for(i=0;i<4;i=i+1) accumulator[i]<=p20_bias(i+16);
                    fc_index<=0;state<=F_REQ;
                end
                F_REQ: state<=F_PRE;
                F_PRE:begin operand<=pooled_q;weight_operand<={32'd0,fc_q};state<=F_MUL;end
                F_MUL: state<=F_ACC;
                F_ACC: begin
                    for(i=0;i<4;i=i+1) accumulator[i]<=accumulator[i]+{{15{product[i][16]}},product[i]};
                    if(fc_index==511) state<=F_END;
                    else begin fc_index<=fc_index+1'b1;state<=F_REQ;end
                end
                F_END: begin
                    for(i=0;i<4;i=i+1) result_work[i]<=signed_clip(accumulator[i],shift_rom[i+2][4:0]);
                    head_index<=0;state<=H_CRC;
                end
                H_CRC: begin
                    crc_head_work<=crc_byte(crc_head_work,result_work[head_index]);
                    if(head_index==3) state<=FINISH;else head_index<=head_index+1'b1;
                end
                FINISH: begin
                    open_logit<=result_work[0];fist_logit<=result_work[1];reject_logit<=result_work[2];accept_logit<=result_work[3];
                    input_crc<=~crc_in_work;feature_crc<=~crc_feature_work;head_crc<=~crc_head_work;
                    cycles<=running_cycles+1'b1;busy<=0;done<=1;error<=0;state<=IDLE;
                end
                default: begin state<=IDLE;busy<=0;done<=1;error<=1;loaded<=0;end
            endcase
        end
    end
endmodule
