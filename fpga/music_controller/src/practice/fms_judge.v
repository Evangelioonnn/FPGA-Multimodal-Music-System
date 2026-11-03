// Shared per-note settlement across teaching/game transitions. Musical time is
// supplied by one transport; this module never owns a second rhythm clock.
module fms_judge #(parameter CLK_HZ=50000000,WITH_TEACHING=1)(
 input wire clk,rst,start,stop,reconfigure,mode,running,paused,
 input wire [31:0] time_us,duration_us,input wire [15:0] count,input wire [24:0] keys,
 output wire time_wait,output wire complete,output reg [24:0] targets,output wire [24:0] correct,output reg [24:0] wrong,
 output reg [15:0] hits,misses,extras,output reg [2:0] timing_status,output reg overflow,
 output wire query, input wire query_ready,output wire [10:0] query_index,
 input wire response,input wire [79:0] note_data
);
 wire effective_mode=WITH_TEACHING ? mode : 1'b1;
 localparam IDLE=0,REQUEST=1,WAIT_NOTE=2,EVALUATE=3,BUILD_DONE=4,TEACH_WAIT=5,
 TEACH_COMMIT=6,HIT_DONE=7,CLEAR_SETTLED=8,TEACH_LOAD=9;
 localparam JOB_BUILD=0,JOB_EXPIRE=1,JOB_STRIKE=2;
 reg [3:0] state;reg [1:0] job;reg [10:0] index,expire_index,best_index;
 (* syn_ramstyle="block_ram" *) reg settled[0:2047];
 reg settled_q,settled_read,after_clear;reg [10:0] clear_index;reg [79:0] note;
 reg [32:0] note_deadline_q,distance_q;
 reg [31:0] group_start,best_time,strike_time;reg [32:0] best_distance;
 reg [24:0] work_targets,eligible,group_ends_pending,carry,previous,press_mask;
 reg [24:0] green_feedback,late_members,game_targets;
 assign correct=effective_mode ? green_feedback : (green_feedback & ~targets) | strike_hits;
 // Validity comes from work_targets/targets, so these one-write/one-read
 // records need no bulk reset. The target device has no distributed SRAM;
 // these small records remain registers, with shared time arithmetic below.
 // One128x16 physical RAM. End_us32 and note_index11 are lossless.
 (* syn_ramstyle="block_ram" *)reg[15:0]group_memory[0:127];reg[15:0]group_q;
 reg group_writing;reg[1:0]group_write_beat;reg[4:0]group_write_lane;reg[47:0]group_write_word;
 reg[2:0]group_read_phase;reg[31:0]group_commit_end;reg[10:0]group_commit_index;
 generate if(WITH_TEACHING)begin:teach_group
 always @(posedge clk)begin
  group_q<=group_memory[{commit_key,group_read_phase[2:1]}];
  if(group_writing)group_memory[{group_write_lane,group_write_beat}]<=group_write_word[group_write_beat*16+:16];
 end
 end else begin:no_teach_group
  always @(posedge clk)group_q<=0;
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin group_writing<=0;group_write_beat<=0;group_write_lane<=0;group_write_word<=0;group_commit_end<=0;group_commit_index<=0;end
  else begin
   if(build_record)begin group_writing<=1;group_write_beat<=0;group_write_lane<=lane;group_write_word<={5'd0,index,end_us};end
   else if(group_writing)begin if(group_write_beat==2)group_writing<=0;else group_write_beat<=group_write_beat+1'b1;end
   if(state==TEACH_LOAD)case(group_read_phase)
    1:group_commit_end[15:0]<=group_q;
    3:group_commit_end[31:16]<=group_q;
    5:group_commit_index<=group_q[10:0];
   endcase
  end
 end

 reg [4:0] strike_key,commit_key;reg found,group_found,accept_record;
 localparam WAIT_W=$clog2(CLK_HZ/5+1)>0 ? $clog2(CLK_HZ/5+1) : 1;
 localparam MS_W=$clog2(CLK_HZ/1000)>0 ? $clog2(CLK_HZ/1000) : 1;
 reg [WAIT_W-1:0] wait_cycles;reg [9:0] feedback_ms;reg [MS_W-1:0] millisecond;
 wire ms_tick=millisecond>=CLK_HZ/1000-1;
 wire [24:0] rising=keys & ~previous,falling=previous & ~keys;
 wire [24:0] strike_hits=({1'b0,time_us}+33'd200000>={1'b0,group_start}) ? keys & eligible & targets : 25'd0;
 wire [24:0] physical_extra=keys & ~targets & ~carry;
 wire full_chord=targets!=0 && strike_hits==targets && physical_extra==0;
 wire waiting=running && !effective_mode && state==TEACH_WAIT && time_us>=group_start;
 wire late=waiting && wait_cycles>=CLK_HZ/5;
 wire [31:0] start_us=note[31:0],end_us=note[63:32];wire [6:0] pitch=note[70:64];
 wire [4:0] lane=pitch-7'd48;
 wire [32:0] distance=distance_q;
 wire[32:0]time_difference={1'b0,note_data[31:0]}-{1'b0,strike_time};
 wire[32:0]incoming_distance=time_difference[32] ? -time_difference : time_difference;
 reg end_due;
 always @(posedge clk)if(rst||start||stop||reconfigure)end_due<=0;else end_due<=time_us>=duration_us;
 wire expired=({1'b0,time_us}>note_deadline_q)||(effective_mode&&end_due);
 // fms_keymap publishes coherent keys every52 clocks. A full scan is26;
 // classify the original falling-edge timestamp, never the display time.
 wire release_write=state==TEACH_COMMIT && targets[commit_key] && running && !paused && !reconfigure && !stop;wire[24:0]release_fault_q,release_late_q,release_clear_q,last_release;wire release_overflow;
 genvar rk;generate for(rk=0;rk<25;rk=rk+1)begin:release_fields
  if(rk==24)assign last_release[rk]=release_fault_q[rk];
  else assign last_release[rk]=release_fault_q[rk]&&!(|release_fault_q[24:rk+1]);
 end endgenerate
 generate if(WITH_TEACHING)begin:teach_release
 practice_release_checks release_classifier(clk,rst,
  running&&!paused&&!effective_mode&&!start&&!stop&&!reconfigure,
  time_us,group_ends_pending,falling,keys,release_write,commit_key,group_commit_end,
  release_fault_q,release_late_q,release_clear_q,release_overflow);
 end else begin:no_teach_release
  assign release_fault_q=0;assign release_late_q=0;assign release_clear_q=0;assign release_overflow=0;
 end endgenerate


 wire build_record=running && !paused && !start && !stop && !reconfigure &&
  state==EVALUATE && job==JOB_BUILD && !settled_q && !expired &&
  (!group_found || start_us<=best_time);

 wire [31:0] queue_time;wire [24:0] queue_keys;wire queue_ready,queue_valid;
 wire queue_pop=state==IDLE && effective_mode && running && !paused && queue_valid && press_mask==0;
 wire queue_input=effective_mode && running && !paused && rising!=0;
 // Coherent keymap updates are at least52 clocks apart. This FIFO writes
 // four16-bit beats and keeps a cached head; original edge timestamps and
 // logical capacity16 are unchanged. An illegal faster/full input is rejected
 // through queue_ready and the existing explicit overflow flag.
 wire[63:0]queue_front;wire queue_front_valid;wire[4:0]queue_level;
 assign queue_valid=queue_front_valid&&queue_level!=0;
 assign {queue_time,queue_keys}=queue_front[56:0];
 fms_record_fifo #(.DEPTH(16)) presses(clk,rst,start || stop || reconfigure,
  queue_input,{7'd0,time_us,rising},queue_ready,queue_pop,queue_front,queue_front_valid,queue_level,);
 assign query=state==REQUEST && running && !paused;
 assign query_index=index;
 assign time_wait=running && !paused && (state==CLEAR_SETTLED || (!effective_mode &&
  ((state!=TEACH_WAIT && state!=IDLE && hits+misses<count) || (targets!=0 && time_us>=group_start))));
 assign complete=running && hits+misses==count && time_us>=duration_us && (effective_mode || group_ends_pending==0);
 function[2:0]population5;input[4:0]v;begin case(v)
 5'd0:population5=3'd0;
 5'd1:population5=3'd1;
 5'd2:population5=3'd1;
 5'd3:population5=3'd2;
 5'd4:population5=3'd1;
 5'd5:population5=3'd2;
 5'd6:population5=3'd2;
 5'd7:population5=3'd3;
 5'd8:population5=3'd1;
 5'd9:population5=3'd2;
 5'd10:population5=3'd2;
 5'd11:population5=3'd3;
 5'd12:population5=3'd2;
 5'd13:population5=3'd3;
 5'd14:population5=3'd3;
 5'd15:population5=3'd4;
 5'd16:population5=3'd1;
 5'd17:population5=3'd2;
 5'd18:population5=3'd2;
 5'd19:population5=3'd3;
 5'd20:population5=3'd2;
 5'd21:population5=3'd3;
 5'd22:population5=3'd3;
 5'd23:population5=3'd4;
 5'd24:population5=3'd2;
 5'd25:population5=3'd3;
 5'd26:population5=3'd3;
 5'd27:population5=3'd4;
 5'd28:population5=3'd3;
 5'd29:population5=3'd4;
 5'd30:population5=3'd4;
 5'd31:population5=3'd5;
 endcase end endfunction
 function[5:0]population;input[24:0]bits;reg[3:0]a,b;begin
 a={1'b0,population5(bits[4:0])}+{1'b0,population5(bits[9:5])};
 b={1'b0,population5(bits[14:10])}+{1'b0,population5(bits[19:15])};
 population={2'd0,a}+{2'd0,b}+{3'd0,population5(bits[24:20])};
 end endfunction
 reg [5:0] teach_extra_record;
 // One synchronous read and one serialized write replace a 2048-bit FF bitmap
 // with several dynamic write decoders. A new round clears it in 2048 clocks;
 // the single musical clock is held for this short preparation in both modes.
 always @(posedge clk)begin
  settled_read<=settled[index];
  if(!rst)begin
   if(state==CLEAR_SETTLED)settled[clear_index]<=0;
   else if(running && !paused && !start && !stop && !reconfigure)begin
    if(state==EVALUATE && !settled_q && job!=JOB_STRIKE && expired)settled[index]<=1;
    else if(state==HIT_DONE && found)settled[best_index]<=1;
    else if(state==TEACH_COMMIT && targets[commit_key])settled[group_commit_index]<=1;
   end
  end
 end
 reg [24:0] error_record,clear_record;reg [2:0] status_record;
 integer k;
 always @(posedge clk)begin
  if(rst)begin
   previous<=0;millisecond<=0;feedback_ms<=0;wait_cycles<=0;accept_record<=0;
   green_feedback<=0;wrong<=0;timing_status<=0;overflow<=0;teach_extra_record<=0;
   error_record<=0;clear_record<=0;status_record<=0;late_members<=0;
  end else begin
   previous<=keys;millisecond<=ms_tick ? 0 : millisecond+1'b1;
   accept_record<=running && !paused && !effective_mode && state==TEACH_WAIT && full_chord;
   teach_extra_record<=!effective_mode && running && !paused ? population(rising & ~targets & ~carry) : 0;
   error_record<=0;clear_record<=0;status_record<=0;
   if((queue_input && !queue_ready)||release_overflow)overflow<=1;
   if(!waiting)wait_cycles<=0;else if(!paused && wait_cycles<CLK_HZ/5)wait_cycles<=wait_cycles+1'b1;
   if(running && !paused)begin
    if(!effective_mode && state==TEACH_WAIT)begin
     if(late)late_members<=late_members | (rising & targets & eligible);
     if({1'b0,time_us}+33'd200000<{1'b0,group_start} && (rising&targets)!=0)begin
      error_record<=rising&targets;status_record<=1;
     end else if(late && (targets&~strike_hits)!=0)begin error_record<=targets&~strike_hits;status_record<=2;end
     clear_record<=rising&targets;
    end
    if(!effective_mode && (rising&~targets&~carry)!=0)begin error_record<=rising&~targets&~carry;status_record<=2;end
    if(!effective_mode)begin
     for(k=0;k<25;k=k+1)begin
      if(release_fault_q[k])error_record[k]<=1;
      else if(release_clear_q[k])clear_record[k]<=1;
     end
     if(|release_fault_q)status_record<=|(last_release & release_late_q) ? 4 : 3;
    end
    if(error_record!=0)begin wrong<=(wrong & ~clear_record)|error_record;timing_status<=status_record;feedback_ms<=0;end
    else if(feedback_ms>=600)begin wrong<=0;green_feedback<=green_feedback&keys;timing_status<=0;end
    else begin wrong<=wrong&~clear_record;if(ms_tick)feedback_ms<=feedback_ms+1'b1;end
   end
   if(start || stop || reconfigure)begin
    accept_record<=0;error_record<=0;clear_record<=0;status_record<=0;wrong<=0;green_feedback<=0;
    wait_cycles<=0;feedback_ms<=0;timing_status<=0;teach_extra_record<=0;late_members<=0;
    if(start || stop)overflow<=0;
   end
   if(state==BUILD_DONE)late_members<=0;
   // Result colors are shared by both judging paths, while each score note is
   // settled only by the serialized main state machine below.
   if(state==HIT_DONE && running && !paused && !start && !stop && !reconfigure)begin
    if(found)begin green_feedback[strike_key]<=1;wrong[strike_key]<=0;end
    else begin wrong[strike_key]<=1;green_feedback[strike_key]<=0;end
    feedback_ms<=0;
   end
   if(state==TEACH_COMMIT && targets[commit_key] && running && !paused && !reconfigure && !stop)begin
    green_feedback[commit_key]<=1;wrong[commit_key]<=late_members[commit_key];feedback_ms<=0;
    if(late_members[commit_key])timing_status<=2;
   end
  end
 end
 reg picked;reg [4:0] picked_key;integer j;
 always @* begin
  picked=0;picked_key=0;
  for(j=0;j<25;j=j+1)if(press_mask[j] && !picked)begin picked=1;picked_key=j;end
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;job<=JOB_BUILD;index<=0;expire_index<=0;best_index<=0;settled_q<=0;note<=0;clear_index<=0;after_clear<=0;
   group_start<=0;best_time<=32'hffffffff;strike_time<=0;best_distance<=33'h1ffffffff;
   work_targets<=0;eligible<=0;group_ends_pending<=0;carry<=0;press_mask<=0;strike_key<=0;commit_key<=0;
   found<=0;group_found<=0;targets<=0;hits<=0;misses<=0;extras<=0;game_targets<=0;
   group_read_phase<=0;
  end else begin
   carry<=carry&keys;group_ends_pending<=group_ends_pending&keys;
   if(start || stop)begin
    hits<=0;misses<=0;extras<=0;targets<=0;press_mask<=0;carry<=keys;
    group_ends_pending<=0;expire_index<=0;index<=0;best_time<=32'hffffffff;work_targets<=0;group_found<=0;
    state<=CLEAR_SETTLED;clear_index<=0;after_clear<=start;job<=JOB_BUILD;
   end else if(reconfigure)begin
    targets<=0;press_mask<=0;carry<=keys;group_ends_pending<=0;index<=0;expire_index<=0;
    best_time<=32'hffffffff;work_targets<=0;group_found<=0;job<=JOB_BUILD;state<=state==CLEAR_SETTLED ? CLEAR_SETTLED : effective_mode ? IDLE : REQUEST;
   end else if(state==CLEAR_SETTLED)begin
    if(clear_index==2047)state<=after_clear && running && !effective_mode ? REQUEST : IDLE;
    else clear_index<=clear_index+1'b1;
   end else if(running && !paused)begin
    if(teach_extra_record!=0)extras<=({1'b0,extras}+teach_extra_record)>65535 ? 16'hffff : extras+teach_extra_record;
    case(state)
     IDLE:if(effective_mode && count!=0)begin
      if(press_mask!=0)begin
       strike_key<=picked_key;press_mask[picked_key]<=0;index<=0;found<=0;best_distance<=33'h1ffffffff;job<=JOB_STRIKE;state<=REQUEST;
      end else if(queue_valid)begin press_mask<=queue_keys;strike_time<=queue_time;end
      else begin index<=expire_index;job<=JOB_EXPIRE;state<=REQUEST;end
     end
     REQUEST:if(query_ready)state<=WAIT_NOTE;
     WAIT_NOTE:if(response)begin note<=note_data;settled_q<=settled_read;state<=EVALUATE;end
     EVALUATE:begin
      if(!settled_q)begin
       if(job==JOB_BUILD)begin
        if(expired)begin misses<=misses+1'b1;end
        else if(!group_found || start_us<best_time)begin
         group_found<=1;best_time<=start_us;work_targets<=25'd1<<lane;
        end else if(start_us==best_time)begin work_targets[lane]<=1;end
       end else if(job==JOB_EXPIRE)begin
        if(expired)begin misses<=misses+1'b1;end
       end else if(pitch=={2'd0,strike_key}+7'd48 && distance<=200000 && (!found || distance<best_distance || (distance==best_distance && index<best_index)))begin
        found<=1;best_index<=index;best_distance<=distance;
       end
      end
      if(job==JOB_EXPIRE)begin
       game_targets<=(index==0 ? 25'd0 : game_targets) | (!settled_q && !expired && {1'b0,start_us}<={1'b0,time_us}+33'd200000 ? 25'd1<<lane : 25'd0);
       if(index+1>=count)targets<=(index==0 ? 25'd0 : game_targets) | (!settled_q && !expired && {1'b0,start_us}<={1'b0,time_us}+33'd200000 ? 25'd1<<lane : 25'd0);
       expire_index<=index+1>=count ? 0 : index+1'b1;state<=IDLE;
      end
      else if(index+1>=count)state<=job==JOB_BUILD ? BUILD_DONE : HIT_DONE;
      else begin index<=index+1'b1;state<=REQUEST;end
     end
     BUILD_DONE:if(!group_writing)begin
      targets<=work_targets;group_start<=best_time;eligible<=~keys;
      state<=group_found ? TEACH_WAIT : IDLE;
     end
     TEACH_WAIT:begin
      if({1'b0,time_us}+33'd200000<{1'b0,group_start})eligible<=~keys;
      else eligible<=eligible|~keys;
      if(accept_record)begin commit_key<=0;group_read_phase<=0;state<=TEACH_LOAD;end
     end
     TEACH_LOAD:if(group_read_phase==5)state<=TEACH_COMMIT;else group_read_phase<=group_read_phase+1'b1;
     TEACH_COMMIT:begin
      if(targets[commit_key])begin
       // BUILD selected only unsettled, distinct note indices, and no other
       // settlement job runs during this chord's serialized commit.
       hits<=hits+1'b1;
       carry[commit_key]<=keys[commit_key];group_ends_pending[commit_key]<=keys[commit_key];
      end
      if(commit_key==24)begin
       targets<=0;index<=0;best_time<=32'hffffffff;group_found<=0;work_targets<=0;job<=JOB_BUILD;state<=REQUEST;
      end else begin commit_key<=commit_key+1'b1;group_read_phase<=0;state<=TEACH_LOAD;end
     end
     HIT_DONE:begin
      if(found)begin hits<=hits+1'b1;end
      else extras<=extras==65535 ? extras : extras+1'b1;
      state<=IDLE;
     end
    endcase
   end else if(paused)begin
    // Preserve a valid partial chord held across pause; a NEW press during
    // pause is ineligible until released, matching the ignored-input policy.
    eligible<=eligible & ~rising;
    if(state==WAIT_NOTE && response)begin note<=note_data;settled_q<=settled_read;state<=EVALUATE;end
   end
  end
 end
 // Arithmetic captured with the same note response; no extra state/cycle.
 always @(posedge clk)begin
  if(rst)begin note_deadline_q<=0;distance_q<=0;end
  else if(state==WAIT_NOTE && response)begin
   note_deadline_q<={1'b0,note_data[31:0]}+33'd200000;distance_q<=incoming_distance;
  end
 end
endmodule

module practice_release_checks(input wire clk,rst,enabled,input wire[31:0]time_us,
 input wire[24:0]pending,falling,keys,input wire deadline_we,input wire[4:0]deadline_wa,input wire[31:0]deadline_wd,
 output reg[24:0]faults,late_flags,clears,output reg overflow);
 reg busy,edge_frame;reg[4:0]lane;reg[31:0]stamp;
 reg[24:0]p,f,k,fb,lb,cb;
 // One lookahead read preserves the original26-clock scan and edge timestamp.
 // Validity comes from the job's pending mask; RAM does not need a bulk reset.
 (* syn_ramstyle="block_ram" *)reg[31:0]deadlines[0:31];reg[31:0]deadline;
 wire[4:0]read_lane=(falling!=0||!busy) ? 5'd0 : lane+5'd1;
 always @(posedge clk)begin
  if(deadline_we)deadlines[deadline_wa]<=deadline_wd;
  deadline<=deadline_we&&deadline_wa==read_lane ? deadline_wd : deadlines[read_lane];
 end
 wire early=p[lane]&&f[lane]&&({1'b0,stamp}+33'd300000<{1'b0,deadline});
 wire late=p[lane]&&(f[lane]||k[lane])&&!early&&stamp>300000&&(stamp-32'd300000)>deadline;
 wire clean=p[lane]&&f[lane]&&!early&&!late;
 wire[24:0]mask=25'd1<<lane;
 always @(posedge clk)begin
  if(rst||!enabled)begin busy<=0;edge_frame<=0;lane<=0;stamp<=0;p<=0;f<=0;k<=0;fb<=0;lb<=0;cb<=0;faults<=0;late_flags<=0;clears<=0;overflow<=0;end
  else begin
   faults<=0;late_flags<=0;clears<=0;overflow<=0;
   // Edge jobs preempt only a periodic held-note scan. With the actual
   // coherent producer another falling group cannot arrive before completion.
   if(falling!=0||!busy)begin
    if(falling!=0&&busy&&edge_frame)overflow<=1;
    busy<=1;edge_frame<=falling!=0;lane<=0;stamp<=time_us;p<=pending;f<=falling;k<=keys;fb<=0;lb<=0;cb<=0;
   end else begin
    if(early||late)fb[lane]<=1;
    if(late)lb[lane]<=1;
    if(clean)cb[lane]<=1;
    if(lane==24)begin
     faults<=fb|((early||late) ? mask : 25'd0);late_flags<=lb|(late ? mask : 25'd0);clears<=cb|(clean ? mask : 25'd0);busy<=0;edge_frame<=0;
    end else lane<=lane+1'b1;
   end
  end
 end
endmodule
