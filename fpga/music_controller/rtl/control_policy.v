// All user-approved musical control assignments live here. No sound DSP.
// A single dispatcher-owned transaction stays in flight until its matching ACK.
module control_policy #(parameter WITH_GESTURE=0,WITH_V18=0,WITH_NEW_FX=0,CLEAR_CYCLES=100000000)(
 input wire clk,rst,input wire [10:0] function_keys,
 input wire [2:0] enc_short,enc_long,step_valid,input wire [5:0] steps,
 input wire panic_request,input wire [127:0] session_state,input wire [159:0] audio_state,
 input wire[15:0]gesture_status,
 input wire [87:0] envelope_status,output wire [31:0] envelope_control,
 input wire [47:0] harmonic_targets,input wire [63:0] synth_status,input wire adc_stale,
 input wire signed [4:0] joystick_bend,input wire [6:0] joystick_vibrato,
 input wire [63:0] navigation,input wire nav_activate,input wire lock_audio,input wire [67:0] mixer_targets,
 output reg valid,input wire ready,ack_valid,ack_accepted,ack_applied,input wire [7:0] ack_addr,ack_reason,
 input wire [31:0] ack_value,output reg [7:0] addr,output reg [31:0] value,
 output wire command_busy,output reg [7:0] last_action,output reg action_accepted,action_applied,
 output reg [2:0] focus,output reg [6:0] left_base,right_base,
 output reg overflow,output reg [31:0] rejected,output reg [7:0] last_reason,
 output reg [15:0] result_sequence,output reg [6:0] base_depth,
 output reg [2:0] vibrato_speed,output reg custom_hold);
 wire [2:0] page=session_state[2:0],preset=session_state[5:3];
 wire [2:0] nav_tab=navigation[2:0];wire [1:0] nav_sub=navigation[4:3];
 wire [3:0] nav_focus=navigation[8:5];wire nav_browse=navigation[9],nav_editing=navigation[10];
 wire [2:0] desired_page=nav_tab==1 ? (nav_sub==1 ? 2 : 1) : nav_tab==2&&nav_sub==1 ? 4 : nav_tab==4 ? 3 : 0;
 reg [2:0] event_tab,rotate_tab;reg [1:0] event_sub,rotate_sub,event_track;
 reg [3:0] event_focus,rotate_focus;
 wire [1:0] ensemble_style=audio_state[147:146];wire ensemble_mode=audio_state[148];
 wire [1:0] ensemble_minimum=audio_state[150:149],ensemble_maximum=audio_state[152:151];
 wire [1:0] track=session_state[7:6];wire running=session_state[8];
 wire busy=|session_state[14:9];wire click=session_state[15];
 wire [7:0] bpm=session_state[23:16];wire [2:0] meter=session_state[34:32],bars=session_state[37:35];
 wire [1:0] quantize=session_state[39:38];wire [8:0] click_gain=session_state[48:40];
 wire [3:0] muted=session_state[52:49];
 wire sustain=WITH_GESTURE ? gesture_status[3]:audio_state[81],sostenuto=audio_state[82],fx=audio_state[83];
 wire [2:0] release_index=audio_state[72:70],glide_index=audio_state[75:73];
 wire signed [4:0] applied_bend=audio_state[80:76];
 wire [6:0] applied_depth=audio_state[90:84];
 wire signed [4:0] desired_bend;wire [6:0] desired_depth;
 control_expression expression(preset,adc_stale,joystick_bend,joystick_vibrato,base_depth,desired_bend,desired_depth);
 reg [10:0] previous;reg [17:0] pending;reg waiting;reg [1:0] cooldown;
 reg signed [7:0] rotations[0:2];
 
 wire envelope_supported=preset==0||preset==4||preset==5;
 wire envelope_page=nav_tab==0&&nav_sub==2;
 // Navigation's activate is registered. Bind visible EDIT selection on the
 // physical short-press edge so simultaneous RELEASE/EDIT uses that card.
 wire envelope_activate=(envelope_page&&nav_browse&&!nav_editing&&enc_short[2]&&nav_focus<4)||
                         (nav_activate&&nav_focus==4);
 wire env_valid,env_ready,env_overflow;wire[31:0]env_value;
 wire[1:0]env_selected;wire[7:0]env_feedback;wire[15:0]env_sequence;
 wire timbre_pending=rotations[0]!=0||((valid||waiting)&&addr==0);
 envelope_controls env_controls(.clk(clk),.rst(rst),.preset(preset),.epoch(envelope_status[75:68]),
  .locked(lock_audio||busy),.timbre_pending(timbre_pending),.tim_step(step_valid[0]),
  .release_short(enc_short[1]),.release_long(enc_long[1]),.release_step(step_valid[1]),.release_direction(steps[3:2]),
  .edit_step(step_valid[2]),.edit_direction(steps[5:4]),.navigation(navigation),.activate(envelope_activate),
  .selected(env_selected),.valid(env_valid),.ready(env_ready),.value(env_value),.overflow(env_overflow),.feedback(env_feedback),.sequence(env_sequence));
 assign envelope_control={4'd0,env_sequence,env_feedback,env_overflow,envelope_supported,env_selected};
 assign env_ready=!valid&&!waiting&&cooldown==0&&panic_remaining==0&&chosen<0&&rot!=0&&env_valid;
 reg [2:0] panic_remaining;
 reg [17:0] incoming;integer i,chosen,rot;
 reg [31:0] edit_value;reg positive;
 function [31:0] bounded;input [31:0] x,increment,minimum,maximum;input up;
  begin bounded=up ? (x+increment>maximum ? maximum : x+increment) :
   (x<minimum+increment ? minimum : x-increment);end
 endfunction
 function [31:0] next_preset;input [2:0] p;input up;
  begin if(up) case(p) 0:next_preset=3;1:next_preset=0;2:next_preset=3;3:next_preset=4;4:next_preset=5;5:next_preset=6;6:next_preset=7;7:next_preset=ensemble_style==2 ? 10 : 8+ensemble_style;default:next_preset=0;endcase
   else case(p) 0:next_preset=10;1:next_preset=9;7:next_preset=ensemble_style==0 ? 6 : 6+ensemble_style;2:next_preset=0;3:next_preset=0;4:next_preset=3;5:next_preset=4;6:next_preset=5;default:next_preset=0;endcase
  end
 endfunction
 assign command_busy=valid||waiting;
 task unavailable;
  begin last_reason<=7;rejected<=rejected+1'b1;result_sequence<=result_sequence+1'b1;
   last_action<=8'hff;action_accepted<=0;action_applied<=0;end
 endtask
 task reject_edit;input [7:0] code,action;
 begin last_reason<=code;last_action<=action;rejected<=rejected+1'b1;
  result_sequence<=result_sequence+1'b1;action_accepted<=0;action_applied<=0;end
 endtask
 task edit_zone;input right,up;reg [31:0] target;
 begin
  target=bounded(right ? right_base : left_base,12,preset==7 ? 24 : 36,72,up);
  if((!right&&target+12>right_base)||(right&&target<left_base+12)) reject_edit(9,right ? 4 : 3);
  else issue(right ? 4 : 3,target);
 end endtask
 task edit_bars;input up;
 begin if(running||busy||(|session_state[68:53])) reject_edit(10,8'h2c);
  else issue(8'h2c,bounded(bars,1,1,4,up));end endtask
 task issue;input [7:0] a;input [31:0] v;
  begin valid<=1;addr<=a;value<=v;last_action<=a;action_accepted<=0;action_applied<=0;end
 endtask
 // Screen widgets use the same authoritative transaction/ACK path as physical keys.
 task activate_widget;input [2:0] t;input [1:0] sub;input [3:0] f;input [1:0] tr;
 begin
  case(t)
   0:if(sub==2)begin end else if(sub==3)begin if(f==0&&!WITH_NEW_FX)issue(18,!fx);end else if(sub==1) begin
    if(f==0&&preset==5)issue(15,!custom_hold);
    else if((f==0&&preset!=5)||(f!=0&&preset!=7&&preset!=1))unavailable;
   end else case(f)
    2:issue(5,!sustain);3:issue(6,!sostenuto);7:begin end
    4,5:if(preset!=4&&preset!=7&&preset!=1) unavailable;
    6:if(preset!=4) unavailable;
    default:begin end
   endcase
   1:if(sub==0) case(f)
    1:issue(8'h29,{29'd0,tr,!muted[tr]});
    2:issue(8'h25,1);3:issue(8'h23,1);4:issue(8'h24,1);5:issue(8'h26,{30'd0,tr});
    6:if(!running&&!busy) issue(8'h27,32'h434c5200|tr);else unavailable;
    default:begin end
   endcase else if(sub==1&&f<8) begin
    if(f[0]) issue(8'h29,{29'd0,f[2:1],!muted[f[2:1]]});
    else issue(8'h22,{30'd0,f[2:1]});
   end
   2:if(sub==0)begin
    if((f==0&&preset!=5)||(f==1&&preset!=1))issue(0,f==0 ? 5 : 10);
   end else if(sub==1 && f==4) begin if(preset==5) issue(28,32'h40000001);else unavailable;end
    else if(sub==2 && f==3) begin if(preset==1) issue(28,32'h30000001);else unavailable;end
    else if(preset!=5&&preset!=1) unavailable;
   4:if(sub==0&&f==5) issue(8'h2e,!click);
   default:begin end
  endcase
 end endtask
 task edit_effect;input [3:0] f;input up;
 begin
  case(f)
   0:if(preset==4) issue(8,bounded(glide_index,1,0,4,up));else unavailable;
   1:if(preset==4||preset==7||preset==1) base_depth<=bounded(base_depth,4,0,64,up);else unavailable;
   2:if(preset==4||preset==7||preset==1) issue(17,bounded(vibrato_speed,1,0,7,up));else unavailable;
   5:if(preset==7||preset==1) issue(25,up);else unavailable;
   6:if(preset==7||preset==1) issue(26,bounded(ensemble_minimum,1,0,3,up));else unavailable;
   7:if(preset==7||preset==1) issue(27,bounded(ensemble_maximum,1,0,3,up));else unavailable;
   default:begin end
  endcase
 end endtask
 task edit_widget;input [2:0] t;input [1:0] sub;input [3:0] f;input up;
 begin
  case(t)
   0:if(sub==2)begin end else if(sub==3)begin if(f==1)issue(19,bounded(envelope_status[87:80],8,0,128,up));end else if(sub==1)begin
    case(f)1:edit_effect(5,up);2:edit_effect(6,up);3:edit_effect(7,up);default:begin end endcase
   end else case(f)
    0:issue(0,next_preset(preset,up));1:issue(7,bounded(release_index,1,0,7,up));
    4:edit_effect(1,up);5:edit_effect(2,up);6:edit_effect(0,up);
    default:begin end
   endcase
   1:if(sub==0&&f==0) issue(8'h22,bounded(track,1,0,3,up));
    else if(sub==0&&f==8) edit_bars(up);
    else if(sub==1&&f<8&&!f[0]) begin
     edit_value=bounded(mixer_targets[f[2:1]*17+:17],2048,0,65536,up);
     issue(8'h28,{13'd0,f[2:1],edit_value[16:0]});
    end
   2:if(sub==2&&preset==1) begin
     case(f)
      0:issue(28,bounded({30'd0,synth_status[1:0]},1,0,3,up));
      1:issue(28,32'h10000000|bounded({30'd0,synth_status[3:2]},1,0,3,up));
      2:issue(28,32'h20000000|bounded({20'd0,synth_status[15:4]},64,0,4095,up));
      default:begin end
     endcase
    end else if(sub==1&&preset==5&&f<4) begin
     edit_value={20'd0,harmonic_targets[f[1:0]*12+:12]};
     issue(20+f,bounded(edit_value,16,0,4095,up));
    end else unavailable;
   4:if(sub==0) case(f)
    0:issue(8'h2a,bounded(bpm,1,40,240,up));
    1:issue(8'h2b,bounded(meter,1,2,4,up));
    2:edit_bars(up);
    3:issue(8'h2d,bounded(quantize,1,0,3,up));
    4:issue(8'h2f,bounded(click_gain,8,0,256,up));
    default:begin end
   endcase
   default:begin end
  endcase
 end endtask
 reg auto_needed;reg [7:0]auto_addr;reg [31:0]auto_value;
 always @(posedge clk)begin
  if(rst)auto_needed<=0;else auto_needed<=page!=desired_page||desired_bend!=applied_bend||desired_depth!=applied_depth;
  if(page!=desired_page)begin auto_addr<=8'h20;auto_value<={29'd0,desired_page};end
  else if(desired_bend!=applied_bend)begin auto_addr<=9;auto_value<={{27{desired_bend[4]}},desired_bend};end
  else begin auto_addr<=16;auto_value<={25'd0,desired_depth};end
 end
 always @* begin
  incoming=0;incoming[10:0]=function_keys&~previous;
  incoming[12]=enc_short[1]&&!envelope_supported;incoming[15]=nav_activate&&!envelope_page;
  chosen=-1;for(i=17;i>=0;i=i-1) if(pending[i]) chosen=i;
  if(pending[2]) chosen=2; // Global play/stop transaction has priority.
  rot=-1;for(i=2;i>=0;i=i-1) if(rotations[i]!=0&&!step_valid[i]) rot=i;
 end
 always @(posedge clk) begin
  if(rst) begin
   last_action<=0;action_accepted<=0;action_applied<=0;previous<=0;pending<=0;waiting<=0;cooldown<=0;valid<=0;addr<=0;value<=0;
   focus<=0;left_base<=48;right_base<=60;overflow<=0;rejected<=0;last_reason<=0;result_sequence<=0;
   base_depth<=0;vibrato_speed<=0;custom_hold<=0;
   event_tab<=0;event_sub<=0;event_focus<=0;event_track<=0;rotate_tab<=0;rotate_sub<=0;rotate_focus<=0;
   panic_remaining<=0;
   for(i=0;i<3;i=i+1) rotations[i]<=0;
  end else begin
   focus<=nav_focus[2:0];
   if(env_overflow)overflow<=1;
   previous<=function_keys;pending<=pending|incoming;
   if(nav_activate&&!pending[15]) begin event_tab<=nav_tab;event_sub<=nav_sub;event_focus<=nav_focus;event_track<=track;end
   if(|(pending&incoming)) begin overflow<=1;rejected<=rejected+1'b1;end
   if(cooldown!=0) cooldown<=cooldown-1'b1;
   for(i=0;i<3;i=i+1) if(step_valid[i]&&(i!=1||!envelope_supported)&&(i!=2||(nav_browse&&nav_editing&&!envelope_page))) begin
    if(i==2) begin rotate_tab<=nav_tab;rotate_sub<=nav_sub;rotate_focus<=nav_focus;end
    if(($signed(steps[i*2+:2])>0&&rotations[i]==127)||($signed(steps[i*2+:2])<0&&rotations[i]==-127)) begin overflow<=1;rejected<=rejected+1'b1;end
    else rotations[i]<=rotations[i]+$signed(steps[i*2+:2]);
   end
   if(valid&&ready) begin valid<=0;waiting<=1;end
   if(ack_valid&&waiting) begin
    action_accepted<=ack_accepted;action_applied<=ack_applied;waiting<=0;cooldown<=2;last_reason<=ack_reason;result_sequence<=result_sequence+1'b1;
    if(!ack_accepted) rejected<=rejected+1'b1;
    else case(ack_addr)
     0:begin if(ack_value<7||ack_value==10) begin if(left_base<36) begin left_base<=36;if(right_base<48) right_base<=48;end end end
     3:left_base<=ack_value[6:0];4:right_base<=ack_value[6:0];
     15:custom_hold<=ack_value[0];17:vibrato_speed<=ack_value[2:0];
     30:base_depth<=0;
     default:begin end
    endcase
   end
   if(panic_request) begin
    panic_remaining<=3;pending<=0;base_depth<=0;
    for(i=0;i<3;i=i+1) rotations[i]<=0;
   end else if(!valid&&!waiting&&cooldown==0) begin
    if(panic_remaining!=0) begin
     case(panic_remaining) 3:issue(8'h24,1);2:issue(8'h2e,0);default:issue(8'h1e,1);endcase
     panic_remaining<=panic_remaining-1'b1;
    end else if(chosen>=0) begin
     pending[chosen]<=incoming[chosen];
     case(chosen)
      0:issue(8'h22,{30'd0,(track==3 ? 2'd0 : track+2'd1)});
      1:issue(8'h22,{30'd0,(track==0 ? 2'd3 : track-2'd1)});
      2:issue((running||busy) ? 8'h24 : 8'h23,1);
      3:issue(8'h25,1);
      4:issue(8'h2e,!click);
      5:if(preset!=6) edit_zone(1'b0,1'b0);
      6:if(preset!=6) edit_zone(1'b0,1'b1);
      7:if(preset!=6) edit_zone(1'b1,1'b0);
      8:if(preset!=6) edit_zone(1'b1,1'b1);
      9:issue(5,!sustain);10:issue(6,!sostenuto);
      12:issue(7,5);
      15:activate_widget(event_tab,event_sub,event_focus,event_track);
      default:begin end
     endcase
    end else if(env_valid&&rot!=0)begin
     issue(29,env_value);
    end else if(rot>=0) begin
     positive=rotations[rot]>0;
     rotations[rot]<=rotations[rot]+(positive ? -1 : 1);
     case(rot)
      0:issue(0,next_preset(preset,positive));
      1:issue(7,bounded(release_index,1,0,7,positive));
      2:edit_widget(rotate_tab,rotate_sub,rotate_focus,positive);
      default:begin end
     endcase
    end else begin
     // Invalid payload may update, but a scoring lock can never publish valid.
     // Stable valid/ready transactions and matching ACK retain the old contract.
     addr<=auto_addr;value<=auto_value;
     if(!lock_audio&&auto_needed)begin valid<=1;last_action<=auto_addr;action_accepted<=0;action_applied<=0;end
    end
   end
  end
 end
endmodule
