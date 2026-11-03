// Display-only, two-pass normalization. Audio never consumes ready from here.
// Packet: {4'hA, gain_log2[3:0], scaled_R[7:0], peak[15:8],
//          scaled_L[7:0], peak[7:0]}. Metadata belongs to this exact window.
module av_wave_capture(input wire clk,rst,ready,sample_valid,
    input wire signed [15:0] left,right,
    output wire wr_en,output wire [8:0] wr_addr,
    output wire [39:0] wr_data,output wire publish);
    localparam COLLECT=0,PREP=1,PRIME=2,WRITE=3,WAIT_PEAK=4;
    reg [2:0] state=COLLECT;
    wire raw_we,raw_done;wire [8:0] raw_addr;wire [31:0] raw_data;
    av_pcm_window raw(clk,rst,ready && state==COLLECT,sample_valid,left,right,
        raw_we,raw_addr,raw_data,raw_done);
    // The collection and normalization phases never overlap. Both 16-bit
    // ports share one 1024-word true dual-port block: L at [0..511], R at
    // [512..1023]. Ports write together during COLLECT and read together
    // during PRIME/WRITE; output registers retain the old one-edge latency.
    wire [15:0] sample_left,sample_right;
    wire [31:0] read_data={sample_right,sample_left};
    wire sample_read=(state==PRIME || (state==WRITE && ready));
    wire sample_enable=raw_we || sample_read;
    wire [8:0] sample_index=raw_we ? raw_addr : read_addr;
    DPB #(.READ_MODE0(1'b0),.READ_MODE1(1'b0),
          .WRITE_MODE0(2'b00),.WRITE_MODE1(2'b00),
          .BIT_WIDTH_0(16),.BIT_WIDTH_1(16),.RESET_MODE("SYNC")) samples(
        .DOA(sample_left),.DOB(sample_right),
        .DIA(raw_data[15:0]),.DIB(raw_data[31:16]),
        // DPB x16 uses address bits [1:0] as active-high byte write enables.
        .ADA({1'b0,sample_index,4'b0011}),.ADB({1'b1,sample_index,4'b0011}),
        .WREA(raw_we),.WREB(raw_we),.CLKA(clk),.CLKB(clk),
        .CEA(sample_enable),.CEB(sample_enable),.OCEA(1'b1),.OCEB(1'b1),
        .RESETA(1'b0),.RESETB(1'b0),.BLKSELA(3'b0),.BLKSELB(3'b0));
    reg [8:0] read_addr=0,index=0;
    reg [15:0] peak=0,frame_peak=0;
    reg [3:0] shift=0;
    wire [15:0] abs_l=left[15] ? (~left+16'd1) : left;
    wire [15:0] abs_r=right[15] ? (~right+16'd1) : right;
    reg [15:0] abs_l_q,abs_r_q,pair_peak_q;
    reg [1:0] peak_valid=0,peak_last=0;
    wire [15:0] next_peak=pair_peak_q>peak ? pair_peak_q : peak;
    always @(posedge clk)begin
        abs_l_q<=abs_l;abs_r_q<=abs_r;pair_peak_q<=abs_l_q>abs_r_q ? abs_l_q : abs_r_q;
        if(rst)begin peak_valid<=0;peak_last<=0;end
        else begin peak_valid<={peak_valid[0],raw_we};peak_last<={peak_last[0],raw_done};end
    end
    function [3:0] choose_shift;
        input [15:0] p;
        begin
            if(p==0 || p>=16384)choose_shift=0;
            else if(p>=8192)choose_shift=1;
            else if(p>=4096)choose_shift=2;
            else if(p>=2048)choose_shift=3;
            else if(p>=1024)choose_shift=4;
            else if(p>=512)choose_shift=5;
            else if(p>=256)choose_shift=6;
            else if(p>=128)choose_shift=7;
            else choose_shift=8;
        end
    endfunction
    // The peak-selected gain guarantees signed 16-bit range, including -32768.
    wire [15:0] scaled_l=read_data[15:0]<<shift;
    wire [15:0] scaled_r=read_data[31:16]<<shift;
    assign wr_en=!rst && state==WRITE && ready;
    assign wr_addr=index;
    assign wr_data={4'hA,shift,scaled_r[15:8],frame_peak[15:8],scaled_l[15:8],frame_peak[7:0]};
    assign publish=wr_en && (&index);
    always @(posedge clk)begin
        // Read/write storage is implemented by the two synchronous DPB ports.
        if(rst)begin state<=COLLECT;peak<=0;frame_peak<=0;shift<=0;index<=0;read_addr<=0;end
        else begin
          if(peak_valid[1])peak<=next_peak;
          case(state)
            COLLECT:if(raw_done)state<=WAIT_PEAK;
            WAIT_PEAK:if(peak_last[1])begin frame_peak<=next_peak;state<=PREP;end
            PREP:begin shift<=choose_shift(frame_peak);read_addr<=0;index<=0;state<=PRIME;end
            PRIME:begin read_addr<=1;state<=WRITE;end
            WRITE:if(ready)begin
                read_addr<=read_addr+1'b1;index<=index+1'b1;
                if(&index)begin state<=COLLECT;peak<=0;end
            end
          endcase
        end
    end
endmodule
