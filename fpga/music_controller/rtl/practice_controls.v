// Visible context actions, one held request, and explicit shared-RAM ownership.
// This module never synthesizes sound and never resets the saved Looper layers.
module practice_controls #(parameter WITH_TEACHING=1)(input wire clk,rst,input wire[63:0]navigation,input wire activate,
 input wire tim_step,input wire[1:0]tim_direction,input wire[10:0]function_keys,
 input wire panic,input wire safe_enter,quiet,ram_stopped,keys_released,
 input wire score_request,score_active,score_memory_ready,
 input wire song_valid,upload_busy,running,paused,preparing,input wire mode,
 input wire[3:0]preset,input wire record_active,record_closing,activity_request,
 output reg scene,output reg local_valid,input wire local_ready,
 output reg[2:0]local_action,output reg[3:0]local_value,
 output reg score_owner,score_toggle,release_song,confirm_release,denied,
 output reg[7:0]last_action,output reg[15:0]action_sequence,output reg restore_mapping,confirm_mapping);
 reg[10:0]previous;reg[2:0]loan_state;reg[27:0]confirm_age;reg[4:0]previous_page;
 wire[10:0]pressed=function_keys&~previous;
 wire[2:0]tab=navigation[2:0];wire[1:0]sub=navigation[4:3];wire[3:0]focus=navigation[8:5];
 wire can_enter=ram_stopped && quiet && keys_released && !upload_busy && !record_active && !record_closing && !score_owner;
 wire idle_scene=!running&&!preparing&&!record_active&&!record_closing&&!upload_busy;
 function[3:0]next_preset;input[3:0]p;input reverse;begin
  if(reverse)case(p)0:next_preset=9;3:next_preset=0;7:next_preset=3;8:next_preset=7;default:next_preset=8;endcase
  else case(p)0:next_preset=3;3:next_preset=7;7:next_preset=8;8:next_preset=9;default:next_preset=0;endcase
 end endfunction
 task issue;input[2:0]a;input[3:0]v;begin
  if((scene||can_enter)&&!score_owner)begin scene<=1;local_valid<=1;local_action<=a;local_value<=v;last_action<={5'd0,a};action_sequence<=action_sequence+1'b1;denied<=0;end
  else denied<=1;
 end endtask
 task play_pause;begin issue(!running ? 1 : paused ? 3 : 2,0);end endtask
 always @(posedge clk)begin
  if(rst)begin scene<=0;local_valid<=0;local_action<=0;local_value<=0;score_owner<=0;score_toggle<=0;release_song<=0;confirm_release<=0;denied<=0;previous<=0;loan_state<=0;confirm_age<=0;last_action<=0;action_sequence<=0;restore_mapping<=0;confirm_mapping<=0;previous_page<=0;end
  else begin
   previous<=function_keys;previous_page<=navigation[4:0];score_toggle<=0;release_song<=0;restore_mapping<=0;
   if(navigation[4:0]==5'd13&&previous_page!=5'd13&&!scene)begin
    if(can_enter)begin scene<=1;denied<=0;end else denied<=1;
   end
   if(tab!=5||sub!=3||focus!=0)confirm_mapping<=0;
   if(local_valid&&local_ready)local_valid<=0;
   if(activity_request&&!score_owner)scene<=1;
   if(confirm_release)begin
    if(confirm_age==28'd249999999)begin confirm_release<=0;confirm_age<=0;end
    else confirm_age<=confirm_age+1'b1;
   end
   case(loan_state)
    // Ownership can pauseDD and initiate a source-only flush after entry was
    // first judged safe. Wait for BOTH resources, not just sharedRAM init.
    1:if(score_memory_ready&&safe_enter&&quiet&&ram_stopped&&keys_released)begin score_toggle<=1;loan_state<=2;end
    2:if(score_active)loan_state<=3;
    3:if(!score_active)begin score_owner<=0;loan_state<=0;end
   endcase
   if(score_request)begin
    if(score_active)score_toggle<=1;
    else if(!safe_enter||!can_enter||!idle_scene)denied<=1;
    else if(song_valid&&!confirm_release)begin confirm_release<=1;confirm_age<=0;end
    else begin release_song<=song_valid;score_owner<=1;loan_state<=1;scene<=0;confirm_release<=0;denied<=0;end
   end
   if(panic&&score_active)score_toggle<=1;
   if(!local_valid&&!score_owner&&loan_state==0)begin
    if(panic&&scene)issue(0,0);
    else if(scene&&pressed[2])play_pause;
    else if(scene&&tim_step)issue(5,next_preset(preset,tim_direction[1]));
    else if(activate&&tab==5&&focus!=15)case(sub)
     0:case(focus)
      0:if(scene||can_enter)begin scene<=1;denied<=0;end else denied<=1;
      1:if(WITH_TEACHING)issue(4,{3'd0,!mode});else denied<=1;
      2:play_pause;
      3:issue(0,0);
      5:if(idle_scene&&quiet&&keys_released)begin scene<=0;last_action<=8'h80;action_sequence<=action_sequence+1'b1;denied<=0;end else denied<=1;
     endcase
     1:case(focus)0:play_pause;1:issue(0,0);2:if(WITH_TEACHING)issue(4,{3'd0,!mode});else denied<=1;endcase
     2:case(focus)0:issue(record_active||record_closing ? 7 : 6,0);endcase
     3:if(focus==0)begin
      if(idle_scene&&quiet&&keys_released&&local_ready)begin
       if(confirm_mapping)begin restore_mapping<=1;confirm_mapping<=0;end else confirm_mapping<=1;
      end else denied<=1;
     end
    endcase
   end
  end
 end
endmodule
