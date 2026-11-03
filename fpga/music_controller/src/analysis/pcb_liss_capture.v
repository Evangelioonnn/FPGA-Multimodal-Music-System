// Rasterize the SAME normalized stereo window as the waveform page.
// ready only throttles the display window copier, never the audio producer.
// 64x64 bitmap, Bresenham connected segments, one 256x16 scratch RAM.
module pcb_liss_capture(input wire clk,rst,bank_ready,sample_valid,
 input wire [8:0] sample_index,input wire [39:0] sample_data,
 output wire ready,output wire wr,output wire [7:0] address,
 output wire [15:0] data,output wire publish);
 localparam CLEAR=0,WAIT=1,READ=2,LATCH=3,MARK=4,STEP=5,PRIME=6,COPY=7;
 reg [2:0] state=CLEAR;
 (* syn_ramstyle="block_ram" *) reg [15:0] bitmap[0:255];
 reg [7:0] index=0,read_address=0;
 reg [15:0] read_data;
 reg [5:0] px=32,py=31,tx=32,ty=31,prev_x=32,prev_y=31,dx=0,dy=0;
 reg sx=0,sy=0,last=0;
 reg signed [8:0] error=0;
 wire [5:0] incoming_x={~sample_data[15],sample_data[14:10]};
 wire [5:0] incoming_y=6'd63-{~sample_data[31],sample_data[30:26]};
 wire [5:0] start_x=sample_index==0 ? incoming_x : prev_x;
 wire [5:0] start_y=sample_index==0 ? incoming_y : prev_y;
 wire [5:0] delta_x=incoming_x>=start_x ? incoming_x-start_x : start_x-incoming_x;
 wire [5:0] delta_y=incoming_y>=start_y ? incoming_y-start_y : start_y-incoming_y;
 wire signed [9:0] twice_error=$signed({error[8],error})<<<1;
 wire step_x=twice_error > -$signed({4'b0,dy});
 wire step_y=twice_error < $signed({4'b0,dx});
 wire [5:0] next_px=step_x ? (sx ? px+6'd1 : px-6'd1) : px;
 wire [5:0] next_py=step_y ? (sy ? py+6'd1 : py-6'd1) : py;
 wire signed [9:0] next_error=$signed({error[8],error})-
    (step_x ? $signed({4'b0,dy}) : 10'sd0)+
    (step_y ? $signed({4'b0,dx}) : 10'sd0);
 assign ready=!rst && state==WAIT && bank_ready;
 assign wr=!rst && state==COPY && bank_ready;
 assign address=index;assign data=read_data;assign publish=wr && index==255;
 always @(posedge clk)begin
  // In COPY read the following word on the edge that consumes this word.
  if(state==READ || state==PRIME || (state==COPY && bank_ready))read_data<=bitmap[read_address];
  if(rst)begin state<=CLEAR;index<=0;read_address<=0;prev_x<=32;prev_y<=31;end
  else case(state)
   CLEAR:begin bitmap[index]<=0;if(index==255)begin index<=0;state<=WAIT;end else index<=index+1'b1;end
   WAIT:if(sample_valid && ready)begin
    px<=start_x;py<=start_y;tx<=incoming_x;ty<=incoming_y;
    prev_x<=incoming_x;prev_y<=incoming_y;dx<=delta_x;dy<=delta_y;
    sx<=incoming_x>=start_x;sy<=incoming_y>=start_y;
    error<=$signed({3'b0,delta_x})-$signed({3'b0,delta_y});
    last<=sample_index==511;read_address<={start_y,start_x[5:4]};state<=READ;
   end
   READ:state<=LATCH;
   LATCH:state<=MARK;
   MARK:begin
    bitmap[{py,px[5:4]}]<=read_data | (16'd1<<px[3:0]);
    if(px==tx && py==ty)begin
     if(last)begin index<=0;read_address<=0;state<=PRIME;end
     else state<=WAIT;
    end else state<=STEP;
   end
   STEP:begin
    if(step_x)px<=sx ? px+1'b1 : px-1'b1;
    if(step_y)py<=sy ? py+1'b1 : py-1'b1;
    error<=next_error[8:0];
    read_address<={next_py,next_px[5:4]};
    state<=READ;
   end
   PRIME:begin read_address<=1;state<=COPY;end
   COPY:if(bank_ready)begin
    index<=index+1'b1;read_address<=read_address+1'b1;
    if(index==255)begin index<=0;state<=CLEAR;end
   end
   default:begin state<=CLEAR;index<=0;end
  endcase
 end
endmodule
