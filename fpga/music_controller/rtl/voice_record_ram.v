// V15:351-bit state as7x51 bits. Three extra read clocks versus V15 four-beat state.
// Request-edge forwarding preserves read-after-write while physical writes
// drain. The bank never issues overlapping writes (checked by regression).
module voice_record_ram #(parameter N=32,AW=(N>1?$clog2(N):1))(
 input wire clk,rst,read_enable,input wire [AW-1:0] read_index,
 output reg read_valid,output wire [350:0] read_data,
 input wire write_enable,input wire [AW-1:0] write_index,input wire [350:0] write_data);
 (* syn_ramstyle="block_ram" *) reg [16:0] ram0[0:N*8-1];
 (* syn_ramstyle="block_ram" *) reg [16:0] ram1[0:N*8-1];
 (* syn_ramstyle="block_ram" *) reg [16:0] ram2[0:N*8-1];
 reg reading,writing;reg [2:0] phase,write_phase;
 reg [AW-1:0] read_slot,write_slot;
 reg [350:0] read_record,write_record;
 reg [50:0] q;reg forward,forward_new;
 wire[2:0]read_word=read_enable ? 3'd0 : phase+3'd1;
 assign read_data=read_record;
 always @(posedge clk) begin
  q<={ram2[{read_enable ? read_index : read_slot,read_word}],ram1[{read_enable ? read_index : read_slot,read_word}],ram0[{read_enable ? read_index : read_slot,read_word}]};
  if(!rst&&writing)case(write_phase)
   0:begin
    ram0[{write_slot,3'd0}]<=write_record[16:0];
    ram1[{write_slot,3'd0}]<=write_record[33:17];
    ram2[{write_slot,3'd0}]<=write_record[50:34];
   end
   1:begin
    ram0[{write_slot,3'd1}]<=write_record[67:51];
    ram1[{write_slot,3'd1}]<=write_record[84:68];
    ram2[{write_slot,3'd1}]<=write_record[101:85];
   end
   2:begin
    ram0[{write_slot,3'd2}]<=write_record[118:102];
    ram1[{write_slot,3'd2}]<=write_record[135:119];
    ram2[{write_slot,3'd2}]<=write_record[152:136];
   end
   3:begin
    ram0[{write_slot,3'd3}]<=write_record[169:153];
    ram1[{write_slot,3'd3}]<=write_record[186:170];
    ram2[{write_slot,3'd3}]<=write_record[203:187];
   end
   4:begin
    ram0[{write_slot,3'd4}]<=write_record[220:204];
    ram1[{write_slot,3'd4}]<=write_record[237:221];
    ram2[{write_slot,3'd4}]<=write_record[254:238];
   end
   5:begin
    ram0[{write_slot,3'd5}]<=write_record[271:255];
    ram1[{write_slot,3'd5}]<=write_record[288:272];
    ram2[{write_slot,3'd5}]<=write_record[305:289];
   end
   6:begin
    ram0[{write_slot,3'd6}]<=write_record[322:306];
    ram1[{write_slot,3'd6}]<=write_record[339:323];
    ram2[{write_slot,3'd6}]<={6'd0,write_record[350:340]};
   end
  endcase
 end
 always @(posedge clk) begin
  if(rst) begin reading<=0;writing<=0;phase<=0;write_phase<=0;read_slot<=0;write_slot<=0;
   read_valid<=0;forward<=0;forward_new<=0;end
  else begin
   read_valid<=0;
   if(writing)begin write_phase<=write_phase+1'b1;if(write_phase==6)writing<=0;end
   if(write_enable)begin write_record<=write_data;write_slot<=write_index;write_phase<=0;writing<=1;end
   if(read_enable) begin
    read_slot<=read_index;phase<=0;reading<=1;
    forward<=(write_enable&&write_index==read_index)||(writing&&write_slot==read_index);
    forward_new<=write_enable&&write_index==read_index;
    read_record<=write_record;
   end else if(reading) begin
    phase<=phase+1'b1;
    if(phase==0&&forward_new)read_record<=write_record;
    else if(forward)begin end
    else case(phase)
     0:read_record[50:0]<=q;
     1:read_record[101:51]<=q;
     2:read_record[152:102]<=q;
     3:read_record[203:153]<=q;
     4:read_record[254:204]<=q;
     5:read_record[305:255]<=q;
     6:read_record[350:306]<=q[44:0];
    endcase
    if(phase==6)begin reading<=0;read_valid<=1;end
   end
  end
 end
endmodule
