// Nine pixel clocks, matching the untouched V2 Chinese home/wave compositor.
// V5: graph ends at607; frequency ticks608..639; feedback starts672.
// No font ROM: all labels use the existing shared Chinese text layer.
module pcb_analysis_plot(input wire clk,rst,input wire [1:0] page,
 input wire [10:0] x,y,input wire de,valid,
 output reg [8:0] address,input wire [17:0] data,
 output wire [23:0] rgb,output wire mask);
 // Raw pixel state and dual-read cell lookup share the added first clock.
 reg[10:0]xp,yp;reg[1:0]pp;reg dep,vp;
 (* syn_ramstyle="block_ram" *)reg[5:0]cell_xy[0:1023];integer n;
 reg[5:0]xxq,yyq;
 initial for(n=0;n<1024;n=n+1)cell_xy[n]=n>=416&&n<608 ? (n-416)/3 : 0;
 always @(posedge clk)begin
  xp<=x;yp<=y;pp<=page;dep<=de;vp<=valid;
  xxq<=cell_xy[x[10:1]];yyq<=cell_xy[{1'b0,y[9:1]}+10'd304];
  if(rst)begin dep<=0;vp<=0;end
 end
 wire[5:0]xx=xxq,yy=yyq;
 wire fft_box=xp>=512&&xp<1536&&yp>=224&&yp<608;
 wire xy_box=xp>=832&&xp<1216&&yp>=224&&yp<608;
 always @(posedge clk)address<=pp==2 ? {2'b0,(xp[9:3]-7'd64)} : {1'b0,yy,xx[5:4]};
 reg [7:0] masks=0;
 reg [17:0] mag2;
 reg [9:0] height4;
 reg [8:0] ordinate1,ordinate2,ordinate3,ordinate4;
 reg [3:0] bit1,bit2;reg xy2,xy3,xy4,fft1,fft2,fft3,fft4,bar1,bar2,bar3,bar4;
 reg valid1,valid2,valid3,valid4,point3,point4,hit5;reg grid1,axis1;
 reg [23:0] bg2,bg3,bg4,bg5,color6,color7,color8,color9;
 reg[5:0]groups2;
 function[17:1]leading_from_groups;input[17:0]value;input[5:0]groups;
 reg[5:0]allow;integer b;
 begin
  allow[5]=1'b1;allow[4]=!groups[5];allow[3]=!(|groups[5:4]);
  allow[2]=!(|groups[5:3]);allow[1]=!(|groups[5:2]);allow[0]=!(|groups[5:1]);
  leading_from_groups=0;
  for(b=1;b<18;b=b+1)case(b%3)
   0:leading_from_groups[b]=allow[b/3]&&value[b]&&!value[b+1]&&!value[b+2];
   1:leading_from_groups[b]=allow[b/3]&&value[b]&&!value[b+1];
   default:leading_from_groups[b]=allow[b/3]&&value[b];
  endcase
 end endfunction
 function[9:0]logheight;input[17:0]value;input[17:1]leading;begin
  logheight=
   ({10{leading[1]}} & 10'd32) |
   ({10{leading[2]}} & 10'd64) |
   ({10{leading[3]}} & 10'd96) |
   ({10{leading[4]}} & {5'd4,value[3:0],1'b0}) |
   ({10{leading[5]}} & {5'd5,value[4:1],1'b0}) |
   ({10{leading[6]}} & {5'd6,value[5:2],1'b0}) |
   ({10{leading[7]}} & {5'd7,value[6:3],1'b0}) |
   ({10{leading[8]}} & {5'd8,value[7:4],1'b0}) |
   ({10{leading[9]}} & {5'd9,value[8:5],1'b0}) |
   ({10{leading[10]}} & {5'd10,value[9:6],1'b0}) |
   ({10{leading[11]}} & {5'd11,value[10:7],1'b0}) |
   ({10{leading[12]}} & {5'd12,value[11:8],1'b0}) |
   ({10{leading[13]}} & {5'd13,value[12:9],1'b0}) |
   ({10{leading[14]}} & {5'd14,value[13:10],1'b0}) |
   ({10{leading[15]}} & {5'd15,value[14:11],1'b0}) |
   ({10{leading[16]}} & {5'd16,value[15:12],1'b0}) |
   ({10{leading[17]}} & {5'd17,value[16:13],1'b0});
 end endfunction
 // Retime the wide priority reduction behind mag2. Six three-bit flags
 // share the existing capture boundary; total pixel latency is unchanged.
 // Split exponent decoding and scaling across the existing stages3/4.
 // Inside the graph ordinate<=383, so clipping the height to384 is redundant.
 wire [9:0] scaled_height=height4-(height4>>2);
 // Grid/axes use direct pixel ranges; avoid a subtract/multiply/divide chain
 // feeding stage1. These ranges equal the original six-pixel cell tests.
 wire xy_grid_x=(xp>=832&&xp<838)||(xp>=928&&xp<934)||(xp>=1024&&xp<1030)||(xp>=1120&&xp<1126);
 wire xy_grid_y=(yp>=224&&yp<230)||(yp>=320&&yp<326)||(yp>=416&&yp<422)||(yp>=512&&yp<518);
 wire xy_axis_x=xp>=1024&&xp<1030,xy_axis_y=yp>=410&&yp<416;
 always @(posedge clk)begin
  // Stage1 geometry travels with the synchronous external RAM read.
  masks<={masks[6:0],dep&&((pp==2&&fft_box)||(pp==3&&xy_box))};
  ordinate1<=11'd607-yp;bit1<=xx[3:0];
  fft1<=pp==2;fft2<=fft1;fft3<=fft2;fft4<=fft3;
  xy2<=!fft1;xy3<=xy2;xy4<=xy3;
  valid1<=vp;valid2<=valid1;valid3<=valid2;valid4<=valid3;
  bar1<=xp[2:0]!=7;bar2<=bar1;bar3<=bar2;bar4<=bar3;
  grid1<=pp==2 ? (xp[6:0]==0||yp[5:0]==0) : (xy_grid_x||xy_grid_y);
  axis1<=pp==3&&(xy_axis_x||xy_axis_y);
  bg2<=axis1 ? 24'h566369 : grid1 ? 24'h333D42 : 24'h1C2225;
  bg3<=bg2;bg4<=bg3;bg5<=bg4;
  bit2<=bit1;
  mag2<=data;groups2<={|data[17:15],|data[14:12],|data[11:9],|data[8:6],|data[5:3],|data[2:0]};point3<=data[bit2];ordinate2<=ordinate1;ordinate3<=ordinate2;ordinate4<=ordinate3;
  height4<=logheight(mag2,leading_from_groups(mag2,groups2));point4<=point3;
  hit5<=valid4 && ((fft4&&bar4&&{1'b0,ordinate4}<scaled_height)||(xy4&&point4));
  color6<=hit5 ? 24'h78BEA1 : bg5;
  color7<=color6;color8<=color7;color9<=color8;
  if(rst)begin masks<=0;hit5<=0;valid1<=0;valid2<=0;valid3<=0;valid4<=0;end
 end
 assign rgb=color8;assign mask=masks[7];
endmodule
