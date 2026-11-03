// V14 single-note heap plus indexes; derived from the frozen W6 parser.
// Transactional FMS ingestion. Raw FMS stays raw on UART/SD; compact decoded
// events and guide notes share one stopped-only score RAM. A started load
// invalidates the previous score; only full validation + commit makes it usable.
module fms_store #(parameter MAX_EVENTS=4096,MAX_NOTES=2048,LOAD_VOICES=12)(
 input wire clk,rst,start,abort,input wire [31:0] input_size,input_crc,
 input wire byte_valid,output wire byte_ready,input wire [7:0] byte_data,
 output reg busy,load_done,staged_valid,output reg [7:0] load_error,
 input wire commit,output reg score_valid,output reg [31:0] generation,
 output reg [15:0] song_id,note_count,output reg [12:0] event_count,
 output reg [31:0] duration_us,nominal_us,output wire [383:0] title,
 output reg [1:0] melody_track,output wire [543:0] patches,
 output wire [67:0] gains,output wire [15:0] presets,
 input wire [11:0] event_address,output reg [71:0] event_data,
 input wire [10:0] note_address,output reg [79:0] note_data,
 input wire invalidate,score_owner,
 input wire event_request,output wire event_ready,output wire event_valid,input wire event_accept,
 input wire note_request,output wire note_ready,output wire note_valid,input wire note_accept,
 output wire heap_we,output wire[11:0]heap_wa,output wire[47:0]heap_wd,
 output wire[11:0]heap_ra,input wire[47:0]heap_rd
);
 assign title=score_valid ? title_work : 384'd0;
 assign patches=score_valid ? patches_work : 544'd0;
 assign gains=score_valid ? gains_work : 68'd0;
 assign presets=score_valid ? presets_work : 16'd0;
 `include "fms_functions.vh"
 `include "fms_capacity.vh"
 localparam IDLE=0,CLEAR=1,BYTES=2,TRACK=3,HEADER=4,EVENT=5,
 SEEN_READ=6,SEEN_CHECK=7,SCAN=8,ON_WRITE=9,OFF_WRITE=10,EVENT_WRITE=11,FINAL=12,SLOT_WAIT=13,SLOT_READ=14,SLOT_WRITE=15;
 localparam TOKEN_WAIT=16,G_BEGIN=17,G_WAIT=18,G_LOW=19,G_HIGH0=20,G_HIGH1=21,G_HIGH=22;
 reg [4:0] state;
 reg[12:0] heap_top;reg[11:0] current_heap,all_notes,token_scan,build_index,build_count;
 reg[47:0] build_low;
 // During load: original tokens, serial exact duplicate detection. After
 // CRC/pairing validation: same RAM becomes the main-note -> heap index.
 (* syn_ramstyle="block_ram" *)reg[15:0] token_memory[0:2047];reg[15:0] token_q;
 // start validates the full32bit input before either counter is written.
 // Accepted size<=512+MAX_EVENTS*16, position advances only while<size.
 // Default4096events therefore needs17bits rather than32, with no new cycle.
 localparam FILE_COUNT_WIDTH=$clog2(512+MAX_EVENTS*16+1);
 reg [FILE_COUNT_WIDTH-1:0] position,size;
 reg [31:0] expected_crc,file_crc,header_crc,event_crc,caps;
 reg[159:0] head_variables;reg[63:0]head_crcs;reg[15:0]head_song_id;reg head_fixed_invalid;
 wire[511:0]head={16'd8249,head_song_id,64'h003153554d2d3756,head_crcs,8'd8,8'd32,16'd1040,32'd50000000,head_variables,64'h0010020000000001,64'h0031474e534d4746};reg[7:0] track_public;reg[1:0]track_role;reg[16:0]track_gain;
 reg[2:0]track_release;reg track_invalid;
 wire[3:0]track_internal=fms_internal(track_public);
 wire[135:0]track_patch=fms_patch(track_public,track_release);
 // Only variable fields are retained. Fixed bytes are checked on arrival;
 // TRACK reports the same error at the same original boundary.
 wire[255:0]track_record={40'd0,(track_public==6 ? 8'd9 : {6'd0,track_number}),
  fms_gm(track_public),track_patch,15'd0,track_gain,{4'd0,track_internal},track_public,{6'd0,track_role},8'd1};
 wire[135:0]incoming_patch=fms_patch(track_public,byte_data[5:3]);
 wire[7:0]expected_patch_byte=incoming_patch[(position[4:0]-5'd8)*8+:8];reg track_nonzero,event_reserved_nonzero;reg [383:0] title_work;
 reg [79:0] event_record;
 reg [12:0] events_seen;reg [15:0] notes_seen;reg [2:0] main_tracks;
 reg [1:0] main_work,track_number;wire [543:0] patches_work;
 // Every accepted file patch is already checked against fms_patch(pub,tail).
 // Keep only its variable tail index; presets_work already retains publicID.
 // 4'hf marks an absent track and must still expose an all-zero patch.
 reg[11:0]patch_release_work;genvar pp;
 generate for(pp=0;pp<4;pp=pp+1)begin:canonical_patch
  assign patches_work[pp*136+:136]=presets_work[pp*4+:4]==4'hf ? 136'd0 :
   fms_patch({4'd0,presets_work[pp*4+:4]},patch_release_work[pp*3+:3]);
 end endgenerate
 reg [67:0] gains_work;reg [15:0] presets_work;reg [7:0] roles_work;
 reg [31:0] last_time;reg [1:0] last_event_priority;
 reg [5:0] scan;reg found,free_found,same_pitch;reg [4:0] match_slot,free_slot;
 reg [LOAD_VOICES-1:0] held_mask,slot_valid;reg [31:0] drum_end[0:3];reg tail_pending;reg [5:0] scan_weight;
 reg [4:0] write_slot;
 // Load-time held-note metadata: LOAD_VOICES complete 80-bit records in one narrow RAM.
 // Playback score RAM is separate. Five 16-bit beats avoid 2432 FFs/mux trees;
 // validity remains in held_mask, so stale RAM is never semantically visible.
 (* syn_ramstyle="block_ram" *) reg [15:0] slot_memory[0:255];
 reg [15:0] slot_word;reg [2:0] slot_beat;reg [79:0] slot_record,matched_record,write_record;
 wire [7:0] slot_address={state==SLOT_WRITE ? write_slot : scan[4:0],slot_beat};
 always @(posedge clk)begin
  // GW5AT-60B SP RAM supports write-through, not inferred read-before-write.
  // The loader never consumes slot_word while writing; explicit forwarding
  // gives the supported mode without changing any read/request latency.
  if(state==SLOT_WRITE)begin
   slot_memory[slot_address]<=write_record[slot_beat*16+:16];
   slot_word<=write_record[slot_beat*16+:16];
  end else slot_word<=slot_memory[slot_address];
 end
 wire [15:0] slot_token=slot_record[15:0];wire [1:0] slot_track=slot_record[16+:2];
 wire [6:0] slot_pitch=slot_record[18+:7];
 // The active descriptor is held in the output registers. There is exactly
 // one in-flight staging transaction, whose validated descriptor remains in
 // the working registers until commit/start/abort. Two additional descriptor
 // banks would duplicate both records without adding transactional safety.
 reg text_nul;reg [1:0] text_left;reg [7:0] text_min,text_max;
 wire [31:0] total_events=head[16*8+:32],duration=head[20*8+:32],musical_end=head[24*8+:32];
 wire [7:0] track_count=head[34*8+:8];
 wire [31:0] t=event_record[31:0];wire [15:0] token=event_record[47:32];
 wire [7:0] op=event_record[55:48],et=event_record[63:56],pitch=event_record[71:64],vel=event_record[79:72];
 wire [1:0] event_priority=op==2 ? 0 : op==1 ? 1 : op==3 ? 2 : 3;
 wire [7:0] pub=track_record[23:16];wire [3:0] internal=fms_internal(pub);
 wire [135:0] patch=track_record[64+:136];
 wire in_text=(position>=64 && position<192) || (position>=256 && position[5:0]>=32);
 wire text_start=position==64 || position==112 || position==160 || (position>=256 && position[5:0]==32);
 wire text_end=position==111 || position==159 || position==191 || (position>=256 && position[5:0]==63);
 wire slot_in_use=slot_valid[scan[4:0]] && (!slot_record[77] || slot_record[25+:32]>t);
 wire [4:0] free_now=!free_found&&!slot_in_use ? scan[4:0] : free_slot;
 wire any_drum=presets_work[3:0]==6 || presets_work[7:4]==6 || presets_work[11:8]==6 || presets_work[15:12]==6;
 assign byte_ready=busy && state==BYTES && position<size && !abort && !score_owner;
 // Chronological list is only16 bits/event; ON/OFF share the one full note.
 wire[15:0] descriptor_write=op==127 ? 16'd0 : {et[1:0],op[1:0],
  op==1 ? current_heap : op==2 ? matched_record[65+:12] : heap_top[11:0]};
 wire[15:0] descriptor_q;
 reg[11:0] timeline_ra;
 fms_packed_ram #(.WIDTH(16),.ADDR(12)) timeline(clk,state==EVENT_WRITE,events_seen[11:0],descriptor_write,timeline_ra,descriptor_q);
 reg[3:0] reader;reg read_note;reg[10:0] guide_ra;reg[15:0] descriptor;
 reg[11:0] read_heap;reg[47:0] read_low;
 assign event_ready=reader==0 && !busy && !score_owner && !rst;
 assign note_ready=event_ready && !event_request;
 assign event_valid=reader==9 && !read_note;
 assign note_valid=reader==9 && read_note;
 wire[10:0] token_ra=busy ? token_scan[10:0] : guide_ra;
 wire build_index_write=state==G_HIGH && heap_rd[33:32]==main_work;
 always @(posedge clk)begin
  token_q<=token_memory[token_ra];
  if(state==ON_WRITE)token_memory[all_notes[10:0]]<=token;
  else if(build_index_write)token_memory[build_count[10:0]]<={4'd0,build_index};
 end
 assign heap_we=!score_owner && ((state==ON_WRITE) ||
   (state==SLOT_WRITE && slot_beat==0 && op==1) || state==OFF_WRITE || (state==EVENT_WRITE && op==3));
 assign heap_wa=state==ON_WRITE || (state==EVENT_WRITE && op==3) ? heap_top[11:0] :
   state==OFF_WRITE ? matched_record[65+:12]+12'd1 : current_heap+12'd1;
 assign heap_wd=state==ON_WRITE ? {1'b1,vel,pitch[6:0],t} :
  (state==EVENT_WRITE && op==3) ? {1'b0,1'b0,et[1:0],vel,pitch[3:0],t} :
  {14'd0,et[1:0],state==OFF_WRITE ? t : 32'd0};
 wire build_high=state==G_HIGH0 || state==G_HIGH1 || state==G_HIGH;
 assign heap_ra=busy ? (build_high ? build_index+12'd1 : build_index) :
  ((reader==6 || reader==7 || reader==8) ? read_heap+12'd1 : read_heap);
 // Variable-latency, bounded handshake. Event fetch wins; guide queries cannot
 // change a pending response or feed display stalls into the audio scheduler.
 always @(posedge clk)begin
  if(rst || invalidate || start || score_owner)begin
   reader<=0;read_note<=0;guide_ra<=0;timeline_ra<=0;descriptor<=0;read_heap<=0;read_low<=0;event_data<=0;note_data<=0;
  end else case(reader)
   0:if(event_request && event_ready)begin read_note<=0;timeline_ra<=event_address;reader<=1;end
     else if(note_request && note_ready)begin read_note<=1;guide_ra<=note_address;reader<=1;end
   1:reader<=2;
   2:if(read_note)begin read_heap<=token_q[11:0];reader<=3;end
     else if(descriptor_q[13:12]==0)begin event_data<={40'd0,duration_us};reader<=9;end
     else begin descriptor<=descriptor_q;read_heap<=descriptor_q[11:0];reader<=3;end
   3:reader<=4;
   4:reader<=5;
   5:begin
    read_low<=heap_rd;
    if(read_note || descriptor[13:12]==2)reader<=6;
    else begin
     event_data<={5'd0,descriptor[13:12]==3 ? heap_rd[43:36] : heap_rd[46:39],
      descriptor[13:12]==3 ? {3'd0,heap_rd[35:32]} : heap_rd[38:32],
      descriptor[15:14],descriptor[13:12],descriptor[13:12]==3 ? 16'd0 : {4'd0,read_heap}+16'd1,heap_rd[31:0]};
     reader<=9;
    end
   end
   6:reader<=7;
   7:reader<=8;
   8:begin
    if(read_note)note_data<={1'b0,read_low[46:39],read_low[38:32],heap_rd[31:0],read_low[31:0]};
    else event_data<={5'd0,8'd255,read_low[38:32],descriptor[15:14],2'd2,{4'd0,read_heap}+16'd1,heap_rd[31:0]};
    reader<=9;
   end
   9:if(read_note ? note_accept : event_accept)reader<=0;
   default:reader<=0;
  endcase
 end
 task fail;input [7:0] code;begin
  load_error<=code;busy<=0;staged_valid<=0;load_done<=1;state<=IDLE;
 end endtask
 wire [3:0] event_preset=presets_work[et[1:0]*4+:4];
 wire [135:0] event_patch=patches_work[et[1:0]*136+:136];
 wire [31:0] automatic_tail=fms_melodic_tail(event_preset,patch_release_work[et[1:0]*3+:3]);
 wire [31:0] accepted_tail=et==main_work && automatic_tail<113776 ? 113776 : automatic_tail;
 wire [5:0] weight_now=scan_weight+(slot_in_use ? (slot_track==main_work ? 6'd2 : 6'd1) : 6'd0);
 // Event bytes are complete before EVENT and remain immutable through the
 // slot scan. Precompute during that existing work, without adding a state,
 // parser backpressure or any audio-clock latency. Keep the overflow bit.
 reg [32:0] release_end;
 always @(posedge clk)release_end<={1'b0,t}+{1'b0,accepted_tail};
 // synthesis translate_off
 always @(posedge clk)if(!rst&&!invalidate&&!abort&&state==OFF_WRITE)
  if(release_end!==({1'b0,t}+{1'b0,accepted_tail}))
   $fatal(1,"release_end precompute used before event became stable");
 // synthesis translate_on
 wire [32:0] drum_deadline={1'b0,t}+{1'b0,fms_drum_tail(pitch[3:0])};
 wire drum_free=drum_end[0]<=t || drum_end[1]<=t || drum_end[2]<=t || drum_end[3]<=t;
 wire [1:0] drum_slot=drum_end[0]<=t ? 0 : drum_end[1]<=t ? 1 : drum_end[2]<=t ? 2 : 3;
 function[7:0]fixed_header_byte;input[5:0]offset;begin case(offset)
 6'd0:fixed_header_byte=8'd70;
 6'd1:fixed_header_byte=8'd71;
 6'd2:fixed_header_byte=8'd77;
 6'd3:fixed_header_byte=8'd83;
 6'd4:fixed_header_byte=8'd78;
 6'd5:fixed_header_byte=8'd71;
 6'd6:fixed_header_byte=8'd49;
 6'd7:fixed_header_byte=8'd0;
 6'd8:fixed_header_byte=8'd1;
 6'd9:fixed_header_byte=8'd0;
 6'd10:fixed_header_byte=8'd0;
 6'd11:fixed_header_byte=8'd0;
 6'd12:fixed_header_byte=8'd0;
 6'd13:fixed_header_byte=8'd2;
 6'd14:fixed_header_byte=8'd16;
 6'd15:fixed_header_byte=8'd0;
 6'd36:fixed_header_byte=8'd128;
 6'd37:fixed_header_byte=8'd240;
 6'd38:fixed_header_byte=8'd250;
 6'd39:fixed_header_byte=8'd2;
 6'd40:fixed_header_byte=8'd16;
 6'd41:fixed_header_byte=8'd4;
 6'd42:fixed_header_byte=8'd32;
 6'd43:fixed_header_byte=8'd8;
 6'd52:fixed_header_byte=8'd86;
 6'd53:fixed_header_byte=8'd55;
 6'd54:fixed_header_byte=8'd45;
 6'd55:fixed_header_byte=8'd77;
 6'd56:fixed_header_byte=8'd85;
 6'd57:fixed_header_byte=8'd83;
 6'd58:fixed_header_byte=8'd49;
 6'd59:fixed_header_byte=8'd0;
 6'd62:fixed_header_byte=8'd57;
 6'd63:fixed_header_byte=8'd32;
 default:fixed_header_byte=0;endcase end endfunction

 // A successful load necessarily writes all48 bytes before score_valid.
 // Invalid/staged titles are externally zero. No reset/whole-word shift is
 // needed for this private scratch register; never publish a partial title.
 genvar title_bank;
 generate for(title_bank=0;title_bank<48;title_bank=title_bank+1)begin:title_bytes
  always @(posedge clk)
   if(!rst&&!invalidate&&!abort&&!(start&&!busy&&!score_owner)&&
      state==BYTES&&position<size&&byte_valid&&byte_ready&&position==64+title_bank)
    title_work[title_bank*8+:8]<=byte_data;
 end endgenerate
 integer i;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;busy<=0;load_done<=0;load_error<=0;staged_valid<=0;
   score_valid<=0;generation<=0;song_id<=0;note_count<=0;event_count<=0;duration_us<=0;nominal_us<=0;
   melody_track<=0;position<=0;size<=0;heap_top<=0;current_heap<=0;all_notes<=0;token_scan<=0;build_index<=0;build_count<=0;build_low<=0;
   expected_crc<=0;file_crc<=32'hffffffff;header_crc<=32'hffffffff;event_crc<=32'hffffffff;caps<=0;
   head_variables<=0;head_crcs<=0;head_song_id<=0;head_fixed_invalid<=0;track_public<=0;track_role<=0;track_gain<=0;track_release<=0;track_invalid<=0;track_nonzero<=0;event_reserved_nonzero<=0;event_record<=0;events_seen<=0;notes_seen<=0;main_tracks<=0;
   main_work<=0;track_number<=0;patch_release_work<=0;gains_work<=0;presets_work<=16'hffff;roles_work<=0;
   last_time<=0;last_event_priority<=0;held_mask<=0;slot_valid<=0;tail_pending<=0;write_slot<=0;for(i=0;i<4;i=i+1)drum_end[i]<=0;scan<=0;scan_weight<=0;found<=0;free_found<=0;same_pitch<=0;match_slot<=0;free_slot<=0;
   text_nul<=0;text_left<=0;text_min<=8'h80;text_max<=8'hbf;slot_beat<=0;slot_record<=0;matched_record<=0;write_record<=0;
  end else begin
   load_done<=0;
   if(commit && staged_valid && !busy)begin
    staged_valid<=0;score_valid<=1;generation<=generation+1'b1;
    song_id<=head[60*8+:16];note_count<=notes_seen;event_count<=events_seen;
    duration_us<=duration;nominal_us<=head[28*8+:32];
    melody_track<=main_work;
   end
   if(invalidate)begin busy<=0;staged_valid<=0;score_valid<=0;generation<=generation+1'b1;song_id<=0;note_count<=0;event_count<=0;state<=IDLE;held_mask<=0;end
   else if(abort)begin busy<=0;staged_valid<=0;load_error<=0;state<=IDLE;held_mask<=0;end
   else if(start && !busy && !score_owner)begin
    staged_valid<=0;load_error<=0;
    if(input_size<1024 || input_size>512+MAX_EVENTS*16 || input_size[8:0]!=0)fail(1);
    else begin
     busy<=1;position<=0;size<=input_size[FILE_COUNT_WIDTH-1:0];heap_top<=0;current_heap<=0;all_notes<=0;token_scan<=0;build_index<=0;build_count<=0;expected_crc<=input_crc;
     score_valid<=0;song_id<=0;note_count<=0;event_count<=0;duration_us<=0;nominal_us<=0;
     melody_track<=0;
     file_crc<=32'hffffffff;header_crc<=32'hffffffff;event_crc<=32'hffffffff;
     head_variables<=0;head_crcs<=0;head_song_id<=0;head_fixed_invalid<=0;track_public<=0;track_role<=0;track_gain<=0;track_release<=0;track_invalid<=0;track_nonzero<=0;event_reserved_nonzero<=0;event_record<=0;events_seen<=0;notes_seen<=0;main_tracks<=0;
     main_work<=0;patch_release_work<=0;gains_work<=0;presets_work<=16'hffff;roles_work<=0;caps<=0;
     held_mask<=0;slot_valid<=0;tail_pending<=0;for(i=0;i<4;i=i+1)drum_end[i]<=0;last_time<=0;last_event_priority<=0;text_nul<=0;text_left<=0;state<=CLEAR;
    end
   end else case(state)
    CLEAR:state<=BYTES;
    BYTES:if(position==size)state<=FINAL;
    else if(byte_valid && byte_ready)begin
     position<=position+1'b1;file_crc<=fms_crc(file_crc,byte_data);
     if(position<512)begin
      header_crc<=fms_crc(header_crc,(position>=48 && position<52) ? 8'd0 : byte_data);
      if(position<64)begin
       if(position>=16&&position<36)head_variables<={byte_data,head_variables[159:8]};
       else if(position>=44&&position<52)head_crcs<={byte_data,head_crcs[63:8]};
       else if(position>=60&&position<62)head_song_id<={byte_data,head_song_id[15:8]};
       else if(byte_data!=fixed_header_byte(position[5:0]))head_fixed_invalid<=1;
      end
      // Title bytes use independent eight-bit banks below.
      if(position>=192 && position<196)caps<={byte_data,caps[31:8]};
      if(position>=196 && position<256 && byte_data!=0)fail(2);
      if(position>=256)begin
       // Text bytes are validated by the unchanged streaming UTF-8 parser.
       // Keep an all64-byte nonzero flag for absent-track rejection.
       case(position[5:0])
        0:track_invalid<=byte_data!=1;
        1:begin track_role<=byte_data[1:0];if(byte_data>3)track_invalid<=1;end
        2:track_public<=byte_data;
        3:if(byte_data!={4'd0,track_internal})track_invalid<=1;
        4:track_gain[7:0]<=byte_data;
        5:track_gain[15:8]<=byte_data;
        6:begin track_gain[16]<=byte_data[0];if(byte_data[7:1]!=0)track_invalid<=1;end
        7:if(byte_data!=0)track_invalid<=1;
        25:if(byte_data!=fms_gm(track_public))track_invalid<=1;
        26:if(byte_data!=(track_public==6 ? 8'd9 : {6'd0,position[7:6]}))track_invalid<=1;
        27,28,29,30,31:if(byte_data!=0)track_invalid<=1;
        default:if(position[5:0]>=8&&position[5:0]<=24)begin
         if(byte_data!=expected_patch_byte)track_invalid<=1;
         if(position[5:0]==22)track_release<=byte_data[5:3];
        end
       endcase
       track_nonzero<=position[5:0]==0 ? byte_data!=0 : track_nonzero||(byte_data!=0);
       if(position[5:0]==63)begin track_number<=(position-256)>>6;state<=TRACK;end
      end
      if(in_text)begin
       if(text_start)begin text_nul<=byte_data==0;text_left<=0;text_min<=8'h80;text_max<=8'hbf;end
       if((text_start || text_left==0) && (!text_nul || text_start))begin
        if(byte_data==0)text_nul<=1;
        else if(byte_data<128)text_left<=0;
        else if(byte_data>=8'hc2 && byte_data<=8'hdf)begin text_left<=1;text_min<=8'h80;text_max<=8'hbf;end
        else if(byte_data>=8'he0 && byte_data<=8'hef)begin text_left<=2;text_min<=byte_data==8'he0 ? 8'ha0 : 8'h80;text_max<=byte_data==8'hed ? 8'h9f : 8'hbf;end
        else if(byte_data>=8'hf0 && byte_data<=8'hf4)begin text_left<=3;text_min<=byte_data==8'hf0 ? 8'h90 : 8'h80;text_max<=byte_data==8'hf4 ? 8'h8f : 8'hbf;end
        else fail(3);
       end else if(text_nul)begin if(byte_data!=0)fail(3);end
       else if(byte_data<text_min || byte_data>text_max)fail(3);
       else begin text_left<=text_left-1'b1;text_min<=8'h80;text_max<=8'hbf;end
       if(text_end && !(byte_data==0 && text_left==0) && !text_nul)fail(3);
      end
     end else if(position<512+total_events*16)begin
      if(position[3:0]<10)event_record<={byte_data,event_record[79:8]};
      if(position[3:0]==0)event_reserved_nonzero<=0;
      else if(position[3:0]>=10&&byte_data!=0)event_reserved_nonzero<=1;
      event_crc<=fms_crc(event_crc,byte_data);
      if(position[3:0]==15)state<=EVENT;
     end else if(byte_data!=0)fail(2);
    end
    TRACK:begin
     if({6'd0,track_number}>=track_count)begin
      if(track_nonzero)fail(4);else state<=track_number==3 ? HEADER : BYTES;
     end else if(track_invalid || track_record[7:0]!=1 || track_record[15:8]>3 || internal==15 ||
       track_record[31:24]!={4'd0,internal} || track_record[32+:32]>65536 ||
       ((track_record[15:8]==3)!=(pub==6)) || patch!=fms_patch(pub,patch[117:115]) ||
       track_record[200+:8]!=fms_gm(pub) || track_record[208+:8]!=(pub==6 ? 8'd9 : {6'd0,track_number}) ||
       track_record[216+:40]!=0)fail(4);
     else begin
      patch_release_work[track_number*3+:3]<=patch[117:115];gains_work[track_number*17+:17]<=track_record[32+:17];
      presets_work[track_number*4+:4]<=pub[3:0];roles_work[track_number*2+:2]<=track_record[9:8];
      if(track_record[15:8]==0)begin main_tracks<=main_tracks+1'b1;main_work<=track_number;end
      state<=track_number==3 ? HEADER : BYTES;
     end
    end
    HEADER:begin
     if(head_fixed_invalid || head[63:0]!=64'h0031474e534d4746 || head[64+:64]!=64'h0010020000000001 ||
       head[52*8+:64]!=64'h003153554d2d3756 || total_events==0 || total_events>MAX_EVENTS ||
       ((512+total_events*16+511)&32'hfffffe00)!=size || duration==0 || musical_end==0 || musical_end>duration ||
       head[28*8+:32]<100000 || head[28*8+:32]>3000000 ||
       head[32*8+:8]<1 || head[32*8+:8]>12 || head[33*8+:8]<1 || head[33*8+:8]>4 ||
       track_count<1 || track_count>4 || head[35*8+:8]>31 || head[35*8+:2]!=3 ||
       head[36*8+:32]!=50000000 || head[40*8+:16]!=1040 || head[42*8+:8]!=32 || head[43*8+:8]!=8 ||
       (head[35*8+2]!=any_drum) || caps!=(any_drum ? 7 : 3) || main_tracks!=1 || head[60*8+:16]==0 || head[62*8+:16]!=8249)fail(5);
     else if((header_crc^32'hffffffff)!=head[48*8+:32])fail(6);
     else state<=BYTES;
    end
    EVENT:begin
     if(event_reserved_nonzero || (op!=1 && op!=2 && op!=3 && op!=127) || t>duration ||
       (events_seen!=0 && (t<last_time || (t==last_time && event_priority<last_event_priority))))fail(7);
     else if(op==127)begin
      if(events_seen+1!=total_events || t!=duration || event_record[32+:48]!=128'h7f0000 || held_mask!=0)fail(8);
      else if(drum_end[0]>t || drum_end[1]>t || drum_end[2]>t || drum_end[3]>t)fail(16);
      else begin scan<=0;scan_weight<=0;tail_pending<=0;slot_beat<=0;state<=SLOT_WAIT;end
     end else if(events_seen+1>=total_events || et>=track_count || t>musical_end)fail(7);
     else if(op==3)begin
      if(roles_work[et[1:0]*2+:2]!=3 || token!=0 || vel==0 || !(pitch<=9 || pitch==12 || pitch==13))fail(9);
      else if(!drum_free)fail(15);
      else if(drum_deadline[32] || drum_deadline>duration)fail(16);
      else begin drum_end[drum_slot]<=drum_deadline[31:0];state<=EVENT_WRITE;end
     end else if(roles_work[et[1:0]*2+:2]==3 || token==0)fail(9);
     else if(op==1)begin
      if(vel==0 || pitch>84 || pitch<(fms_internal({4'd0,presets_work[et[1:0]*4+:4]})==7 ? 24 : 36) ||
       (et==main_work && (pitch<48 || pitch>72 || notes_seen>=MAX_NOTES)))fail(10);
      else state<=SEEN_READ;
     end else if(vel!=255)fail(9);
     else begin scan<=0;scan_weight<=0;found<=0;free_found<=0;same_pitch<=0;slot_beat<=0;state<=SLOT_WAIT;end
    end
    SEEN_READ:begin token_scan<=0;if(all_notes==0)begin scan<=0;scan_weight<=0;found<=0;free_found<=0;same_pitch<=0;slot_beat<=0;state<=SLOT_WAIT;end else state<=TOKEN_WAIT;end
    TOKEN_WAIT:state<=SEEN_CHECK;
    SEEN_CHECK:if(token_q==token)fail(11);
     else if(token_scan+12'd1>=all_notes)begin scan<=0;scan_weight<=0;found<=0;free_found<=0;same_pitch<=0;slot_beat<=0;state<=SLOT_WAIT;end
     else begin token_scan<=token_scan+1'b1;state<=TOKEN_WAIT;end
    SLOT_WAIT:state<=SLOT_READ;
    SLOT_READ:begin
     slot_record<={slot_word,slot_record[79:16]};
     if(slot_beat==4)state<=SCAN;
     else begin slot_beat<=slot_beat+1'b1;state<=SLOT_WAIT;end
    end
    SCAN:begin
     scan_weight<=weight_now;
     if(held_mask[scan[4:0]] && slot_token==token)begin found<=1;match_slot<=scan[4:0];matched_record<=slot_record;end
     if(!slot_in_use && !free_found)begin free_found<=1;free_slot<=scan[4:0];end
     if(held_mask[scan[4:0]] && slot_track==main_work && slot_pitch==pitch)same_pitch<=1;
     if(op==127 && slot_in_use)tail_pending<=1;
     if(scan==LOAD_VOICES-1)begin
      if(op==127)begin if(tail_pending || slot_in_use)fail(16);else state<=EVENT_WRITE;end
      else if(op==1)begin
       if(et==main_work && (same_pitch || (held_mask[LOAD_VOICES-1] && slot_track==main_work && slot_pitch==pitch)))fail(14);
       else if(found || (held_mask[LOAD_VOICES-1] && slot_token==token))fail(12);
       else if(!(free_found || !slot_in_use) || weight_now+(et==main_work ? 6'd2 : 6'd1)>16)fail(15);
       else begin free_slot<=free_now;state<=ON_WRITE;end
      end else if(!(found || (held_mask[LOAD_VOICES-1] && slot_token==token)))fail(13);
      else begin if(held_mask[LOAD_VOICES-1] && slot_token==token)begin match_slot<=LOAD_VOICES-1;matched_record<=slot_record;end state<=OFF_WRITE;end
     end else begin scan<=scan+1'b1;slot_beat<=0;state<=SLOT_WAIT;end
    end
    ON_WRITE:begin
     held_mask[free_slot]<=1;slot_valid[free_slot]<=1;write_slot<=free_slot;write_record<={3'd0,heap_top[11:0],vel,t,pitch[6:0],et[1:0],token};slot_beat<=0;current_heap<=heap_top[11:0];heap_top<=heap_top+2;all_notes<=all_notes+1'b1;
     if(et==main_work)notes_seen<=notes_seen+1'b1;
     state<=SLOT_WRITE;
    end
    OFF_WRITE:begin
     if(matched_record[16+:2]!=et || matched_record[18+:7]!=pitch || t<=matched_record[25+:32])fail(13);
     else if(release_end[32] || release_end>duration)fail(16);
     else begin held_mask[match_slot]<=0;write_slot<=match_slot;slot_beat<=0;
      write_record<={2'd0,1'b1,matched_record[76:57],release_end[31:0],matched_record[24:0]};state<=SLOT_WRITE;end
    end
    SLOT_WRITE:if(slot_beat==4)state<=EVENT_WRITE;else slot_beat<=slot_beat+1'b1;
    EVENT_WRITE:begin if(op==3)heap_top<=heap_top+1'b1;events_seen<=events_seen+1'b1;last_time<=t;last_event_priority<=event_priority;state<=BYTES;end
    FINAL:begin
     if(events_seen!=total_events || notes_seen==0 || held_mask!=0)fail(8);
     else if((event_crc^32'hffffffff)!=head[44*8+:32] || (file_crc^32'hffffffff)!=expected_crc)fail(6);
     else begin
      build_index<=0;build_count<=0;state<=G_BEGIN;
     end
    end
    G_BEGIN:if({1'b0,build_index}>=heap_top)begin
     if(build_count!=notes_seen)fail(8);else begin busy<=0;staged_valid<=1;load_done<=1;load_error<=0;state<=IDLE;end
    end else state<=G_WAIT;
    G_WAIT:state<=G_LOW;
    G_LOW:if(heap_rd[47])begin build_low<=heap_rd;state<=G_HIGH0;end
      else begin build_index<=build_index+1'b1;state<=G_BEGIN;end
    G_HIGH0:state<=G_HIGH1;
    G_HIGH1:state<=G_HIGH;
    G_HIGH:begin if(heap_rd[33:32]==main_work)build_count<=build_count+1'b1;build_index<=build_index+2;state<=G_BEGIN;end
    default:begin end
   endcase
  end
 end
endmodule
