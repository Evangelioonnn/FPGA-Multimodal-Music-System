//128 logical64-bit events in ONE512x16 RAM. Four write beats, cached head,
// explicit head validity. UART clients may wait; audio is never backpressured.
module fms_record_fifo #(parameter DEPTH=128,AW=$clog2(DEPTH))(
 input wire clk,rst,flush,input wire push,input wire[63:0]data,
 output wire ready,input wire pop,output reg[63:0]front,output reg front_valid,
 output reg[AW:0]level,output wire busy);
 (* syn_ramstyle="block_ram" *)reg[15:0]memory[0:DEPTH*4-1];
 reg[AW-1:0]wr,rd;reg writing;reg[1:0]beat;reg[63:0]pending;
 reg[3:0]reader;reg[AW+1:0]ra;reg[15:0]q;reg[47:0]partial;
 wire take=pop&&front_valid&&level!=0;wire commit=writing&&beat==3;
 assign ready=!writing&&(level<DEPTH||take)&&!rst&&!flush;
 assign busy=writing;
 always @(posedge clk)begin
  q<=memory[ra];if(writing)memory[{wr,beat}]<=pending[beat*16+:16];
 end
 // Payload is unobservable while front_valid=0. A new session clears only
 // ownership/control; do not route its long validation cone to176 data FFs.
 // RAM writes already occurred on flush in R27; invalidated slots remain hidden.
 always @(posedge clk)begin
  if(rst)begin pending<=0;partial<=0;front<=0;end
  else begin
   if(push&&ready)pending<=data;
   case(reader)
    2:partial[15:0]<=q;
    4:partial[31:16]<=q;
    6:partial[47:32]<=q;
    8:front<={q,partial};
   endcase
   if(commit&&(level==0||(level==1&&take)))front<=pending;
  end
 end
 always @(posedge clk)begin
  if(rst||flush)begin wr<=0;rd<=0;writing<=0;beat<=0;reader<=0;ra<=0;front_valid<=0;level<=0;end
  else begin
   if(push&&ready)begin writing<=1;beat<=0;end
   if(writing)begin if(beat==3)begin writing<=0;wr<=wr+1'b1;end else beat<=beat+1'b1;end
   case({commit,take})2'b10:level<=level+1'b1;2'b01:level<=level-1'b1;endcase
   case(reader)
    0:if(level!=0&&!front_valid)begin ra<={rd,2'd0};reader<=1;end
    1:reader<=2;
    2:begin ra<={rd,2'd1};reader<=3;end
    3:reader<=4;
    4:begin ra<={rd,2'd2};reader<=5;end
    5:reader<=6;
    6:begin ra<={rd,2'd3};reader<=7;end
    7:reader<=8;
    8:begin front_valid<=1;reader<=0;end
   endcase
   if(take)begin rd<=rd+1'b1;front_valid<=0;reader<=0;end
   if(commit&&(level==0||(level==1&&take)))begin front_valid<=1;reader<=0;end
  end
 end
endmodule
