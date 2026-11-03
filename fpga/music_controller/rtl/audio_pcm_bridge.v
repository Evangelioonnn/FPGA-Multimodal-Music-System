// Gray frame pointers publish only after four narrow RAM writes are complete.
module audio_pcm_bridge #(
    parameter ADDR_W=6
)(
    input wire src_clk,dst_clk,arst,
    input wire src_valid,
    input wire signed [15:0] src_left,src_right,
    input wire [31:0] src_index,
    output reg [31:0] src_drop_count,
    output reg src_overflow,
    output wire dst_valid,
    input wire dst_ready,
    output wire signed [15:0] dst_left,dst_right,
    output wire [31:0] dst_index,
    output wire dst_gap,dst_session_start
);
    localparam PTR_W=ADDR_W+1;
    localparam HALFWORD_DEPTH=1<<(ADDR_W+2);
    wire src_rst,dst_rst;
    audio_transport_reset source_reset(src_clk,arst,src_rst);
    audio_transport_reset destination_reset(dst_clk,arst,dst_rst);
    reg [15:0] frame_ram[0:HALFWORD_DEPTH-1];
    reg [PTR_W-1:0] write_binary,write_gray,read_binary,read_gray;
    (* async_reg = "true" *) reg [PTR_W-1:0] read_gray_sync1,read_gray_sync2;
    (* async_reg = "true" *) reg [PTR_W-1:0] write_gray_sync1,write_gray_sync2;
    wire [PTR_W-1:0] write_next=write_binary+1'b1;
    wire [PTR_W-1:0] write_next_gray=(write_next>>1)^write_next;
    wire [PTR_W-1:0] read_next=read_binary+1'b1;
    wire [PTR_W-1:0] read_next_gray=(read_next>>1)^read_next;
    wire [PTR_W-1:0] full_mask=(1<<ADDR_W)|(1<<(ADDR_W-1));
    wire full=write_gray==(read_gray_sync2^full_mask);
    wire empty=read_gray==write_gray_sync2;
    reg writing;
    reg [1:0] write_phase;
    reg [63:0] staging_frame;
    wire [ADDR_W+1:0] write_address={write_binary[ADDR_W-1:0],write_phase};
    always @(posedge src_clk) begin
        if(writing&&!src_rst) frame_ram[write_address]<=staging_frame[write_phase*16+:16];
    end
    always @(posedge src_clk or posedge src_rst) begin
        if(src_rst) begin
            write_binary<=0;write_gray<=0;read_gray_sync1<=0;read_gray_sync2<=0;
            writing<=0;write_phase<=0;staging_frame<=0;src_drop_count<=0;src_overflow<=0;
        end else begin
            read_gray_sync1<=read_gray;read_gray_sync2<=read_gray_sync1;
            if(src_valid) begin
                if(writing||full) begin src_drop_count<=src_drop_count+1'b1;src_overflow<=1;end
                else begin
                    staging_frame<={src_index,src_right,src_left};writing<=1;write_phase<=0;
                end
            end
            if(writing) begin
                if(write_phase==3) begin
                    writing<=0;write_binary<=write_next;write_gray<=write_next_gray;
                end else write_phase<=write_phase+1'b1;
            end
        end
    end
    reg [2:0] read_phase;
    reg [15:0] read_halfword;
    reg [63:0] assembled_frame;
    reg output_valid,first_session;
    reg [31:0] expected_index;
    reg [15:0] successor_low,successor_high;reg successor_carry,gap_q;
    wire read_enable=!dst_rst&&!empty&&!output_valid&&read_phase<4;
    wire [ADDR_W+1:0] read_address={read_binary[ADDR_W-1:0],2'b00}+read_phase[1:0];
    always @(posedge dst_clk) begin
        if(read_enable) read_halfword<=frame_ram[read_address];
    end
    assign dst_valid=output_valid&&!dst_rst;
    assign dst_left=assembled_frame[15:0];
    assign dst_right=assembled_frame[31:16];
    assign dst_index=assembled_frame[63:32];
    assign dst_session_start=first_session;
    assign dst_gap=gap_q;
    always @(posedge dst_clk or posedge dst_rst) begin
        if(dst_rst) begin
            read_binary<=0;read_gray<=0;write_gray_sync1<=0;write_gray_sync2<=0;
            read_phase<=0;assembled_frame<=0;output_valid<=0;expected_index<=0;successor_low<=0;successor_high<=0;successor_carry<=0;gap_q<=1;first_session<=1;
        end else begin
            write_gray_sync1<=write_gray;write_gray_sync2<=write_gray_sync1;
            if(output_valid) begin
                if(dst_ready) begin
                    output_valid<=0;read_phase<=0;expected_index<={successor_high,successor_low};first_session<=0;
                    read_binary<=read_next;read_gray<=read_next_gray;
                end
            end else if(!empty) begin
                case(read_phase)
                    1:assembled_frame[15:0]<=read_halfword;
                    2:assembled_frame[31:16]<=read_halfword;
                    3:begin assembled_frame[47:32]<=read_halfword;successor_low<=read_halfword+16'd1;successor_carry<=&read_halfword;end
                    4:begin assembled_frame[63:48]<=read_halfword;successor_high<=read_halfword+successor_carry;end
                    5:begin gap_q<=first_session || assembled_frame[63:32]!=expected_index;output_valid<=1;end
                    default:begin end
                endcase
                if(read_phase<5) read_phase<=read_phase+1'b1;
            end
        end
    end
endmodule
