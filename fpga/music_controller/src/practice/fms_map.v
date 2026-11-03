// Fixed25 occupancy/head map. Geometry uses original FMS microseconds directly,
// 8192us per row, with a frozen frame snapshot and two RAM banks.
module fms_map #(parameter READ_TIMEOUT_CLKS=500000)(
 input wire clk,rst,display_reset,input wire [383:0] state_in,input wire [31:0] time_us,
 input wire [15:0] count,input wire score_valid,input wire [31:0] generation,
 input wire time_wait,input wire [2:0] timing_status,input wire active,
 input wire published_bank,packet_ready,output wire packet_valid,output wire [415:0] packet,
 output wire req_valid,input wire req_ready,output wire [10:0] event_index,
 input wire event_valid,output wire event_ready,input wire [79:0] event_data,output reg fault,
 input wire pixel_clk,input wire [8:0] pixel_address,output reg [63:0] pixel_data);
 localparam IDLE=0,CLEAR=1,REQ=2,WAIT_DATA=3,DELTA=4,BOTTOM=5,TOP=6,CLIP=7,DRAW=8,READ_ROW=9,WRITE_ROW=10,NEXT=11,PUBLISH=12;
 reg [3:0] state;wire[53:0]rows_read,pixels_read;reg [63:0] row_data;
 reg [7:0] row,last_row;reg bank,reading_score,abort_frame;reg [10:0] index;reg [15:0] saved_count;
 reg [31:0] saved_generation,saved_time,age;reg [383:0] saved_state;reg saved_wait;reg [2:0] saved_status;
 reg [79:0] note;reg [4:0] lane;reg signed [33:0] start_delta,end_delta,bottom,top,lower,note_bottom;
 wire cancel=display_reset || generation!=saved_generation || (reading_score && (!active || !score_valid));
 wire [8:0] address={bank,row};wire write_enable=(state==CLEAR || state==WRITE_ROW) && !abort_frame && !cancel;
 wire [63:0] mask=(64'd1<<lane) | (note_bottom==$signed({26'd0,row}) ? 64'd1<<(lane+25) : 64'd0);
 wire [63:0] write_data=state==CLEAR ? 64'd0 : row_data|mask;
 genvar mc;
 generate for(mc=0;mc<3;mc=mc+1)begin:map_columns
  (* syn_ramstyle="block_ram" *)reg[17:0]memory[0:511];reg[17:0]rq,pq;
  wire[53:0]padded_write={4'd0,write_data[49:0]};
  always @(posedge clk)if(write_enable)begin memory[address]<=padded_write[mc*18+:18];rq<=padded_write[mc*18+:18];end else rq<=memory[address];
  always @(posedge pixel_clk)pq<=memory[pixel_address];
  assign rows_read[mc*18+:18]=rq;assign pixels_read[mc*18+:18]=pq;
 end endgenerate
 always @*begin row_data={14'd0,rows_read[49:0]};pixel_data={14'd0,pixels_read[49:0]};end
 assign req_valid=state==REQ;assign event_ready=state==WAIT_DATA;assign event_index=index;
 assign packet_valid=state==PUBLISH && !abort_frame && !cancel && state_in[57:50]==saved_state[57:50];
 assign packet={13'd0,fault,1'b1,bank,saved_wait,saved_status,12'd0,saved_state};
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;row<=0;last_row<=0;bank<=1;reading_score<=0;abort_frame<=0;index<=0;saved_count<=0;
   saved_generation<=0;saved_time<=0;age<=0;saved_state<=0;saved_wait<=0;saved_status<=0;note<=0;lane<=0;
   start_delta<=0;end_delta<=0;bottom<=0;top<=0;lower<=0;note_bottom<=0;fault<=0;
  end else begin
   if(cancel)abort_frame<=1;
   if(state==REQ || state==WAIT_DATA)begin if(age<READ_TIMEOUT_CLKS)age<=age+1'b1;else begin fault<=1;abort_frame<=1;end end
   else age<=0;
   // Always drain an accepted note response even if the frame is canceled.
   if((abort_frame || cancel) && state!=REQ && state!=WAIT_DATA && state!=IDLE)state<=IDLE;
   else case(state)
    IDLE:if(!display_reset && packet_ready)begin
     row<=0;bank<=!published_bank;index<=0;abort_frame<=0;saved_count<=count;
     saved_generation<=generation;saved_time<=time_us;saved_state<=state_in;saved_wait<=time_wait;saved_status<=timing_status;
     reading_score<=active && score_valid && !fault;state<=CLEAR;
    end
    CLEAR:if(row==255)begin row<=0;state<=reading_score && saved_count!=0 ? REQ : PUBLISH;end else row<=row+1'b1;
    REQ:if(req_ready)state<=WAIT_DATA;
    WAIT_DATA:if(event_valid)begin if(abort_frame || cancel)state<=IDLE;else begin note<=event_data;state<=DELTA;end end
    DELTA:begin
     start_delta<=$signed({2'd0,note[31:0]})-$signed({2'd0,saved_time});
     end_delta<=$signed({2'd0,note[63:32]})-$signed({2'd0,saved_time});state<=BOTTOM;
    end
    BOTTOM:begin bottom<=34'sd255-(start_delta>>>13);state<=TOP;end
    TOP:begin top<=34'sd255-(end_delta>>>13);state<=CLIP;end
    CLIP:begin lower<=top+1>bottom ? bottom : top+1;state<=DRAW;end
    DRAW:begin
     if(note[63:32]<=note[31:0] || note[70:64]<48 || note[70:64]>72)begin fault<=1;state<=IDLE;end
     else if(bottom<0 || lower>255)state<=NEXT;
     else begin lane<=note[70:64]-7'd48;note_bottom<=bottom;row<=lower<0 ? 0 : lower[7:0];last_row<=bottom>255 ? 255 : bottom[7:0];state<=READ_ROW;end
    end
    READ_ROW:state<=WRITE_ROW;
    WRITE_ROW:if(row==last_row)state<=NEXT;else begin row<=row+1'b1;state<=READ_ROW;end
    NEXT:if({5'd0,index}+16'd1==saved_count)state<=PUBLISH;else begin index<=index+1'b1;state<=REQ;end
    PUBLISH:if(state_in[57:50]!=saved_state[57:50] || packet_ready)state<=IDLE;
   endcase
  end
 end
endmodule
