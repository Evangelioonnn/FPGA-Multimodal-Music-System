// Local input adapter; source: session_ready_lab/src/looper_platform.v.
module control_audio_platform #(
    parameter WITH_GESTURE=0,WITH_LOOP_EXPORT=0,WITH_NEW_FX=0,WITH_DD=0,ROW_CYCLES = 2500,WITH_PRACTICE=0,
    parameter DEBOUNCE_FRAMES = 8,
    parameter BUTTON_CYCLES = 150000,
    parameter AUDIO_N = 32,
    parameter PLUCK_N = 0,
    parameter LONG_CYCLES = 50000000,
    parameter ENCODER_CYCLES = 2500,
    parameter WITH_SCORE = 0,WITH_TF=0,
    parameter SCORE_N = 512,
    parameter APPENDIX_W = (296+AUDIO_N*5>512 ? 296+AUDIO_N*5 : 512)
)(
    input wire gesture_rx,gesture_toggle,output wire[15:0]gesture_status,output wire[31:0]gesture_expression_status,
    input wire loop_export_lock,
    input wire[1:0]space_type,filter_type,input wire[3:0]filter_cutoff,input wire[2:0]chorus_rate,chorus_depth,
    input wire dd_rx,dd_swap,dd_reload,record_source,output wire[63:0]dd_status,
    input wire sys_clk,input wire reset_request,output wire reset_active,
    input wire tf_owner,tf_pause,tf_flush,tf_lock,tf_fx,input wire[7:0]tf_wet,
    input wire tf_event_valid,output wire tf_event_ready,input wire[71:0]tf_event_data,input wire[135:0]tf_event_patch,input wire[67:0]tf_track_gains,
    output wire tf_source_safe,tf_ram_stopped,output wire[255:0]tf_save_snapshot,
    input wire export_request,output wire export_ready,input wire export_kind,input wire[3:0]export_lane,input wire[6:0]export_address,
    output wire export_valid,input wire export_response_ready,output wire export_enabled,output wire[7:0]export_count,
    output wire[135:0]export_patch,output wire[31:0]export_order,output wire[44:0]export_event,
    input wire [24:0] physical_keys,
    input wire score_toggle,score_safe,score_panic,
    input wire [2:0] score_size,input wire [1:0] score_group,input wire score_probe,
    output wire [127:0] score_status,
    output wire sample_ce,
    output wire [159:0] performance_status,
    output wire [127:0] session_status,
    output wire hp_bck,
    output wire hp_ws,
    output wire hp_din,
    output wire pa_en,
    output wire status_led,
    input wire adc_valid,output wire adc_ready,input wire [59:0] adc_data,
    input wire mixer_valid,output wire mixer_ready,input wire [67:0] mixer_data,
    input wire remote_valid,output wire remote_ready,input wire [4:0] remote_addr,input wire [31:0] remote_value,
    output wire remote_ack_valid,remote_ack_accepted,remote_ack_applied,
    output wire [4:0] remote_ack_addr,output wire [31:0] remote_ack_value,
    output wire snapshot_valid,output wire [320+AUDIO_N*64+APPENDIX_W-1:0] snapshot_data,
    output wire [255:0] snapshot_extension,output wire [15:0] snapshot_keys,
    output wire [127:0] capabilities,
    output wire pcm_valid,output wire signed [15:0] pcm_left,pcm_right,output wire [31:0] pcm_index,
    output wire mix_mode,output wire [47:0] harmonic_targets,output wire [47:0] fader_targets,output wire [63:0] synth_status,output wire [87:0] envelope_status,output wire [67:0] mixer_targets,
    output wire [3:0] fader_invalidate,
    input wire ui_valid,output wire ui_ready,input wire [7:0] ui_addr,input wire [31:0] ui_value,
    output wire ui_ack,ui_accepted,ui_applied,output wire [7:0] ui_reason,
    input wire menu_drums_commit,input wire [3:0] ui_mixer_pickup,
    output reg ui_snapshot_valid,output reg [63:0] ui_layer_timbres,output reg [639:0] ui_snapshot_data,
 input wire shared_score_owner,
 output wire shared_score_read,output wire[8:0]shared_score_ra,
 input wire[47:0]shared_score_state,shared_score_control,
 output wire shared_score_state_we,output wire[8:0]shared_score_state_wa,output wire[47:0]shared_score_state_wd,
 output wire shared_score_control_we,output wire[8:0]shared_score_control_wa,output wire[47:0]shared_score_control_wd,
 output wire shared_score_ready,input wire practice_mode,practice_manual_reset,input wire[3:0]practice_preset,input wire[135:0]practice_patch,
 input wire practice_event_valid,output wire practice_event_ready,input wire[71:0]practice_event,
 input wire[135:0]practice_event_patch,input wire[67:0]practice_gains,
 input wire practice_flush,practice_running,practice_paused,practice_wait,
 input wire[31:0]practice_time,practice_beat,practice_run_id,
 output wire practice_flushing,practice_quiet,practice_ram_stopped
);
    wire [4:0] host_addr;wire [31:0] host_value;
    wire [3:0] mixer_local_invalidate;
    localparam AUDIO_W=320+AUDIO_N*64;
    wire audio_snapshot_valid;wire [AUDIO_W-1:0] audio_snapshot;
    wire [127:0] audio_capabilities;wire [AUDIO_N*5-1:0] voice_origins;
    wire fault;
    reg [5:0] startup = 0;
    reg rst=1;
    always @(posedge sys_clk) rst<=!startup[5] || reset_request;
    assign reset_active=rst;
    always @(posedge sys_clk) begin
        if(reset_request) startup<=0;
        else if(!startup[5]) startup<=startup+1'b1;
    end

    wire [2:0] selected_preset;
    // Register the timbre-dependent key mask before change/overflow detection.
    // One 50MHz cycle; snapshot ownership and original-note OFF stay intact.
    reg [24:0] keys;
    always @(posedge sys_clk) if(rst) keys<=0;
    else keys<=WITH_PRACTICE&&practice_mode ? physical_keys : selected_preset==6 ? physical_keys & 25'h00003ff : physical_keys;
    reg [24:0] previous_keys;
    always @(posedge sys_clk) if(rst) previous_keys<=0;else previous_keys<=keys;
    wire changed=keys!=previous_keys;
    wire ghost=1'b0,all_released=physical_keys==0;
    wire [2:0] btn_down=0,btn_release=0;
    wire enc_step_valid=1'b0;wire signed [1:0] enc_step=0;
    wire tx_sample_ce;
    wire signed [15:0] audio_left,audio_right;
    output_tx tx(.clk(sys_clk),.rst(rst),.sample_left(audio_left),.sample_right(audio_right),
        .sample_ce(tx_sample_ce),.hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din));
    wire transport_run,count_in,playing,transport_recording,record_armed;
    reg [7:0] fault_causes;
    wire record_start_pulse,record_done_pulse,loop_wrap_pulse,stop_pulse;
    wire [11:0] loop_tick;
    wire [31:0] loop_number;
    wire tick_pulse,beat_pulse,bar_pulse;
    wire [6:0] tick_in_beat;wire [2:0] beat_in_bar;
    wire [2:0] applied_meter;wire [31:0] frame_index;wire [7:0] applied_bpm;
    wire [2:0] page,mode;
    wire [1:0] selected_track,quantize;
    wire start_req,stop_req,record_req,undo_req,clear_req;
    wire met_enable;wire [7:0] bpm;wire [2:0] meter,bars;
    wire [8:0] click_gain;wire [3:0] muted;wire [67:0] track_gains;
    wire host_valid,host_ready,control_overflow;
    wire backend_valid,backend_ready,backend_ack_valid,backend_ack_source,backend_ack_accepted,backend_ack_applied;
    wire [4:0] backend_addr,backend_ack_addr;wire [31:0] backend_value,backend_ack_value;
    wire arbiter_fault;
    refinement_config_arbiter config_arbiter(.clk(sys_clk),.rst(rst),
        .local_valid(host_valid),.local_ready(host_ready),.local_addr(host_addr),.local_value(host_value),
        .remote_valid(remote_valid),.remote_ready(remote_ready),.remote_addr(remote_addr),.remote_value(remote_value),
        .backend_valid(backend_valid),.backend_ready(backend_ready),.backend_addr(backend_addr),.backend_value(backend_value),
        .ack_valid(backend_ack_valid && backend_ack_source),.ack_addr(backend_ack_addr),.ack_value(backend_ack_value),
        .ack_accepted(backend_ack_accepted),.ack_applied(backend_ack_applied),
        .remote_ack_valid(remote_ack_valid),.remote_ack_addr(remote_ack_addr),.remote_ack_value(remote_ack_value),
        .remote_ack_accepted(remote_ack_accepted),.remote_ack_applied(remote_ack_applied),.protocol_error(arbiter_fault));
    assign mix_mode=page==2;
    wire [15:0] layer_valid;wire store_edit_busy;wire [31:0] ui_result;wire [159:0] performance_view;
    wire record_busy,recording,flushing;
    looper_controls #(.LONG_CYCLES(LONG_CYCLES),.WITH_TF(WITH_TF)) controls(
        .clk(sys_clk),.rst(rst),.sample_ce(tx_sample_ce),.edit_lock(loop_export_lock||tf_owner||tf_lock||(WITH_PRACTICE&&practice_mode)),.down(btn_down),.released(btn_release),
        .step_valid(enc_step_valid),.step(enc_step),.transport_run(transport_run),
        .host_ready(host_ready),.has_layers(|layer_valid),.host_valid(host_valid),.host_addr(host_addr),.host_value(host_value),
        .preset(selected_preset),.page(page),.mode(mode),.track(selected_track),
        .start_req(start_req),.stop_req(stop_req),.record_req(record_req),.undo_req(undo_req),.clear_req(clear_req),
        .met_enable(met_enable),.bpm(bpm),.meter(meter),.bars(bars),.click_gain(click_gain),
        .quantize(quantize),.track_gains(track_gains),.muted(muted),.overflow(control_overflow),
        .sync_valid(backend_ack_valid&&backend_ack_source&&backend_ack_accepted&&backend_ack_applied),
        .sync_remote(remote_ack_valid),.sync_addr(backend_ack_addr),.sync_value(backend_ack_value),
        .mixer_valid(mixer_valid&&!loop_export_lock&&!(WITH_TF&&(tf_owner||tf_lock))),.mixer_ready(mixer_ready),.mixer_data(mixer_data),
         .mixer_targets(mixer_targets),.mixer_invalidate(mixer_local_invalidate),
        .ui_valid(ui_valid),.ui_ready(ui_ready),.ui_addr(ui_addr),.ui_value(ui_value),
        .ui_recording(recording),.ui_armed(record_armed),.ui_count_in(count_in),.ui_busy(record_busy||store_edit_busy||loop_export_lock),.ui_flushing(flushing),
        .ui_layers(layer_valid),.menu_drums_commit(menu_drums_commit),
        .ui_ack(ui_ack),.ui_accepted(ui_accepted),.ui_applied(ui_applied),.ui_reason(ui_reason),.ui_result(ui_result));
    assign fader_invalidate=mixer_local_invalidate |
        ((backend_ack_valid && backend_ack_source && backend_ack_accepted && backend_ack_applied) ?
            (backend_ack_addr>=20 && backend_ack_addr<=23 ? (4'b0001<<(backend_ack_addr-20)) :
             (backend_ack_addr==31 || backend_ack_addr==0 || backend_ack_addr==28) ? 4'b1111 : 4'b0000) : 4'b0000);
    looper_clock looper_clock_i(
        .clk(sys_clk),.rst(rst),.sample_ce(tx_sample_ce),.run(transport_run||met_enable),.restart(start_req),
        .bpm(bpm),.beats_per_bar(meter),.tick_pulse(tick_pulse),.beat_pulse(beat_pulse),.bar_pulse(bar_pulse),
        .tick_in_beat(tick_in_beat),.beat_in_bar(beat_in_bar),.frame_index(frame_index),.applied_bpm(applied_bpm),.applied_meter(applied_meter));
    looper_transport transport_i(
        .clk(sys_clk),.rst(rst),.tick_pulse(tick_pulse),.beat_pulse(beat_pulse),.bar_pulse(bar_pulse),
        .tick_in_beat(tick_in_beat),.beat_in_bar(beat_in_bar),.start_req(start_req),.stop_req(stop_req),
        .record_req(record_req),.beats_per_bar(meter),.loop_bars(bars),.metronome_enable(1'b0),
        .transport_run(transport_run),.count_in(count_in),.playing(playing),.recording(transport_recording),
        .record_armed(record_armed),.record_start_pulse(record_start_pulse),.record_done_pulse(record_done_pulse),
        .loop_wrap_pulse(loop_wrap_pulse),.stop_pulse(stop_pulse),.metronome_click(),.metronome_accent(),
        .loop_tick(loop_tick),.loop_number(loop_number));
    reg[31:0]next_practice_click,click_run;reg[2:0]practice_beat_index;reg practice_click;
    wire click_valid,click_onset;wire signed [15:0] click_sample;wire [31:0] clicks_delivered;
    metronome_click click_generator(.clk(sys_clk),.rst(rst),.sample_ce(tx_sample_ce),
        .trigger(WITH_PRACTICE&&practice_mode ? practice_click : beat_pulse),.accent(WITH_PRACTICE&&practice_mode ? practice_beat_index==0 : beat_in_bar==0),.enable((met_enable||count_in)&&!(WITH_PRACTICE&&shared_score_owner)),.gain_q8(click_gain),
        .valid(click_valid),.sample(click_sample),.onset(click_onset),.delivered(clicks_delivered));

    always @(posedge sys_clk)begin
     if(rst || !practice_running || practice_run_id!=click_run)begin next_practice_click<=0;practice_beat_index<=0;practice_click<=0;click_run<=practice_run_id;end
     else begin
      practice_click<=0;
      if(practice_mode&&!practice_paused&&!practice_wait&&practice_time>=next_practice_click)begin
       practice_click<=1;next_practice_click<=next_practice_click+practice_beat;
       practice_beat_index<=practice_beat_index==3 ? 0 : practice_beat_index+1'b1;
      end
     end
    end
    reg [1:0] record_track;
    reg [1:0] free_layer;reg lane_available;
    integer li;
    always @* begin
        free_layer=0;lane_available=0;
        for(li=0;li<4;li=li+1) if(!layer_valid[record_track*4+li] && !lane_available) begin
            free_layer=li;lane_available=1;
        end
    end
    always @(posedge sys_clk) if(rst) record_track<=0;else if(record_req) record_track<=selected_track;
    wire [3:0] record_lane={record_track,free_layer};
    wire [63:0] layer_timbres;
    wire [11:0] record_event_tick;
    wire record_commit,record_overflow,record_error,record_event_ready;
    wire [7:0] recorded_events;reg [11:0] loop_length;
    always @(posedge sys_clk) if(rst) loop_length<=384;else case({meter,bars})
        6'd17:loop_length<=12'd192;
        6'd18:loop_length<=12'd384;
        6'd19:loop_length<=12'd576;
        6'd20:loop_length<=12'd768;
        6'd25:loop_length<=12'd288;
        6'd26:loop_length<=12'd576;
        6'd27:loop_length<=12'd864;
        6'd28:loop_length<=12'd1152;
        6'd33:loop_length<=12'd384;
        6'd34:loop_length<=12'd768;
        6'd35:loop_length<=12'd1152;
        6'd36:loop_length<=12'd1536;
        default:loop_length<=384;
    endcase
    wire loop_event_valid,loop_event_ready,loop_event_off,loop_event_drum;
    wire loop_event_control,expression_overflow;
    wire [1:0] loop_event_track,loop_event_layer;
    wire [11:0] loop_event_tick;wire [6:0] loop_event_note;
    wire [15:0] loop_event_id;wire [7:0] loop_event_velocity;
    wire [2:0] loop_event_preset;wire [135:0] loop_event_patch,core_patch,dd_patch;
    wire [31:0] event_late_count;
    wire record_event_valid;wire [1:0] record_event_kind;
    wire [6:0] record_event_note;wire [15:0] record_event_id;wire [7:0] record_event_velocity;
    wire removed_valid;wire [1:0] removed_track,removed_layer;
    looper_event_store #(.LANES(16),.LAYERS_PER_TRACK(4),.RECORD_TICK_INPUT(1),.EVENTS_PER_LANE(128),.EVENT_AW(7),.SERIAL_NOTES(1),.ACTIVE_NOTES(AUDIO_N)) store(
        .clk(sys_clk),.rst(rst),.play_enable(playing&&!(WITH_TF&&tf_owner)&&!(WITH_PRACTICE&&practice_mode)),.playback_reset(stop_pulse),
        .loop_wrap(loop_wrap_pulse),.loop_tick(loop_tick),.loop_length(loop_length),.quantize_mode(quantize),
        .layer_timbres(layer_timbres),.record_start(record_start_pulse),.record_lane(record_lane),.record_patch(record_source===1'b1 ? dd_patch : selected_preset==6 ? {core_patch[135:3],3'd6} : core_patch),
        .record_tick(record_event_tick),.record_busy(record_busy),.record_cancel(stop_req||stop_pulse||expression_overflow),.record_event_valid(record_event_valid),.record_event_ready(record_event_ready),
        .record_event_kind(record_event_kind),.record_note(record_event_note),.record_note_id(record_event_id),
        .record_velocity(record_event_velocity),.recording(recording),.record_commit(record_commit),
        .record_overflow(record_overflow),.record_error(record_error),.recorded_events(recorded_events),
        .undo_valid(undo_req && !flushing),.undo_lane({2'd0,selected_track}),
        .clear_valid(clear_req && !flushing),.clear_track(selected_track),
        .removed_valid(removed_valid),.removed_track(removed_track),.removed_layer(removed_layer),
        .layer_valid(layer_valid),.edit_busy(store_edit_busy),.event_valid(loop_event_valid),.event_ready(loop_event_ready),
        .event_off(loop_event_off),.event_drum(loop_event_drum),.event_track(loop_event_track),.event_layer(loop_event_layer),
        .event_control(loop_event_control),
        .event_tick(loop_event_tick),.event_note(loop_event_note),.event_note_id(loop_event_id),.event_velocity(loop_event_velocity),
        .event_preset(loop_event_preset),.event_patch(loop_event_patch),.event_late_count(event_late_count),
        .export_request((WITH_TF||WITH_LOOP_EXPORT)&&export_request),.export_ready(export_ready),.export_kind(export_kind),.export_lane(export_lane),.export_address(export_address),
        .export_valid(export_valid),.export_response_ready(export_response_ready),.export_enabled(export_enabled),.export_count(export_count),
        .export_patch(export_patch),.export_order(export_order),.export_event(export_event));
    wire drum_event_valid,drum_engine_ready,drum_engine_accepted;wire [3:0] drum_event_pad;
    wire [1:0] drum_event_layer;wire [2:0] drum_event_track;wire [7:0] drum_event_velocity;
    wire drum_sample_valid;wire signed [19:0] drum_sample;wire [7:0] drum_active;
    wire [31:0] drum_late,drum_rejected;wire [31:0] active_pads;
    wire practice_clear_auto,practice_source_busy;wire melodic_seq_busy,drum_seq_busy;wire[7:0]current_effect_wet;
    wire[67:0]effective_track_gains=WITH_PRACTICE&&practice_mode ? practice_gains : WITH_TF&&tf_owner ? tf_track_gains : track_gains;
    wire source_flush=stop_pulse||(WITH_TF&&tf_flush)||(WITH_PRACTICE&&practice_flush);
    looper_drum_engine #(.VOICES(8),.WITH_TF(WITH_TF),.WITH_PRACTICE(WITH_PRACTICE)) drum(.practice_mode(WITH_PRACTICE&&practice_mode),.practice_clear_auto(practice_clear_auto),.clk(sys_clk),.rst(rst),.sample_ce(tx_sample_ce),.pause_loops(WITH_TF&&tf_pause),.sequencer_busy(drum_seq_busy),
        .strike_valid(drum_event_valid),.strike_ready(drum_engine_ready),.strike_accepted(drum_engine_accepted),.strike_pad(drum_event_pad),
        .strike_layer(drum_event_layer),.strike_track(drum_event_track),.track_gains(effective_track_gains),.strike_velocity(drum_event_velocity),
        .flush_all(source_flush),.flush_valid(clear_req||removed_valid),
        .flush_track(removed_valid ? removed_track : selected_track),.flush_layer(removed_layer),.flush_whole_track(clear_req),
        .sample_valid(drum_sample_valid),.sample(drum_sample),.active(drum_active),.active_pads(active_pads),
        .late_strikes(drum_late),.rejected_strikes(drum_rejected));
    reg signed [15:0] drum_audio;
    always @(posedge sys_clk) if(rst||practice_clear_auto) drum_audio<=0;else if(drum_sample_valid) drum_audio<=drum_sample>>>4;
    wire signed [16:0] auxiliary_wide=$signed(drum_audio)+$signed(click_sample);
    wire signed [15:0] auxiliary_sample=auxiliary_wide[15:0];
    wire [31:0] loop_route_faults,loop_unmatched_offs;
    wire audio_deadline,blocked,rejected,clip_seen,final_valid;
    wire [AUDIO_N-1:0] occupied,held,gated;
    // The qualified V6 delivery keeps the score engine as an experimental
    // compile-time option; this candidate measures the safe bank/wave optimizations
    // without spending the complete PnR budget on an unqualified 512 path.
    assign tf_ram_stopped=!transport_run&&!recording&&!record_armed&&!record_busy&&!store_edit_busy&&!flushing;
    assign tf_source_safe=tf_ram_stopped&&!melodic_seq_busy&&!drum_seq_busy&&!score_status[0];
    assign tf_save_snapshot[15:0]=layer_valid;assign tf_save_snapshot[83:16]=mixer_targets;assign tf_save_snapshot[87:84]=muted;
    assign tf_save_snapshot[95:88]=bpm;assign tf_save_snapshot[98:96]=meter;assign tf_save_snapshot[101:99]=bars;
    assign tf_save_snapshot[102]=performance_view[83];assign tf_save_snapshot[110:103]=current_effect_wet;
    assign tf_save_snapshot[142:111]=ui_result;assign tf_save_snapshot[154:143]=loop_length;assign tf_save_snapshot[255:155]=0;
    wire use_practice=WITH_PRACTICE&&practice_mode;
    wire use_tf=WITH_TF&&tf_owner;wire use_sequence=use_tf||use_practice;wire sequence_ready;
    wire[71:0]sequence_event=use_practice ? practice_event : tf_event_data;
    wire[135:0]sequence_patch=use_practice ? practice_event_patch : tf_event_patch;
    assign practice_event_ready=use_practice&&sequence_ready;
    assign practice_flushing=flushing;
    assign practice_quiet=!(|occupied)&&!(|drum_active)&&!flushing&&!melodic_seq_busy&&!drum_seq_busy;
    assign practice_ram_stopped=tf_ram_stopped;
    assign tf_event_ready=use_tf&&sequence_ready;
    assign loop_event_ready=!use_sequence&&sequence_ready;
    looper_audio_core #(.WITH_GESTURE(WITH_GESTURE),.WITH_NEW_FX(WITH_NEW_FX),.WITH_DD(WITH_DD),.WITH_PRACTICE(WITH_PRACTICE),.KEYS(25),.SPLIT(12),.DIATONIC(0),.N(AUDIO_N),.PLUCK_N(PLUCK_N),.WITH_FX(1),.WITH_EXPRESSION(1),.WITH_TF(WITH_TF),.WITH_SCORE(WITH_SCORE),.SCORE_N(SCORE_N)) audio(
        .tf_owner(use_sequence),.practice_mode(use_practice),.practice_manual_reset(WITH_PRACTICE&&practice_manual_reset),.practice_preset(practice_preset),.practice_patch(practice_patch),.practice_flush(WITH_PRACTICE&&practice_flush),.practice_drum_idle(drum_engine_ready),.practice_clear_auto(practice_clear_auto),.practice_source_busy(practice_source_busy),.tf_pause(WITH_TF&&tf_pause),.tf_fx(tf_fx),.tf_wet(tf_wet),.sequencer_busy(melodic_seq_busy),.effect_wet_current(current_effect_wet),
        .score_toggle(score_toggle),.score_safe(score_safe),.score_panic(score_panic),.score_size(score_size),
        .score_group(score_group),.score_probe(score_probe),.score_status(score_status),.shared_score_owner(shared_score_owner),.shared_score_read(shared_score_read),.shared_score_ra(shared_score_ra),.shared_score_state(shared_score_state),.shared_score_control(shared_score_control),.shared_score_state_we(shared_score_state_we),.shared_score_state_wa(shared_score_state_wa),.shared_score_state_wd(shared_score_state_wd),.shared_score_control_we(shared_score_control_we),.shared_score_control_wa(shared_score_control_wa),.shared_score_control_wd(shared_score_control_wd),.shared_score_ready(shared_score_ready),
        .clk(sys_clk),.rst(rst),.sample_ce(tx_sample_ce),.keys(keys),.changed(changed),.ghost(ghost),.all_released(all_released),
        .button_n(3'b111),.step_valid(1'b0),.step(2'sd0),.recording(recording),.capture_recording(recording && transport_recording),
        .gesture_rx(gesture_rx),.gesture_toggle(gesture_toggle),.gesture_status(gesture_status),.gesture_expression_status(gesture_expression_status),
        .gesture_blocked(recording||record_armed||count_in||record_busy||store_edit_busy||flushing||record_req),
        .envelope_edit_lock(recording||record_armed||count_in||record_busy||store_edit_busy||flushing),
        .current_loop_tick(loop_tick),.record_busy(record_busy),.record_event_tick(record_event_tick),.record_ready(record_event_ready),
        .drum_mode(selected_preset==6),.auxiliary_sample(auxiliary_sample),
        .flush_all(source_flush),.flush_valid(removed_valid||clear_req),
        .flush_track(removed_valid ? removed_track : selected_track),.flush_layer(removed_layer),
        .flush_whole_track(clear_req),.flushing(flushing),
        .loop_event_valid(use_practice ? practice_event_valid : use_tf ? tf_event_valid : loop_event_valid),.loop_event_ready(sequence_ready),.loop_event_off(use_sequence ? sequence_event[19:18]==1 : loop_event_off),
        .loop_event_drum(use_sequence ? sequence_event[19:18]==2 : loop_event_drum),.loop_event_track(use_sequence ? sequence_event[23:22] : loop_event_track),.loop_event_layer(use_sequence ? sequence_event[21:20] : loop_event_layer),
        .loop_event_control(use_sequence ? sequence_event[19:18]==3 : loop_event_control),.expression_overflow(expression_overflow),
        .loop_event_id(use_sequence ? sequence_event[39:24] : loop_event_id),.loop_event_tick(use_sequence ? 12'd0 : loop_event_tick),.loop_event_note(use_sequence ? sequence_event[17:11] : loop_event_note),
        .loop_event_velocity(use_sequence ? sequence_event[10:3] : loop_event_velocity),.loop_event_preset(use_sequence ? sequence_patch[2:0] : loop_event_preset),.loop_event_patch(use_sequence ? sequence_patch : loop_event_patch),
        .loop_route_faults(loop_route_faults),.loop_unmatched_offs(loop_unmatched_offs),
        .track_gains(effective_track_gains),.record_event_valid(record_event_valid),.record_event_kind(record_event_kind),
        .record_event_note(record_event_note),.record_event_id(record_event_id),.record_event_velocity(record_event_velocity),
        .space_type(space_type),.filter_type(filter_type),.filter_cutoff(filter_cutoff),.chorus_rate(chorus_rate),.chorus_depth(chorus_depth),.dd_rx(dd_rx),.dd_swap(dd_swap),.dd_reload(dd_reload),.record_source(record_source),.dd_status(dd_status),.dd_patch_snapshot(dd_patch),.record_patch_current(core_patch),.drum_event_valid(drum_event_valid),.drum_event_ready(drum_engine_ready),.drum_event_accepted(drum_engine_accepted),
        .drum_event_layer(drum_event_layer),.drum_event_track(drum_event_track),.drum_event_pad(drum_event_pad),.drum_event_velocity(drum_event_velocity),
        .host_valid(backend_valid),.host_ready(backend_ready),.host_addr(backend_addr),.host_value(backend_value),
        .adc_valid(adc_valid),.adc_ready(adc_ready),.adc_ch0(adc_data[11:0]),.adc_ch1(adc_data[23:12]),
        .adc_ch2(adc_data[35:24]),.adc_ch3(adc_data[47:36]),.adc_ch4(adc_data[59:48]),
        .final_valid(final_valid),.final_left(audio_left),.final_right(audio_right),.sample_index(pcm_index),
        .snapshot_valid(audio_snapshot_valid),.snapshot_data(audio_snapshot),.selected_preset(),.control_mode(),.sustain(),.sostenuto(),.blocked(blocked),
        .rejected(rejected),.deadline_missed(audio_deadline),.occupied(occupied),.held(held),.gated(gated),.muting(),
        .clip_seen(clip_seen),.capabilities(audio_capabilities),.snapshot_extension(snapshot_extension),.snapshot_keys(),.performance_view(performance_view),
        .harmonic_targets(harmonic_targets),.fader_targets(fader_targets),.synth_status(synth_status),.envelope_status(envelope_status),.voice_origins(voice_origins),
        .ack_valid(backend_ack_valid),.ack_source(backend_ack_source),.ack_accepted(backend_ack_accepted),
        .ack_applied(backend_ack_applied),.ack_addr(backend_ack_addr),.ack_value(backend_ack_value));
    // Versioned appendix, latched on the SAME audio snapshot publication.
    // audio_snapshot stays stable until its next 1024-frame publication.
    reg [APPENDIX_W-1:0] appendix;reg published;
    assign snapshot_data={appendix,audio_snapshot};assign snapshot_valid=published;
    localparam [15:0] OBSERVATION_W=320+APPENDIX_W+AUDIO_N*64;
    assign capabilities={audio_capabilities[127:112],OBSERVATION_W,audio_capabilities[95:0]};
    assign pcm_valid=final_valid;assign pcm_left=audio_left;assign pcm_right=audio_right;
    always @(posedge sys_clk) begin
        if(rst) begin appendix<=0;published<=0;end
        else begin
            published<=audio_snapshot_valid;
            if(audio_snapshot_valid) begin
                appendix<=0;
                appendix[15:0]<=16'h4c52;appendix[23:16]<=2;appendix[31:24]<=AUDIO_N;
                appendix[34:32]<=page;appendix[37:35]<=mode;appendix[39:38]<=selected_track;
                appendix[42:40]<=selected_preset;
                appendix[43]<=transport_run;appendix[44]<=count_in;appendix[45]<=playing;
                appendix[46]<=recording;appendix[47]<=record_armed;appendix[48]<=met_enable;
                appendix[56:49]<=bpm;appendix[64:57]<=applied_bpm;
                appendix[67:65]<=meter;appendix[70:68]<=bars;appendix[72:71]<=quantize;
                appendix[84:73]<=loop_tick;appendix[116:85]<=loop_number;
                appendix[132:117]<=layer_valid;appendix[136:133]<=muted;
                appendix[204:137]<=track_gains;appendix[212:205]<=drum_active;
                appendix[221:213]<=click_gain;appendix[229:222]<=recorded_events;
                appendix[230]<=fault;appendix[231]<=clip_seen;
                appendix[263:232]<=loop_route_faults;appendix[295:264]<=event_late_count;
                appendix[296+:AUDIO_N*5]<=voice_origins;
            end
        end
    end
    // Coherent count derived from one registered occupancy image in eight
    // groups, not an unbounded64-input combinational carry chain.
    reg [AUDIO_N-1:0] count_image;
    reg [3:0] count_group[0:7];reg [7:0] active_count;integer cg,cb;
    reg [3:0] group_value;
    always @(posedge sys_clk)begin
      if(rst)begin count_image<=0;active_count<=0;for(cg=0;cg<8;cg=cg+1)count_group[cg]<=0;end
      else begin
        count_image<=occupied;
        for(cg=0;cg<8;cg=cg+1)begin
          group_value=0;
          for(cb=0;cb<8;cb=cb+1)if(cg*8+cb<AUDIO_N)group_value=group_value+count_image[cg*8+cb];
          count_group[cg]<=group_value;
        end
        active_count<={4'd0,count_group[0]}+count_group[1]+count_group[2]+count_group[3]+count_group[4]+count_group[5]+count_group[6]+count_group[7];
      end
    end
    reg [7:0] ui_frame_divider;
    reg [15:0] drum_sequence;reg [3:0] last_drum_pad;reg [2:0] last_drum_track;reg [1:0] last_drum_layer;
    reg [15:0] drum_pad_mask;integer ds;
    always @* begin
        drum_pad_mask=0;
        for(ds=0;ds<8;ds=ds+1) if(drum_active[ds]) drum_pad_mask[active_pads[ds*4+:4]]=1;
    end
    always @(posedge sys_clk) begin
        if(rst) begin ui_frame_divider<=0;ui_snapshot_valid<=0;ui_snapshot_data<=0;
            drum_sequence<=0;last_drum_pad<=0;last_drum_track<=4;last_drum_layer<=0;end
        else begin
            ui_snapshot_valid<=0;
            if(drum_event_valid && drum_engine_ready && drum_engine_accepted) begin
                drum_sequence<=drum_sequence+1'b1;last_drum_pad<=drum_event_pad;
                last_drum_track<=drum_event_track;last_drum_layer<=drum_event_layer;
            end
            if(tx_sample_ce) begin
                ui_frame_divider<=ui_frame_divider+1'b1;
                if(ui_frame_divider==0) begin
                    ui_snapshot_valid<=1;ui_snapshot_data<=0;ui_layer_timbres<=layer_timbres;
                    ui_snapshot_data[0+:32]<={3'd0,record_track,(|layer_valid),muted,flushing,(record_busy||store_edit_busy),
                        (transport_run||met_enable),clip_seen,fault,met_enable,record_armed,recording,playing,count_in,transport_run,
                        selected_preset,selected_track,mode,page};
                    ui_snapshot_data[32+:32]<={8'd0,quantize,bars,meter,applied_bpm,bpm};
                    ui_snapshot_data[64+:32]<={10'd0,beat_in_bar,tick_in_beat,loop_tick};
                    ui_snapshot_data[96+:32]<={4'd0,loop_length,layer_valid};
                    ui_snapshot_data[128+:32]<={active_count,performance_view[95:91],performance_view[97:96],performance_view[16:0]};
                    ui_snapshot_data[160+:32]<={15'd0,performance_view[33:17]};
                    ui_snapshot_data[192+:32]<={15'd0,track_gains[0+:17]};
                    ui_snapshot_data[224+:32]<={15'd0,track_gains[17+:17]};
                    ui_snapshot_data[256+:32]<={15'd0,track_gains[34+:17]};
                    ui_snapshot_data[288+:32]<={15'd0,track_gains[51+:17]};
                    ui_snapshot_data[320+:32]<={5'd0,performance_view[60:34]};
                    ui_snapshot_data[352+:32]<={2'd0,performance_view[90:61]};
                    ui_snapshot_data[384+:32]<={drum_pad_mask,physical_keys[15:0]};
                    ui_snapshot_data[416+:32]<={7'd0,last_drum_layer,last_drum_track,last_drum_pad,drum_sequence};
                    ui_snapshot_data[448+:32]<=loop_number;
                    ui_snapshot_data[480+:32]<={12'd0,ui_mixer_pickup,drum_active,recorded_events};
                    ui_snapshot_data[512+:32]<=ui_result;
                    ui_snapshot_data[544+:32]<={8'd0,performance_view[121:98]};
                    ui_snapshot_data[576+:32]<={8'd0,performance_view[145:122]};
                    ui_snapshot_data[608+:32]<={8'd0,fault_causes,click_gain,applied_meter,(event_late_count!=0),(loop_route_faults!=0),(drum_rejected!=0),(drum_late!=0)};
                    ui_snapshot_data[639:632]<=AUDIO_N;
                end
            end
        end
    end
    // One LED encodes page by short flashes; faults use rapid blinking. Beat
    // flash is overlaid, recording/count-in produces an obvious steady light.
    reg [25:0] led_counter;
    always @(posedge sys_clk) if(rst) led_counter<=0;else led_counter<=led_counter+1'b1;
    always @(posedge sys_clk) if(rst) fault_causes<=0;
      else fault_causes<=fault_causes | {audio_deadline,(drum_late!=0),(loop_route_faults!=0),(drum_rejected!=0),record_overflow,expression_overflow,record_error,rejected};
    reg operation_error;
    always @(posedge sys_clk) if(rst) operation_error<=0;
        else if(expression_overflow || record_error || rejected || loop_route_faults!=0 || drum_rejected!=0) operation_error<=1;
    assign fault=operation_error||arbiter_fault||control_overflow||record_overflow||expression_overflow||audio_deadline||drum_late!=0;
    assign status_led=fault ? led_counter[21] :
        (recording||count_in) ? 1'b1 :
        (led_counter[25:23]<=page && led_counter[22:19]==0) || (met_enable && tick_in_beat<5);
    assign pa_en=1'b0;
    // Board-profile sideband. Legacy LU1 layout is unchanged, and still 16 keys.
    assign sample_ce=tx_sample_ce;
    assign performance_status=performance_view;
    assign snapshot_keys=physical_keys[15:0];
    assign session_status={47'd0,clip_seen,fault,tick_in_beat,beat_in_bar,layer_valid,muted,
        click_gain,quantize,bars,meter,applied_bpm,bpm,met_enable,flushing,
        (record_busy||store_edit_busy),record_armed,recording,playing,count_in,
        transport_run,selected_track,selected_preset,page};
endmodule
