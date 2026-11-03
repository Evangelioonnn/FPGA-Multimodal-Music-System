// One UART serializes a GS2 sustain snapshot and a separate atomic GE3 snapshot.
// Each 5ms tick: GS2 A5 5A 02 seq flags 02 pose crc, then
// GE3 A5 5A 03 seq flags gain bend crc. Both frames have exactly eight bytes.
module gs2_ge3_sender #(parameter CLK_HZ=74250000,BAUD=115200,SEND_HZ=200)(
 input wire clk,rst,control_valid,sustain_request,unstable,camera_fault,
 input wire [1:0] diagnostic_pose,
 input wire position_owned,returning,input wire [1:0] axis,
 input wire [7:0] expression_gain,input wire signed [7:0] bend_offset,
 output wire tx,output reg [7:0] sequence_id,output wire busy);
 localparam CYCLES=CLK_HZ/SEND_HZ,TW=$clog2(CYCLES);
 localparam WAIT=0,CRC=1,SEND=2,NEXT=3;
 reg [1:0] state;reg [TW-1:0] timer;
 reg [63:0] packet;reg [7:0] crc,saved_seq,saved_flags,saved_gain,saved_bend;
 reg [2:0] index;reg expression_frame;
 wire ready;wire [7:0] current_byte=packet[index*8+:8];
 wire owner=control_valid&&!camera_fault;
 wire [7:0] gs2_flags={4'd0,camera_fault,unstable,owner,sustain_request&&owner};
 wire pos_owner=position_owned&&!camera_fault;
 wire pos_return=returning&&!pos_owner;
 wire effect_active=pos_owner||pos_return;
 wire [1:0] clean_axis=pos_owner&&axis!=3 ? axis : 2'd0;
 wire [7:0] ge3_flags={3'd0,camera_fault,clean_axis,pos_return,pos_owner};
 wire [7:0] clean_gain=expression_gain<128 ? 8'd128 : expression_gain;
 wire signed [7:0] clean_bend=bend_offset>64 ? 8'sd64 : bend_offset< -64 ? -8'sd64 : bend_offset;
 assign busy=state!=WAIT||!ready;
 gs2_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(clk,rst,current_byte,state==SEND,ready,tx);
 function [7:0] crc8;input [7:0] old,b;reg [7:0] c;integer i;begin
  c=old^b;for(i=0;i<8;i=i+1)c=c[7] ? (c<<1)^8'h07 : (c<<1);crc8=c;
 end endfunction
 always @(posedge clk)begin
  if(rst)begin
   state<=WAIT;timer<=0;packet<=0;crc<=0;index<=0;expression_frame<=0;sequence_id<=0;
   saved_seq<=0;saved_flags<=0;saved_gain<=255;saved_bend<=0;
  end else begin
   if(timer==CYCLES-1)timer<=0;else timer<=timer+1'b1;
   case(state)
    WAIT:if(timer==CYCLES-1&&ready)begin
     packet<={8'd0,{6'd0,(diagnostic_pose<=2 ? diagnostic_pose : 2'd0)},8'd2,
       gs2_flags,sequence_id,8'd2,8'h5a,8'ha5};
     saved_seq<=sequence_id;saved_flags<=ge3_flags;saved_gain<=effect_active ? clean_gain : 8'd255;
     saved_bend<=effect_active ? clean_bend : 8'sd0;
     sequence_id<=sequence_id+1'b1;index<=0;crc<=0;expression_frame<=0;state<=CRC;
    end
    CRC:begin
     crc<=crc8(crc,current_byte);
     if(index==6)begin packet[63:56]<=crc8(crc,current_byte);index<=0;state<=SEND;end
     else index<=index+1'b1;
    end
    SEND:if(ready)begin
     if(index==7)begin state<=expression_frame ? WAIT : NEXT;index<=0;end
     else index<=index+1'b1;
    end
    NEXT:begin
     packet<={8'd0,saved_bend,saved_gain,saved_flags,saved_seq,8'd3,8'h5a,8'ha5};
     expression_frame<=1;crc<=0;index<=0;state<=CRC;
    end
    default:state<=WAIT;
   endcase
  end
 end
endmodule
