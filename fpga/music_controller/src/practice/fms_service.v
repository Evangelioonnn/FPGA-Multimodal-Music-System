// W4: one in-flight UART request, one canonical immutable response cache.
// A 64x8 RAM retains the exact preceding request; comparison and storage share
// one byte selector. No hash collision can turn a changed packet into a retry.
module fms_service #(parameter WITH_LOOP=0,TRANSFER_TIMEOUT_CLKS=500000000,WITH_TEACHING=1,BYTE_PACKET=0,WITH_LIVE=0,LIVE_LEASE_CYCLES=50000000)(
 input wire clk,rst,
 input wire req_valid,output wire req_ready,input wire [7:0] req_command,input wire [31:0] req_session,
 input wire [15:0] req_sequence,input wire [6:0] req_length,input wire [511:0] req_payload,
 output reg reply_valid,input wire reply_ready,output wire [7:0] reply_command,output wire [31:0] reply_session,
 output wire [15:0] reply_sequence,output wire [6:0] reply_length,output wire [511:0] reply_payload,
 input wire score_valid,running,paused,finished,preparing,mode,input wire [3:0] preset,
 input wire [15:0] song_id,note_count,hits,misses,extras,input wire [31:0] generation,run_id,revision,time_us,duration_us,
 input wire [383:0] title,input wire [15:0] presets,input wire [2:0] timing_status,input wire [7:0] faults,
 output wire command_valid,input wire command_ready,output wire [2:0] command_action,output wire [3:0] command_value,
 input wire command_done,input wire [7:0] command_error,
 input wire catalog_valid,input wire [4:0] song_count,input wire [7:0] sd_error,input wire sd_busy,
 output wire library_valid,input wire library_ready,output wire library_load,output wire [3:0] library_index,
 input wire library_done,input wire [1023:0] library_info,
 output reg upload_active,output reg store_start,store_abort,store_commit,output reg [31:0] store_size,store_crc,
 output wire store_valid,input wire store_ready,output wire [7:0] store_byte,
 input wire store_busy,store_done,store_staged,input wire [7:0] store_error,
 output wire idle,
 output reg record_start,record_stop,record_pop,record_abort,output wire [31:0] record_request_id,
 input wire record_done,input wire [7:0] record_error,
 input wire [31:0] record_id,input wire [3:0] record_preset,
 input wire record_active,record_closing,record_complete,record_failed,
 input wire [2:0] record_reason,input wire [15:0] record_ms,record_total,record_notes,
 input wire [7:0] record_level,input wire [63:0] record_front,
 output reg map_swap,map_restore,output wire [31:0] map_expected,
 output wire [4:0] map_a,map_b,input wire map_done,input wire [7:0] map_error,
 input wire [31:0] map_revision,input wire [124:0] map_table,input wire environment_busy,record_front_valid,
 input wire[95:0]req_header,input wire[7:0]req_byte,output wire[5:0]req_byte_addr,
 input wire live_safe,live_kill,output wire live_active,output wire[24:0]live_keys,output wire[3:0]live_preset,
 input wire loop_safe,loop_armed,loop_cancel,input wire[255:0]loop_metadata,
 output reg loop_lock,loop_finished,loop_failed,output reg[11:0]loop_progress,
 output reg export_request,input wire export_ready,output reg export_kind,output reg[3:0]export_lane,output reg[6:0]export_address,
 input wire export_valid,export_enabled,input wire[7:0]export_count,input wire[135:0]export_patch,input wire[31:0]export_order,input wire[44:0]export_event,
 input wire[5:0]reply_byte_addr,output wire[7:0]reply_byte
);
 localparam IDLE=0,COMPARE=1,CHECK=2,EXECUTE=3,CONTROL=4,CONTROL_WAIT=5,
 COMPARE_BYTE=6,SAVE_REQUEST=7,DATA=8,COMMIT_WAIT=9,COMMIT_PULSE=10,COMMIT_ACK=11,REC_WAIT=12,REC_READ0=13,REC_READ1=14,REC_COPY=15;
 reg [2:0] record_batch,record_word;
 localparam LOOP_SEND=16,LOOP_WAIT=17,LOOP_BEGIN_REPLY=18;
 localparam LIVE_REPLY=19,ENV_CHECK=20;
 // One transaction admission edge before the cached reply formatter. This
 // cuts bank-busy -> scene -> service -> reply-length combinational depth.
 // Packet/header/payload are immutable here; UART and audio clocks stay put.
 // live_kill carries the current score-owner/panic veto and is never delayed.
 reg admission_busy;
 reg[7:0]live_reply_code;reg[47:0]live_reply_body;
 reg[31:0]loop_id;reg loop_begin_ok;reg[2:0]loop_batch,loop_word;reg[6:0]loop_first;
 reg [4:0] state;reg have_session,cache_valid,transferring;
 reg [31:0] session,owner,transfer_id,received,inactivity;
 reg [15:0] seq_current;reg [7:0] command;reg [6:0] length;
 reg [95:0] payload;reg live_new_session;
 wire[7:0]live_error;
 wire live_command=state==EXECUTE&&command==8'h69&&length==6&&!loop_lock;
 generate if(WITH_LIVE)begin: live_enabled
  bt_live_keys #(.LEASE_CYCLES(LIVE_LEASE_CYCLES)) live(clk,rst,live_kill,live_new_session,live_safe,
   live_command,payload[7:0],payload[15:8],payload[47:16],live_active,live_keys,live_preset,live_error);
 end else begin: no_realtime
  assign live_active=0;assign live_keys=0;assign live_preset=0;assign live_error=1;
 end endgenerate
 reg request_bank;
 (* syn_ramstyle="block_ram" *) reg [7:0] previous_request[0:127];
 reg [7:0] previous_q;reg [5:0] compare_index;reg bytes_equal;
 reg same_request;reg [5:0] chunk_index;
 reg [6:0] saved_reply_length;reg [511:0] legacy_reply_payload;
 reg [503:0] parallel_reply_body;
 wire[511:0]saved_reply_payload=WITH_LOOP ? legacy_reply_payload : {parallel_reply_body,legacy_reply_payload[7:0]};
 reg reject_reply;reg [7:0] incoming_command;reg [31:0] incoming_session;
 reg [15:0] incoming_sequence;reg [6:0] incoming_length;
 assign record_request_id=payload[31:0];
 assign map_expected=payload[31:0];assign map_a=payload[36:32];assign map_b=payload[44:40];
 wire [231:0] map_body;assign map_body[31:0]=map_revision;
 genvar mg;generate for(mg=0;mg<25;mg=mg+1)begin: map_reply
  assign map_body[32+mg*8+:8]={3'd0,map_table[mg*5+:5]};
 end endgenerate
 wire [31:0] data_size={25'd0,length}-8;
 // The producer retains its immutable packet until the last byte is copied.
 assign req_ready=state==COMPARE_BYTE && compare_index==63 && !rst;
 assign idle=state==IDLE && !reply_valid && !req_valid && !rst;
 wire control_identity=payload[47:16]==revision && payload[63:48]==song_id && payload[95:64]==generation;
 assign command_valid=state==CONTROL && control_identity;
 assign command_action=payload[2:0];assign command_value=payload[11:8];
 assign library_valid=0;assign library_load=0;assign library_index=0;
 assign store_valid=state==DATA && store_error==0;
 // IDLE prefetches old byte0; each capture prefetches the next old
 // byte, comparing against the still-stable incoming packet. Other states
 // prefetch the accepted request byte needed by DATA.
 wire request_capture=state==COMPARE_BYTE && req_valid;
 wire[7:0]incoming_byte=BYTE_PACKET ? req_byte : req_payload[compare_index*8+:8];
 assign req_byte_addr=state==COMPARE_BYTE ? compare_index+6'd1 : 6'd0;
 wire[5:0]read_index=state==IDLE ? 6'd0 :
  state==COMPARE_BYTE ? compare_index+6'd1 :
  state==EXECUTE ? 6'd8 :
  state==DATA ? chunk_index+6'd8+(store_ready&&store_error==0 ? 6'd1 : 6'd0) : 6'd0;
 assign store_byte=previous_q;
 assign reply_command=(reject_reply ? incoming_command : command)|8'h80;
 assign reply_session=reject_reply ? incoming_session : session;
 assign reply_sequence=reject_reply ? incoming_sequence : seq_current;
 assign reply_length=reject_reply ? 7'd1 : saved_reply_length;
 assign reply_payload=reject_reply ? 512'd5 : saved_reply_payload;
 // The private TX capture counter is the read address. Keep the rejection
 // choice on this eight-bit port; the unused parallel observer may be swept.
 assign reply_byte=reject_reply ? (reply_byte_addr==0 ? 8'd5 : 8'd0) :
   saved_reply_payload[reply_byte_addr*8+:8];
 // Two logical banks, one 128x8 synchronous-read / separate-write RAM.
 // request_bank is the last accepted request, its inverse is staging.
 // No RAM reset; cache_valid is the sole replay-validity authority.
 always @(posedge clk)begin
  previous_q<=previous_request[{request_bank,read_index}];
  if(request_capture)previous_request[{!request_bank,compare_index}]<=incoming_byte;
 end
 task respond;input [7:0] status;input [6:0] body_length;input [503:0] body;
  begin
   reply_valid<=1;reject_reply<=0;
   saved_reply_length<=body_length+1'b1;
   legacy_reply_payload[7:0]<=status;
   if(WITH_LOOP&&body_length!=0)legacy_reply_payload[511:8]<=body;
   cache_valid<=1;state<=IDLE;
  end
 endtask
 task reject_sequence;begin
  reply_valid<=1;reject_reply<=1;state<=IDLE;
 end endtask
 wire [7:0] record_flags={4'd0,record_failed,record_complete,record_closing,record_active};
 wire [135:0] record_body={5'd0,record_reason,8'd0,record_level,record_notes,record_total,16'd0,record_ms,4'd0,record_preset,record_flags,record_id};
 wire [7:0] flags={2'b00,transferring,preparing,finished,paused,running,score_valid};
 always @(posedge clk)begin
  if(rst)begin
   if(WITH_LOOP)legacy_reply_payload<=0;else legacy_reply_payload[7:0]<=0;
   live_reply_code<=0;live_reply_body<=0;map_swap<=0;map_restore<=0;record_start<=0;record_stop<=0;record_pop<=0;record_abort<=0;record_batch<=0;record_word<=0;
   loop_lock<=0;loop_finished<=0;loop_failed<=0;loop_progress<=0;loop_id<=0;loop_begin_ok<=0;loop_batch<=0;loop_word<=0;loop_first<=0;export_request<=0;export_kind<=0;export_lane<=0;export_address<=0;
   request_bank<=0;state<=IDLE;have_session<=0;cache_valid<=0;transferring<=0;upload_active<=0;
   session<=0;owner<=0;transfer_id<=0;received<=0;inactivity<=0;seq_current<=0;command<=0;length<=0;payload<=0;
   live_new_session<=0;admission_busy<=1;
   reply_valid<=0;reject_reply<=0;
   compare_index<=0;bytes_equal<=0;same_request<=0;chunk_index<=0;store_start<=0;store_abort<=0;store_commit<=0;
   store_size<=0;store_crc<=0;saved_reply_length<=0;incoming_command<=0;
   incoming_session<=0;incoming_sequence<=0;incoming_length<=0;
  end else begin
   store_start<=0;store_abort<=0;store_commit<=0;map_swap<=0;map_restore<=0;record_start<=0;record_stop<=0;record_pop<=0;record_abort<=0;live_new_session<=0;loop_finished<=0;loop_failed<=0;
   if(export_request&&export_ready)export_request<=0;
   if(reply_valid && reply_ready)reply_valid<=0;
   if(transferring)begin
    if(req_valid && req_ready)inactivity<=0;
    else if(inactivity<TRANSFER_TIMEOUT_CLKS)inactivity<=inactivity+1'b1;
    if(state==IDLE && inactivity==TRANSFER_TIMEOUT_CLKS)begin
     transferring<=0;upload_active<=0;store_abort<=1;received<=0;cache_valid<=0;
    end
   end
   if(loop_lock&&!transferring)begin
    if(req_valid&&req_ready)inactivity<=0;else if(inactivity<TRANSFER_TIMEOUT_CLKS)inactivity<=inactivity+1'b1;
   end
   // Body is captured on its original execution/ack edge. Invalid replies
   // advertise only status, so their unused body may change. IDLE/CHECK and
   // a stalled published reply never alter this cache; exact retries retain it.
   case(state)
    IDLE:if(req_valid && !reply_valid)begin
     incoming_command<=req_command;incoming_session<=req_session;incoming_sequence<=req_sequence;incoming_length<=req_length;
     payload<=BYTE_PACKET ? req_header : req_payload[95:0];compare_index<=0;bytes_equal<=1;
     same_request<=req_command==command && req_length==length;
     state<=COMPARE_BYTE;
    end
    COMPARE_BYTE:if(!req_valid)state<=IDLE;else begin
     if(incoming_byte!=previous_q)bytes_equal<=0;
     if(compare_index==63)state<=CHECK;
     else compare_index<=compare_index+1'b1;
    end
    CHECK:begin
     if(have_session && incoming_session==session && incoming_sequence==seq_current && cache_valid)begin
      if(same_request && bytes_equal)begin
       if(WITH_LOOP&&command>=8'h71&&command<=8'h73&&!loop_lock)respond(4,0,0);
       else begin reply_valid<=1;reject_reply<=0;state<=IDLE;end
      end else reject_sequence();
     end else if(incoming_session==0 || (!have_session || incoming_session!=session) && incoming_command!=8'h50 ||
      (have_session && incoming_session==session && incoming_sequence!=seq_current+16'd1))reject_sequence();
     else begin
      command<=incoming_command;session<=incoming_session;seq_current<=incoming_sequence;length<=incoming_length;
      have_session<=1;cache_valid<=0;compare_index<=0;
      request_bank<=!request_bank;state<=ENV_CHECK;
      if(!have_session || incoming_session!=session)begin
       live_new_session<=1;
       if(loop_lock)loop_failed<=1;loop_lock<=0;export_request<=0;
       record_abort<=1;
       if(upload_active)store_abort<=1;
       transferring<=0;upload_active<=0;received<=0;
      end
     end
    end

    ENV_CHECK:begin admission_busy<=environment_busy;state<=EXECUTE;end
    EXECUTE:if(loop_lock&&!(command>=8'h70&&command<=8'h74)&&command!=8'h50)respond(3,0,0);else case(command)
     8'h70:if(!WITH_LOOP)respond(1,0,0);else if(length!=0)respond(2,0,0);
      else respond(0,8,{8'd1,7'd0,loop_lock,7'd0,loop_armed,8'd4,16'd2048,8'd16,8'd1});
     8'h71:if(!WITH_LOOP)respond(1,0,0);else if(length!=0)respond(2,0,0);
      else begin
       loop_begin_ok<=!(loop_lock||!loop_safe||!loop_armed||live_active||record_active||record_closing||transferring||running||preparing||loop_id==32'hffffffff);
       if(!(loop_lock||!loop_safe||!loop_armed||live_active||record_active||record_closing||transferring||running||preparing||loop_id==32'hffffffff))begin loop_lock<=1;loop_id<=loop_id+1'b1;loop_progress<=0;inactivity<=0;end
       // Body is unconditionally prepared for this well-formed BEGIN. No
       // safety/router decision lies on its wide metadata data/enable path.
       legacy_reply_payload<={216'd0,loop_metadata,(loop_id+32'd1),8'd0};
       state<=LOOP_BEGIN_REPLY;
      end
     8'h72,8'h73:if(!WITH_LOOP)respond(1,0,0);
      else if((command==8'h72&&length!=5)||(command==8'h73&&length!=7)||payload[39:32]>=16||
       (command==8'h73&&(payload[47:40]>=128||payload[55:48]==0||payload[55:48]>4||({1'b0,payload[47:40]}+{1'b0,payload[55:48]})>128)))respond(2,0,0);
      else if(!loop_lock||payload[31:0]!=loop_id)respond(4,0,0);
      else begin export_lane<=payload[35:32];export_kind<=command==8'h73;export_address<=payload[46:40];
       loop_first<=payload[46:40];loop_batch<=payload[50:48];loop_word<=0;export_request<=1;state<=LOOP_SEND;
       if(command==8'h73)begin legacy_reply_payload<=0;legacy_reply_payload[63:0]<={payload[55:48],payload[47:40],payload[39:32],loop_id,8'd0};saved_reply_length<=8+payload[55:48]*6;end
      end
     8'h74:if(!WITH_LOOP)respond(1,0,0);else if((length!=4&&length!=5)||(length==5&&payload[39:32]>1))respond(2,0,0);
      else if(!loop_lock||payload[31:0]!=loop_id)respond(4,0,0);
      else begin loop_lock<=0;loop_finished<=!(length==5&&payload[32]);loop_failed<=length==5&&payload[32];respond(0,4,{loop_id});end

     8'h50:if(length!=0)respond(2,0,0);else respond(0,17,{368'd0,8'd4,8'd16,8'd4,16'h0389,32'd66048,16'd2048,16'd4096,(WITH_TEACHING ? 8'd3 : 8'd2),8'd72,8'd48,8'd8});
     8'h51:if(length!=0)respond(2,0,0);else respond(0,52,
      {88'd0,faults,transfer_id,store_size,received,extras,misses,hits,note_count,duration_us,time_us,revision,run_id,generation,song_id,
       5'd0,timing_status,store_error,8'd0,8'd0,8'd0,4'd0,preset,7'd0,mode,flags,8'd8});
     8'h52:begin
      if(length!=12 || payload[7:0]>5 || payload[15:8]>15)respond(2,0,0);
      else if(payload[47:16]!=revision || payload[63:48]!=song_id || payload[95:64]!=generation)respond(4,0,0);
      else if(live_active || live_kill || admission_busy || transferring || sd_busy || store_busy || ((record_active || record_closing) && payload[7:0]>=4))respond(3,0,0);
      else state<=CONTROL;
     end
     8'h53,8'h54:respond(1,0,0); // SD is absent in this firmware profile.
     8'h55:if(length!=0)respond(2,0,0);else respond(0,56,{56'd0,presets,title,generation,song_id});
     8'h58:begin
      if(length!=12 || payload[31:0]==0 || payload[63:32]<512 || payload[63:32]>66048 || payload[40:32]!=0)respond(2,0,0);
      else if(live_active || live_kill || admission_busy || transferring || running || preparing || sd_busy || store_busy || record_active || record_closing)respond(3,0,0);
      else begin
       owner<=session;transfer_id<=payload[31:0];store_size<=payload[63:32];store_crc<=payload[95:64];
       received<=0;transferring<=1;upload_active<=1;inactivity<=0;store_start<=1;respond(0,4,0);
      end
     end
     8'h59:begin
      if(length<9 || length>60)respond(2,0,0);
      else if(!transferring || session!=owner || payload[31:0]!=transfer_id)respond(4,0,0);
      else if(payload[63:32]!=received || {1'b0,received}+data_size>{1'b0,store_size})respond(7,0,0);
      else if(store_error!=0)respond(6,0,0);
      else begin chunk_index<=0;state<=DATA;end
     end
     8'h5a:begin
      if(length!=4)respond(2,0,0);
      else if(!transferring || session!=owner || payload[31:0]!=transfer_id)respond(4,0,0);
      else if(received!=store_size)respond(7,0,0);
      else state<=COMMIT_WAIT;
     end
     8'h5b:begin
      if(length!=4)respond(2,0,0);
      else if(!transferring || session!=owner || payload[31:0]!=transfer_id)respond(4,0,0);
      else begin store_abort<=1;transferring<=0;upload_active<=0;received<=0;respond(0,0,0);end
     end
     8'h60:if(length!=0)respond(2,0,0);else respond(0,8,{440'd0,8'd6,8'd8,16'd128,16'd512,8'd60,8'd1});
     8'h61:begin
      if(length!=4 || payload[31:0]==0)respond(2,0,0);
      else if(live_active || live_kill || admission_busy || transferring || preparing || sd_busy || store_busy || record_active || record_closing)respond(3,0,0);
      else begin record_start<=1;state<=REC_WAIT;end
     end
     8'h62:begin
      if(length!=4)respond(2,0,0);
      else if(record_id==0 || payload[31:0]!=record_id)respond(4,0,0);
      else begin record_stop<=1;state<=REC_WAIT;end
     end
     8'h63:begin
      if(length!=4)respond(2,0,0);
      else if(record_id==0 || payload[31:0]!=record_id)respond(4,0,0);
      else if(record_level==0)respond(0,5,{464'd0,8'd0,record_id});
      else begin
       record_batch<=record_level>6 ? 3'd6 : record_level[2:0];record_word<=0;
       if(WITH_LOOP)legacy_reply_payload<=0;else legacy_reply_payload[7:0]<=0;
       if(WITH_LOOP)legacy_reply_payload[39:8]<=record_id;
       if(WITH_LOOP)legacy_reply_payload[47:40]<=record_level>6 ? 8'd6 : record_level;
       saved_reply_length<=7'd6+((record_level>6 ? 7'd6 : {4'd0,record_level[2:0]})<<3);
       state<=REC_READ0;
      end
     end
     8'h64:if(length!=0)respond(2,0,0);else respond(0,17,record_body);
     8'h65:if(length!=0)respond(2,0,0);else respond(0,29,map_body);
     8'h66,8'h67:begin
      if((command==8'h66 && (length!=6 || payload[39:32]>24 || payload[47:40]>24)) ||
       (command==8'h67 && length!=4))respond(2,0,0);
      else if(live_active || live_kill || admission_busy || running || preparing || transferring || sd_busy || store_busy || record_active || record_closing)respond(3,0,0);
      else begin map_swap<=command==8'h66;map_restore<=command==8'h67;state<=CONTROL_WAIT;end
     end
     8'h68:if(!WITH_LIVE)respond(1,0,0);else if(length!=0)respond(2,0,0);
      else respond(0,12,{408'd0,8'd0,4'd0,live_preset,8'd72,8'd48,16'h0389,7'd0,live_active,16'd1000,8'd4,8'd25,8'd1});
     8'h69:if(loop_lock)respond(3,0,0);else if(!WITH_LIVE)respond(1,0,0);else if(length!=6)respond(2,0,0);
      else begin
       // bt_live_keys still handles this EXECUTE edge; only reply formatting
       // is deferred. Snapshot all valid body fields, including old preset.
       live_reply_code<=live_error;
       live_reply_body<={(payload[7:0]==0 ? payload[15:8] : {4'd0,live_preset}),
        (payload[7:0]==1 ? payload[47:16] : 32'd0),7'd0,payload[7:0]!=2};
       state<=LIVE_REPLY;
      end
     default:respond(1,0,0);
    endcase
    LIVE_REPLY:respond(live_reply_code,live_reply_code==0 ? 7'd6 : 7'd0,{456'd0,live_reply_body});
    REC_WAIT:if(record_done)respond(record_error,record_error==0 ? 7'd17 : 7'd0,record_body);
    LOOP_BEGIN_REPLY:if(loop_begin_ok)begin
     reply_valid<=1;reject_reply<=0;saved_reply_length<=37;cache_valid<=1;state<=IDLE;
    end else respond(3,0,0);
    LOOP_SEND:if(export_request&&export_ready)state<=LOOP_WAIT;
    LOOP_WAIT:if(export_valid)begin
     if(!loop_lock)respond(4,0,0);
     else if(command==8'h72)respond(0,28,{(export_enabled ? export_patch : 136'd0),(export_enabled ? export_order : 32'd0),(export_enabled ? export_count : 8'd0),7'd0,export_enabled,4'd0,export_lane,loop_id});
     else if(!export_enabled||export_address>=export_count)respond(2,0,0);
     else begin
      case(loop_word)
       0:legacy_reply_payload[111:64]<={3'd0,export_event};
       1:legacy_reply_payload[159:112]<={3'd0,export_event};
       2:legacy_reply_payload[207:160]<={3'd0,export_event};
       3:legacy_reply_payload[255:208]<={3'd0,export_event};
      endcase
      if(loop_word+1'b1==loop_batch)begin reply_valid<=1;reject_reply<=0;cache_valid<=1;state<=IDLE;loop_progress<=loop_progress+loop_batch;end
      else begin loop_word<=loop_word+1'b1;export_address<=export_address+1'b1;export_request<=1;state<=LOOP_SEND;end
     end
    end
    REC_READ0:state<=REC_READ1;
    REC_READ1:if(record_front_valid)state<=REC_COPY;
    REC_COPY:begin
     if(WITH_LOOP)case(record_word)
      0:legacy_reply_payload[111:48]<=record_front;
      1:legacy_reply_payload[175:112]<=record_front;
      2:legacy_reply_payload[239:176]<=record_front;
      3:legacy_reply_payload[303:240]<=record_front;
      4:legacy_reply_payload[367:304]<=record_front;
      5:legacy_reply_payload[431:368]<=record_front;
     endcase
     record_pop<=1;
     if(record_word+1'b1==record_batch)begin reply_valid<=1;reject_reply<=0;cache_valid<=1;state<=IDLE;end
     else begin record_word<=record_word+1'b1;state<=REC_READ0;end
    end
    CONTROL:if(!control_identity)respond(4,0,0);else if(command_ready)state<=CONTROL_WAIT;
    CONTROL_WAIT:if(command==8'h66 || command==8'h67)begin
     if(map_done)respond(map_error,4,{472'd0,map_revision});
    end else if(command_done)respond(command_error,8,{440'd0,run_id,revision});
    DATA:begin
     if(store_error!=0)respond(6,0,0);
     else if(store_valid && store_ready)begin
      if(chunk_index+1==data_size)begin received<=received+data_size;respond(0,4,{472'd0,received+data_size});end
      else chunk_index<=chunk_index+1'b1;
     end
    end
    COMMIT_WAIT:if(!store_busy)begin
     if(store_error!=0 || !store_staged)respond(6,0,0);
     else begin store_commit<=1;state<=COMMIT_PULSE;end
    end
    COMMIT_PULSE:state<=COMMIT_ACK;
    COMMIT_ACK:begin transferring<=0;upload_active<=0;respond(0,6,{456'd0,generation,song_id});end
   endcase
   if(WITH_LOOP&&loop_lock&&(loop_cancel||live_kill||inactivity==TRANSFER_TIMEOUT_CLKS))begin
    loop_lock<=0;loop_failed<=1;export_request<=0;
    if(state==LOOP_SEND||state==LOOP_WAIT||state==LOOP_BEGIN_REPLY)respond(4,0,0);
   end
  end
 end
 // Each reply kind is disjoint in state/command; do not priority-mux the body.
 generate if(!WITH_LOOP)begin:parallel_body
 wire select_0=state==EXECUTE&&command==8'h50;wire[135:0]body_0={8'd4,8'd16,8'd4,16'h0389,32'd66048,16'd2048,16'd4096,(WITH_TEACHING ? 8'd3 : 8'd2),8'd72,8'd48,8'd8};
 wire select_1=state==EXECUTE&&command==8'h51;wire[415:0]body_1={faults,transfer_id,store_size,received,extras,misses,hits,note_count,duration_us,time_us,revision,run_id,generation,song_id,5'd0,timing_status,store_error,8'd0,8'd0,8'd0,4'd0,preset,7'd0,mode,flags,8'd8};
 wire select_2=state==EXECUTE&&command==8'h55;wire[447:0]body_2={presets,title,generation,song_id};
 wire select_3=state==EXECUTE&&command==8'h58;wire[31:0]body_3=32'd0;
 wire select_4=state==EXECUTE&&command==8'h60;wire[63:0]body_4={8'd6,8'd8,16'd128,16'd512,8'd60,8'd1};
 wire select_5=state==EXECUTE&&command==8'h63;wire[39:0]body_5={(record_level>6 ? 8'd6 : record_level),record_id};
 wire select_6=(state==EXECUTE&&command==8'h64)||state==REC_WAIT;wire[135:0]body_6=record_body;
 wire select_7=state==EXECUTE&&command==8'h65;wire[231:0]body_7=map_body;
 wire select_8=state==EXECUTE&&command==8'h68;wire[95:0]body_8={8'd0,4'd0,live_preset,8'd72,8'd48,16'h0389,7'd0,live_active,16'd1000,8'd4,8'd25,8'd1};
 wire select_9=state==LIVE_REPLY;wire[47:0]body_9=live_reply_body;
 wire select_10=state==CONTROL_WAIT&&(command==8'h66||command==8'h67);wire[31:0]body_10=map_revision;
 wire select_11=state==CONTROL_WAIT&&command!=8'h66&&command!=8'h67;wire[63:0]body_11={run_id,revision};
 wire select_12=state==DATA;wire[31:0]body_12=received+data_size;
 wire select_13=state==COMMIT_ACK;wire[47:0]body_13={generation,song_id};
 wire select_14=state==REC_COPY&&record_word==3'd0;wire[63:0]body_14=record_front;
 wire select_15=state==REC_COPY&&record_word==3'd1;wire[63:0]body_15=record_front;
 wire select_16=state==REC_COPY&&record_word==3'd2;wire[63:0]body_16=record_front;
 wire select_17=state==REC_COPY&&record_word==3'd3;wire[63:0]body_17=record_front;
 wire select_18=state==REC_COPY&&record_word==3'd4;wire[63:0]body_18=record_front;
 wire select_19=state==REC_COPY&&record_word==3'd5;wire[63:0]body_19=record_front;
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_3|select_4|select_5|select_6|select_7|select_8|select_9|select_10|select_11|select_12|select_13))parallel_reply_body[0+:8]<=({8{select_0}}&body_0[0+:8])|({8{select_1}}&body_1[0+:8])|({8{select_2}}&body_2[0+:8])|({8{select_3}}&body_3[0+:8])|({8{select_4}}&body_4[0+:8])|({8{select_5}}&body_5[0+:8])|({8{select_6}}&body_6[0+:8])|({8{select_7}}&body_7[0+:8])|({8{select_8}}&body_8[0+:8])|({8{select_9}}&body_9[0+:8])|({8{select_10}}&body_10[0+:8])|({8{select_11}}&body_11[0+:8])|({8{select_12}}&body_12[0+:8])|({8{select_13}}&body_13[0+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_3|select_4|select_5|select_6|select_7|select_8|select_9|select_10|select_11|select_12|select_13))parallel_reply_body[8+:8]<=({8{select_0}}&body_0[8+:8])|({8{select_1}}&body_1[8+:8])|({8{select_2}}&body_2[8+:8])|({8{select_3}}&body_3[8+:8])|({8{select_4}}&body_4[8+:8])|({8{select_5}}&body_5[8+:8])|({8{select_6}}&body_6[8+:8])|({8{select_7}}&body_7[8+:8])|({8{select_8}}&body_8[8+:8])|({8{select_9}}&body_9[8+:8])|({8{select_10}}&body_10[8+:8])|({8{select_11}}&body_11[8+:8])|({8{select_12}}&body_12[8+:8])|({8{select_13}}&body_13[8+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_3|select_4|select_5|select_6|select_7|select_8|select_9|select_10|select_11|select_12|select_13))parallel_reply_body[16+:8]<=({8{select_0}}&body_0[16+:8])|({8{select_1}}&body_1[16+:8])|({8{select_2}}&body_2[16+:8])|({8{select_3}}&body_3[16+:8])|({8{select_4}}&body_4[16+:8])|({8{select_5}}&body_5[16+:8])|({8{select_6}}&body_6[16+:8])|({8{select_7}}&body_7[16+:8])|({8{select_8}}&body_8[16+:8])|({8{select_9}}&body_9[16+:8])|({8{select_10}}&body_10[16+:8])|({8{select_11}}&body_11[16+:8])|({8{select_12}}&body_12[16+:8])|({8{select_13}}&body_13[16+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_3|select_4|select_5|select_6|select_7|select_8|select_9|select_10|select_11|select_12|select_13))parallel_reply_body[24+:8]<=({8{select_0}}&body_0[24+:8])|({8{select_1}}&body_1[24+:8])|({8{select_2}}&body_2[24+:8])|({8{select_3}}&body_3[24+:8])|({8{select_4}}&body_4[24+:8])|({8{select_5}}&body_5[24+:8])|({8{select_6}}&body_6[24+:8])|({8{select_7}}&body_7[24+:8])|({8{select_8}}&body_8[24+:8])|({8{select_9}}&body_9[24+:8])|({8{select_10}}&body_10[24+:8])|({8{select_11}}&body_11[24+:8])|({8{select_12}}&body_12[24+:8])|({8{select_13}}&body_13[24+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_4|select_5|select_6|select_7|select_8|select_9|select_11|select_13))parallel_reply_body[32+:8]<=({8{select_0}}&body_0[32+:8])|({8{select_1}}&body_1[32+:8])|({8{select_2}}&body_2[32+:8])|({8{select_4}}&body_4[32+:8])|({8{select_5}}&body_5[32+:8])|({8{select_6}}&body_6[32+:8])|({8{select_7}}&body_7[32+:8])|({8{select_8}}&body_8[32+:8])|({8{select_9}}&body_9[32+:8])|({8{select_11}}&body_11[32+:8])|({8{select_13}}&body_13[32+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_4|select_6|select_7|select_8|select_9|select_11|select_13|select_14))parallel_reply_body[40+:8]<=({8{select_0}}&body_0[40+:8])|({8{select_1}}&body_1[40+:8])|({8{select_2}}&body_2[40+:8])|({8{select_4}}&body_4[40+:8])|({8{select_6}}&body_6[40+:8])|({8{select_7}}&body_7[40+:8])|({8{select_8}}&body_8[40+:8])|({8{select_9}}&body_9[40+:8])|({8{select_11}}&body_11[40+:8])|({8{select_13}}&body_13[40+:8])|({8{select_14}}&body_14[0+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_4|select_6|select_7|select_8|select_11|select_14))parallel_reply_body[48+:8]<=({8{select_0}}&body_0[48+:8])|({8{select_1}}&body_1[48+:8])|({8{select_2}}&body_2[48+:8])|({8{select_4}}&body_4[48+:8])|({8{select_6}}&body_6[48+:8])|({8{select_7}}&body_7[48+:8])|({8{select_8}}&body_8[48+:8])|({8{select_11}}&body_11[48+:8])|({8{select_14}}&body_14[8+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_4|select_6|select_7|select_8|select_11|select_14))parallel_reply_body[56+:8]<=({8{select_0}}&body_0[56+:8])|({8{select_1}}&body_1[56+:8])|({8{select_2}}&body_2[56+:8])|({8{select_4}}&body_4[56+:8])|({8{select_6}}&body_6[56+:8])|({8{select_7}}&body_7[56+:8])|({8{select_8}}&body_8[56+:8])|({8{select_11}}&body_11[56+:8])|({8{select_14}}&body_14[16+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_8|select_14))parallel_reply_body[64+:8]<=({8{select_0}}&body_0[64+:8])|({8{select_1}}&body_1[64+:8])|({8{select_2}}&body_2[64+:8])|({8{select_6}}&body_6[64+:8])|({8{select_7}}&body_7[64+:8])|({8{select_8}}&body_8[64+:8])|({8{select_14}}&body_14[24+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_8|select_14))parallel_reply_body[72+:8]<=({8{select_0}}&body_0[72+:8])|({8{select_1}}&body_1[72+:8])|({8{select_2}}&body_2[72+:8])|({8{select_6}}&body_6[72+:8])|({8{select_7}}&body_7[72+:8])|({8{select_8}}&body_8[72+:8])|({8{select_14}}&body_14[32+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_8|select_14))parallel_reply_body[80+:8]<=({8{select_0}}&body_0[80+:8])|({8{select_1}}&body_1[80+:8])|({8{select_2}}&body_2[80+:8])|({8{select_6}}&body_6[80+:8])|({8{select_7}}&body_7[80+:8])|({8{select_8}}&body_8[80+:8])|({8{select_14}}&body_14[40+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_8|select_14))parallel_reply_body[88+:8]<=({8{select_0}}&body_0[88+:8])|({8{select_1}}&body_1[88+:8])|({8{select_2}}&body_2[88+:8])|({8{select_6}}&body_6[88+:8])|({8{select_7}}&body_7[88+:8])|({8{select_8}}&body_8[88+:8])|({8{select_14}}&body_14[48+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_14))parallel_reply_body[96+:8]<=({8{select_0}}&body_0[96+:8])|({8{select_1}}&body_1[96+:8])|({8{select_2}}&body_2[96+:8])|({8{select_6}}&body_6[96+:8])|({8{select_7}}&body_7[96+:8])|({8{select_14}}&body_14[56+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_15))parallel_reply_body[104+:8]<=({8{select_0}}&body_0[104+:8])|({8{select_1}}&body_1[104+:8])|({8{select_2}}&body_2[104+:8])|({8{select_6}}&body_6[104+:8])|({8{select_7}}&body_7[104+:8])|({8{select_15}}&body_15[0+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_15))parallel_reply_body[112+:8]<=({8{select_0}}&body_0[112+:8])|({8{select_1}}&body_1[112+:8])|({8{select_2}}&body_2[112+:8])|({8{select_6}}&body_6[112+:8])|({8{select_7}}&body_7[112+:8])|({8{select_15}}&body_15[8+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_15))parallel_reply_body[120+:8]<=({8{select_0}}&body_0[120+:8])|({8{select_1}}&body_1[120+:8])|({8{select_2}}&body_2[120+:8])|({8{select_6}}&body_6[120+:8])|({8{select_7}}&body_7[120+:8])|({8{select_15}}&body_15[16+:8]);
 always @(posedge clk)if(!rst&&(select_0|select_1|select_2|select_6|select_7|select_15))parallel_reply_body[128+:8]<=({8{select_0}}&body_0[128+:8])|({8{select_1}}&body_1[128+:8])|({8{select_2}}&body_2[128+:8])|({8{select_6}}&body_6[128+:8])|({8{select_7}}&body_7[128+:8])|({8{select_15}}&body_15[24+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_15))parallel_reply_body[136+:8]<=({8{select_1}}&body_1[136+:8])|({8{select_2}}&body_2[136+:8])|({8{select_7}}&body_7[136+:8])|({8{select_15}}&body_15[32+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_15))parallel_reply_body[144+:8]<=({8{select_1}}&body_1[144+:8])|({8{select_2}}&body_2[144+:8])|({8{select_7}}&body_7[144+:8])|({8{select_15}}&body_15[40+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_15))parallel_reply_body[152+:8]<=({8{select_1}}&body_1[152+:8])|({8{select_2}}&body_2[152+:8])|({8{select_7}}&body_7[152+:8])|({8{select_15}}&body_15[48+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_15))parallel_reply_body[160+:8]<=({8{select_1}}&body_1[160+:8])|({8{select_2}}&body_2[160+:8])|({8{select_7}}&body_7[160+:8])|({8{select_15}}&body_15[56+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[168+:8]<=({8{select_1}}&body_1[168+:8])|({8{select_2}}&body_2[168+:8])|({8{select_7}}&body_7[168+:8])|({8{select_16}}&body_16[0+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[176+:8]<=({8{select_1}}&body_1[176+:8])|({8{select_2}}&body_2[176+:8])|({8{select_7}}&body_7[176+:8])|({8{select_16}}&body_16[8+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[184+:8]<=({8{select_1}}&body_1[184+:8])|({8{select_2}}&body_2[184+:8])|({8{select_7}}&body_7[184+:8])|({8{select_16}}&body_16[16+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[192+:8]<=({8{select_1}}&body_1[192+:8])|({8{select_2}}&body_2[192+:8])|({8{select_7}}&body_7[192+:8])|({8{select_16}}&body_16[24+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[200+:8]<=({8{select_1}}&body_1[200+:8])|({8{select_2}}&body_2[200+:8])|({8{select_7}}&body_7[200+:8])|({8{select_16}}&body_16[32+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[208+:8]<=({8{select_1}}&body_1[208+:8])|({8{select_2}}&body_2[208+:8])|({8{select_7}}&body_7[208+:8])|({8{select_16}}&body_16[40+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[216+:8]<=({8{select_1}}&body_1[216+:8])|({8{select_2}}&body_2[216+:8])|({8{select_7}}&body_7[216+:8])|({8{select_16}}&body_16[48+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_7|select_16))parallel_reply_body[224+:8]<=({8{select_1}}&body_1[224+:8])|({8{select_2}}&body_2[224+:8])|({8{select_7}}&body_7[224+:8])|({8{select_16}}&body_16[56+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[232+:8]<=({8{select_1}}&body_1[232+:8])|({8{select_2}}&body_2[232+:8])|({8{select_17}}&body_17[0+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[240+:8]<=({8{select_1}}&body_1[240+:8])|({8{select_2}}&body_2[240+:8])|({8{select_17}}&body_17[8+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[248+:8]<=({8{select_1}}&body_1[248+:8])|({8{select_2}}&body_2[248+:8])|({8{select_17}}&body_17[16+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[256+:8]<=({8{select_1}}&body_1[256+:8])|({8{select_2}}&body_2[256+:8])|({8{select_17}}&body_17[24+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[264+:8]<=({8{select_1}}&body_1[264+:8])|({8{select_2}}&body_2[264+:8])|({8{select_17}}&body_17[32+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[272+:8]<=({8{select_1}}&body_1[272+:8])|({8{select_2}}&body_2[272+:8])|({8{select_17}}&body_17[40+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[280+:8]<=({8{select_1}}&body_1[280+:8])|({8{select_2}}&body_2[280+:8])|({8{select_17}}&body_17[48+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_17))parallel_reply_body[288+:8]<=({8{select_1}}&body_1[288+:8])|({8{select_2}}&body_2[288+:8])|({8{select_17}}&body_17[56+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[296+:8]<=({8{select_1}}&body_1[296+:8])|({8{select_2}}&body_2[296+:8])|({8{select_18}}&body_18[0+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[304+:8]<=({8{select_1}}&body_1[304+:8])|({8{select_2}}&body_2[304+:8])|({8{select_18}}&body_18[8+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[312+:8]<=({8{select_1}}&body_1[312+:8])|({8{select_2}}&body_2[312+:8])|({8{select_18}}&body_18[16+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[320+:8]<=({8{select_1}}&body_1[320+:8])|({8{select_2}}&body_2[320+:8])|({8{select_18}}&body_18[24+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[328+:8]<=({8{select_1}}&body_1[328+:8])|({8{select_2}}&body_2[328+:8])|({8{select_18}}&body_18[32+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[336+:8]<=({8{select_1}}&body_1[336+:8])|({8{select_2}}&body_2[336+:8])|({8{select_18}}&body_18[40+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[344+:8]<=({8{select_1}}&body_1[344+:8])|({8{select_2}}&body_2[344+:8])|({8{select_18}}&body_18[48+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_18))parallel_reply_body[352+:8]<=({8{select_1}}&body_1[352+:8])|({8{select_2}}&body_2[352+:8])|({8{select_18}}&body_18[56+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_19))parallel_reply_body[360+:8]<=({8{select_1}}&body_1[360+:8])|({8{select_2}}&body_2[360+:8])|({8{select_19}}&body_19[0+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_19))parallel_reply_body[368+:8]<=({8{select_1}}&body_1[368+:8])|({8{select_2}}&body_2[368+:8])|({8{select_19}}&body_19[8+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_19))parallel_reply_body[376+:8]<=({8{select_1}}&body_1[376+:8])|({8{select_2}}&body_2[376+:8])|({8{select_19}}&body_19[16+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_19))parallel_reply_body[384+:8]<=({8{select_1}}&body_1[384+:8])|({8{select_2}}&body_2[384+:8])|({8{select_19}}&body_19[24+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_19))parallel_reply_body[392+:8]<=({8{select_1}}&body_1[392+:8])|({8{select_2}}&body_2[392+:8])|({8{select_19}}&body_19[32+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_19))parallel_reply_body[400+:8]<=({8{select_1}}&body_1[400+:8])|({8{select_2}}&body_2[400+:8])|({8{select_19}}&body_19[40+:8]);
 always @(posedge clk)if(!rst&&(select_1|select_2|select_19))parallel_reply_body[408+:8]<=({8{select_1}}&body_1[408+:8])|({8{select_2}}&body_2[408+:8])|({8{select_19}}&body_19[48+:8]);
 always @(posedge clk)if(!rst&&(select_2|select_19))parallel_reply_body[416+:8]<=({8{select_2}}&body_2[416+:8])|({8{select_19}}&body_19[56+:8]);
 always @(posedge clk)if(!rst&&(select_2))parallel_reply_body[424+:8]<=({8{select_2}}&body_2[424+:8]);
 always @(posedge clk)if(!rst&&(select_2))parallel_reply_body[432+:8]<=({8{select_2}}&body_2[432+:8]);
 always @(posedge clk)if(!rst&&(select_2))parallel_reply_body[440+:8]<=({8{select_2}}&body_2[440+:8]);
 always @(posedge clk)if(rst)parallel_reply_body[448+:8]<=0;
 always @(posedge clk)if(rst)parallel_reply_body[456+:8]<=0;
 always @(posedge clk)if(rst)parallel_reply_body[464+:8]<=0;
 always @(posedge clk)if(rst)parallel_reply_body[472+:8]<=0;
 always @(posedge clk)if(rst)parallel_reply_body[480+:8]<=0;
 always @(posedge clk)if(rst)parallel_reply_body[488+:8]<=0;
 always @(posedge clk)if(rst)parallel_reply_body[496+:8]<=0;
 end endgenerate

endmodule
