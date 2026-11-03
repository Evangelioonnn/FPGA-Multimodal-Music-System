// Twelve pixel clocks, matching av_display. RAM -> distance -> hit/color.
module synth_overlay(input wire clk,rst,input wire [1:0] mode,input wire valid,
 input wire [10:0] x,y,output reg [7:0] address,input wire [23:0] data,
 input wire [23:0] background,output wire [23:0] rgb);
 reg[10:0]xp,yp;reg[1:0]mp;reg vp;
 always @(posedge clk)begin xp<=x;yp<=y;mp<=mode;vp<=valid;if(rst)vp<=0;end
 wire curve_area=xp>=512&&xp<1536&&yp>=480&&yp<704;
 wire bar_area=mp==1&&((xp>=448&&xp<960)||(xp>=1280&&xp<1792))&&
  ((yp>=224&&yp<240)||(yp>=352&&yp<368));
 wire area=vp&&mp!=0&&(curve_area||bar_area);
 // Bars end at367; the curve starts at448. Read addresses depend only on
 // coordinates, never on the text RAM's late page-mode bits. Outside those
 // disjoint visible areas the read has no side effects and is masked out.
 // Both offsets are modulo256.  Subtract128 flips bit7; subtract224 adds32
 // and can carry through only the top three bits.  Express that small
 // Boolean transform directly instead of routing a selected subtractor
 // into the curve RAM address.  This is exact even outside visible areas.
 wire right_bar=x[10]&&(x[9]||x[8]); // x>=1280, over all 11-bit x values.
 wire [7:0] bar_address={x[8]^(right_bar||(x[7]&&x[6])),
  x[7]^(x[6]&&!right_bar),x[6]^!right_bar,x[5:1]};
 wire [7:0] curve_address={~x[9],x[8:2]};
 reg[7:0]bar_address_q,curve_address_q;reg select_bar_q;
 always @(posedge clk)begin
  bar_address_q<=bar_address;curve_address_q<=curve_address;select_bar_q<=y<384;
  address<=select_bar_q ? bar_address_q : curve_address_q;
 end
 reg signed [11:0] ordinate_q,ordinate_qq;
 reg [1:0] mode_q,mode1,mode2;
 reg signed [11:0] distance_a,distance_b,distance_m;
 reg bar_q,bar_1,bar_2,bar_hit;reg [1:0] bar_index_q,bar_index_qq;
 reg[2:0]border_pipe,grid_pipe;wire border=border_pipe[2],grid=grid_pipe[2];reg curve_area_q,valid_q;reg [9:0] mask_pipe;reg [191:0] colors;integer i;
 wire hit_a=distance_a==0||distance_a==12'sd1||distance_a== -12'sd1;
 wire hit_b=distance_b==0||distance_b==12'sd1||distance_b== -12'sd1;
 wire hit_m=distance_m==0||distance_m==12'sd1||distance_m== -12'sd1;
 reg [23:0] color;
 always @* begin
  color=border ? 24'h59656b : grid ? 24'h344149 : 24'h1b2024;
  if(mode2==2) begin
   if(hit_a) color=24'h7989c6;
   if(hit_b) color=24'hc79169;
  end
  if(hit_m&&!bar_2) color=24'h78bea1;
  if(bar_2)color=bar_hit ? 24'h78bea1 : 24'h344149;
 end
 always @(posedge clk) begin
  // Mask reset flushes the full twelve-clock pipeline before a pixel is visible.
  // Payload is overwritten every clock, so it does not need a reset mux/net.
   bar_q<=bar_area;bar_1<=bar_q;bar_2<=bar_1;
   bar_index_q<={yp>=352,xp>=1280};bar_index_qq<=bar_index_q;bar_hit<=data[bar_index_qq];
   ordinate_q<=$signed({1'b0,yp})-12'sd592;ordinate_qq<=ordinate_q;
   mode_q<=mp;mode1<=mode_q;mode2<=mode1;
   distance_a<=ordinate_qq+$signed({{4{data[7]}},data[7:0]});
   distance_b<=ordinate_qq+$signed({{4{data[15]}},data[15:8]});
   distance_m<=ordinate_qq+$signed({{4{data[23]}},data[23:16]});
   border_pipe<={border_pipe[1:0],yp==480||yp==703||xp==512||xp==1535};
   grid_pipe<={grid_pipe[1:0],yp==592||xp[7:0]==0};
   curve_area_q<=curve_area;
   if(rst)begin mask_pipe<=0;valid_q<=0;end
   else begin valid_q<=vp;mask_pipe<={mask_pipe[8:0],valid_q&&mode_q!=0&&(curve_area_q||bar_q)};end
   colors<={colors[167:0],color};
 end
 assign rgb=mask_pipe[9] ? colors[191:168] : background;
endmodule
