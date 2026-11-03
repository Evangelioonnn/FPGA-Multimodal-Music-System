// Text and synth curves share ONE publication/ack toggle and bank index.
// Neither buffer can be reused until the pixel consumer commits both at VBlank.
module synth_frame_ram #(parameter WITH_IDENTITY=0,WITH_CURVE=1)(input wire src_clk,src_rst,dst_clk,dst_rst,
 input wire text_we,input wire [10:0] text_wa,input wire [31:0] text_wd,
 input wire curve_we,input wire [7:0] curve_wa,input wire [23:0] curve_wd,
 input wire publish,output wire ready,input wire frame_start,
 input wire [10:0] text_ra,output reg [31:0] text_rd,
 input wire [7:0] curve_ra,output wire [23:0] curve_rd,
 output reg have_frame,frame_changed,
 input wire[63:0]source_identity,output wire[63:0]visible_identity);
 // Mode is uniform for the whole frame: keep it beside the bank ownership,
 // rather than widening all4096 text words from16 to18bits (five physical RAMs).
 (* syn_ramstyle="block_ram" *) reg [15:0] text_mem[0:4095];
 generate if(WITH_CURVE)begin: curves
  (* syn_ramstyle="block_ram" *) reg [23:0] curve_mem[0:511];reg[23:0]curve_payload;
  always @(posedge src_clk)if(curve_we&&ready)curve_mem[{!request,curve_wa}]<=curve_wd;
  always @(posedge dst_clk)curve_payload<=curve_mem[{ack,curve_ra}];
  assign curve_rd=curve_payload;
 end else begin: no_curves
  assign curve_rd=24'd0;
 end endgenerate
 reg [15:0] write_mode,mode0,mode1;
 reg request=0,ack=0;
 (* async_reg="true" *) reg ack_meta=0,ack_sync=0,request_meta=0,request_sync=0;
 assign ready=!src_rst && request==ack_sync;
 // Bundled data shares the existing publication/ACK. The producer cannot
 // change this register until the consumer has captured it at VBlank.
 generate if(WITH_IDENTITY)begin: identity
  reg[63:0]held,visible;
  always @(posedge src_clk)if(src_rst)held<=0;else if(publish&&ready)held<=source_identity;
  always @(posedge dst_clk)if(dst_rst)visible<=0;else if(frame_start&&request_sync!=ack)visible<=held;
  assign visible_identity=visible;
 end else begin:no_identity
  assign visible_identity=0;
 end endgenerate
 always @(posedge src_clk) begin
  if(text_we&&ready) begin text_mem[{!request,text_wa}]<=text_wd[15:0];write_mode<=text_wd[31:16];end
  if(src_rst) begin request<=0;ack_meta<=0;ack_sync<=0;end
  else begin ack_meta<=ack;ack_sync<=ack_meta;if(publish&&ready) begin
   if(!request)mode1<=write_mode;else mode0<=write_mode;
   request<=!request;
  end end
 end
 always @(posedge dst_clk) begin
  text_rd<={ack ? mode1 : mode0,text_mem[{ack,text_ra}]};
  if(dst_rst) begin ack<=0;request_meta<=0;request_sync<=0;have_frame<=0;frame_changed<=0;end
  else begin request_meta<=request;request_sync<=request_meta;frame_changed<=0;
   if(frame_start&&request_sync!=ack) begin ack<=request_sync;have_frame<=1;frame_changed<=1;end
  end
 end
endmodule
