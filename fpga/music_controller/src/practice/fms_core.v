// W4 Bluetooth-only core. No SD/FAT controller or physical SD pins.
module fms_core #(parameter CLK_HZ=50000000,BOOT_DEMO=1,WITH_TEACHING=1,BYTE_PACKET=0,WITH_LOOP=0,WITH_LIVE=0)(
 input wire clk,rst,input wire [24:0] keys,
 input wire req_valid,output wire req_ready,input wire [7:0] req_command,input wire [31:0] req_session,
 input wire [15:0] req_sequence,input wire [6:0] req_length,input wire [511:0] req_payload,
 output wire reply_valid,input wire reply_ready,output wire [7:0] reply_command,output wire [31:0] reply_session,
 output wire [15:0] reply_sequence,output wire [6:0] reply_length,output wire [511:0] reply_payload,
 input wire local_valid,output wire local_ready,input wire [2:0] local_action,input wire [3:0] local_value,
 input wire local_next,local_load,
 output wire score_valid,output wire [15:0] song_id,note_count,output wire [31:0] generation,run_id,revision,time_us,duration_us,
 output wire mode,output wire [3:0] preset,output wire running,paused,preparing,finished,
 output wire [24:0] targets,correct,wrong,output wire [15:0] hits,misses,extras,
 output wire time_wait,output wire [2:0] timing_status,output wire [7:0] errors,
 output wire catalog_valid,output wire [4:0] song_count,output wire [3:0] selected,
 input wire [7:0] audio_faults,input wire audio_flushing,
 output wire automatic_enabled,automatic_flush,manual_reset,output wire [14:0] automatic_epoch,
 output wire automatic_valid,input wire automatic_ready,output wire [71:0] automatic_event,
 output wire [543:0] patches,output wire [67:0] gains,
 input wire display_req,output wire display_ready,input wire [10:0] display_index,
 output wire display_valid,input wire display_accept,output wire [79:0] display_data,input wire manual_panic,
 output wire [24:0] playable_keys,led_targets,led_correct,led_wrong,
 output wire playable_changed,keymap_flush,input wire environment_busy,score_owner,
 output wire heap_we,output wire[11:0]heap_wa,output wire[47:0]heap_wd,
 output wire[11:0]heap_ra,input wire[47:0]heap_rd,
 output wire[383:0]song_title,output wire[31:0]song_beat_us,
 output wire[127:0]record_status,output wire[31:0]keymap_revision,output wire upload_busy,activity_request,output wire[7:0]local_error,output wire[124:0]keymap_table,
 input wire[95:0]req_header,input wire[7:0]req_byte,output wire[5:0]req_byte_addr,
 input wire live_safe,live_panic,output wire live_active,output wire[24:0]live_keys,output wire[3:0]live_preset,
 input wire loop_safe,loop_armed,loop_cancel,input wire[255:0]loop_metadata,
 output wire loop_lock,loop_finished,loop_failed,output wire[11:0]loop_progress,
 output wire export_request,input wire export_ready,output wire export_kind,output wire[3:0]export_lane,output wire[6:0]export_address,
 input wire export_valid,export_enabled,input wire[7:0]export_count,input wire[135:0]export_patch,input wire[31:0]export_order,input wire[44:0]export_event,
 input wire[5:0]reply_byte_addr,output wire[7:0]reply_byte
);
wire erq,err,erv,era,nrq,nrr,nrv,nra;
 assign song_title=title;assign song_beat_us=nominal;assign keymap_revision=map_revision;assign keymap_table=map_table;
 assign upload_busy=ua || sbusy || boot_busy;
 assign activity_request=(service_cv && ca!=0 && (WITH_TEACHING || ca!=4 || cv!=0)) || (local_valid && local_ready && local_action!=0 && (WITH_TEACHING || local_action!=4 || local_value!=0)) || record_start;
 assign local_error=ce;
 assign record_status[31:0]=record_id;assign record_status[35:32]=record_preset;
 assign record_status[51:36]=record_ms;assign record_status[67:52]=record_total;assign record_status[83:68]=record_notes;
 assign record_status[91:84]=record_level;assign record_status[95:92]={record_failed,record_complete,record_closing,record_active};
 assign record_status[98:96]=record_reason;assign record_status[106:99]=record_error;assign record_status[127:107]=0;
 wire map_swap,map_restore,map_busy,map_done;wire [7:0] map_error;
 wire [31:0] map_revision,map_expected;wire [4:0] map_a,map_b;wire [124:0] map_table;
 wire record_start,record_stop,record_pop,record_abort,record_done;
 wire record_front_valid;wire [31:0] record_request_id;wire [7:0] record_error,record_level;wire [31:0] record_id;wire [3:0] record_preset;
 wire record_active,record_closing,record_complete,record_failed;wire [2:0] record_reason;
 wire [15:0] record_ms,record_total,record_notes;wire [63:0] record_front;
 fms_recorder #(.CLK_HZ(CLK_HZ)) recorder(clk,rst,playable_keys,preset,
  record_abort || manual_panic || manual_reset || ((record_active || record_closing) && preset!=record_preset),record_abort ? 3'd5 : 3'd4,
  (record_start || (local_valid && local_ready && local_action==6)),(record_stop || (local_valid && local_ready && local_action==7)),
  (record_start || record_stop) ? record_request_id : (local_action==6 ? record_id+32'd1 : record_id),record_done,record_error,record_pop,record_front,
  record_id,record_preset,record_active,record_closing,record_complete,record_failed,record_reason,
  record_ms,record_total,record_notes,record_level,record_front_valid);
 // The service is not idle on its record pulse, so local and service
 // recorder strobes cannot coincide. Unstrobed requested_id is don't-care.
 // Keep the wide ID data mux independent of environment_busy/local_ready.
 // synthesis translate_off
 always @(posedge clk)if(!rst && (record_start||record_stop) && local_valid&&local_ready&&local_action>=6)
  $fatal(1,"local/service recorder collision");
 // synthesis translate_on
 wire service_cv,service_cr,transport_cr,cd,req_ready_internal,library_ready,service_idle;wire [2:0] ca;wire [3:0] cv;wire [7:0] ce;
 reg [31:0] seen_generation;
 wire score_changed=generation!=seen_generation;
 wire transport_ready=transport_cr && !score_changed;
 wire [1:0] main_track;
 wire [383:0] title;wire [15:0] presets;wire [12:0] ec;wire [31:0] nominal;
 wire judge_start,judge_stop,judge_reconfigure,judge_paused,judge_done,judge_fault,transport_fault;
 wire [11:0] ea;wire [71:0] ed;wire [10:0] na;wire [79:0] nd;
 wire jq,jready,jvalid;wire [10:0] ji;wire [79:0] jd;
 wire sbusy,sdone,staged,ss,sa,sc,bv,br;wire [31:0] size,crc;wire [7:0] bd,se;
 wire ua,uss,usa,usc,ubv;wire [31:0] usize,ucrc;wire [7:0] ubyte;
 wire lss,lsa,lsc,lbv;wire [31:0] lsize,lcrc;wire [7:0] lbyte;
 wire lv,lr,ll,ldone,lbusy;wire [3:0] li;wire [1023:0] info;wire [7:0] le;
 wire boot_busy,bs,ba,bc,bbv;wire [31:0] bsize,bcrc;wire [7:0] bbyte;
 fms_keymap keymap(clk,rst,keys,targets,correct,wrong,
  !running && !preparing && !record_active && !record_closing && !ua && !sbusy && !boot_busy && !audio_flushing,
  map_swap,(map_restore||local_next),(local_next ? map_revision : map_expected),map_a,map_b,map_busy,map_done,keymap_flush,map_error,map_revision,map_table,
  playable_keys,playable_changed,led_targets,led_correct,led_wrong);
 assign errors=se | le;
 wire [7:0] faults=audio_faults | {6'd0,transport_fault,judge_fault};
 assign local_ready=!environment_busy && transport_ready && service_idle && !map_busy && !boot_busy && !ua && !lbusy && !sbusy;
 assign service_cr=transport_ready && !boot_busy && !map_busy;
 always @(posedge clk)if(rst)seen_generation<=0;else seen_generation<=generation;
 fms_transport #(.CLK_HZ(CLK_HZ),.WITH_TEACHING(WITH_TEACHING)) transport(
  clk,rst,score_valid,ec,duration_us,time_wait,judge_done,
  !boot_busy && (score_changed || service_cv || (local_valid && local_ready && local_action<6)),transport_cr,
  score_changed ? 3'd0 : service_cv ? ca : local_action,score_changed ? 4'd0 : service_cv ? cv : local_value,cd,ce,
  mode,preset,running,paused,finished,preparing,judge_paused,time_us,run_id,revision,
  judge_start,judge_stop,judge_reconfigure,automatic_enabled,automatic_flush,manual_reset,
  audio_flushing,automatic_epoch,automatic_valid,automatic_ready,automatic_event,ea,ed,transport_fault,erq,err,erv,era);
 fms_judge #(.CLK_HZ(CLK_HZ),.WITH_TEACHING(WITH_TEACHING)) judge(clk,rst,judge_start,judge_stop,judge_reconfigure,mode,running,judge_paused,
  time_us,duration_us,note_count,playable_keys,time_wait,judge_done,targets,correct,wrong,hits,misses,extras,timing_status,judge_fault,
  jq,jready,ji,jvalid,jd);
 fms_note_arbiter reader(clk,rst||score_owner||ss||sa||local_load,jq,jready,ji,jvalid,1'b1,jd,
  display_req,display_ready,display_index,display_valid,display_accept,display_data,na,nd,nrq,nrr,nrv,nra);
 fms_service #(.WITH_LOOP(WITH_LOOP),.WITH_TEACHING(WITH_TEACHING),.BYTE_PACKET(BYTE_PACKET),.WITH_LIVE(WITH_LIVE),.LIVE_LEASE_CYCLES(CLK_HZ)) service(clk,rst,req_valid && !boot_busy,req_ready_internal,req_command,req_session,req_sequence,req_length,req_payload,
  reply_valid,reply_ready,reply_command,reply_session,reply_sequence,reply_length,reply_payload,
  score_valid,running,paused,finished,preparing,mode,preset,song_id,note_count,hits,misses,extras,generation,run_id,revision,time_us,duration_us,
  title,presets,timing_status,faults,service_cv,service_cr,ca,cv,cd,ce,
  catalog_valid,song_count,le,lbusy || boot_busy,lv,lr,ll,li,ldone,info,
  ua,uss,usa,usc,usize,ucrc,ubv,br && ua,ubyte,sbusy,sdone,staged,se,service_idle,
  record_start,record_stop,record_pop,record_abort,record_request_id,
  record_done,record_error,record_id,record_preset,record_active,record_closing,record_complete,record_failed,
  record_reason,record_ms,record_total,record_notes,record_level,record_front,
  map_swap,map_restore,map_expected,map_a,map_b,map_done,map_error,map_revision,map_table,environment_busy,record_front_valid,req_header,req_byte,req_byte_addr,
  live_safe,live_panic||manual_panic||score_owner,live_active,live_keys,live_preset,
  loop_safe,loop_armed,loop_cancel,loop_metadata,loop_lock,loop_finished,loop_failed,loop_progress,export_request,export_ready,export_kind,export_lane,export_address,export_valid,export_enabled,export_count,export_patch,export_order,export_event,reply_byte_addr,reply_byte);
 assign req_ready=req_ready_internal && !boot_busy;
 // Reserved catalog signals are permanently empty in this board profile.
 // Legacy SD opcodes are explicitly rejected by service, never queued.
 assign catalog_valid=0;assign song_count=0;assign selected=0;
 assign le=0;assign lbusy=0;assign lr=0;assign ldone=0;assign info=0;
 assign lss=0;assign lsa=0;assign lsc=0;assign lsize=0;assign lcrc=0;assign lbv=0;assign lbyte=0;
 generate if(BOOT_DEMO)begin: diagnostic_demo
  fms_boot boot(clk,rst,boot_busy,bs,ba,bc,bsize,bcrc,bbv,br && boot_busy,bbyte,sbusy,sdone,staged,se);
 end else begin: empty_library_boot
  assign boot_busy=0;assign bs=0;assign ba=0;assign bc=0;assign bsize=0;assign bcrc=0;assign bbv=0;assign bbyte=0;
 end endgenerate
 assign ss=boot_busy ? bs : ua ? uss : lss;
 // ABORT also relinquishes ownership in the same cycle. Keep its pulse visible
 // after upload_active drops, otherwise a canceled clear/load would hang.
 assign sa=ba || usa || lsa;
 assign sc=boot_busy ? bc : ua ? usc : lsc;
 assign size=boot_busy ? bsize : ua ? usize : lsize;
 assign crc=boot_busy ? bcrc : ua ? ucrc : lcrc;
 assign bv=boot_busy ? bbv : ua ? ubv : lbv;
 assign bd=boot_busy ? bbyte : ua ? ubyte : lbyte;
 fms_store store(clk,rst,ss,sa,size,crc,bv,br,bd,sbusy,sdone,staged,se,sc,
  score_valid,generation,song_id,note_count,ec,duration_us,nominal,title,main_track,patches,gains,presets,ea,ed,na,nd,local_load,score_owner,erq,err,erv,era,nrq,nrr,nrv,nra,heap_we,heap_wa,heap_wd,heap_ra,heap_rd);
endmodule
