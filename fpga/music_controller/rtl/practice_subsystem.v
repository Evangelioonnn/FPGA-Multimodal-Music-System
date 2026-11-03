// W6 protocol/teaching/game frontend. All sounds go to the product audio core.
module practice_subsystem #(parameter WITH_RELEASE_HINT=0,WITH_LIBRARY=0,WITH_LOOP=0,CLK_HZ=50000000,CPB=(CLK_HZ+57600)/115200,BOOT_DEMO=0)(
 input wire library_safe,edit_step,input wire[1:0]edit_direction,
 output wire[191:0]library_status,output wire[319:0]library_title,
 input wire loop_safe,loop_armed,loop_cancel,input wire[255:0]loop_metadata,
 output wire loop_lock,loop_finished,loop_failed,output wire[11:0]loop_progress,
 output wire export_request,input wire export_ready,output wire export_kind,output wire[3:0]export_lane,output wire[6:0]export_address,
 input wire export_valid,export_enabled,input wire[7:0]export_count,input wire[135:0]export_patch,input wire[31:0]export_order,input wire[44:0]export_event,
 input wire clk,rst,uart_rx,bt_state,output wire uart_tx,
 input wire[24:0]keys,input wire[63:0]navigation,input wire activate,tim_step,input wire[1:0]tim_direction,
 input wire[10:0]function_keys,input wire panic,quiet,ram_stopped,safe_score,
 input wire score_request,score_active,
 output wire scene,audio_scene,library_audio_lock,output wire[24:0]playable_keys,led_targets,led_correct,led_wrong,
 output wire[3:0]preset,output wire[135:0]manual_patch,
 output wire event_valid,input wire event_ready,output wire[71:0]event_data,
 output wire[135:0]event_patch,output wire[67:0]gains,
 output wire automatic_flush,manual_reset,audio_manual_reset,input wire audio_flushing,input wire[7:0]audio_faults,
 output wire running,paused,time_wait,output wire[31:0]time_us,beat_us,run_id,
 output wire score_owner,score_toggle,
 input wire shared_score_read,input wire[8:0]shared_score_ra,
 output wire[47:0]shared_score_state,shared_score_control,
 input wire shared_score_state_we,input wire[8:0]shared_score_state_wa,input wire[47:0]shared_score_state_wd,
 input wire shared_score_control_we,input wire[8:0]shared_score_control_wa,input wire[47:0]shared_score_control_wd,
 input wire shared_score_ready,
 output wire[511:0]status,output wire[127:0]record_status,output wire[383:0]song_title,
 input wire keys_released_hint,
 input wire pixel_clk,pixel_rst,frame_start,input wire[8:0]map_address,output wire[63:0]map_data,output wire[415:0]visible);
 // WITH_RELEASE_HINT requires equality to (keys==0) on every clock;
 // standalone legacy users retain the original direct decode by default.
 wire keys_empty=WITH_RELEASE_HINT ? keys_released_hint : keys==0;
 `include "fms_functions.vh"
 (* async_reg="true" *)reg bt_meta,bt_sync;
 always @(posedge clk)if(rst)begin bt_meta<=0;bt_sync<=0;end else begin bt_meta<=bt_state;bt_sync<=bt_meta;end
 wire[7:0]rx_byte,tx_byte,command,reply_command;wire rbv,rbe,tbv,tbr,req_valid,req_ready,rv,rr;
 wire[31:0]session,reply_session;wire[15:0]wire_sequence,reply_sequence;wire[6:0]length,reply_length;wire[511:0]payload,reply_payload;
 bt_uart_rx #(.CLKS_PER_BIT(CPB)) receiver(clk,rst,uart_rx,rx_byte,rbv,rbe);
 wire[5:0]req_byte_addr,core_req_address,library_req_address;wire core_req_ready,library_rsp_ready;
 wire library_reply=WITH_LIBRARY&&(command>=8'hc0&&command<=8'hc3);
 assign req_ready=library_reply ? library_rsp_ready:core_req_ready;
 assign req_byte_addr=library_reply ? library_req_address:core_req_address;
 wire[5:0]unused_req_addr;wire[7:0]req_byte;wire[95:0]req_header;
 bt_packet_rx #(.BYTE_PORT(1)) packets(clk,rst,rx_byte,rbv,rbe,req_valid,req_ready,command,session,wire_sequence,length,payload,,,,req_byte_addr,req_byte,req_header);
 wire[7:0]reply_byte;wire[5:0]reply_byte_addr;
 // Preserve the64 capture clocks and private TX RAM. The service's full
 // parallel response bus is an unconnected observer in the physical top.
 wire tx_valid,tx_ready;wire[7:0]tx_command,tx_payload_byte;wire[31:0]tx_session;wire[15:0]tx_sequence;wire[6:0]tx_length;
 wire menu_valid,menu_ready;wire[7:0]menu_command,menu_byte;wire[31:0]menu_session;wire[15:0]menu_sequence;wire[6:0]menu_length;
 library_tx_arbiter mux(clk,rst,rv,rr,reply_command,reply_session,reply_sequence,reply_length,reply_byte,
  menu_valid,menu_ready,menu_command,menu_session,menu_sequence,menu_length,menu_byte,
  tx_valid,tx_ready,tx_command,tx_session,tx_sequence,tx_length,tx_payload_byte);
 practice_packet_tx #(.BYTE_PAYLOAD(1)) replies(clk,rst,tx_valid,tx_ready,tx_command,tx_session,tx_sequence,tx_length,512'd0,tx_byte,tbv,tbr,tx_payload_byte,reply_byte_addr);
 bt_uart_tx #(.CLKS_PER_BIT(CPB)) transmitter(clk,rst,tx_byte,tbv,tbr,uart_tx);
 wire local_valid,local_ready;wire[2:0]local_action;wire[3:0]local_value;wire release_song,confirm_release,denied,restore_mapping,confirm_mapping;wire[124:0]keymap_table;
 wire[7:0]last_action,local_error;wire[15:0]action_sequence;
 wire song_valid,mode,preparing,finished,upload_busy,activity_request;
 wire live_active;wire control_scene;reg realtime_scene;reg previous_live_active;reg panic_pending,previous_panic;
 wire library_loading,library_admit;wire library_lock=library_loading||library_admit;
 assign scene=control_scene||realtime_scene||library_lock;
 // Same-edge admission/transaction guards above are retained. This existing
 // loading FF bounds the added global safety cone before musical consumers.
 // Acceptance requires no keys, idle audio/Loop/guide, and no pending commands.
 assign audio_scene=control_scene||realtime_scene||library_loading;
 assign library_audio_lock=library_loading;
 always @(posedge clk)if(rst)realtime_scene<=0;else if(live_active)realtime_scene<=1;else if(keys_empty&&quiet&&!audio_flushing)realtime_scene<=0;
 // Flush a local request formed on the same clock as remote CLOSE.
 wire live_lock=live_active||previous_live_active;
 always @(posedge clk)begin
  if(rst)begin previous_live_active<=0;previous_panic<=0;panic_pending<=0;end
  else begin previous_live_active<=live_active;previous_panic<=panic;
   if(panic&&!previous_panic&&scene&&(running||paused||preparing))panic_pending<=1;
   else if(panic_pending&&local_valid&&local_ready&&local_action==0)panic_pending<=0;
  end
 end
 wire[24:0]live_keys,physical_playable_keys;wire[3:0]live_preset,core_preset;
 assign playable_keys=library_lock ? 25'd0 : physical_playable_keys|live_keys;
 assign preset=live_active ? live_preset : core_preset;
 wire[15:0]song_id,note_count,hits,misses,extras;wire[31:0]generation,revision,map_revision,duration_us;
 wire[2:0]timing_status;wire[7:0]errors;wire[24:0]targets,correct,wrong;
 wire automatic_enabled,keymap_flush,core_manual_reset,playable_changed;wire[14:0]epoch;
 wire auto_valid,auto_ready;wire[71:0]auto_event;wire[543:0]patches;
 wire hwe;wire[11:0]hwa,hra;wire[47:0]hwd,hrd;
 wire dq,dr,dv,da;wire[10:0]di;wire[79:0]dd;
 wire display_fault;wire environment_busy=(WITH_LIBRARY&&!library_lock&&!library_safe&&command==8'h58) || score_owner || (!scene && (!quiet || !ram_stopped || !keys_empty));
 wire live_safe=!library_lock&&!loop_lock&&!panic_pending&&!local_valid&&!environment_busy&&!running&&!preparing&&!upload_busy&&!record_status[92]&&!record_status[93]&&!audio_flushing&&keys_empty&&quiet&&ram_stopped;
 fms_core #(.WITH_LOOP(WITH_LOOP),.CLK_HZ(CLK_HZ),.BOOT_DEMO(BOOT_DEMO),.WITH_TEACHING(0),.BYTE_PACKET(1),.WITH_LIVE(1)) core(
  .clk(clk),.rst(rst),.keys(scene&&!library_lock ? keys : 25'd0),
  .req_valid(req_valid&&!library_reply),.req_ready(core_req_ready),.req_command(command),.req_session(session),.req_sequence(wire_sequence),.req_length(length),.req_payload(payload),.req_header(req_header),.req_byte(req_byte),.req_byte_addr(core_req_address),
  .reply_valid(rv),.reply_ready(rr),.reply_command(reply_command),.reply_session(reply_session),.reply_sequence(reply_sequence),.reply_length(reply_length),.reply_payload(reply_payload),.reply_byte_addr(reply_byte_addr),.reply_byte(reply_byte),
  .local_valid(local_valid&&!live_lock&&!library_lock),.local_ready(local_ready),.local_action(local_action),.local_value(local_value),.local_next(restore_mapping),.local_load(release_song),
  .score_valid(song_valid),.song_id(song_id),.note_count(note_count),.generation(generation),.run_id(run_id),.revision(revision),.time_us(time_us),.duration_us(duration_us),
  .mode(mode),.preset(core_preset),.running(running),.paused(paused),.preparing(preparing),.finished(finished),
  .targets(targets),.correct(correct),.wrong(wrong),.hits(hits),.misses(misses),.extras(extras),.time_wait(time_wait),.timing_status(timing_status),.errors(errors),
  .catalog_valid(),.song_count(),.selected(),.audio_faults(audio_faults|{7'd0,display_fault}),.audio_flushing(audio_flushing),
  .automatic_enabled(automatic_enabled),.automatic_flush(automatic_flush),.manual_reset(core_manual_reset),.automatic_epoch(epoch),
  .automatic_valid(auto_valid),.automatic_ready(auto_ready),.automatic_event(auto_event),.patches(patches),.gains(gains),
  .display_req(dq),.display_ready(dr),.display_index(di),.display_valid(dv),.display_accept(da),.display_data(dd),.manual_panic(panic),
  .playable_keys(physical_playable_keys),.led_targets(led_targets),.led_correct(led_correct),.led_wrong(led_wrong),.playable_changed(playable_changed),.keymap_flush(keymap_flush),
  .environment_busy(environment_busy),.score_owner(score_owner),.heap_we(hwe),.heap_wa(hwa),.heap_wd(hwd),.heap_ra(hra),.heap_rd(hrd),
  .song_title(song_title),.song_beat_us(beat_us),.record_status(record_status),.keymap_revision(map_revision),.upload_busy(upload_busy),.activity_request(activity_request),.local_error(local_error),.keymap_table(keymap_table),
  .loop_safe(loop_safe),.loop_armed(loop_armed),.loop_cancel(loop_cancel),.loop_metadata(loop_metadata),.loop_lock(loop_lock),.loop_finished(loop_finished),.loop_failed(loop_failed),.loop_progress(loop_progress),.export_request(export_request),.export_ready(export_ready),.export_kind(export_kind),.export_lane(export_lane),.export_address(export_address),.export_valid(export_valid),.export_enabled(export_enabled),.export_count(export_count),.export_patch(export_patch),.export_order(export_order),.export_event(export_event),
  .live_safe(live_safe),.live_panic(panic),.live_active(live_active),.live_keys(live_keys),.live_preset(live_preset));
 practice_controls #(.WITH_TEACHING(0)) controls(clk,rst,navigation,activate&&!live_active&&!library_lock,tim_step&&!live_active&&!library_lock,tim_direction,library_lock ? 11'd0:function_keys,panic||panic_pending,safe_score&&!library_lock,quiet,ram_stopped,keys_empty&&!library_lock,
  score_request&&!live_active&&!library_lock,score_active,shared_score_ready,song_valid,upload_busy,running,paused,preparing,mode,preset,
  record_status[92],record_status[93],activity_request||live_active,control_scene,local_valid,local_ready||live_lock||library_lock,local_action,local_value,
  score_owner,score_toggle,release_song,confirm_release,denied,last_action,action_sequence,restore_mapping,confirm_mapping);
 generate if(WITH_LIBRARY)begin: catalog
  reg previous_page;
  wire page=navigation[2:0]==5&&navigation[4:3]==0;
  always @(posedge clk)if(rst)previous_page<=0;else previous_page<=page;
  wire active,entry_ready,linked,unknown,selected_loaded,busy;
  wire[7:0]error;wire[5:0]count;wire[4:0]index;wire[15:0]id,notes;
  wire[31:0]duration;wire[16:0]size,received,total;
  wire safe=library_safe&&keys_empty&&quiet&&ram_stopped&&!live_lock&&!local_valid&&!running&&!paused&&!preparing&&
   !upload_busy&&!record_status[92]&&!record_status[93]&&!score_owner&&!score_request&&!audio_flushing&&audio_faults==0&&
   !tim_step&&function_keys==0&&!panic;
  library_client #(.TIMEOUT_CYCLES(CLK_HZ*10),.POLL_CYCLES(CLK_HZ/10)) menu(
   .clk(clk),.rst(rst),.enter(page&&!previous_page),.leave(!page&&previous_page),
   .next_song(page&&navigation[10]&&navigation[8:5]==1&&edit_step&&!edit_direction[1]),
   .previous_song(page&&navigation[10]&&navigation[8:5]==1&&edit_step&&edit_direction[1]),
   .confirm(page&&activate&&navigation[8:5]==6),.refresh(page&&activate&&navigation[8:5]==7),
   .safe_stopped(safe),.phone_connected(bt_sync),.panic(panic),.load_admit(library_admit),
   .ram_valid(song_valid),.ram_id(song_id),.ram_generation(generation),.upload_busy(upload_busy),.flushing(audio_flushing),
   .request_valid(menu_valid),.request_ready(menu_ready),.request_command(menu_command),.request_length(menu_length),
   .request_session(menu_session),.request_sequence(menu_sequence),.request_address(reply_byte_addr),.request_byte(menu_byte),
   .response_valid(req_valid&&library_reply),.response_ready(library_rsp_ready),.response_command(command),.response_session(session),
   .response_sequence(wire_sequence),.response_length(length),.response_address(library_req_address),.response_byte(req_byte),
   .active(active),.entry_ready(entry_ready),.loading(library_loading),.linked(linked),.unknown(unknown),.error(error),
   .count(count),.index(index),.selected_id(id),.selected_notes(notes),.selected_title(library_title),
   .selected_duration(duration),.selected_size(size),.received(received),.total(total),.selected_loaded(selected_loaded),.transaction_busy(busy));
  assign library_status={15'd0,total,15'd0,received,15'd0,size,duration,notes,id,3'd0,index,2'd0,count,error,
   bt_sync,busy,selected_loaded,unknown,linked,library_lock,entry_ready,active};
 end else begin:no_library
  assign library_loading=0;assign library_admit=0;assign menu_valid=0;assign menu_command=0;assign menu_length=0;
  assign menu_session=0;assign menu_sequence=0;assign menu_byte=0;assign library_rsp_ready=1;assign library_req_address=0;
  assign library_status=0;assign library_title=0;
 end endgenerate
 practice_shared_memory pool(clk,score_owner,hwe,hwa,hwd,hra,hrd,shared_score_read,shared_score_ra,shared_score_state,shared_score_control,
  shared_score_state_we,shared_score_state_wa,shared_score_state_wd,shared_score_control_we,shared_score_control_wa,shared_score_control_wd);
 // Decode ALL fields explicitly. Old TF72 and W6's72 are unrelated layouts.
 wire[1:0]op=auto_event[49:48],track=auto_event[51:50];
 assign event_valid=scene && automatic_enabled && auto_valid && op!=0;
 assign auto_ready=automatic_enabled && scene && (op==0 || event_ready);
 assign event_data={32'd0,auto_event[47:32],track,2'd0,op==2 ? 2'd1 : op==3 ? 2'd2 : 2'd0,auto_event[58:52],auto_event[66:59],3'd0};
 assign event_patch=patches[track*136+:136];
 // MarkerB freezes per-strike patch; global CH0 remains downstream and live.
 assign manual_patch=fms_patch({4'd0,preset},3'd3)|(136'd1<<132);
 reg previous_scene,previous_audio_scene;
 always @(posedge clk)if(rst)begin previous_scene<=0;previous_audio_scene<=0;end
 else begin previous_scene<=scene;previous_audio_scene<=audio_scene;end
 assign manual_reset=core_manual_reset||keymap_flush||(scene!=previous_scene);
 // R20: LOAD pre-admit control transition must not traverse musical reset.
 assign audio_manual_reset=core_manual_reset||keymap_flush||(audio_scene!=previous_audio_scene);
 assign status[15:0]={timing_status,denied,confirm_release,score_owner,bt_sync,upload_busy,time_wait,mode,finished,preparing,paused,running,scene,song_valid};
 assign status[31:16]=song_id;assign status[63:32]=generation;assign status[95:64]=run_id;assign status[127:96]=revision;
 assign status[159:128]=time_us;assign status[191:160]=duration_us;assign status[207:192]=note_count;assign status[223:208]=hits;assign status[239:224]=misses;assign status[255:240]=extras;
 assign status[287:256]=map_revision;assign status[291:288]=preset;assign status[299:292]=errors;
 assign status[307:300]=local_error;assign status[315:308]=last_action;assign status[331:316]=action_sequence;assign status[363:332]=beat_us;
 assign status[488:364]=keymap_table;assign status[489]=confirm_mapping;assign status[511:490]=0;
 wire[255:0]ui_state={8'd0,1'b0,4'd0,6'd0,5'd0,6'd0,4'd0,7'd0,
  running ? correct : playable_keys,generation,16'd0,song_id,duration_us,time_us,4'd0,
  2'd0,song_valid,finished,paused,running,preparing,running||preparing,wrong,targets};
 wire[127:0]extra_state={4'd0,preset,run_id,68'd0,7'd48,7'd48,2'd2,2'd2,mode,mode};
 wire[415:0]packet;wire packet_valid,packet_ready,published_bank;
 dual_exchange frames(clk,rst,packet_valid,packet_ready,packet,published_bank,pixel_clk,pixel_rst,frame_start,visible);
 fms_map roll(clk,rst||score_owner||upload_busy,rst||score_owner||upload_busy,{extra_state,ui_state},time_us,note_count,song_valid,generation,time_wait,timing_status,
  navigation[2:0]==5 && navigation[4:3]==1,published_bank,packet_ready,packet_valid,packet,
  dq,dr,di,dv,da,dd,display_fault,pixel_clk,map_address,map_data);
 // synthesis translate_off
 always @(posedge clk)if(!rst&&WITH_RELEASE_HINT&&keys_released_hint!==(keys==0))
  $fatal(1,"Noncoherent performance-key release hint");
 // synthesis translate_on
endmodule

