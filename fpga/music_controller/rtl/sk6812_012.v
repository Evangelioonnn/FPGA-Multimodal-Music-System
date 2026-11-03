// Production descriptor variant: the producer freezes this81-bit frame until
// ready returns. It is sampled one LED at a time, preserving all serial timing.
// {black,guide,timbre[3:0],next_pitch[24:0],current_pitch[24:0],pressed[24:0]}.
module sk6812_012 #(parameter LEDS=25,BIT_CYCLES=64,ZERO_HIGH=16,ONE_HIGH=45,RESET_CYCLES=15000)(
 input wire clk,rst,frame_valid,input wire [131:0] frame,
 output wire frame_ready,output wire busy,output wire data_out,
 output reg [31:0] frames);
 reg [23:0] word;reg sending;reg [15:0] reset_count;
 reg [6:0] tick;reg [4:0] bit_index;reg [5:0] led;
 function [4:0] identity_index;input [5:0] index;begin
  case(index)
   0:identity_index=24;1:identity_index=18;2:identity_index=12;3:identity_index=6;4:identity_index=0;
   5:identity_index=1;6:identity_index=2;7:identity_index=3;8:identity_index=4;9:identity_index=5;
   10:identity_index=11;11:identity_index=10;12:identity_index=9;13:identity_index=8;14:identity_index=7;
   15:identity_index=17;16:identity_index=16;17:identity_index=15;18:identity_index=14;19:identity_index=13;
   20:identity_index=23;21:identity_index=22;22:identity_index=21;23:identity_index=20;default:identity_index=19;
  endcase
 end endfunction
 function [4:0] pitch_index;input [4:0] identity;begin
  case(identity)
   0:pitch_index=10;1:pitch_index=13;2:pitch_index=15;3:pitch_index=18;4:pitch_index=20;
   5:pitch_index=22;6:pitch_index=8;7:pitch_index=17;8:pitch_index=19;9:pitch_index=21;
   10:pitch_index=23;11:pitch_index=24;12:pitch_index=6;13:pitch_index=9;14:pitch_index=11;
   15:pitch_index=12;16:pitch_index=14;17:pitch_index=16;18:pitch_index=3;19:pitch_index=0;
   20:pitch_index=2;21:pitch_index=4;22:pitch_index=5;23:pitch_index=7;default:pitch_index=1;
  endcase
 end endfunction
 function [23:0] make_word;input [131:0] descriptor;input [5:0] index;
  reg [4:0] identity,pitch;reg [23:0] base,pressed;begin
   identity=identity_index(index);pitch=pitch_index(identity);
   case(descriptor[78:75])
    0:begin base=24'h020004;pressed=24'h001810;end
    3:begin base=24'h030200;pressed=24'h000818;end
    4:begin base=24'h000302;pressed=24'h180008;end
    5:begin base=24'h000203;pressed=24'h180c00;end
    6:begin base=24'h020300;pressed=24'h001018;end
    7:begin base=24'h040000;pressed=24'h001018;end
    8:begin base=24'h000400;pressed=24'h180010;end
    9:begin base=24'h030003;pressed=24'h001800;end
    10:begin base=24'h010304;pressed=24'h180800;end
    default:begin base=24'h010101;pressed=24'h101010;end
   endcase
   if(descriptor[80])make_word=0;
   else if(descriptor[131]&&descriptor[81+pitch])make_word=24'h001000;
   else if(descriptor[131]&&descriptor[106+pitch])make_word=24'h100000;
   else if(descriptor[131]&&descriptor[25+pitch])make_word=24'h0b1600;
   else if(descriptor[79]&&descriptor[identity])make_word=24'h001818;
   else if(descriptor[79]&&descriptor[25+pitch])make_word=24'h180000;
   else if(descriptor[79]&&descriptor[50+pitch])make_word=24'h000008;
   else make_word=descriptor[identity] ? pressed : base;
  end
 endfunction
 wire bit_value=word[bit_index];
 assign frame_ready=!rst&&!sending&&reset_count==RESET_CYCLES;
 assign busy=!frame_ready;
 assign data_out=!rst&&sending&&tick<(bit_value ? ONE_HIGH : ZERO_HIGH);
 always @(posedge clk)begin
  if(rst)begin word<=0;sending<=0;reset_count<=0;tick<=0;bit_index<=23;led<=0;frames<=0;end
  else if(sending)begin
   if(tick==BIT_CYCLES-1)begin
    tick<=0;
    if(bit_index==0)begin
     bit_index<=23;
     if(led==LEDS-1)begin sending<=0;reset_count<=0;frames<=frames+1'b1;end
     else begin led<=led+1'b1;word<=make_word(frame,led+1'b1);end
    end else bit_index<=bit_index-1'b1;
   end else tick<=tick+1'b1;
  end else begin
   if(reset_count<RESET_CYCLES)reset_count<=reset_count+1'b1;
   if(frame_valid&&frame_ready)begin word<=make_word(frame,0);sending<=1;led<=0;bit_index<=23;tick<=0;end
  end
 end
endmodule
