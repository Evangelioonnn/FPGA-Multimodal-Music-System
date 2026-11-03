// V1 byte-identical formatter with a registered byte-fetch stage before
// escape/CRC control. The original bt_packet_tx is unchanged for old projects.
module practice_packet_tx #(parameter BYTE_PAYLOAD=0)(
 input wire clk,rst,frame_valid,output wire frame_ready,
 input wire [7:0] command,input wire [31:0] session,input wire [15:0] sequence,
 input wire [6:0] length,input wire [511:0] payload,
 output wire [7:0] byte_data,output wire byte_valid,input wire byte_ready,
 input wire[7:0]payload_byte,output wire[5:0]payload_byte_addr
);
 localparam IDLE=0,OPEN=1,FETCH=2,BODY=3,CLOSE=4,CAPTURE=5,READ=6;
 reg [2:0] state;reg second_escape,crc_byte,last_byte;
 reg [6:0] index,saved_length;reg [7:0] saved_command,raw;
 reg [31:0] saved_session;reg [15:0] saved_sequence,crc;
 // The source keeps valid/payload stable until capture completes (64clocks,
 // 1.28us). A private byte RAM then decouples the full UART transmission.
 // This does not hold local controls for the tens of milliseconds on wire.
 (* syn_ramstyle="block_ram" *)reg[7:0]payload_memory[0:63];
 reg[5:0]capture_index;reg[7:0]payload_q;
 assign payload_byte_addr=capture_index;
 wire[5:0]payload_ra=index-7'd10;
 always @(posedge clk)begin
  payload_q<=payload_memory[payload_ra];
  if(state==CAPTURE)payload_memory[capture_index]<=BYTE_PAYLOAD ? payload_byte : payload[capture_index*8+:8];
 end
 reg [7:0] selected;
 wire escape=raw==8'h7d || raw==8'h7e;
 assign frame_ready=!rst && state==CAPTURE && capture_index==63;
 assign byte_valid=!rst && (state==OPEN || state==BODY || state==CLOSE);
 assign byte_data=state==OPEN || state==CLOSE ? 8'h7e : second_escape ? raw^8'h20 : escape ? 8'h7d : raw;
 function [15:0] crc_next;
  input [15:0] previous;input [7:0] value;integer i;reg [15:0] c;
  begin c=previous^{value,8'd0};for(i=0;i<8;i=i+1)c=c[15] ? (c<<1)^16'h1021 : c<<1;crc_next=c;end
 endfunction
 always @* begin
  case(index)
   0:selected=1;1:selected=saved_command;
   2:selected=saved_session[7:0];3:selected=saved_session[15:8];4:selected=saved_session[23:16];5:selected=saved_session[31:24];
   6:selected=saved_sequence[7:0];7:selected=saved_sequence[15:8];8:selected={1'b0,saved_length};9:selected=0;
   default:if(index<10+saved_length)selected=payload_q;else if(index==10+saved_length)selected=crc[7:0];else selected=crc[15:8];
  endcase
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;second_escape<=0;crc_byte<=0;last_byte<=0;index<=0;saved_length<=0;saved_command<=0;
   raw<=0;saved_session<=0;saved_sequence<=0;crc<=16'hffff;capture_index<=0;
  end else case(state)
   IDLE:if(frame_valid)begin
    saved_command<=command;saved_session<=session;saved_sequence<=sequence;saved_length<=length;capture_index<=0;
    index<=0;crc<=16'hffff;second_escape<=0;state<=CAPTURE;
   end
   CAPTURE:if(capture_index==63)state<=OPEN;else capture_index<=capture_index+1'b1;
   OPEN:if(byte_ready)state<=FETCH;
   FETCH:if(index>=10&&index<10+saved_length)state<=READ;
    else begin raw<=selected;crc_byte<=index<10+saved_length;last_byte<=index==11+saved_length;second_escape<=0;state<=BODY;end
   READ:begin raw<=payload_q;crc_byte<=1;last_byte<=0;second_escape<=0;state<=BODY;end
   BODY:if(byte_ready)begin
    if(escape && !second_escape)second_escape<=1;
    else begin
     second_escape<=0;
     if(crc_byte)crc<=crc_next(crc,raw);
     if(last_byte)state<=CLOSE;else begin index<=index+1'b1;state<=FETCH;end
    end
   end
   CLOSE:if(byte_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
