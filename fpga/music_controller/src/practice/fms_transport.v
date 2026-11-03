// One absolute-microsecond clock and event cursor for both practice modes.
// Control transitions freeze grading/time, drain due records, and rebuild only
// sustained automatic notes. Manual sound is owned by the audio wrapper.
module fms_transport #(parameter CLK_HZ=50000000,WITH_TEACHING=1)(
 input wire clk,rst,score_valid,input wire [12:0] event_count,
 input wire [31:0] duration_us,input wire judge_wait,judge_complete,
 input wire command_valid,output wire command_ready,input wire [2:0] action,input wire [3:0] value,
 output reg command_done,output reg [7:0] command_error,
 output reg mode,output reg [3:0] manual_preset,output reg running,paused,finished,
 output wire preparing,output wire judge_paused,output reg [31:0] time_us,run_id,revision,
 output reg judge_start,judge_stop,judge_reconfigure,
 output wire automatic_enabled,output reg automatic_flush,manual_reset,
 input wire audio_flushing,output reg [14:0] automatic_epoch,
 output wire automatic_valid,input wire automatic_ready,output wire [71:0] automatic_event,
 output wire [11:0] event_address,input wire [71:0] event_data,output reg fault,output wire event_request,input wire event_ready,event_valid,output wire event_accept
);
 localparam US_DIV=CLK_HZ>=1000000 ? CLK_HZ/1000000 : 1;
 localparam US_STEP=CLK_HZ>=1000000 ? 1 : 1000000/CLK_HZ;
 localparam C_IDLE=0,C_DRAIN=1,C_FLUSH=2,C_SETTLE=3,C_WAIT=4,C_APPLY=5,C_RESTORE=6,C_FINISH=7;
 localparam P_READ0=0,P_READ1=1,P_READ2=2,P_HAVE=3,P_SCAN=4,P_EMIT=5,P_APPLY=6,P_END=7,P_SCAN0=8,P_SCAN1=9;
 reg [3:0] control,player;reg [2:0] pending_action;reg [3:0] pending_value;
 reg resume_after;reg [31:0] fraction;reg [12:0] cursor;reg [71:0] record;
 reg armed,ended;reg [31:0] held;
 (* syn_ramstyle="block_ram" *)reg[15:0]held_memory[0:255];
 reg[15:0]held_q;reg held_writing;reg[2:0]held_beat;reg[4:0]held_wa;reg[79:0]held_word;
 wire[7:0]held_ra=control==C_RESTORE ? {restore_index[4:0],restore_phase[3:1]} : {scan[4:0],3'd2};
 always @(posedge clk)begin
  held_q<=held_memory[held_ra];
  if(held_writing)held_memory[{held_wa,held_beat}]<=held_word[held_beat*16+:16];
 end
 always @(posedge clk)begin
  if(rst)begin held_writing<=0;held_beat<=0;held_wa<=0;held_word<=0;end
  else if(held_writing)begin
   if(held_beat==4)held_writing<=0;else held_beat<=held_beat+1'b1;
  end else if(running && play_records && player==P_APPLY && op==1 && free_found && !found)begin
   held_writing<=1;held_beat<=0;held_wa<=free_slot;held_word<={8'd0,record};
  end
 end
 reg [5:0] scan,restore_index;reg found,free_found;reg [4:0] found_slot,free_slot;
 reg [3:0] restore_phase;reg [71:0] restore_record;
 wire accepted=command_valid && command_ready;
 assign command_ready=control==C_IDLE && !audio_flushing && !rst;
 assign preparing=control!=C_IDLE;
 // The accepting edge belongs to the old running state. All consumers see
 // the registered control transition together on the following cycle; a
 // combinational ready/valid command must not gate other modules' handshakes.
 assign judge_paused=paused || preparing || !armed;
 assign event_address=cursor[11:0];
 assign event_request=running && player==P_READ0 && !held_writing;
 assign event_accept=running && player==P_READ1;
 wire due=record[31:0]<=time_us;
 wire [1:0] op=record[49:48];
 wire draining=control==C_DRAIN;
 wire play_records=running && (!paused || draining) && (control==C_IDLE || draining);
 wire quiescent=ended || (player==P_HAVE && !due);
 wire normal_sound=running && mode && !paused && control==C_IDLE;
 assign automatic_enabled=(normal_sound || (control==C_RESTORE && resume_after && mode)) && !rst;
 wire restoring=control==C_RESTORE && restore_phase==10 && restore_index<32 && held[restore_index[4:0]];
 assign automatic_valid=automatic_enabled && (restoring || player==P_EMIT);
 assign automatic_event=restoring ? restore_record : record;
 // Fetch without downstream ready in the RAM address path. Two preparation
 // beats precede valid; music time remains frozen throughout C_RESTORE.
 always @(posedge clk)if(control==C_RESTORE && restore_phase[0] && restore_phase<10)begin
  if(restore_phase==9)restore_record[71:64]<=held_q[7:0];
  else restore_record[restore_phase[3:1]*16+:16]<=held_q;
 end
 wire valid_preset=value==0 || value==3 || value==7 || value==8 || value==9;
 wire invalid_command=action>5 || ((action==4) && value>1) || ((action==5) && !valid_preset);
 wire needs_score=action==1 || action==2 || action==3;
 wire invalid_state=(needs_score && !score_valid) || (action==4 && running) || (action==2 && (!running || paused)) ||
  (action==3 && (!running || !paused));
 integer k;
 always @(posedge clk)begin
  if(rst)begin
   control<=C_IDLE;player<=P_END;pending_action<=0;pending_value<=0;resume_after<=0;
   command_done<=0;command_error<=0;mode<=WITH_TEACHING ? 0 : 1;manual_preset<=0;running<=0;paused<=0;finished<=0;
   time_us<=0;run_id<=0;revision<=0;judge_start<=0;judge_stop<=0;judge_reconfigure<=0;
   automatic_flush<=0;manual_reset<=0;automatic_epoch<=0;fraction<=0;cursor<=0;record<=0;
   armed<=0;ended<=1;held<=0;scan<=0;restore_index<=0;found<=0;free_found<=0;
   found_slot<=0;free_slot<=0;fault<=0;restore_phase<=0;
  end else begin
   command_done<=0;judge_start<=0;judge_stop<=0;judge_reconfigure<=0;automatic_flush<=0;manual_reset<=0;
   if(running && !judge_paused && !judge_wait && !finished)begin
    if(fraction==US_DIV-1)begin
     fraction<=0;
     time_us<=time_us>=duration_us || duration_us-time_us<US_STEP ? duration_us : time_us+US_STEP;
    end else fraction<=fraction+1'b1;
   end
   // RAM fetch and due-event consumption do not own a second musical clock.
   if(running)case(player)
    P_READ0:if(event_ready && !held_writing)player<=P_READ1;
    P_READ1:if(event_valid)begin record<=event_data;player<=P_HAVE;armed<=1;end
    P_HAVE:if(play_records && due)begin
     if(op==0)begin ended<=1;player<=P_END;if(cursor+1'b1!=event_count)fault<=1;end
     else if(op==3)player<=P_EMIT;
     else begin scan<=0;found<=0;free_found<=0;found_slot<=0;free_slot<=0;player<=P_SCAN0;end
    end
    P_SCAN0:if(play_records)player<=P_SCAN1;
    P_SCAN1:if(play_records)player<=P_SCAN;
    P_SCAN:if(play_records)begin
     if(held[scan[4:0]] && held_q==record[47:32])begin found<=1;found_slot<=scan[4:0];end
     if(!held[scan[4:0]] && !free_found)begin free_found<=1;free_slot<=scan[4:0];end
     if(scan==31)player<=P_EMIT;else begin scan<=scan+1'b1;player<=P_SCAN0;end
    end
    P_EMIT:if(play_records && (!normal_sound || automatic_ready))player<=P_APPLY;
    P_APPLY:if(play_records)begin
     if(op==1)begin
      if(free_found && !found)begin held[free_slot]<=1;end
      else fault<=1;
     end else if(op==2)begin if(found)held[found_slot]<=0;else fault<=1;end
     if(cursor+1'b1>=event_count)begin ended<=1;player<=P_END;fault<=1;end
     else begin cursor<=cursor+1'b1;player<=P_READ0;end
    end
   endcase
   case(control)
    C_IDLE:begin
     if(accepted)begin
      command_error<=0;
      if(!WITH_TEACHING && action==4 && value==0)begin command_done<=1;command_error<=1;end
      else if(invalid_command || invalid_state)begin command_done<=1;command_error<=2;end
      else begin
       pending_action<=action;pending_value<=value;
       resume_after<=(action==1 || (action==5 && score_valid) || action==3 || (action==4 && running && !paused));
       if(action==0 || action==1 || action==5 || !running)control<=C_FLUSH;
       else control<=C_DRAIN;
      end
     end else if(running && judge_complete && ended)begin
      running<=0;paused<=0;finished<=1;automatic_flush<=1;revision<=revision+1'b1;
     end
    end
    C_DRAIN:if(quiescent)control<=C_FLUSH;
    C_FLUSH:begin automatic_flush<=1;control<=C_SETTLE;end
    C_SETTLE:control<=C_WAIT;
    C_WAIT:if(!audio_flushing)control<=C_APPLY;
    C_APPLY:begin
     automatic_epoch<=automatic_epoch+1'b1;
     restore_index<=0;restore_phase<=0;
     if(pending_action==0)begin
      running<=0;paused<=0;finished<=0;time_us<=0;fraction<=0;judge_stop<=1;held<=0;player<=P_END;ended<=1;control<=C_FINISH;
     end else if(pending_action==1 || pending_action==5)begin
      if(pending_action==5)begin manual_preset<=pending_value;manual_reset<=1;end
      if(score_valid)begin
       running<=1;paused<=0;finished<=0;time_us<=0;fraction<=0;run_id<=run_id+1'b1;
       judge_start<=1;held<=0;cursor<=0;player<=P_READ0;ended<=0;armed<=0;fault<=0;
      end
      control<=C_FINISH;
     end else begin
      if(pending_action==4)begin
       mode<=WITH_TEACHING ? pending_value[0] : 1'b1;time_us<=0;fraction<=0;finished<=0;
       judge_stop<=1;held<=0;player<=P_END;ended<=1;armed<=0;
      end
      paused<=running && !resume_after;
      control<=C_RESTORE;
     end
    end
    C_RESTORE:begin
     if(!resume_after || !mode || restore_index==32)control<=C_FINISH;
     else case(restore_phase)
      0:if(!held[restore_index[4:0]])restore_index<=restore_index+1'b1;else restore_phase<=1;
      1,2,3,4,5,6,7,8,9:restore_phase<=restore_phase+1'b1;
      10:if(automatic_ready)begin restore_index<=restore_index+1'b1;restore_phase<=0;end
     endcase
    end
    C_FINISH:begin revision<=revision+1'b1;command_done<=1;control<=C_IDLE;end
   endcase
  end
 end
endmodule
