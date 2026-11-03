// Atomic8-byte GS2 snapshots. UART never stalls camera/model processing.
module gs2_sender #(parameter CLK_HZ=74250000,BAUD=115200,SEND_HZ=200)(
 input wire clk,rst,control_valid,sustain_request,unstable,camera_fault,
 input wire [1:0] diagnostic_pose,output wire tx,
 output reg [7:0] sequence_id,output wire busy);
 localparam SEND_CYCLES=CLK_HZ/SEND_HZ;
 localparam TW=SEND_CYCLES>1 ? $clog2(SEND_CYCLES):1;
 localparam WAIT=0,CRC=1,SEND=2;
 reg [1:0] state;reg [TW-1:0] timer;reg [63:0] packet;
 reg [2:0] index;reg [7:0] crc;
 wire [7:0] current_byte=packet[index*8+:8];wire ready;
 wire owner=control_valid && !camera_fault;
 wire request=sustain_request && owner;
 assign busy=state!=WAIT || !ready;
 gs2_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(clk,rst,current_byte,state==SEND,ready,tx);
 function [7:0] crc8;input [7:0] old,b;reg [7:0] c;integer j;begin
  c=old^b;for(j=0;j<8;j=j+1)c=c[7] ? (c<<1)^8'h07:(c<<1);crc8=c;
 end endfunction
 always @(posedge clk)begin
  if(rst)begin state<=WAIT;timer<=0;packet<=0;index<=0;crc<=0;sequence_id<=0;end
  else begin
   if(timer==SEND_CYCLES-1)timer<=0;else timer<=timer+1'b1;
   case(state)
    WAIT:if(timer==SEND_CYCLES-1 && ready)begin
     packet<={8'd0,{6'd0,(diagnostic_pose<=2 ? diagnostic_pose:2'd0)},8'd2,
              {4'd0,camera_fault,unstable,owner,request},sequence_id,8'd2,8'h5a,8'ha5};
     index<=0;crc<=0;state<=CRC;sequence_id<=sequence_id+1'b1;
    end
    CRC:begin
     crc<=crc8(crc,current_byte);
     if(index==6)begin packet[63:56]<=crc8(crc,current_byte);index<=0;state<=SEND;end
     else index<=index+1'b1;
    end
    SEND:if(ready)begin
     if(index==7)begin state<=WAIT;index<=0;end else index<=index+1'b1;
    end
    default:state<=WAIT;
   endcase
  end
 end
endmodule
