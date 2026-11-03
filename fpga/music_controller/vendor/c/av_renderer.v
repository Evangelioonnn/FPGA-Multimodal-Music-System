// Eleven pixel clocks: geometry3,address,RAM,state,request,font2,glyph,RGB.
module av_renderer(input wire clk,rst,input wire [10:0] x,y,
 input wire de,hs,vs,text_valid,scope_valid,text_changed,frame_start,
 output reg [10:0] text_address,input wire [12:0] text_data,
 input wire [15:0] scene,output wire [8:0] scope_address,input wire [17:0] scope_data,
 output reg [23:0] rgb,output reg out_de,out_hs,out_vs);
 wire [10:0] ga;wire [3:0] gr,gc,gb;wire [2:0] gl;wire [4:0] gk;wire ge,gd;
 workbench_geometry geometry(clk,x,y,scene,ga,gr,gc,gl,gk,gb,ge,gd);
 wire [21:0] gm={gr,gc,gl,gk,gb,ge,gd};
 reg [21:0] m4,m5,m6;reg [12:0] word6;
 wire [3:0] row6=m6[21:18],col6=m6[17:14],base6=m6[5:2];
 wire [2:0] kind6=m6[13:11];wire [4:0] key6=m6[10:6];
 wire edge6=m6[1],bold6=m6[0];
 function [23:0] material;
 input [3:0] code;begin case(code)
  0:material=24'h141c26;1:material=24'h10171f;2:material=24'h1b2734;3:material=24'h28384d;
  4:material=24'he7e4d8;5:material=24'h18212c;6:material=24'h3b3530;7:material=24'hbcb8a9;
  8:material=24'h627783;9:material=24'hb59e66;10:material=24'he1d4a3;11:material=24'hccba82;
  12:material=24'h8d7a4c;13:material=24'hdddcca;14:material=24'hbcc8cb;15:material=24'hc4c8ba;default:material=24'h16212b;
 endcase end endfunction
 function [23:0] foreground;
 input [3:0] color;begin case(color)
  2:foreground=24'he8cc92;3:foreground=24'hd5c4f4;4:foreground=24'h9ed5bf;
  5:foreground=24'hf2a0a6;6:foreground=24'h8c9aab;7:foreground=24'hd4efe2;default:foreground=24'he2e7ee;
 endcase end endfunction
 function [7:0] note_letter;input [4:0] key;begin case(key)
  0,1,12,13,24:note_letter="C";2,3,14,15:note_letter="D";4,16:note_letter="E";
  5,6,17,18:note_letter="F";7,8,19,20:note_letter="G";9,10,21,22:note_letter="A";default:note_letter="B";
 endcase end endfunction
 reg [8:0] char_next,char7;reg [23:0] bg_next,fg_next;
 reg [23:0] bg7,bg8,bg9,bg10,fg7,fg8,fg9,fg10;
 reg [3:0] row7,col7,col8,col9;reg label_next,label7,label8,label9,bold7,bold8,bold9,glyph10;
 wire [15:0] font_bits;av_font font(clk,{char7,row7},font_bits);
 reg [10:0] de_pipe=0,hs_pipe=0,vs_pipe=0,valid_pipe=0;
 assign scope_address=0;
 always @* begin
  char_next=word6[8:0];bg_next=material(base6);fg_next=foreground(word6[12:9]);label_next=kind6==0||kind6==2||kind6==3||kind6==6;
  if(kind6==0)begin
   if(word6[12:9]==3)bg_next=24'h30394b;
   if(word6[12:9]==7)bg_next=24'h244b40;
  end
  if(kind6>=1&&kind6<=3)begin
   if(word6[7])bg_next=base6==5 ? 24'h7962a1 : 24'hc0a9e9;
   if(edge6)bg_next=24'h10171f;
   fg_next=base6==5 ? 24'he6e4e8 : 24'h424953;
   if(kind6==2)char_next=note_letter(key6);
   if(kind6==3)char_next=word6[6:0]<36 ? "1" : word6[6:0]<48 ? "2" : word6[6:0]<60 ? "3" : word6[6:0]<72 ? "4" : word6[6:0]<84 ? "5" : "6";
  end
  if(kind6==4&&word6[7]&&edge6)bg_next=24'hb7a1de;
  if(kind6==5)begin
   if(word6[7])bg_next=24'hb791d5;
   else if(word6[8]&&(base6==8||base6==14||base6==10))bg_next=24'hc1a9dd;
  end
  if(kind6==6)fg_next=base6==6 ? 24'he2e7ee : 24'h38444c;
 end
 always @(posedge clk)begin
  text_address<=ga;m4<=gm;m5<=m4;m6<=m5;word6<=text_data;
  char7<=char_next;row7<=row6;col7<=col6;label7<=label_next;bold7<=bold6;
  bg7<=bg_next;fg7<=fg_next;
  col8<=col7;label8<=label7;bold8<=bold7;bg8<=bg7;fg8<=fg7;
  col9<=col8;label9<=label8;bold9<=bold8;bg9<=bg8;fg9<=fg8;
  glyph10<=label9&&(font_bits[15-col9]||(bold9&&col9!=0&&font_bits[16-col9]));
  bg10<=bg9;fg10<=fg9;
  if(rst)begin de_pipe<=0;hs_pipe<=0;vs_pipe<=0;valid_pipe<=0;out_de<=0;out_hs<=0;out_vs<=0;rgb<=0;end
  else begin
   de_pipe<={de_pipe[9:0],de};hs_pipe<={hs_pipe[9:0],hs};vs_pipe<={vs_pipe[9:0],vs};valid_pipe<={valid_pipe[9:0],text_valid};
   out_de<=de_pipe[9];out_hs<=hs_pipe[9];out_vs<=vs_pipe[9];
   rgb<=!de_pipe[9] ? 24'd0 : glyph10&&valid_pipe[9] ? fg10 : bg10;
  end
 end
endmodule
