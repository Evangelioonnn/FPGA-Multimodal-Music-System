// Bank and all UI fields travel in one frame-boundary bundled handshake.
module dual_exchange(input wire clk,rst,input wire valid,output wire ready,
 input wire [415:0] packet,output reg published_bank,
 input wire pixel_clk,pixel_rst,frame_start,output reg [415:0] visible);
 reg [415:0] payload;reg request,ack,capture;
 (* async_reg="true" *) reg ack_meta,ack_sync,request_meta,request_sync;
 assign ready=ack_sync==request && !rst;
 always @(posedge clk)begin
  if(rst)begin payload<=0;request<=0;published_bank<=0;ack_meta<=0;ack_sync<=0;end
  else begin
   ack_meta<=ack;ack_sync<=ack_meta;
   if(valid && ready)begin payload<=packet;request<=!request;published_bank<=packet[400];end
  end
 end
 always @(posedge pixel_clk)begin
  if(pixel_rst)begin request_meta<=0;request_sync<=0;ack<=0;visible<=0;capture<=0;end
  else begin
   request_meta<=request;request_sync<=request_meta;
   // Register the frame decision before its 416-bit fanout. ACK is delayed
   // with the actual capture, so the producer still holds the whole payload.
   capture<=frame_start && request_sync!=ack;
   if(capture)begin visible<=payload;ack<=request_sync;end
  end
 end
endmodule
