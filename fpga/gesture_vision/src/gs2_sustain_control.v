// GS2 R3L: confirmed ON/OFF is latched, independent of observation freshness.
// LOSS_MS now bounds vote-history/diagnostic age only; it NEVER expires control.
// Only distinct forward, current-ROI observations enter the five-frame vote.
module gs2_sustain_control #(
 parameter CLK_HZ=74250000, LOSS_MS=800, UNSTABLE_MS=250
)(input wire clk,rst,camera_ok,observation_enable,observation_event,
 input wire [31:0] observation_frame,input wire [1:0] observation_pose,
 output wire control_valid,sustain_request,unstable,camera_fault,
 output reg [1:0] diagnostic_pose);
 localparam MS_CYCLES=CLK_HZ/1000;
 localparam MW=MS_CYCLES>1 ? $clog2(MS_CYCLES):1;
 localparam AW=LOSS_MS>0 ? $clog2(LOSS_MS+1):1;
 reg [MW-1:0] ms_count;
 reg [AW-1:0] age_ms,history_age_ms;
 reg have_control,requested,seen_frame;
 reg [31:0] last_frame;
 reg [7:0] history; // four preceding two-bit raw results, newest in bits1:0
 wire tick=ms_count==MS_CYCLES-1;
 wire [31:0] frame_delta=observation_frame-last_frame;
 wire fresh=observation_enable && observation_event &&
             (!seen_frame || (frame_delta!=0 && !frame_delta[31]));
 wire history_expired=history_age_ms>=LOSS_MS ||
      (tick && history_age_ms==LOSS_MS-1);
 wire [7:0] vote_history=history_expired ? 8'd0:history;
 wire [1:0] raw_pose=(observation_pose==1 || observation_pose==2) ? observation_pose:2'd0;
 reg [2:0] open_count,fist_count;
 integer i;
 always @* begin
  open_count=raw_pose==1 ? 3'd1:3'd0;
  fist_count=raw_pose==2 ? 3'd1:3'd0;
  for(i=0;i<4;i=i+1)begin
   if(vote_history[i*2+:2]==1)open_count=open_count+1'b1;
   if(vote_history[i*2+:2]==2)fist_count=fist_count+1'b1;
  end
 end
 wire confirm_open=raw_pose==1 && open_count>=3 && fist_count<=1;
 wire confirm_fist=raw_pose==2 && fist_count>=3 && open_count<=1;
 wire same_support=have_control &&
       raw_pose==(requested ? 2'd2:2'd1);
 assign camera_fault=!camera_ok;
 assign control_valid=camera_ok && have_control;
 assign sustain_request=control_valid && requested;
 assign unstable=camera_ok && (!control_valid || !observation_enable ||
       age_ms>=UNSTABLE_MS || diagnostic_pose!=(requested ? 2'd2:2'd1));
 always @(posedge clk)begin
  if(rst)begin
   ms_count<=0;age_ms<=LOSS_MS;history_age_ms<=LOSS_MS;history<=0;
   have_control<=0;requested<=0;
   seen_frame<=0;last_frame<=0;diagnostic_pose<=0;
  end else begin
   if(tick)begin
    ms_count<=0;
    if(age_ms<LOSS_MS)age_ms<=age_ms+1'b1;
    if(history_age_ms<LOSS_MS)history_age_ms<=history_age_ms+1'b1;
   end
   else ms_count<=ms_count+1'b1;
   if(history_expired)history<=0;
   if(!observation_enable)begin history<=0;diagnostic_pose<=0;history_age_ms<=LOSS_MS;end
   if(fresh && camera_ok)begin
    seen_frame<=1;last_frame<=observation_frame;
    diagnostic_pose<=raw_pose;
    history<={vote_history[5:0],raw_pose};history_age_ms<=0;
    // Raw support refreshes diagnostic age only, not the latched ON/OFF.
    // REJECT, no event and ROI mismatch cannot clear the confirmed state.
    if(same_support || confirm_open || confirm_fist)age_ms<=0;
    if(confirm_open || confirm_fist)begin
     have_control<=1;requested<=confirm_fist;
    end
   end
   if(!camera_ok)begin
    have_control<=0;requested<=0;age_ms<=LOSS_MS;
    history_age_ms<=LOSS_MS;history<=0;seen_frame<=0;diagnostic_pose<=0;
   end
  end
 end
endmodule
