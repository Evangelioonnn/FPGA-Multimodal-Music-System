// Musical board adapter. All sideband outputs are synchronous to sys_clk50MHz.
// C must capture/handshake the complete bundle before crossing clock domains.
module control_audio_system #(
 parameter WITH_LIBRARY=0,WITH_GESTURE=0,WITH_V18=0,WITH_LOOP_EXPORT=0,WITH_NEW_FX=0,WITH_DD=0,ROW_CYCLES=2500,DEBOUNCE_FRAMES=4,ENC_CYCLES=2500,BUTTON_SAMPLES=60,
 LONG_CYCLES=50000000,CLEAR_CYCLES=100000000,BUTTON_CYCLES=150000,
 ADC_HALF_CYCLES=50,ADC_SCAN_CYCLES=50000,AUDIO_N=32,BT_CPB=434,WITH_PRACTICE=0,WITH_TF=0,WITH_SCORE=0,SCORE_N=512
)(output wire[191:0]ui_library_status,output wire[319:0]ui_library_title,
 input wire gesture_rx,output wire[15:0]ui_gesture_status,output wire[31:0]ui_gesture_expression_status,
 input wire dd_rx,dd_swap,dd_reload,record_source,output wire[63:0]ui_dd_status,output wire[63:0]ui_v18_status,
  input wire sys_clk,reset_n,panic_n,calibrate_n,
 input wire sd_miso,output wire sd_sclk,sd_mosi,sd_cs_n,output wire[255:0]ui_storage_status,
 input wire [5:0] col_n,output wire [5:0] row_n,
 input wire [2:0] enc_a,enc_b,enc_button_n,
 input wire adc_miso,output wire adc_sclk,adc_mosi,adc_cs_n,
 output wire [3:0] status_led,output wire rgb_data,
 output wire hp_bck,hp_ws,hp_din,pa_en,
 output wire [127:0] ui_score_status,output wire [95:0] ui_guide_status,
 output wire state_valid,output wire [639:0] state_data,
 output wire [255:0] controller_state,output wire [95:0] adc_raw,
 output wire pcm_valid,output wire signed [15:0] pcm_left,pcm_right,output wire [31:0] pcm_index,
 output wire pcm_sample_ce,
 output wire reset_active,output wire [159:0] ui_audio_status,
 output wire [119:0] ui_envelope_status,output wire [63:0] ui_layer_timbres,output wire [63:0] ui_synth_status,output wire [47:0] ui_harmonics,output wire ui_view,output wire [63:0] ui_navigation_state,input wire uart_rx,bt_state,output wire uart_tx,
 output wire[511:0]ui_practice_status,output wire[127:0]ui_record_status,output wire[383:0]ui_song_title,
 input wire pixel_clk,pixel_rst,frame_start,input wire[8:0]practice_map_address,
 output wire[63:0]practice_map_data,output wire[415:0]practice_visible
);
 reg [5:0] startup=0;
 always @(posedge sys_clk) if(!reset_n) startup<=0;else if(!startup[5]) startup<=startup+1'b1;
 wire reset_request=!startup[5]||!reset_n;wire rst=reset_active;
 wire [5:0] row_low;genvar g;
 generate for(g=0;g<6;g=g+1) begin: rows assign row_n[g]=row_low[g] ? 1'b0 : 1'bz;end endgenerate
 wire [35:0] matrix_keys;wire [24:0] identity_keys,pitch_keys;wire [10:0] function_keys;
 wire frame_valid,changed,performance_released;wire [2:0] step_valid,pressed,short_press,long_press,invalid;
 wire [5:0] steps;wire [47:0] positions;
 board_inputs #(.ROW_CYCLES(ROW_CYCLES),.DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),
  .ENC_CYCLES(ENC_CYCLES),.BUTTON_SAMPLES(BUTTON_SAMPLES),.LONG_CYCLES(LONG_CYCLES)) inputs(
  .clk(sys_clk),.rst(rst),.col_n(col_n),.row_low(row_low),.enc_a(enc_a),.enc_b(enc_b),.enc_button_n(enc_button_n),
  .matrix_keys(matrix_keys),.frame_valid(frame_valid),.changed(changed),.performance_keys(identity_keys),
  .function_keys(function_keys),.performance_released(performance_released),.step_valid(step_valid),.steps(steps),.pressed(pressed),
  .short_press(short_press),.long_press(long_press),.invalid_transition(invalid),.positions(positions));
 control_key_map key_map(identity_keys,pitch_keys);
 wire panic_down,panic_press,panic_release,cal_down,cal_press,cal_release;
 playable_button #(.DEBOUNCE_CYCLES(BUTTON_CYCLES)) panic_button(sys_clk,rst,panic_n,panic_down,panic_press,panic_release);
 playable_button #(.DEBOUNCE_CYCLES(BUTTON_CYCLES)) cal_button(sys_clk,rst,calibrate_n,cal_down,cal_press,cal_release);
 wire sample_ce,mix_mode;
 wire score_active,practice_audio_scene,shared_score_owner,nav_activate;
 wire practice_scene,library_audio_lock,practice_control_manual_reset; // frontend control view; registered-loading audio gate below
 wire[63:0]v18_status_raw;
 assign ui_v18_status=WITH_NEW_FX ? v18_status_raw : {v18_status_raw[63:16],v18_status_raw[15:14],12'd0,1'b0,audio_state[83]};
 wire[1:0]cfg_space,cfg_filter;wire[3:0]cfg_cutoff;wire[2:0]cfg_rate,cfg_depth;
 wire cfg_swap,cfg_reload,cfg_source,loop_export_armed,loop_export_cancel;
 wire loop_export_lock,loop_export_finished,loop_export_failed;wire[11:0]loop_export_progress;
 v18_controls #(.WITH_LOOP_EXPORT(WITH_LOOP_EXPORT),.WITH_NEW_FX(WITH_NEW_FX)) additions(.clk(sys_clk),.rst(rst),.enabled(WITH_V18!=0),
  .locked(loop_export_lock||score_active||practice_audio_scene||shared_score_owner),.record_locked(session_state[8]||(|session_state[14:9])),
  .navigation(ui_navigation_state),.dd_status(ui_dd_status),.activate(nav_activate),.edit_step(step_valid[2]),.direction(steps[5:4]),
  .export_lock(loop_export_lock),.export_finished(loop_export_finished),.export_failed(loop_export_failed),.export_progress(loop_export_progress),
  .space_type(cfg_space),.filter_type(cfg_filter),.cutoff(cfg_cutoff),.chorus_rate(cfg_rate),.chorus_depth(cfg_depth),
  .record_source(cfg_source),.dd_swap(cfg_swap),.dd_reload(cfg_reload),.export_armed(loop_export_armed),.export_cancel(loop_export_cancel),.status(v18_status_raw));

 wire practice_running,practice_paused,practice_wait,practice_flush,practice_manual_reset,practice_flushing,practice_quiet,practice_ram_stopped;
 wire[24:0]practice_keys,practice_targets,practice_correct,practice_wrong;wire[3:0]practice_preset;
 wire practice_event_valid,practice_event_ready;wire[71:0]practice_event;wire[135:0]practice_event_patch,practice_patch;wire[67:0]practice_gains;
 wire[31:0]practice_time,practice_beat,practice_run_id;
 wire shared_score_read,shared_score_state_we,shared_score_control_we,shared_score_ready;
 wire[8:0]shared_score_ra,shared_score_state_wa,shared_score_control_wa;
 wire[47:0]shared_score_state,shared_score_control,shared_score_state_wd,shared_score_control_wd;
 wire score_go,score_entry_safe;

 // Observer strobe is the real DAC input latch edge; render completion may move
 // inside its1040-clock budget. This output never acknowledges or gates audio.
 assign pcm_sample_ce=sample_ce;
 wire scan_valid,scan_ready,fader_ready,analog_ready;wire [95:0] scan_data;
 wire [31:0] adc_sequence,adc_skipped;
 mcp3208_reader #(.HALF_CYCLES(ADC_HALF_CYCLES),.SCAN_CYCLES(ADC_SCAN_CYCLES)) adc(
  .clk(sys_clk),.rst(rst),.miso(adc_miso),.sclk(adc_sclk),.mosi(adc_mosi),.cs_n(adc_cs_n),
  .scan_valid(scan_valid),.scan_ready(scan_ready),.scan_data(scan_data),.sequence(adc_sequence),.skipped_scans(adc_skipped));
 assign scan_ready=fader_ready&&analog_ready;
 wire [59:0] reversed_faders;
 generate for(g=0;g<5;g=g+1) begin: reverse_faders
  assign reversed_faders[g*12+:12]=12'd4095-scan_data[g*12+:12];
 end endgenerate
 wire [87:0] envelope_status;wire[31:0] envelope_control;
 assign ui_envelope_status={envelope_control,envelope_status};
 wire [47:0] harmonic_targets,fader_targets;wire [63:0] synth_status;wire [67:0] mixer_targets,mixer_data;
 wire [3:0] invalidate,acquired;wire [59:0] adc_data;wire adc_valid,adc_ready,mixer_valid,mixer_ready;
 fader_mode_adapter faders(.clk(sys_clk),.rst(rst),.mix_mode(mix_mode&&!practice_audio_scene),
  .scan_valid(scan_valid&&analog_ready),.scan_ready(fader_ready),.scan_data(reversed_faders),
  .harmonic_targets(fader_targets),.mixer_targets(mixer_targets),.invalidate(invalidate),
  .adc_valid(adc_valid),.adc_ready(adc_ready),.adc_data(adc_data),
  .mixer_valid(mixer_valid),.mixer_ready(mixer_ready),.mixer_data(mixer_data),.acquired(acquired));
 wire [83:0] analog_smooth;wire [23:0] centers;wire [31:0] scans;wire adc_stale;
 wire signed [4:0] bend;wire [6:0] vibrato;wire signed [12:0] expression_x,expression_y;
 reg [25:0] cal_duration;reg cal_fired,calibrate;reg [1:0] calibration_result;reg [15:0] calibration_sequence;
 wire [127:0] session_state;wire [159:0] audio_state;
 always @(posedge sys_clk) begin
  if(rst) begin cal_duration<=0;cal_fired<=0;calibrate<=0;calibration_result<=0;calibration_sequence<=0;end
  else begin
   calibrate<=0;
   if(!cal_down) begin cal_duration<=0;cal_fired<=0;end
   else if(!cal_fired) begin
    if(cal_duration==LONG_CYCLES-1) begin
     cal_fired<=1;calibration_sequence<=calibration_sequence+1'b1;calibration_result<=2;
     if(performance_released&&!session_state[8]&&!(|session_state[14:9])&&!adc_stale) begin calibrate<=1;calibration_result<=1;end
    end else cal_duration<=cal_duration+1'b1;
   end
  end
 end
 board_analog analog(.clk(sys_clk),.rst(rst),.sample_ce(sample_ce),
  .scan_valid(scan_valid&&fader_ready),.scan_ready(analog_ready),.scan_data(scan_data),.calibrate(calibrate),
  .raw(adc_raw),.smooth(analog_smooth),.centers(centers),.scans(scans),.stale(adc_stale),
  .bend(bend),.vibrato(vibrato),.x_expression(expression_x),.y_expression(expression_y));
 assign ui_synth_status=synth_status;assign ui_audio_status=audio_state;assign ui_harmonics=harmonic_targets;
 wire [2:0] nav_tab;wire [1:0] nav_sub;wire [3:0] nav_focus;
 wire nav_browse,nav_editing,nav_armed,nav_confirm,expression_enable;
 control_navigation #(.WITH_LIBRARY(WITH_LIBRARY),.WITH_GESTURE(WITH_GESTURE),.WITH_LOOP_EXPORT(WITH_LOOP_EXPORT),.WITH_NEW_FX(WITH_NEW_FX),.WITH_V18(WITH_V18),.WITH_STORAGE(WITH_TF),.WITH_PRACTICE(WITH_PRACTICE)) navigation(.clk(sys_clk),.rst(rst),.mode_toggle(short_press[0]),.home(long_press[0]),
  .edit_press(short_press[2]),.back(long_press[2]),.stale(adc_stale),.x(expression_x),.y(expression_y),
  .preset(session_state[5:3]),.practice_locked(practice_audio_scene),.selected_track(session_state[7:6]),.tab(nav_tab),.subpage(nav_sub),
  .focus(nav_focus),.browse(nav_browse),.editing(nav_editing),.armed(nav_armed),.confirm_clear(nav_confirm),
  .v18_config(ui_v18_status),.envelope_selected(envelope_control[1:0]),.release_select(short_press[1]&&!long_press[1]),
  .activate(nav_activate),.expression_enable(expression_enable),.state(ui_navigation_state));
 assign ui_view=nav_tab==3;
 wire score_toggle;assign score_active=ui_score_status[0];
 wire [2:0] score_size;wire [1:0] score_group;wire score_probe;
 wire guide_start,guide_pause,guide_stop,guide_loop;
 wire signed [5:0] guide_transpose;
 wire guide_running,guide_paused,guide_step,guide_beat,guide_done,guide_range;
 wire [4:0] guide_index;wire [24:0] guide_keys,guide_next;
 wire [7:0] guide_bpm;
 score_guide_controls extra_controls(.clk(sys_clk),.rst(rst),.navigation(ui_navigation_state),
  .activate(nav_activate),.step_valid(step_valid[2]),.step(steps[5:4]),.score_active(score_active),
  .score_toggle(score_toggle),.score_size(score_size),.score_group(score_group),.score_probe(score_probe),
  .guide_start(guide_start),.guide_pause(guide_pause),.guide_stop(guide_stop),
  .guide_loop(guide_loop),.guide_transpose(guide_transpose));
 offline_song_guide guide(.clk(sys_clk),.rst(rst),.sample_ce(sample_ce),
  .start_pulse(guide_start&&!score_active),.pause_pulse(guide_pause),.stop_pulse(guide_stop||panic_press),
  .loop_enable(guide_loop),.bpm(session_state[23:16]),.transpose_semitones(guide_transpose),
  .running(guide_running),.paused(guide_paused),.step_index(guide_index),.current_keys(guide_keys),
  .next_keys(guide_next),.step_pulse(guide_step),.beat_pulse(guide_beat),.done_pulse(guide_done),
  .out_of_range(guide_range),.bpm_effective(guide_bpm));
 assign ui_guide_status={23'd0,guide_next,guide_keys,guide_transpose,guide_bpm,
  guide_index,guide_range,guide_loop,guide_paused,guide_running};
 wire command_busy;wire [7:0] last_command;wire last_accepted,last_applied;
 wire storage_owner,storage_pause,storage_flush,storage_fx,storage_source_safe,storage_ram_stopped;
 wire[7:0]storage_wet;wire[67:0]storage_gains;wire storage_event_valid,storage_event_ready;
 wire[71:0]storage_event;wire[135:0]storage_patch;wire[255:0]storage_snapshot;
 wire export_request,export_ready,export_kind,export_valid,export_response_ready,export_enabled;
 wire phone_export_request,phone_export_kind;wire[3:0]phone_export_lane;wire[6:0]phone_export_address;
 wire[255:0]loop_metadata={68'd0,audio_state[16:0],ui_v18_status[15:0],storage_snapshot[154:103],(WITH_NEW_FX ? cfg_space!=0 : audio_state[83]),storage_snapshot[101:0]};
 wire loop_export_safe=WITH_LOOP_EXPORT&&!practice_audio_scene&&!score_active&&!shared_score_owner&&storage_ram_stopped&&!command_busy&&!ui_valid&&!nav_activate;

 wire[3:0]export_lane;wire[6:0]export_address;wire[7:0]export_count;wire[135:0]export_patch;wire[31:0]export_order;wire[44:0]export_event;
 generate if(WITH_TF)begin: storage
  wire cmd_valid,cmd_ready;wire[3:0]cmd;wire[4:0]idx;wire[15:0]seq;
  wire ack;wire[15:0]ack_seq;wire[7:0]ack_reason;
  tf_ui_controls controls(sys_clk,rst,ui_navigation_state,nav_activate,step_valid[2],steps[5:4],function_keys,ui_storage_status,storage_owner,cmd_valid,cmd_ready,cmd,idx,seq);
  tf_storage tf(.clk(sys_clk),.rst(rst),.sample_ce(sample_ce),.panic(panic_press),.sd_miso(sd_miso),.sd_sclk(sd_sclk),.sd_mosi(sd_mosi),.sd_cs_n(sd_cs_n),
   .command_valid(cmd_valid),.command_ready(cmd_ready),.command(cmd),.command_index(idx),.command_sequence(seq),.ack_valid(ack),.ack_sequence(ack_seq),.ack_reason(ack_reason),
   .source_safe(storage_source_safe),.ram_stopped(storage_ram_stopped),.save_snapshot(storage_snapshot),
   .owner(storage_owner),.paused(storage_pause),.flush(storage_flush),.track_gains(storage_gains),.scene_enable(storage_fx),.scene_wet(storage_wet),
   .event_valid(storage_event_valid),.event_ready(storage_event_ready),.event_data(storage_event),.event_patch(storage_patch),.status(ui_storage_status),
   .export_request(export_request),.export_ready(export_ready),.export_kind(export_kind),.export_lane(export_lane),.export_address(export_address),
   .export_valid(export_valid),.export_response_ready(export_response_ready),.export_enabled(export_enabled),.export_count(export_count),.export_patch(export_patch),.export_order(export_order),.export_event(export_event));
 end else begin: no_storage
  assign sd_sclk=0;assign sd_mosi=1;assign sd_cs_n=1;assign ui_storage_status=0;
  assign storage_owner=0;assign storage_pause=0;assign storage_flush=0;assign storage_gains=0;assign storage_fx=0;assign storage_wet=0;
  assign storage_event_valid=0;assign storage_event=0;assign storage_patch=0;
  assign export_request=phone_export_request;assign export_kind=phone_export_kind;assign export_lane=phone_export_lane;assign export_address=phone_export_address;assign export_response_ready=1;
 end endgenerate
 wire command_valid,command_ready,command_ack,command_accepted,command_applied;
 wire [7:0] command_addr,ack_addr,ack_reason;wire [31:0] command_value,ack_value;
 wire [2:0] focus;wire [6:0] left_base,right_base,base_depth;wire [2:0] vibrato_speed;
 wire custom_hold,control_overflow;wire [31:0] rejected;wire [7:0] last_reason;wire [15:0] result_sequence;
 control_policy #(.WITH_GESTURE(WITH_GESTURE),.WITH_NEW_FX(WITH_NEW_FX),.WITH_V18(WITH_V18),.CLEAR_CYCLES(CLEAR_CYCLES)) policy(.clk(sys_clk),.rst(rst),.function_keys((WITH_LIBRARY&&library_audio_lock) ? 11'd0 : (score_active||shared_score_owner) ? 11'd0 : practice_audio_scene ? function_keys&11'h010 : (storage_owner||ui_storage_status[7]) ? function_keys&11'h7f0 : function_keys),
  .enc_short((score_active||practice_audio_scene||shared_score_owner) ? short_press&3'b101 : short_press),.enc_long(long_press),.step_valid(practice_audio_scene ? 3'd0 : (score_active||shared_score_owner) ? step_valid&3'b100 : step_valid),.steps(steps),.panic_request(panic_press),
  .gesture_status(ui_gesture_status),.envelope_status(envelope_status),.envelope_control(envelope_control),.session_state(session_state),.audio_state(audio_state),.harmonic_targets(harmonic_targets),
  .adc_stale(adc_stale||!expression_enable),.joystick_bend(bend),.joystick_vibrato(vibrato),
  .synth_status(synth_status),.navigation(ui_navigation_state),.nav_activate((score_active||practice_audio_scene||shared_score_owner) ? 1'b0 : nav_activate),.lock_audio(loop_export_lock||score_active||practice_audio_scene||shared_score_owner),.mixer_targets(mixer_targets),
  .valid(command_valid),.ready(command_ready),.ack_valid(command_ack),.ack_accepted(command_accepted),
  .command_busy(command_busy),.last_action(last_command),.action_accepted(last_accepted),.action_applied(last_applied),
  .ack_applied(command_applied),.ack_addr(ack_addr),.ack_reason(ack_reason),.ack_value(ack_value),.addr(command_addr),.value(command_value),
  .focus(focus),.left_base(left_base),.right_base(right_base),.overflow(control_overflow),.rejected(rejected),
  .last_reason(last_reason),.result_sequence(result_sequence),.base_depth(base_depth),.vibrato_speed(vibrato_speed),.custom_hold(custom_hold));
 wire remote_valid,remote_ready,remote_ack,remote_accepted,remote_applied;
 wire [4:0] remote_addr,remote_ack_addr;wire [31:0] remote_value,remote_ack_value;
 wire ui_valid,ui_ready,ui_ack,ui_accepted,ui_applied,menu_drums,protocol_error;
 wire [7:0] ui_addr,ui_reason;wire [31:0] ui_value;
 session_dispatcher dispatcher(.clk(sys_clk),.rst(rst),.host_valid(command_valid),.host_ready(command_ready),
  .host_addr(command_addr),.host_value(command_value),.ack_valid(command_ack),.ack_addr(ack_addr),.ack_value(ack_value),
  .ack_accepted(command_accepted),.ack_applied(command_applied),.ack_reason(ack_reason),
  .audio_valid(remote_valid),.audio_ready(remote_ready),.audio_addr(remote_addr),.audio_value(remote_value),
  .audio_ack_valid(remote_ack),.audio_ack_addr(remote_ack_addr),.audio_ack_value(remote_ack_value),
  .audio_ack_accepted(remote_accepted),.audio_ack_applied(remote_applied),
  .ui_valid(ui_valid),.ui_ready(ui_ready),.ui_addr(ui_addr),.ui_value(ui_value),
  .ui_ack(ui_ack),.ui_accepted(ui_accepted),.ui_applied(ui_applied),.ui_reason(ui_reason),
  .menu_drums_commit(menu_drums),.protocol_error(protocol_error));
 control_audio_platform #(.WITH_GESTURE(WITH_GESTURE),.WITH_LOOP_EXPORT(WITH_LOOP_EXPORT),.WITH_NEW_FX(WITH_NEW_FX),.WITH_DD(WITH_DD),.WITH_PRACTICE(WITH_PRACTICE),.AUDIO_N(AUDIO_N),.WITH_TF(WITH_TF),.WITH_SCORE(WITH_SCORE),.SCORE_N(SCORE_N)) platform(.sys_clk(sys_clk),.reset_request(reset_request),.reset_active(reset_active),
  .gesture_rx(gesture_rx),.gesture_toggle(WITH_GESTURE&&nav_activate&&nav_tab==4&&nav_sub==1&&nav_focus==2),.gesture_status(ui_gesture_status),.gesture_expression_status(ui_gesture_expression_status),
  .loop_export_lock(loop_export_lock),.space_type(cfg_space),.filter_type(cfg_filter),.filter_cutoff(cfg_cutoff),.chorus_rate(cfg_rate),.chorus_depth(cfg_depth),
  .dd_rx(dd_rx),.dd_swap(WITH_V18 ? cfg_swap : dd_swap),.dd_reload(WITH_V18 ? cfg_reload : dd_reload),.record_source(WITH_V18 ? cfg_source : record_source),.dd_status(ui_dd_status),.tf_owner(storage_owner),.tf_pause(storage_pause),.tf_flush(storage_flush),.tf_lock(ui_storage_status[7]),.tf_fx(storage_fx),.tf_wet(storage_wet),
  .tf_event_valid(storage_event_valid),.tf_event_ready(storage_event_ready),.tf_event_data(storage_event),.tf_event_patch(storage_patch),.tf_track_gains(storage_gains),
  .tf_source_safe(storage_source_safe),.tf_ram_stopped(storage_ram_stopped),.tf_save_snapshot(storage_snapshot),
  .export_request(export_request),.export_ready(export_ready),.export_kind(export_kind),.export_lane(export_lane),.export_address(export_address),
  .export_valid(export_valid),.export_response_ready(export_response_ready),.export_enabled(export_enabled),.export_count(export_count),.export_patch(export_patch),.export_order(export_order),.export_event(export_event),
  .score_toggle(score_go),.score_size(score_size),.score_group(score_group),.score_probe(score_probe),
  .score_safe(score_entry_safe),
  .score_panic(panic_press),.score_status(ui_score_status),
  .shared_score_owner(shared_score_owner),.shared_score_read(shared_score_read),.shared_score_ra(shared_score_ra),
  .shared_score_state(shared_score_state),.shared_score_control(shared_score_control),
  .shared_score_state_we(shared_score_state_we),.shared_score_state_wa(shared_score_state_wa),.shared_score_state_wd(shared_score_state_wd),
  .shared_score_control_we(shared_score_control_we),.shared_score_control_wa(shared_score_control_wa),.shared_score_control_wd(shared_score_control_wd),.shared_score_ready(shared_score_ready),
  .practice_mode(practice_audio_scene),.practice_manual_reset(practice_manual_reset),.practice_preset(practice_preset),.practice_patch(practice_patch),
  .practice_event_valid(practice_event_valid),.practice_event_ready(practice_event_ready),.practice_event(practice_event),.practice_event_patch(practice_event_patch),.practice_gains(practice_gains),
  .practice_flush(practice_flush),.practice_running(practice_running),.practice_paused(practice_paused),.practice_wait(practice_wait),
  .practice_time(practice_time),.practice_beat(practice_beat),.practice_run_id(practice_run_id),
  .practice_flushing(practice_flushing),.practice_quiet(practice_quiet),.practice_ram_stopped(practice_ram_stopped),
  .physical_keys(practice_audio_scene ? practice_keys : pitch_keys),.sample_ce(sample_ce),.performance_status(audio_state),.session_status(session_state),
  .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.pa_en(pa_en),
  .adc_valid(adc_valid),.adc_ready(adc_ready),.adc_data(adc_data),
  .mixer_valid(mixer_valid),.mixer_ready(mixer_ready),.mixer_data(mixer_data),
  .mix_mode(mix_mode),.harmonic_targets(harmonic_targets),.fader_targets(fader_targets),.synth_status(synth_status),.envelope_status(envelope_status),.mixer_targets(mixer_targets),.fader_invalidate(invalidate),
  .remote_valid(remote_valid),.remote_ready(remote_ready),.remote_addr(remote_addr),.remote_value(remote_value),
  .remote_ack_valid(remote_ack),.remote_ack_addr(remote_ack_addr),.remote_ack_value(remote_ack_value),
  .remote_ack_accepted(remote_accepted),.remote_ack_applied(remote_applied),
  .ui_valid(ui_valid),.ui_ready(ui_ready),.ui_addr(ui_addr),.ui_value(ui_value),
  .ui_ack(ui_ack),.ui_accepted(ui_accepted),.ui_applied(ui_applied),.ui_reason(ui_reason),
  .menu_drums_commit(menu_drums),.ui_mixer_pickup(acquired),
  .ui_layer_timbres(ui_layer_timbres),.ui_snapshot_valid(state_valid),.ui_snapshot_data(state_data),
  .pcm_valid(pcm_valid),.pcm_left(pcm_left),.pcm_right(pcm_right),.pcm_index(pcm_index));
 assign score_entry_safe=performance_released&&!session_state[8]&&!(|session_state[14:9])&&!session_state[15]&&session_state[5:3]!=6&&!guide_running&&!guide_paused&&!storage_owner&&!ui_storage_status[7]&&ui_storage_status[3:0]!=4;
 generate if(WITH_PRACTICE)begin: practice
  practice_subsystem #(.WITH_LIBRARY(WITH_LIBRARY),.WITH_LOOP(WITH_LOOP_EXPORT),.CPB(BT_CPB),.WITH_RELEASE_HINT(1)) frontend(.clk(sys_clk),.rst(rst),.uart_rx(uart_rx),.bt_state(bt_state),.uart_tx(uart_tx),
   .library_safe(performance_released&&ui_dd_status[21:9]==0&&!ui_dd_status[0]&&!session_state[8]&&!(|session_state[15:9])&&
    !guide_running&&!guide_paused&&!storage_owner&&!command_busy&&!command_valid&&!ui_valid&&!score_active),
   .edit_step(step_valid[2]),.edit_direction(steps[5:4]),.library_status(ui_library_status),.library_title(ui_library_title),
   .loop_safe(loop_export_safe),.loop_armed(loop_export_armed),.loop_cancel(loop_export_cancel),.loop_metadata(loop_metadata),
   .loop_lock(loop_export_lock),.loop_finished(loop_export_finished),.loop_failed(loop_export_failed),.loop_progress(loop_export_progress),
   .export_request(phone_export_request),.export_ready(export_ready),.export_kind(phone_export_kind),.export_lane(phone_export_lane),.export_address(phone_export_address),
   .export_valid(export_valid),.export_enabled(export_enabled),.export_count(export_count),.export_patch(export_patch),.export_order(export_order),.export_event(export_event),
   .keys(pitch_keys),.keys_released_hint(performance_released),.navigation(ui_navigation_state),.activate(nav_activate),.tim_step(step_valid[0]),.tim_direction(steps[1:0]),.function_keys(function_keys),.panic(panic_press),
   .quiet(practice_quiet),.ram_stopped(practice_ram_stopped),.safe_score(score_entry_safe),.score_request(score_toggle),.score_active(score_active),
   .scene(practice_scene),.audio_scene(practice_audio_scene),.library_audio_lock(library_audio_lock),.playable_keys(practice_keys),.led_targets(practice_targets),.led_correct(practice_correct),.led_wrong(practice_wrong),
   .preset(practice_preset),.manual_patch(practice_patch),.event_valid(practice_event_valid),.event_ready(practice_event_ready),.event_data(practice_event),.event_patch(practice_event_patch),.gains(practice_gains),
   .automatic_flush(practice_flush),.manual_reset(practice_control_manual_reset),.audio_manual_reset(practice_manual_reset),.audio_flushing(practice_flushing),.audio_faults({7'd0,session_state[79]}),
   .running(practice_running),.paused(practice_paused),.time_wait(practice_wait),.time_us(practice_time),.beat_us(practice_beat),.run_id(practice_run_id),.score_owner(shared_score_owner),.score_toggle(score_go),
   .shared_score_read(shared_score_read),.shared_score_ra(shared_score_ra),.shared_score_state(shared_score_state),.shared_score_control(shared_score_control),
   .shared_score_state_we(shared_score_state_we),.shared_score_state_wa(shared_score_state_wa),.shared_score_state_wd(shared_score_state_wd),
   .shared_score_control_we(shared_score_control_we),.shared_score_control_wa(shared_score_control_wa),.shared_score_control_wd(shared_score_control_wd),.shared_score_ready(shared_score_ready),
   .status(ui_practice_status),.record_status(ui_record_status),.song_title(ui_song_title),
   .pixel_clk(pixel_clk),.pixel_rst(pixel_rst),.frame_start(frame_start),.map_address(practice_map_address),.map_data(practice_map_data),.visible(practice_visible));
 end else begin: no_practice
  assign ui_library_status=0;assign ui_library_title=0;
  assign loop_export_lock=0;assign loop_export_finished=0;assign loop_export_failed=0;assign loop_export_progress=0;
  assign phone_export_request=0;assign phone_export_kind=0;assign phone_export_lane=0;assign phone_export_address=0;
  assign practice_scene=0;assign practice_control_manual_reset=0;assign library_audio_lock=0;assign practice_audio_scene=0;assign practice_keys=0;assign practice_targets=0;assign practice_correct=0;assign practice_wrong=0;assign practice_preset=0;
  assign practice_patch=0;assign practice_event_valid=0;assign practice_event=0;assign practice_event_patch=0;assign practice_gains=0;assign practice_flush=0;assign practice_manual_reset=0;
  assign practice_running=0;assign practice_paused=0;assign practice_wait=0;assign practice_time=0;assign practice_beat=0;assign practice_run_id=0;
  assign shared_score_owner=0;assign shared_score_state=0;assign shared_score_control=0;assign score_go=score_toggle;
  assign uart_tx=1;assign ui_practice_status=0;assign ui_record_status=0;assign ui_song_title=0;assign practice_map_data=0;assign practice_visible=0;
 end endgenerate
 reg [25:0] uptime;reg [18:0] refresh_count;
 wire refresh=refresh_count==499999;
 always @(posedge sys_clk) if(rst) begin uptime<=0;refresh_count<=0;end
  else begin uptime<=uptime+1'b1;refresh_count<=refresh ? 0 : refresh_count+1'b1;end
 assign status_led[0]=(session_state[8]||session_state[15])&&
  session_state[78:72]<(session_state[71:69]==0 ? 10 : 5);
 assign status_led[1]=session_state[11] ? uptime[22] :
  (session_state[9]||session_state[12]) ? uptime[24] : session_state[8];
 assign status_led[2]=(WITH_GESTURE ? ui_gesture_status[3]:audio_state[81])&&!practice_audio_scene; // Connector3 -> physical LED5, above KEY10.
 assign status_led[3]=audio_state[82]&&!practice_audio_scene; // Connector4 -> physical LED6, above KEY11.
 wire [599:0] requested_frame,base_frame,guide_frame;
 wire [3:0] palette_timbre=practice_audio_scene ? practice_preset : session_state[5:3]==1 ? 4'd10 : session_state[5:3]==7 ? 4'd7+{2'd0,audio_state[147:146]} : {1'b0,session_state[5:3]};
 // Keyboard feedback does not latch historical warnings. Diagnostics retain causes.
 control_rgb_palette palette(identity_keys,palette_timbre,base_frame);
 control_guide_rgb guide_palette(.pressed_identity(identity_keys),.current_pitch(guide_keys),
  .next_pitch(guide_next),.normal_frame(base_frame),.frame(guide_frame));
 assign requested_frame=(guide_running||guide_paused) ? guide_frame : base_frame;
 reg rgb_valid,first_rgb;reg [131:0] rgb_frame;wire rgb_ready;
 always @(posedge sys_clk) begin
  if(rst) begin rgb_valid<=0;first_rgb<=1;rgb_frame<=0;end
  else begin
   if(rgb_valid&&rgb_ready) begin rgb_valid<=0;first_rgb<=0;end
   if(!rgb_valid&&rgb_ready&&(refresh||first_rgb)) begin rgb_valid<=1;rgb_frame<={practice_audio_scene,practice_correct,practice_wrong,first_rgb,(practice_audio_scene||guide_running||guide_paused),palette_timbre,(practice_audio_scene ? 25'd0 : guide_next),(practice_audio_scene ? practice_targets : guide_keys),identity_keys};end
  end
 end
 sk6812_012 rgb(.clk(sys_clk),.rst(rst),.frame_valid(rgb_valid),.frame(rgb_frame),.frame_ready(rgb_ready),.data_out(rgb_data));
 assign controller_state={29'd0,command_busy,calibration_sequence,calibration_result,last_applied,last_accepted,last_command,5'd0,invalid,pressed,custom_hold,vibrato_speed,base_depth,centers,
  rejected,result_sequence,last_reason,control_overflow,calibrate,acquired,adc_stale,
  (practice_audio_scene ? 7'd60 : right_base),(practice_audio_scene ? 7'd48 : left_base),focus,function_keys,(practice_audio_scene ? practice_keys : pitch_keys),matrix_keys};
 // synthesis translate_off
 always @(posedge sys_clk)if(!rst&&performance_released!==(pitch_keys==0))
  $fatal(1,"Scanner release hint differs from pitch permutation");
 // synthesis translate_on
endmodule
