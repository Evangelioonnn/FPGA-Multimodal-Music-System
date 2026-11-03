// GS2 v2/kind2: a streaming status receiver, not a model-frame filter.
module gs2_receiver #(parameter CLK_HZ=50000000,CLKS_PER_BIT=434,
 parameter LINK_CYCLES=CLK_HZ/10,BYTE_CYCLES=CLK_HZ*3/1000)(
 input wire clk,rst,sample_ce,rx,
 output reg control_valid,sustain_request,output wire linked,
 output reg unstable,camera_fault,output reg[1:0]diagnostic_pose,
 output reg packet_valid,output wire packet_control_valid,packet_request,
 output reg[7:0]errors,output reg[15:0]packets,
 output wire expression_link,expression_packet_valid,
 output wire position_owned,returning,output wire[1:0]expression_axis,
 output wire[7:0]expression_gain,output wire signed[7:0]expression_bend);
 // Current build deliberately retains ordinary GS2 sustain only.
 assign expression_link=0;assign expression_packet_valid=0;
 assign position_owned=0;assign returning=0;assign expression_axis=0;
 assign expression_gain=8'd255;assign expression_bend=0;
 wire[7:0]data;wire byte_valid,byte_error;
 bt_uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart(clk,rst,rx,data,byte_valid,byte_error);
 localparam LW=LINK_CYCLES>1 ? $clog2(LINK_CYCLES+1):1;
 localparam BW=BYTE_CYCLES>1 ? $clog2(BYTE_CYCLES+1):1;
 reg[LW-1:0]age;reg[BW-1:0]byte_age;
 reg alive,seen_sequence;reg[7:0]last_sequence,sequence_byte,flags_byte,pose_byte,crc;
 reg[3:0]pending_flags;reg[1:0]pending_pose;reg[2:0]index;
 wire[7:0]delta=sequence_byte-last_sequence;
 wire fields_ok=flags_byte[7:4]==0&&pose_byte<=2&&
  (flags_byte[1]||!flags_byte[0])&&(!flags_byte[3]||flags_byte[1:0]==0);
 wire new_sequence=!seen_sequence||!alive||(delta!=0&&!delta[7]);
 wire accepted=byte_valid&&index==7&&data==crc&&fields_ok&&new_sequence;
 wire expires=alive&&age>=LINK_CYCLES-1;
 assign linked=alive;
 assign packet_control_valid=pending_flags[1];assign packet_request=pending_flags[0];
 function[7:0]crc8;input[7:0]old,b;reg[7:0]v;integer k;begin
  v=old^b;for(k=0;k<8;k=k+1)v=v[7] ? (v<<1)^8'h07:v<<1;crc8=v;
 end endfunction
 task restart;input[7:0]b;begin
  if(b==8'ha5)begin index<=1;crc<=crc8(0,b);end else begin index<=0;crc<=0;end
 end endtask
 always @(posedge clk)begin
  if(rst)begin
   index<=0;crc<=0;byte_age<=0;age<=LINK_CYCLES;alive<=0;seen_sequence<=0;
   last_sequence<=0;sequence_byte<=0;flags_byte<=0;pose_byte<=0;pending_flags<=0;pending_pose<=0;
   packet_valid<=0;control_valid<=0;sustain_request<=0;unstable<=0;camera_fault<=0;diagnostic_pose<=0;errors<=0;packets<=0;
  end else begin
   packet_valid<=0;
   if(alive)begin
    if(expires)begin alive<=0;seen_sequence<=0;pending_flags<=0;end
    else age<=age+1'b1;
   end
   if(index!=0)begin
    if(byte_age>=BYTE_CYCLES-1)begin index<=0;byte_age<=0;if(errors!=255)errors<=errors+1'b1;end
    else byte_age<=byte_age+1'b1;
   end
   if(byte_error)begin index<=0;byte_age<=0;if(errors!=255)errors<=errors+1'b1;end
   else if(byte_valid)begin
    byte_age<=0;
    case(index)
     0:restart(data);
     1:if(data==8'h5a)begin crc<=crc8(crc,data);index<=2;end else restart(data);
     2:if(data==2)begin crc<=crc8(crc,data);index<=3;end else restart(data);
     3:begin sequence_byte<=data;crc<=crc8(crc,data);index<=4;end
     4:begin flags_byte<=data;crc<=crc8(crc,data);index<=5;end
     5:if(data==2)begin crc<=crc8(crc,data);index<=6;end else restart(data);
     6:begin pose_byte<=data;crc<=crc8(crc,data);index<=7;end
     7:begin
      if(accepted)begin
       pending_flags<=flags_byte[3:0];pending_pose<=pose_byte[1:0];packet_valid<=1;
       last_sequence<=sequence_byte;seen_sequence<=1;age<=0;alive<=1;packets<=packets+1'b1;
       index<=0;crc<=0;
      end else begin restart(data);if(errors!=255)errors<=errors+1'b1;end
     end
    endcase
   end
   // A new accepted packet wins a coincident lease expiry. No half-updated flags.
   if(sample_ce)begin
    if(accepted)begin
     control_valid<=flags_byte[1];sustain_request<=flags_byte[0];unstable<=flags_byte[2];camera_fault<=flags_byte[3];diagnostic_pose<=pose_byte[1:0];
    end else if(!alive||expires)begin control_valid<=0;sustain_request<=0;unstable<=0;camera_fault<=0;diagnostic_pose<=0;end
    else begin
     control_valid<=pending_flags[1];sustain_request<=pending_flags[0];unstable<=pending_flags[2];camera_fault<=pending_flags[3];diagnostic_pose<=pending_pose;
    end
   end
  end
 end
endmodule
