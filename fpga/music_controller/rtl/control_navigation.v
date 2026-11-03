// UI state only. No audio clock gating; all actions still require backend ACK.
module control_navigation #(
 parameter WITH_LIBRARY=0,WITH_GESTURE=0,WITH_V18=0,WITH_LOOP_EXPORT=0,WITH_NEW_FX=0,CENTER_CYCLES=50000,FIRST_REPEAT=17500000,REPEAT_CYCLES=6000000,WITH_STORAGE=1,WITH_PRACTICE=0,
 ENTER_THRESHOLD=768,EXIT_THRESHOLD=384,CENTER_THRESHOLD=256
)(input wire clk,rst,mode_toggle,home,edit_press,back,stale,
 input wire signed [12:0] x,y,input wire [2:0] preset,input wire [1:0] selected_track,
 output reg [2:0] tab,output reg [1:0] subpage,output reg [3:0] focus,
 output reg browse,editing,armed,confirm_clear,output reg activate,
 output wire expression_enable,output wire [63:0] state,input wire practice_locked,
 input wire[63:0]v18_config,
 input wire [1:0] envelope_selected,input wire release_select);
 wire envelope_supported=preset==0||preset==4||preset==5;
 reg [2:0]previous_preset;
 reg [31:0] center_count,repeat_count;reg [2:0] held_direction,last_direction;
 reg [1:0] synth_request;reg [21:0] synth_wait;reg repeated;
 reg [15:0] sequence;reg [1:0] clear_track;reg [7:0] last_input;
 reg [2:0] direction;reg move;reg [3:0] maximum,candidate;integer k;
 wire [12:0] ax=x<0 ? -x : x,ay=y<0 ? -y : y;
 wire centered=ax<=CENTER_THRESHOLD&&ay<=CENTER_THRESHOLD;
 assign expression_enable=!browse&&armed&&!stale;
 assign state={24'd0,last_input,sequence,last_direction,confirm_clear,armed,editing,browse,focus,subpage,tab};
 wire action=(WITH_V18&&((tab==1&&subpage==2&&focus<3)||(tab==4&&subpage==1&&focus<(WITH_GESTURE ? 3:2))))||(tab==0&&subpage==2&&focus==4)||(tab==0&&subpage==3&&(focus==0||(WITH_NEW_FX&&focus==2)))||(tab==0&&subpage==0&&focus==1&&envelope_supported)||(tab==0&&subpage==0&&(focus==2||focus==3||focus==7||focus==8))||
  (tab==0&&subpage==1&&focus==0)||
  (tab==1&&subpage==0&&focus>=1&&focus<=9)||(tab==1&&subpage==1&&(focus[0]||focus==8))||(tab==1&&subpage==2&&focus!=0)||
  (tab==2&&subpage==0)||(tab==2&&subpage==1&&focus==4)||(tab==2&&subpage==2&&focus==3)||
  tab==3||(tab==5&&!(WITH_LIBRARY&&subpage==0&&focus==1))||(tab==4&&((subpage==0&&focus>=5)||(subpage==2&&(focus==0||focus==3))||(subpage==3&&focus<4)));
 function enabled_at;input [3:0] q;begin
  enabled_at=1;
  if(WITH_PRACTICE && tab==5 && ((subpage==0&&q==1&&!WITH_LIBRARY)||(subpage==1&&q==2)))enabled_at=0;
  if(q!=15)begin
   if(!WITH_STORAGE&&!WITH_PRACTICE&&tab==5)enabled_at=0;
   if(!WITH_STORAGE&&tab==1&&subpage==2)enabled_at=WITH_V18 ? (q==0||q==3||(WITH_LOOP_EXPORT&&q<3)) : q==3;
   if(tab==0&&subpage==0)begin
    if(q==1)enabled_at=preset!=6;
    if(q==4||q==5)enabled_at=preset==4||preset==7||preset==1;
    if(q==6)enabled_at=preset==4;
    if(q==8)enabled_at=preset==5||preset==7||preset==1;
   end
   if(tab==0&&subpage==1)enabled_at=q==0 ? preset==5 : preset==7||preset==1;
   if(tab==0&&subpage==2)enabled_at=envelope_supported&&q<=4;
   if(tab==0&&subpage==3)enabled_at=WITH_NEW_FX ? (q==0||q==2||(q==1&&v18_config[1:0]!=0)||(q==3&&v18_config[3:2]!=0)||((q==4||q==5)&&v18_config[1:0]==2)) : q<=1;
   if(tab==2&&subpage==1)enabled_at=preset==5;
   if(tab==2&&subpage==2)enabled_at=preset==1;
   if(WITH_PRACTICE&&practice_locked&&(tab<3||(tab==4&&(subpage==3||(subpage==0&&(q<6||q==8))))))enabled_at=0;
  end
 end endfunction
 function [2:0] next_tab;input down;begin
  if(down)case(tab)0:next_tab=1;1:next_tab=2;2:next_tab=5;5:next_tab=3;3:next_tab=4;default:next_tab=0;endcase
  else case(tab)0:next_tab=4;4:next_tab=3;3:next_tab=5;5:next_tab=2;2:next_tab=1;default:next_tab=0;endcase
 end endfunction
 wire [4:0] graph_layout=tab==0 ? (subpage==2 ? 9 : subpage==3 ? 7 : subpage==0 ? (preset==4 ? 2 : preset==7||preset==1 ? 1 : preset==5 ? 3 : 0) : preset==5 ? 4 : preset==7||preset==1 ? 5 : 6) :
 tab==1 ? (subpage==0 ? 12 : subpage==1 ? 10 : 16) : tab==2 ? (subpage==0 ? 7 : subpage==1 ? 9 : 8) :
 tab==3 ? 14 : tab==5 ? (WITH_PRACTICE ? 17+subpage : 13) : subpage==0 ? 11 : subpage==1 ? 15 : subpage==2 ? 8 : 9;
 wire content_locked=WITH_PRACTICE&&practice_locked&&(tab<3||(tab==4&&subpage==3));
 wire[3:0]entry_focus=content_locked ? 15 : WITH_PRACTICE&&practice_locked&&tab==4&&subpage==0 ? 6 : 0;
 wire [3:0] graph_candidate;
 workbench_focus_graph focus_graph(graph_layout,focus,direction,graph_candidate);
 always @* begin
  direction=0;
  if(ax>=ENTER_THRESHOLD||ay>=ENTER_THRESHOLD)begin if(ax>=ay)direction=x<0 ? 1 : 2;else direction=y<0 ? 3 : 4;end
  else if(held_direction!=0&&(ax>EXIT_THRESHOLD||ay>EXIT_THRESHOLD))direction=held_direction;
  move=browse&&armed&&!stale&&direction!=0&&(direction!=held_direction||repeat_count>=(repeated ? REPEAT_CYCLES-1 : FIRST_REPEAT-1));
  maximum=8;
  case(tab)
   0:maximum=subpage==2 ? 4 : subpage==3 ? (WITH_NEW_FX ? 5 : 1) : subpage==1 ? 3 : 8;
   1:maximum=subpage==2 ? 3 : subpage==1 ? 8 : 9;
   2:maximum=subpage==0 ? 1 : subpage==1 ? 4 : 3;
   3:maximum=2;
   4:maximum=subpage==0 ? 8 : subpage==2 ? 3 : subpage==3 ? 4 : WITH_GESTURE ? 2 : WITH_V18 ? 1 : 0;
   5:maximum=subpage==0 ? (WITH_LIBRARY ? 7:5) : subpage==1 ? 3 : subpage==2 ? 2 : 1;
  endcase
  candidate=graph_candidate;
  if(WITH_LIBRARY&&tab==5&&subpage==0)begin
   candidate=focus;
   if(direction==1)candidate=focus[0] ? focus-1'b1:15;
   if(direction==2&&!focus[0])candidate=focus+1'b1;
   if(direction==3)candidate=focus<2 ? 15:focus-2;
   if(direction==4&&focus<6)candidate=focus+2;
  end
  if(!WITH_STORAGE&&!WITH_V18&&tab==1&&subpage==2)candidate=3;
  if(WITH_NEW_FX&&tab==0&&subpage==3)begin
   candidate=focus;
   if(direction==1)candidate=focus[0] ? focus-1'b1 : 15;
   else if(direction==2&&!focus[0]&&enabled_at(focus+1'b1))candidate=focus+1'b1;
   else if(direction==3)begin candidate=focus<2 ? 15 : focus-2;if(candidate!=15&&!enabled_at(candidate))candidate=candidate<2 ? 15 : candidate-2;end
   else if(direction==4)begin candidate=focus<4 ? focus+2 : focus;if(!enabled_at(candidate))candidate=candidate<4 ? candidate+2 : focus;if(!enabled_at(candidate))candidate=focus;end
  end
  if(WITH_V18&&tab==4&&subpage==1)begin
   if(WITH_GESTURE)begin
    candidate=focus;
    if(direction==1)candidate=focus==1 ? 0:15;
    if(direction==2&&focus==0)candidate=1;
    if(direction==3)candidate=focus==2 ? 0:15;
    if(direction==4)candidate=2;
   end else candidate=direction==1 ? (focus==1 ? 0 : 15) : direction==4||direction==2 ? 1 : 0;
  end
  if(WITH_V18&&tab==1&&subpage==2)begin
   candidate=focus;
   if(direction==1)candidate=focus[0] ? focus-1'b1 : 15;
   if(direction==2&&!focus[0])candidate=focus+1'b1;
   if(direction==3)candidate=focus<2 ? 15 : focus-2;
   if(direction==4&&focus<2)candidate=focus+2;
  end
  // Paused phone export: only Source and Back are navigable.
  if(WITH_V18&&!WITH_STORAGE&&!WITH_LOOP_EXPORT&&tab==1&&subpage==2)begin
   candidate=focus;
   if(direction==1)candidate=focus==3 ? 0 : 15;
   if(direction==2)candidate=3;
   if(direction==3)candidate=15;
   if(direction==4)candidate=3;
  end
  if(WITH_PRACTICE&&practice_locked&&candidate!=15&&!enabled_at(candidate))candidate=15;
 end
 always @(posedge clk)begin
  if(rst)begin
   previous_preset<=0;tab<=0;subpage<=0;focus<=0;browse<=0;editing<=0;armed<=0;confirm_clear<=0;activate<=0;
   center_count<=0;repeat_count<=0;held_direction<=0;repeated<=0;sequence<=0;last_direction<=0;clear_track<=0;last_input<=0;synth_request<=0;synth_wait<=0;
  end else begin
   activate<=0;previous_preset<=preset;
   if(synth_request!=0)begin if(tab!=2||subpage!=0||synth_wait==0)synth_request<=0;else synth_wait<=synth_wait-1'b1;end
   if(stale||home||mode_toggle)begin armed<=0;center_count<=0;held_direction<=0;repeat_count<=0;repeated<=0;end
   else begin
    if(!armed)begin if(!centered)center_count<=0;else if(center_count>=CENTER_CYCLES-1)armed<=1;else center_count<=center_count+1'b1;end
    if(direction==0||!browse||!armed)begin held_direction<=0;repeat_count<=0;repeated<=0;end
    else if(move)begin held_direction<=direction;repeat_count<=0;repeated<=direction==held_direction;end
    else repeat_count<=repeat_count+1'b1;
   end
   if(confirm_clear&&tab==1&&selected_track!=clear_track)confirm_clear<=0;
   if(home)begin tab<=0;subpage<=0;focus<=0;browse<=0;editing<=0;confirm_clear<=0;synth_request<=0;sequence<=sequence+1'b1;last_input<=2;end
   else if(mode_toggle)begin browse<=!browse;focus<=15;editing<=0;confirm_clear<=0;sequence<=sequence+1'b1;last_input<=1;end
   else if(WITH_PRACTICE&&practice_locked&&focus!=15&&!enabled_at(focus))begin
    focus<=15;editing<=0;confirm_clear<=0;synth_request<=0;synth_wait<=0;
   end
   else if(tab==0&&subpage==2&&preset!=previous_preset)begin
    subpage<=envelope_supported ? 2 : 0;focus<=envelope_supported ? 3 : 0;editing<=0;confirm_clear<=0;
   end
   else if(tab==2&&subpage==0&&synth_request!=0&&((synth_request==1&&preset==5)||(synth_request==2&&preset==1)))begin subpage<=synth_request;focus<=0;editing<=0;synth_request<=0;end
   else if(tab==2&&subpage!=0&&((subpage==2&&preset!=1)||(subpage==1&&preset!=5)))begin subpage<=preset==1 ? 2 : preset==5 ? 1 : 0;focus<=0;editing<=0;confirm_clear<=0;sequence<=sequence+1'b1;end
   else if(back&&browse)begin
    if(confirm_clear)confirm_clear<=0;else if(editing)editing<=0;else if(subpage!=0)begin subpage<=0;focus<=0;end else focus<=15;
    sequence<=sequence+1'b1;last_input<=4;
   end else if(edit_press&&browse)begin
    sequence<=sequence+1'b1;last_input<=3;
    if(focus==15)begin focus<=(!WITH_STORAGE&&!WITH_PRACTICE&&tab==5) ? 15 : entry_focus;if(tab==2&&!content_locked)subpage<=preset==5 ? 1 : preset==1 ? 2 : 0;end
    else if(editing)editing<=0;
    else if(WITH_PRACTICE&&tab==5&&subpage==0&&focus==0)begin subpage<=1;focus<=0;end
    else if(WITH_PRACTICE&&tab==5&&subpage==0&&focus==4)begin subpage<=2;focus<=0;end
    else if(WITH_PRACTICE&&tab==5&&subpage==1&&focus==3)begin subpage<=0;focus<=0;end
    else if(WITH_PRACTICE&&tab==5&&subpage==2&&focus==1)begin subpage<=3;focus<=0;end
    else if(WITH_PRACTICE&&tab==5&&subpage==2&&focus==2)begin subpage<=0;focus<=4;end
    else if(WITH_PRACTICE&&tab==5&&subpage==3&&focus==1)begin subpage<=2;focus<=1;end
    else if(tab==1&&subpage==0&&focus==7)begin subpage<=1;focus<=0;end
    else if(tab==1&&subpage==0&&focus==9)begin subpage<=2;focus<=WITH_STORAGE||WITH_V18 ? 0 : 3;end
    else if(!WITH_STORAGE&&tab==1&&subpage==2&&focus==3)begin subpage<=0;focus<=9;end
    else if(tab==1&&subpage==1&&focus==8)begin subpage<=0;focus<=0;end
    else if(tab==0&&subpage==0&&focus==1&&envelope_supported)begin subpage<=2;focus<=3;editing<=0;end
    else if(tab==0&&subpage==0&&focus==7)begin subpage<=3;focus<=0;editing<=0;end
    else if(tab==0&&subpage==2&&focus==4)begin
     if(confirm_clear)begin activate<=1;confirm_clear<=0;end else confirm_clear<=1;
    end
    else if(tab==0&&subpage==0&&focus==8)begin subpage<=1;focus<=preset==5 ? 0 : 1;end
    else if(tab==2&&subpage==0)begin activate<=1;synth_request<=focus==0 ? 1 : 2;synth_wait<=22'd4194303;end
    else if(tab==3)subpage<=focus[1:0];
    else if(tab==4&&subpage==0&&focus>=6)begin subpage<=focus==6 ? 1 : focus==7 ? 2 : 3;focus<=0;end
    else if(tab==1&&subpage==0&&focus==6)begin
     if(confirm_clear&&selected_track==clear_track)begin activate<=1;confirm_clear<=0;end else begin confirm_clear<=1;clear_track<=selected_track;end
    end else if((WITH_V18||!(tab==4&&subpage==1))&&enabled_at(focus))begin activate<=1;if(!action)editing<=1;end
   end else if(tab==0&&subpage==2&&release_select===1'b1&&envelope_supported)begin
    focus<={2'd0,envelope_selected+2'd1};confirm_clear<=0;sequence<=sequence+1'b1;
   end else if(move&&!editing)begin
    sequence<=sequence+1'b1;last_direction<=direction;last_input<=8+direction;confirm_clear<=0;
    if(focus==15)begin
     if(direction==3||direction==4)begin tab<=next_tab(direction==4);subpage<=0;end
     else if(direction==2)begin focus<=(!WITH_STORAGE&&!WITH_PRACTICE&&tab==5) ? 15 : entry_focus;if(tab==2&&!content_locked)subpage<=preset==5 ? 1 : preset==1 ? 2 : 0;end
    end else focus<=candidate;
   end
  end
 end
endmodule
