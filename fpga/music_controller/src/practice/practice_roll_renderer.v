// Twelve pixel clocks, exactly matching the production av_display path.
// Existing C map:256 rows at8192us/row; bank captured with all grading fields.
module practice_roll_renderer(input wire clk,rst,input wire[10:0]x,y,input wire de,enabled,
 input wire[415:0]visible,output wire[8:0]address,input wire[63:0]map_data,
 output wire mask,output wire[23:0]rgb);
 // Keep the six-bit lane/edge lookup separate from the one-hot selection.
 // A wide logic ROM made each one-hot output a deep coordinate mux.  Each
 // lane is instead one constant seven-cell interval of x/8; lane24 is the
 // saturated tail, including the original modulo-256 wrap below x=416.
 (* syn_romstyle="logic" *)reg[5:0]lane_lookup[0:255];integer i,lookup_lane;
 initial for(i=0;i<256;i=i+1)begin
  lookup_lane=((i+256-52)&255)/7;if(lookup_lane>24)lookup_lane=24;
  lane_lookup[i]={(((i+256-52)&255)%7==0),lookup_lane[4:0]};
 end
 wire[24:0]lane_select;genvar li;
 generate for(li=0;li<24;li=li+1)begin:lane_ranges
  localparam[7:0]LEFT=52+7*li,RIGHT=59+7*li;
  assign lane_select[li]=(x[10:3]>=LEFT)&&(x[10:3]<RIGHT);
 end endgenerate
 assign lane_select[24]=(x[10:3]<8'd52)||(x[10:3]>=8'd220);
 wire in_roll=x>=416&&x<1816&&y>=448&&y<960;
 wire in_keys=x>=416&&x<1816&&y>=960&&y<1008;
 wire[8:0]line=(y-11'd448)>>1;
 assign address={visible[400],line[7:0]};
 reg[5:0]lane;reg keys,boundary,line_edge;reg[24:0]targets,wrong,pressed;
 reg[3:0]colors[0:7];reg[23:0]rgb_q;reg[11:0]masks;integer k;
 function dark_key;input[4:0]q;begin case(q)1,3,6,8,10,13,15,18,20,22:dark_key=1;default:dark_key=0;endcase end endfunction
 function[23:0]palette_rgb;input[3:0]index;begin case(index)
  4'd0:palette_rgb=24'h151d28;
  4'd1:palette_rgb=24'h1c2836;
  4'd2:palette_rgb=24'h27303d;
  4'd3:palette_rgb=24'hd5d8d6;
  4'd4:palette_rgb=24'hb9a1e8;
  4'd5:palette_rgb=24'he0c17f;
  4'd6:palette_rgb=24'he6969f;
  4'd7:palette_rgb=24'hd9caec;
  4'd8:palette_rgb=24'h9f89c8;
  4'd9:palette_rgb=24'hdfc58b;
  4'd10:palette_rgb=24'h89c9ae;
  4'd11:palette_rgb=24'h344354;
  4'd12:palette_rgb=24'h728292;
  4'd13:palette_rgb=24'h10171f;
  default:palette_rgb=24'd0;endcase end endfunction
 wire[24:0]map_heads=map_data[49:25];
 reg key_q,dark_q,edge_q,line_q,boundary_q;
 reg[24:0]lane_mask;reg[4:0]pressed_part,target_part,wrong_part,note_part,head_part;integer g;
 reg[24:0]note_bits2,head_bits2,lane_mask2;
 reg[4:0]pressed_part2,target_part2,wrong_part2;
 reg key2,dark2,edge2,line2,boundary2;
 wire pressed_q=|pressed_part,target_q=|target_part,wrong_q=|wrong_part,note_q=|note_part,head_q=|head_part;
 reg[3:0]color;
 always @*begin
  color=dark_q ? 4'd0 : 4'd1;
  if(key_q)begin
   color=dark_q ? 4'd2 : 4'd3;
   if(pressed_q)color=4'd4;
   if(target_q)color=4'd5;
   if(wrong_q)color=4'd6;
  end else if(note_q)begin
   color=head_q ? 4'd7 : 4'd8;
   if(target_q)color=4'd9;
   if(pressed_q)color=4'd10;
   if(wrong_q)color=4'd6;
  end
  if(edge_q)color=4'd11;
  if(line_q)color=4'd12;
  if(boundary_q)color=4'd13;
 end
 always @(posedge clk)begin
   lane_mask<=lane_select;lane<=lane_lookup[x[10:3]];keys<=in_keys;boundary<=x==416||x==1815||y==448||y==1007;
  line_edge<=y==958||y==959;
  targets<=visible[24:0];wrong<=visible[49:25];pressed<=visible[214:190];
  // Stage2 captures RAM bits without a lane-selection mux on its read path.
  // Stage3 selects lanes; Stage4 resolves color. One original color-delay
  // register is reused for this split, keeping exactly12pixel clocks.
  note_bits2<=map_data[24:0];head_bits2<=map_heads;lane_mask2<=lane_mask;
  key2<=keys;dark2<=dark_key(lane[4:0]);
  for(g=0;g<5;g=g+1)begin
   pressed_part2[g]<=|(pressed[g*5+:5]&lane_mask[g*5+:5]);
   target_part2[g]<=|(targets[g*5+:5]&lane_mask[g*5+:5]);
   wrong_part2[g]<=|(wrong[g*5+:5]&lane_mask[g*5+:5]);
   note_part[g]<=|(note_bits2[g*5+:5]&lane_mask2[g*5+:5]);
   head_part[g]<=|(head_bits2[g*5+:5]&lane_mask2[g*5+:5]);
  end
  edge2<=lane[5];line2<=line_edge;boundary2<=boundary;
  pressed_part<=pressed_part2;target_part<=target_part2;wrong_part<=wrong_part2;
  key_q<=key2;dark_q<=dark2;edge_q<=edge2;line_q<=line2;boundary_q<=boundary2;
  colors[0]<=color;for(k=1;k<8;k=k+1)colors[k]<=colors[k-1];rgb_q<=palette_rgb(colors[7]);
  if(rst)masks<=0;else masks<={masks[10:0],de&&enabled&&visible[401]&&(in_roll||in_keys)};
 end
 assign rgb=rgb_q;assign mask=masks[11];
endmodule
