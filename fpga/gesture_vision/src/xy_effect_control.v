// Position expression is independent of the latched sustain policy.
// Both axes use native pixels in the same 240x240 square ROI.
module xy_effect_control #(
 parameter CLK_HZ=74250000,FRESH_MS=200,DEAD_PIXELS=12,UNLOCK_PIXELS=6,
 parameter GAIN_STEP=328,BEND_STEP=164
)(input wire clk,rst,maximum_roi,camera_ok,measurement_event,track_valid,track_held,
 input wire [31:0] measurement_frame,input wire [8:0] hand_x,input wire [7:0] hand_y,
 output wire position_owned,returning,output wire [1:0] axis,
 output wire [7:0] expression_gain,output wire signed [7:0] bend_offset);
 localparam MS_CYCLES=CLK_HZ/1000,MW=$clog2(MS_CYCLES),AW=$clog2(FRESH_MS+1);
 reg [MW-1:0] ms_count;
 reg [AW-1:0] age_ms;
 reg have_anchor,seen_frame;
 reg [31:0] last_frame;
 reg [8:0] anchor_x;reg [7:0] anchor_y,origin_gain,target_gain;
 reg [1:0] axis_state;
 reg signed [7:0] target_bend;
 reg [15:0] gain_acc;
 reg signed [16:0] bend_acc;
 wire tick=ms_count==MS_CYCLES-1;
 wire allowed=maximum_roi&&camera_ok;
 wire [31:0] frame_delta=measurement_frame-last_frame;
 wire fresh=measurement_event&&track_valid&&!track_held&&allowed&&
  (!seen_frame||(frame_delta!=0&&!frame_delta[31]));
 assign position_owned=allowed&&have_anchor&&track_valid&&!track_held&&age_ms<FRESH_MS;
 assign returning=!position_owned&&(gain_acc!=16'hff00||bend_acc!=0);
 assign axis=position_owned ? axis_state : 2'd0;
 assign expression_gain=gain_acc[15:8];
 wire signed [16:0] bend_magnitude=bend_acc<0 ? -bend_acc : bend_acc;
 assign bend_offset=bend_acc<0 ? -(bend_magnitude>>>8) : (bend_magnitude>>>8);
 // Ownership withdraws combinationally. Register only the smoothing goals so
 // ROI decoding is not chained through the fixed-point slew arithmetic.
 reg [7:0] gain_target;
 reg signed [7:0] bend_target;
 wire [15:0] gain_goal={gain_target,8'd0};
 wire signed [16:0] bend_goal={bend_target[7],bend_target,8'd0};
 wire signed [9:0] dx=$signed({1'b0,hand_x})-$signed({1'b0,anchor_x});
 wire signed [9:0] dy=$signed({2'b0,hand_y})-$signed({2'b0,anchor_y});
 wire [9:0] ax=dx<0 ? -dx : dx,ay=dy<0 ? -dy : dy;
 wire x_dominant=ax>=DEAD_PIXELS && {1'b0,ax,1'b0}>={2'd0,ay}+{1'b0,ay,1'b0};
 wire y_dominant=ay>=DEAD_PIXELS && {1'b0,ay,1'b0}>={2'd0,ax}+{1'b0,ax,1'b0};
 wire centered=ax<=UNLOCK_PIXELS&&ay<=UNLOCK_PIXELS;
 wire signed [9:0] dx_dead=dx>DEAD_PIXELS ? dx-DEAD_PIXELS :
  dx< -DEAD_PIXELS ? dx+DEAD_PIXELS : 10'sd0;
 wire signed [9:0] dy_dead=dy>DEAD_PIXELS ? dy-DEAD_PIXELS :
  dy< -DEAD_PIXELS ? dy+DEAD_PIXELS : 10'sd0;
 wire signed [11:0] dy_wide={{2{dy_dead[9]}},dy_dead};
 wire signed [11:0] gain_calc=$signed({4'd0,origin_gain})-(dy_wide<<<1);
 wire [7:0] mapped_gain=gain_calc>255 ? 8'd255 : gain_calc<128 ? 8'd128 : gain_calc[7:0];
 wire signed [7:0] mapped_bend=dx_dead>64 ? 8'sd64 : dx_dead< -64 ? -8'sd64 : dx_dead[7:0];
 always @(posedge clk)begin
  if(rst)begin
   ms_count<=0;age_ms<=FRESH_MS;have_anchor<=0;seen_frame<=0;last_frame<=0;
   anchor_x<=0;anchor_y<=0;origin_gain<=255;target_gain<=255;target_bend<=0;axis_state<=0;
   gain_acc<=16'hff00;bend_acc<=0;gain_target<=255;bend_target<=0;
  end else begin
   gain_target<=position_owned ? target_gain : 8'd255;
   bend_target<=position_owned ? target_bend : 8'sd0;
   if(tick)begin
    ms_count<=0;if(age_ms<FRESH_MS)age_ms<=age_ms+1'b1;
    if(gain_acc<gain_goal)gain_acc<=gain_goal-gain_acc<=GAIN_STEP ? gain_goal : gain_acc+GAIN_STEP;
    else if(gain_acc>gain_goal)gain_acc<=gain_acc-gain_goal<=GAIN_STEP ? gain_goal : gain_acc-GAIN_STEP;
    if(bend_acc<bend_goal)bend_acc<=bend_goal-bend_acc<=BEND_STEP ? bend_goal : bend_acc+BEND_STEP;
    else if(bend_acc>bend_goal)bend_acc<=bend_acc-bend_goal<=BEND_STEP ? bend_goal : bend_acc-BEND_STEP;
   end else ms_count<=ms_count+1'b1;
   if(!allowed||!track_valid||track_held||age_ms>=FRESH_MS)begin
    have_anchor<=0;axis_state<=0;target_gain<=255;target_bend<=0;origin_gain<=255;
   end
   if(!camera_ok)seen_frame<=0;
   if(fresh)begin
    seen_frame<=1;last_frame<=measurement_frame;age_ms<=0;
    if(!position_owned)begin
     have_anchor<=1;anchor_x<=hand_x;anchor_y<=hand_y;
     axis_state<=0;target_gain<=255;target_bend<=0;origin_gain<=255;
    end else if(axis_state!=0&&centered)begin
     axis_state<=0;target_bend<=0;origin_gain<=target_gain;
     anchor_x<=hand_x;anchor_y<=hand_y;
    end else if(axis_state==1||(axis_state==0&&x_dominant))begin
     axis_state<=1;target_bend<=mapped_bend; // gain holds during BEND
    end else if(axis_state==2||(axis_state==0&&y_dominant))begin
     axis_state<=2;target_gain<=mapped_gain; // bend holds during VOLUME
    end
   end
  end
 end
endmodule
