// Atomic frame type and payload cross together; only two scalar toggles synchronize.
// Producer owns the unpublished bank. Navigation never acknowledges a partial frame.
module pcb_analysis_bank(input wire src_clk,src_rst,dst_clk,dst_rst,
 input wire wr,input wire [8:0] address,input wire [17:0] data,input wire [1:0] mode,
 input wire publish,output wire ready,input wire frame_start,input wire [8:0] rd_address,
 output reg [17:0] rd_data,output reg [1:0] rd_mode,
 output reg have_frame,frame_changed);
 (* syn_ramstyle="block_ram" *) reg [17:0] memory[0:1023];
 reg [1:0] mode0,mode1;
 reg request=0,ack=0;
 (* async_reg="true" *) reg ack_meta=0,ack_sync=0,request_meta=0,request_sync=0;
 assign ready=!src_rst && request==ack_sync;
 always @(posedge src_clk)begin
  if(wr&&ready)memory[{!request,address}]<=data;
  if(src_rst)begin request<=0;ack_meta<=0;ack_sync<=0;end
  else begin
   ack_meta<=ack;ack_sync<=ack_meta;
   if(publish&&ready)begin
    if(!request)mode1<=mode;else mode0<=mode;
    request<=!request;
   end
  end
 end
 always @(posedge dst_clk)begin
  rd_data<=memory[{ack,rd_address}];
  if(dst_rst)begin ack<=0;request_meta<=0;request_sync<=0;have_frame<=0;frame_changed<=0;rd_mode<=0;end
  else begin
   request_meta<=request;request_sync<=request_meta;frame_changed<=0;
   if(frame_start&&request_sync!=ack)begin
    ack<=request_sync;rd_mode<=request_sync ? mode1 : mode0;
    have_frame<=1;frame_changed<=1;
   end
  end
 end
endmodule
