// Audio-domain integration API; the board top only adapts physical inputs.
module looper_audio_core #(
    parameter WITH_GESTURE=0,WITH_GESTURE_EXPRESSION=0,WITH_NEW_FX=0,WITH_DD=0,KEYS=16,WITH_PRACTICE=0,SPLIT=8,DIATONIC=1,N=32,PLUCK_N=0,
    parameter BUTTON_CYCLES=150000,LONG_CYCLES=50000000,
    parameter MIX_W=18, WITH_FX=1, WITH_EXPRESSION=0, WITH_TF=0,WITH_SCORE=0, SCORE_N=512, SNAPSHOT_W=320+N*64
)(
    input wire[1:0]space_type,filter_type,input wire[3:0]filter_cutoff,input wire[2:0]chorus_rate,chorus_depth,
    input wire dd_rx,dd_swap,dd_reload,record_source,output wire[63:0]dd_status,output wire[135:0]dd_patch_snapshot,
    input wire gesture_rx,gesture_toggle,gesture_blocked,output wire[15:0]gesture_status,output wire[31:0]gesture_expression_status,
    input wire clk,rst,sample_ce,input wire tf_owner,tf_pause,tf_fx,input wire[7:0]tf_wet,output wire sequencer_busy,output wire[7:0]effect_wet_current,
    input wire [KEYS-1:0] keys,input wire changed,ghost,all_released,
    input wire [2:0] button_n,input wire step_valid,input wire signed [1:0] step,
    input wire recording,input wire capture_recording,input wire envelope_edit_lock,
    input wire [11:0] current_loop_tick,output wire record_busy,
    output wire [11:0] record_event_tick,
    input wire record_ready,input wire drum_mode,
    input wire flush_all,flush_valid,flush_whole_track,
    input wire [1:0] flush_track,flush_layer,
    output wire flushing,
    input wire signed [15:0] auxiliary_sample,
    input wire loop_event_valid,output wire loop_event_ready,
    input wire loop_event_off,input wire loop_event_drum,
    input wire loop_event_control,
    input wire [1:0] loop_event_track,loop_event_layer,
    input wire [15:0] loop_event_id,
    input wire [11:0] loop_event_tick,
    input wire [6:0] loop_event_note,
    input wire [7:0] loop_event_velocity,
    input wire [2:0] loop_event_preset,
    input wire [135:0] loop_event_patch,
    input wire [67:0] track_gains,
    output wire [31:0] loop_route_faults,loop_unmatched_offs,
    output wire record_event_valid,
    output wire [1:0] record_event_kind,
    output wire [6:0] record_event_note,
    output wire [15:0] record_event_id,
    output wire [7:0] record_event_velocity,
    output wire [135:0] record_patch_current,
    output wire expression_overflow,
    output wire drum_event_valid,input wire drum_event_ready,drum_event_accepted,
    output wire [1:0] drum_event_layer,output wire [2:0] drum_event_track,output wire [3:0] drum_event_pad,output wire [7:0] drum_event_velocity,
    input wire host_valid,output wire host_ready,
    input wire [4:0] host_addr,input wire [31:0] host_value,
    input wire adc_valid,output wire adc_ready,
    input wire [11:0] adc_ch0,adc_ch1,adc_ch2,adc_ch3,adc_ch4,
    output wire ack_valid,ack_source,ack_accepted,ack_applied,
    output wire [4:0] ack_addr,output wire [31:0] ack_value,
    output wire final_valid,output wire signed [15:0] final_left,final_right,
    output reg [31:0] sample_index,
    output reg snapshot_valid,output reg [SNAPSHOT_W-1:0] snapshot_data,
    output wire [2:0] selected_preset,output wire [4:0] control_mode,
    output wire sustain,sostenuto,blocked,rejected,deadline_missed,
    output wire [N-1:0] occupied,held,gated,
    output reg muting,output reg clip_seen,
    output wire [127:0] capabilities,
    output reg [255:0] snapshot_extension,
    output wire [47:0] harmonic_targets,output wire [47:0] fader_targets,output wire [63:0] synth_status,output wire [87:0] envelope_status,output reg [N*5-1:0] voice_origins,
    output wire [159:0] performance_view,
    input wire score_toggle,score_safe,score_panic,
    input wire [2:0] score_size,input wire [1:0] score_group,input wire score_probe,
    output wire [127:0] score_status,
    output reg [KEYS-1:0] snapshot_keys,
 input wire shared_score_owner,
 output wire shared_score_read,output wire[8:0]shared_score_ra,
 input wire[47:0]shared_score_state,shared_score_control,
 output wire shared_score_state_we,output wire[8:0]shared_score_state_wa,output wire[47:0]shared_score_state_wd,
 output wire shared_score_control_we,output wire[8:0]shared_score_control_wa,output wire[47:0]shared_score_control_wd,
 output wire shared_score_ready,input wire practice_mode,practice_manual_reset,input wire[3:0]practice_preset,input wire[135:0]practice_patch,input wire practice_flush,practice_drum_idle,output reg practice_clear_auto,output wire practice_source_busy
);
    assign capabilities[15:0]=16'd2;
    assign capabilities[31:16]=N;
    assign capabilities[47:32]=PLUCK_N;
    assign capabilities[63:48]=KEYS;
    assign capabilities[71:64]=8'hbb;
    assign capabilities[79:72]=8'd2;
    assign capabilities[87:80]=8'd0;
    assign capabilities[95:88]=8'd64;
    assign capabilities[111:96]=320+64*N;
    assign capabilities[127:112]=16'd320;
    wire score_active;

    wire panel_valid,panel_ready,panel_overflow,local_ready;
    wire live_event_valid,live_event_ready,live_event_off,fault;
    reg fault_pending;
    wire [4:0] panel_addr;
    wire [31:0] panel_value,revision;
    wire [16:0] master_target,gain_left,gain_right;
    wire [6:0] left_base,right_base;
    wire [2:0] release_index,glide_index;
    wire [1:0] ensemble_style,ensemble_minimum,ensemble_maximum;wire ensemble_mode;
    wire signed [4:0] bend_index;
    wire [1:0] lead_attack_index;
    wire [15:0] adsr_a,adsr_d,adsr_s,adsr_r;
    wire override_env,custom_hold,effect_enable,panic;
    wire [6:0] vibrato_depth;
    wire [2:0] vibrato_speed;
    wire [7:0] effect_mix;
    wire effective_live_sustain;
    reg [16:0] bend_factor;
    wire[16:0]expressive_bend_factor;
    wire[6:0]visual_depth;
    wire gesture_pitch_deadline;
    wire[6:0]effective_vibrato_depth=visual_depth>vibrato_depth ? visual_depth:vibrato_depth;
    generate if(WITH_GESTURE)begin:gesture
      wire valid,request,linked,vision_unstable,camera_fault,packet_valid,packet_valid_control,packet_request;
      wire[1:0]pose;wire[7:0]errors;wire[15:0]packets;
      wire enabled,active,rearm,expression_link,expression_packet_valid,position_owned,returning;
      wire[1:0]axis;wire[7:0]gain;wire signed[7:0]bend,applied_bend;
      wire expression_active,expression_rearm;wire[6:0]requested_depth;
      wire capable=selected_preset==4||selected_preset==7||selected_preset==1;
      gs2_receiver receiver(.clk(clk),.rst(rst),.sample_ce(sample_ce),.rx(gesture_rx),
       .control_valid(valid),.sustain_request(request),.linked(linked),.unstable(vision_unstable),.camera_fault(camera_fault),.diagnostic_pose(pose),
       .packet_valid(packet_valid),.packet_control_valid(packet_valid_control),.packet_request(packet_request),.errors(errors),.packets(packets),
       .expression_link(expression_link),.expression_packet_valid(expression_packet_valid),.position_owned(position_owned),.returning(returning),
       .expression_axis(axis),.expression_gain(gain),.expression_bend(bend));
      wire allowed=!gesture_blocked&&!score_active&&!shared_score_owner&&!practice_mode&&!tf_owner&&!muting&&!fault&&!panic;
      gesture_pedal_control owner(.clk(clk),.rst(rst),.sample_ce(sample_ce),.toggle(gesture_toggle),.allowed(allowed),
       .panic(panic||score_panic||fault),.manual_write(ack_valid&&ack_applied&&ack_addr==5),.manual_pedal(sustain),
       .control_valid(linked&&packet_valid_control),.request(packet_request),.packet_valid(packet_valid),.packet_control_valid(packet_valid_control),.packet_request(packet_request),
       .enabled(enabled),.active(active),.rearm(rearm),.effective(effective_live_sustain));
      // User-authorized old feature set; ordinary GS2 ownership stays intact.
      if(WITH_GESTURE_EXPRESSION)begin:position_expression
      gesture_expression_control expression_owner(.clk(clk),.rst(rst),.enabled(enabled),.allowed(allowed),
       .panic(panic||score_panic||fault),.linked(expression_link),.packet_valid(expression_packet_valid),
       .position_owned(position_owned),.returning(returning),.gain(gain),.bend(bend),
       .active(expression_active),.rearm(expression_rearm),.depth(requested_depth),.bend_applied(applied_bend));
      assign visual_depth=capable ? requested_depth:7'd0;
      wire signed[7:0]effective_bend=capable ? applied_bend:8'sd0;
      gesture_pitch_apply pitch(.clk(clk),.rst(rst),.sample_ce(sample_ce),.active(expression_active&&capable),
       .bend_offset(effective_bend),.manual_bend_q16(bend_factor),.effective_bend_q16(expressive_bend_factor),.deadline_error(gesture_pitch_deadline));
      assign gesture_expression_status={capable,gesture_pitch_deadline,visual_depth,effective_bend,requested_depth,axis,
       enabled&&allowed,expression_rearm,expression_active,returning,position_owned,expression_link};
      end else begin:sustain_only
       assign visual_depth=0;assign expressive_bend_factor=bend_factor;
       assign gesture_pitch_deadline=0;assign gesture_expression_status=0;
      end
      assign gesture_status={errors[3:0],pose,camera_fault,vision_unstable,!allowed,rearm,valid,request,effective_live_sustain,linked,active,enabled};
    end else begin:no_gesture
      assign effective_live_sustain=sustain;assign gesture_status=0;assign gesture_expression_status=0;
      assign expressive_bend_factor=bend_factor;assign visual_depth=0;assign gesture_pitch_deadline=0;
    end endgenerate
    assign effect_wet_current=effect_mix;
    wire [63:0] query_envelope;wire [3:0] envelope_edited;wire [7:0] envelope_epoch;
    assign envelope_status={effect_mix,4'd0,envelope_epoch,envelope_edited,adsr_r,adsr_s,adsr_d,adsr_a};
    wire [11:0] raw1,raw2,raw3,raw4;
    wire harmonic_valid,harmonic_ready;wire [1:0] wave_a,wave_b;wire [11:0] raw_blend;
    reg [16:0] blend_applied;
    // raw_blend commits only on sample_ce. Precompute during the idle frame;
    // at the next sample edge this is exactly the original pre-edge target.
    // Keep the128-code/sample slew and all audible blend values unchanged.
    reg [16:0] blend_target;
    always @(posedge clk) if(rst) blend_target<=32776;
    else blend_target<=raw_blend==4095 ? 17'd65536 :
        {1'b0,raw_blend,4'd0}+{13'd0,raw_blend[11:8]};
    always @(posedge clk) if(rst) blend_applied<=32776;else if(sample_ce) begin
     if(blend_applied<blend_target) blend_applied<=blend_target-blend_applied>128 ? blend_applied+17'd128 : blend_target;
     else if(blend_applied>blend_target) blend_applied<=blend_applied-blend_target>128 ? blend_applied-17'd128 : blend_target;end
    wire [11:0] harmonic1,harmonic2,harmonic3,harmonic4;
    wire [4:0] fader_acquired;
    wire [1:0] master_owner;
    wire adc_overrun,params_updated;
    audio_panel #(.BUTTON_CYCLES(BUTTON_CYCLES),.LONG_CYCLES(LONG_CYCLES)) panel(
        clk,rst,button_n,step_valid,step,selected_preset,master_target,left_base,right_base,
        sustain,sostenuto,release_index,glide_index,bend_index,lead_attack_index,
        vibrato_depth,vibrato_speed,effect_enable,effect_mix,adsr_a,adsr_d,adsr_s,adsr_r,
        override_env,custom_hold,raw1,raw2,raw3,raw4,
        panel_valid,panel_ready,panel_addr,panel_value,control_mode,panel_overflow);
    wire [2:0] router_bank_preset;
    wire dd_query_grant;wire[2:0]dd_internal_preset;
    // A query's ID settles during the existing router scan / DD query wait.
    // Register only this narrow selector, not the live ADSR parameter values.
    // This cuts the measured practice scene -> key-event arbitration -> query
    // selector -> ADSR -> command_patch combinational chain without new ready
    // latency, parameter sampling, or a timing exception.
    reg[2:0]envelope_query_preset_q;
    wire[2:0]envelope_query_preset_now=dd_query_grant ? dd_internal_preset : router_bank_preset;
    always @(posedge clk)if(rst)envelope_query_preset_q<=0;
      else envelope_query_preset_q<=envelope_query_preset_now;
    // synthesis translate_off
    integer query_selector_main_checks=0,query_selector_dd_checks=0;
    always @(posedge clk)if(!rst)begin
      if(dd_profile_ready)begin
        if(envelope_query_preset_q!==envelope_query_preset_now)$fatal(1,"DD query selector has not settled");
        query_selector_dd_checks=query_selector_dd_checks+1;
      end
      if(router_bank_valid&&route_bank_ready&&!router_bank_loop&&!router_source&&
         !(WITH_PRACTICE&&practice_mode)&&event_envelope_target&&
         !(capture_recording&&!(record_source===1'b1)))begin
        if(envelope_query_preset_q!==envelope_query_preset_now)$fatal(1,"Main query selector has not settled at original admission");
        query_selector_main_checks=query_selector_main_checks+1;
      end
    end
    // synthesis translate_on

    audio_parameter_service parameters(
        .clk(clk),.rst(rst),.sample_ce(sample_ce),.patch_locked(capture_recording),
        .envelope_query_preset(envelope_query_preset_q),.envelope_context_locked(score_active||(WITH_PRACTICE&&practice_mode)||(envelope_edit_lock===1'b1)),
        .envelope_query(query_envelope),.envelope_edited(envelope_edited),.envelope_epoch(envelope_epoch),
        .local_valid(panel_valid||fault_pending),.local_ready(local_ready),
        .local_addr(fault_pending ? 5'd30 : panel_addr),.local_value(fault_pending ? 32'd1 : panel_value),
        .host_valid(host_valid),.host_ready(host_ready),.host_addr(host_addr),.host_value(host_value),
        .adc_valid(adc_valid),.adc_ready(adc_ready),.adc_ch0(adc_ch0),.adc_ch1(adc_ch1),
        .adc_ch2(adc_ch2),.adc_ch3(adc_ch3),.adc_ch4(adc_ch4),
        .ack_valid(ack_valid),.ack_source(ack_source),.ack_addr(ack_addr),
        .ack_value(ack_value),.ack_accepted(ack_accepted),.ack_applied(ack_applied),
        .master_volume_target(master_target),.selected_preset(selected_preset),.wave_a(wave_a),.wave_b(wave_b),.raw_blend(raw_blend),
        .ensemble_style(ensemble_style),.ensemble_mode(ensemble_mode),.ensemble_minimum(ensemble_minimum),.ensemble_maximum(ensemble_maximum),
        .zone_left(left_base),.zone_right(right_base),.ordinary_sustain(sustain),.selective_sustain(sostenuto),
        .release_index(release_index),.glide_index(glide_index),.bend_index(bend_index),
        .lead_attack_index(lead_attack_index),.adsr_attack(adsr_a),.adsr_decay(adsr_d),
        .adsr_sustain(adsr_s),.adsr_release(adsr_r),.envelope_override(override_env),.custom_hold(custom_hold),
        .vibrato_depth(vibrato_depth),.vibrato_speed(vibrato_speed),
        .effect_enable(effect_enable),.effect_mix(effect_mix),.panic_pulse(panic),
        .params_updated(params_updated),.parameter_revision(revision),
        .raw_ch1(raw1),.raw_ch2(raw2),.raw_ch3(raw3),.raw_ch4(raw4),
        .harmonic_snapshot_valid(harmonic_valid),.harmonic_snapshot_ready(harmonic_ready),
        .harmonic_snapshot_ch1(harmonic1),.harmonic_snapshot_ch2(harmonic2),
        .harmonic_snapshot_ch3(harmonic3),.harmonic_snapshot_ch4(harmonic4),
        .fader_acquired(fader_acquired),.master_owner(master_owner),.adc_overrun(adc_overrun));
    assign harmonic_targets={raw4,raw3,raw2,raw1};
    assign fader_targets={raw4,raw3,raw2,(selected_preset==1 ? raw_blend : raw1)};
    assign synth_status={31'd0,blend_applied,raw_blend,wave_b,wave_a};
    wire params_busy,harmonic_overrun;
    wire [15:0] unused_volume,unused_target;
    wire [8:0] coeff0,coeff1,coeff2,coeff3,tc0,tc1,tc2,tc3;
    wire harmonic_updated;
    assign harmonic_ready=!params_busy;
    custom_harmonic_params harmonic_parameters(clk,rst,sample_ce,harmonic_valid&&harmonic_ready,
        12'd4095,harmonic1,harmonic2,harmonic3,harmonic4,
        unused_volume,coeff0,coeff1,coeff2,coeff3,unused_target,tc0,tc1,tc2,tc3,
        harmonic_updated,params_busy,harmonic_overrun);
    always @(posedge clk) begin
        if(rst) bend_factor<=65536;
        else case(bend_index)
            -8:bend_factor<=58386;-7:bend_factor<=59235;-6:bend_factor<=60097;
            -5:bend_factor<=60971;-4:bend_factor<=61858;-3:bend_factor<=62757;
            -2:bend_factor<=63670;-1:bend_factor<=64596;
            1:bend_factor<=66489;2:bend_factor<=67456;3:bend_factor<=68438;
            4:bend_factor<=69433;5:bend_factor<=70443;6:bend_factor<=71468;
            7:bend_factor<=72507;8:bend_factor<=73562;default:bend_factor<=65536;
        endcase
    end
    wire [16:0] vibrato_factor_value;
    wire [6:0] vibrato_depth_applied;
    vibrato_factor vibrato(.clk(clk),.rst(rst),.sample_ce(sample_ce),.enable(effective_vibrato_depth!=0),
        .depth({1'b0,effective_vibrato_depth}),.speed_index(vibrato_speed),.factor_q16(vibrato_factor_value),
        .depth_applied(vibrato_depth_applied));
    reg [16:0] lead_bend_factor;
    wire [33:0] pitch_product=expressive_bend_factor*vibrato_factor_value;
    always @(posedge clk) if(rst) lead_bend_factor<=65536;else lead_bend_factor<=pitch_product[32:16];
    reg [15:0] reference_release;
    always @* case(release_index)
        0:reference_release=96;1:reference_release=48;2:reference_release=24;
        3:reference_release=12;4:reference_release=6;5:reference_release=3;
        6:reference_release=2;default:reference_release=1;
    endcase
    wire [31:0] live_event_token,fault_count;
    wire [6:0] live_event_note;
    wire [2:0] live_event_preset;
    wire overflow_seen,token_exhausted;
    looper_keys #(.KEYS(KEYS),.SPLIT(SPLIT),.DIATONIC(DIATONIC)) key_events(
        clk,rst,panic||muting||(WITH_PRACTICE&&practice_manual_reset),changed,ghost,all_released,(score_active ? {KEYS{1'b0}} : keys),(WITH_PRACTICE&&practice_mode ? practice_patch[2:0] : drum_mode ? 3'd6 : selected_preset),(WITH_PRACTICE&&practice_mode ? 7'd48 : left_base),(WITH_PRACTICE&&practice_mode ? 7'd60 : right_base),
        live_event_valid,live_event_ready,live_event_off,live_event_token,live_event_note,live_event_preset,
        fault,blocked,overflow_seen,token_exhausted,fault_count);
    wire bank_valid,bank_ready,accepted,bank_clip,bank_deadline;
    wire signed [MIX_W-1:0] bank_sample;
    wire [31:0] rejected_count,unmatched_count;
    wire [N-1:0] sost_latched;
    wire [N*7-1:0] voice_notes;
    wire dd_valid,dd_ready,dd_off,dd_fault,dd_idle,dd_request,dd_profile_ready;
    wire[31:0]dd_token;wire[6:0]dd_note,dd_base;wire[2:0]dd_timbre;
    wire[7:0]dd_velocity;wire[3:0]dd_preset;wire[135:0]dd_patch;
    wire router_busy,router_source;
    assign dd_internal_preset=dd_preset==10 ? 1 : dd_preset>=7 ? 7 : dd_preset[2:0];
    reg[1:0]dd_query_phase;
    assign dd_query_grant=WITH_DD&&dd_request&&!router_busy&&!live_event_valid;
    assign dd_profile_ready=dd_query_grant&&dd_query_phase==2;
    reg[135:0]dd_profile_patch;
    always @*begin
      dd_profile_patch=record_patch_current;dd_profile_patch[135:132]=4'hb;
      dd_profile_patch[2:0]=dd_internal_preset;
      if(dd_preset!=(selected_preset==1 ? 10 : selected_preset==7 ? 7+ensemble_style : selected_preset))dd_profile_patch[127]=dd_preset==8||dd_preset==10;
      dd_profile_patch[126:125]=dd_preset>=7&&dd_preset<=9 ? dd_preset-7 : 0;
      dd_profile_patch[123]=dd_preset==0||dd_preset==4||dd_preset==5;
      dd_profile_patch[114:51]=query_envelope;
      if(dd_preset==10)dd_profile_patch[23:0]={blend_applied,wave_b,wave_a,3'd1};
    end
    always @(posedge clk)if(rst||!dd_query_grant)dd_query_phase<=0;
      else if(dd_query_phase!=2)dd_query_phase<=dd_query_phase+1'b1;
    generate if(WITH_DD)begin:dd_input
      dd_keyboard keyboard(.clk(clk),.rst(rst),.rx(dd_rx),.swap_ab(dd_swap),
       .enabled(!score_active&&!practice_mode&&!shared_score_owner&&!muting&&!panic),
       .patch_locked(capture_recording&&record_source),.reload(dd_reload),
       .profile_patch(dd_profile_patch),.profile_ready(dd_profile_ready),.profile_request(dd_request),
       .preset(dd_preset),.base_note(dd_base),.patch(dd_patch),.valid(dd_valid),.ready(dd_ready),
       .off(dd_off),.token(dd_token),.note(dd_note),.timbre(dd_timbre),.velocity(dd_velocity),
       .source_fault(dd_fault),.idle(dd_idle),.status(dd_status));
    end else begin:no_dd
      assign dd_valid=0;assign dd_off=0;assign dd_fault=0;assign dd_idle=1;assign dd_request=0;
      assign dd_token=0;assign dd_note=60;assign dd_timbre=0;assign dd_velocity=255;
      assign dd_preset=0;assign dd_base=60;assign dd_patch=0;assign dd_status=0;
    end endgenerate
    assign dd_patch_snapshot=dd_patch;
    // Fair arbitration is held until the router accepts a complete command.
    reg live_turn,live_chosen,live_owner;
    wire selected_dd=live_chosen ? live_owner : dd_valid&&(!live_event_valid||live_turn);
    wire combined_live_valid=selected_dd ? dd_valid : live_event_valid;
    always @(posedge clk)begin
      if(rst)begin live_turn<=0;live_chosen<=0;live_owner<=0;end
      else if(route_live_ready)begin live_chosen<=0;live_turn<=!selected_dd;end
      else if(live_chosen&&!router_busy&&!combined_live_valid)live_chosen<=0;
      else if(combined_live_valid&&!live_chosen)begin live_chosen<=1;live_owner<=selected_dd;end
    end
    wire [N*3-1:0] voice_presets;
    wire [N*32-1:0] voice_tokens;
    wire [N*16-1:0] voice_envelopes;wire [N*5-1:0] current_origins;
    reg clear_bank,prior_panel_overflow;
    wire panel_fault=panel_overflow&&!prior_panel_overflow;
    assign panel_ready=local_ready&&!fault_pending;
    wire router_bank_valid,router_bank_off,router_bank_loop;
    wire [31:0] router_bank_token;
    wire [6:0] router_bank_note;
    wire [2:0] router_bank_track;
    wire [135:0] router_bank_patch;
    wire [1:0] router_bank_layer;
    wire router_bank_force_release,router_expression_valid;wire [7:0] router_bank_velocity;
    wire [1:0] router_expression_kind,router_expression_track,router_expression_layer;
    wire [16:0] router_expression_value;
    wire [31:0] route_faults,unmatched_route_offs;
    reg record_pending;reg [11:0] pending_tick;reg [1:0] pending_kind;reg [6:0] pending_note;
    reg [15:0] pending_id;reg [7:0] pending_velocity;
    wire [11:0] route_record_tick;wire router_record_busy;wire route_live_ready,route_loop_ready,route_record_valid;
    wire [1:0] route_record_kind;
    wire [6:0] route_record_note;
    wire [15:0] route_record_id;
    wire [7:0] route_record_velocity;
    wire route_drum_valid;
    wire [1:0] route_drum_layer;wire [2:0] route_drum_track;wire [3:0] route_drum_pad;
    wire [7:0] route_drum_velocity;
    wire router_flushing;reg clear_auto_pending,clear_live_pending,practice_clear_live;
    reg[1:0]source_settle;
    assign practice_source_busy=WITH_PRACTICE&&(clear_auto_pending||clear_live_pending||source_settle!=0||practice_clear_auto||practice_clear_live);
    assign flushing=router_flushing||practice_source_busy;
    wire route_bank_ready=bank_ready&&!muting&&!panic&&!fault&&(!practice_source_busy||router_flushing);
    always @(posedge clk)begin
     if(rst||!WITH_PRACTICE)begin clear_auto_pending<=0;clear_live_pending<=0;source_settle<=0;practice_clear_auto<=0;practice_clear_live<=0;end
     else begin
      practice_clear_auto<=0;practice_clear_live<=0;
      if(source_settle!=0)source_settle<=source_settle-1'b1;
      if(practice_flush||practice_manual_reset)begin
       clear_auto_pending<=clear_auto_pending||practice_flush;clear_live_pending<=clear_live_pending||practice_manual_reset;source_settle<=2;
      end else if(source_settle==0&&!router_flushing&&bank_ready&&practice_drum_idle&&(clear_auto_pending||clear_live_pending))begin
       practice_clear_auto<=clear_auto_pending;practice_clear_live<=clear_live_pending;clear_auto_pending<=0;clear_live_pending<=0;source_settle<=2;
      end
     end
    end
    looper_event_router #(.VOICES(N),.PATCH_W(136),.USE_ACK(1)) event_router(
        .clk(clk),.rst(rst||clear_bank),.flush_live(WITH_PRACTICE&&practice_manual_reset),
        .live_tick(current_loop_tick),.record_tick(route_record_tick),.live_valid(combined_live_valid),.live_ready(route_live_ready),.live_off(selected_dd ? dd_off : live_event_off),
        .live_token(selected_dd ? dd_token : live_event_token),.live_note(selected_dd ? dd_note : live_event_note),.live_preset(selected_dd ? dd_timbre : live_event_preset),
        .live_source(selected_dd),.live_velocity(selected_dd ? dd_velocity : 8'd255),.live_patch(dd_patch),
        .live_force_release(1'b0),.live_record(selected_dd==(record_source===1'b1)),
        .flush_source_valid(dd_fault),.flush_source(1'b1),.bank_source(router_source),.router_busy(router_busy),
        .record_busy(router_record_busy),.record_ready(!record_pending),.bank_accepted(accepted),.bank_rejected(rejected),
        .flush_all(flush_all),.flush_valid(flush_valid),.flush_track(flush_track),.flush_layer(flush_layer),
        .flush_whole_track(flush_whole_track),.flushing(router_flushing),
        .recording(capture_recording),.record_valid(route_record_valid),.record_kind(route_record_kind),
        .record_note(route_record_note),.record_local_id(route_record_id),
        .record_velocity(route_record_velocity),
        .loop_valid(loop_event_valid),.loop_ready(route_loop_ready),.loop_off(loop_event_off),
        .loop_drum(loop_event_drum),.loop_track(loop_event_track),.loop_layer(loop_event_layer),
        .loop_control(WITH_EXPRESSION ? loop_event_control : 1'b0),
        .loop_local_id(loop_event_id),.loop_note(loop_event_note),.loop_velocity(loop_event_velocity),
        .loop_preset(loop_event_preset),.loop_patch(loop_event_patch),
        .bank_valid(router_bank_valid),.bank_ready(route_bank_ready),.bank_off(router_bank_off),
        .bank_token(router_bank_token),.bank_note(router_bank_note),.bank_preset(router_bank_preset),
        .bank_track(router_bank_track),
        .bank_patch(router_bank_patch),.bank_loop(router_bank_loop),
        .bank_layer(router_bank_layer),.bank_force_release(router_bank_force_release),
        .bank_velocity(router_bank_velocity),
        .expression_valid(router_expression_valid),.expression_kind(router_expression_kind),
        .expression_track(router_expression_track),.expression_layer(router_expression_layer),.expression_value(router_expression_value),
        .drum_valid(route_drum_valid),.drum_ready(drum_event_ready),.drum_accepted(drum_event_accepted),
        .drum_layer(route_drum_layer),.drum_track(route_drum_track),.drum_pad(route_drum_pad),.drum_velocity(route_drum_velocity),
        .route_faults(route_faults),.unmatched_offs(unmatched_route_offs));
    assign loop_route_faults=route_faults;assign loop_unmatched_offs=unmatched_route_offs;
    assign live_event_ready=route_live_ready&&!selected_dd;assign dd_ready=route_live_ready&&selected_dd;
    assign loop_event_ready=route_loop_ready;
    wire capture_expression_valid,capture_expression_busy,capture_expression_ready;
    wire [11:0] capture_expression_tick;wire [1:0] capture_expression_kind;wire [16:0] capture_expression_value;
    generate if(WITH_EXPRESSION) begin: expression_capture
        looper_expression_capture recorder(.clk(clk),.rst(rst),.sample_ce(sample_ce),.recording(recording),
            .capture_enable(capture_recording && (record_source===1'b1 ? dd_patch[2:0]!=6 : !drum_mode)),.tick(current_loop_tick),
            .pedal(sustain),.sostenuto(sostenuto),.bend(bend_factor),
            .valid(capture_expression_valid),.ready(capture_expression_ready),.event_tick(capture_expression_tick),
            .kind(capture_expression_kind),.value(capture_expression_value),.busy(capture_expression_busy),.overflow(expression_overflow));
    end else begin: no_expression
        assign capture_expression_valid=0;assign capture_expression_busy=0;
        assign capture_expression_tick=0;assign capture_expression_kind=0;assign capture_expression_value=0;assign expression_overflow=0;
    end endgenerate
    // Register the selected payload BEFORE the store's quantizer/identity
    // lookup. No FIFO mux/comparator-to-write cascade; hold on backpressure.
    reg merged_valid;reg [44:0] merged_event;
    wire choose_expression=capture_expression_valid && (!record_pending || capture_expression_tick<=pending_tick);
    wire take_merged=!merged_valid && recording && (choose_expression ||
        (record_pending && (!capture_expression_busy || capture_expression_valid)));
    assign capture_expression_ready=take_merged && choose_expression;
    assign record_busy=merged_valid || record_pending || router_record_busy || capture_expression_busy;
    assign {record_event_velocity,record_event_id,record_event_note,record_event_kind,record_event_tick}=merged_event;
    assign record_event_valid=merged_valid;
    always @(posedge clk) begin
        if(rst || !recording) begin merged_valid<=0;merged_event<=0;end
        else begin
            if(merged_valid && record_ready) merged_valid<=0;
            if(take_merged) begin
                merged_valid<=1;
                merged_event<=choose_expression ? {{7'd0,capture_expression_value[16]},capture_expression_value[15:0],
                    {5'd0,capture_expression_kind},2'd3,capture_expression_tick} :
                    {pending_velocity,pending_id,pending_note,pending_kind,pending_tick};
            end
        end
    end
    always @(posedge clk) begin
        if(rst || !recording) begin record_pending<=0;pending_kind<=0;pending_note<=0;pending_id<=0;pending_velocity<=0;pending_tick<=0;end
        else begin
            if(take_merged && !choose_expression) record_pending<=0;
            if(route_record_valid) begin record_pending<=1;pending_kind<=route_record_kind;
                pending_note<=route_record_note;pending_id<=route_record_id;pending_velocity<=route_record_velocity;pending_tick<=route_record_tick;end
        end
    end
    assign drum_event_valid=route_drum_valid;
    assign drum_event_layer=route_drum_layer;
    assign drum_event_track=route_drum_track;
    assign drum_event_pad=route_drum_pad;
    assign drum_event_velocity=route_drum_velocity;
    wire [135:0] ordinary_patch={4'ha,ensemble_maximum,ensemble_minimum,ensemble_mode,ensemble_style,custom_hold,override_env,glide_index,lead_attack_index,release_index,
        adsr_r,adsr_s,adsr_d,adsr_a,{3'd0,coeff3},{3'd0,coeff2},{3'd0,coeff1},{3'd0,coeff0},
        (drum_mode ? 3'd6 : selected_preset)};
    assign record_patch_current=selected_preset==1 ? {ordinary_patch[135:24],blend_applied,wave_b,wave_a,3'd1} : ordinary_patch;
    reg [135:0] take_patch;reg capture_previous;
    always @(posedge clk) if(rst) begin take_patch<=0;capture_previous<=0;end
      else begin capture_previous<=capture_recording;if(capture_recording&&!capture_previous) take_patch<=record_patch_current;end
    // Internal marker B freezes a captured live strike through its old tail.
    // Stored/replayed public local patches retain version marker A.
    wire event_envelope_target=router_bank_preset==0||router_bank_preset==4||router_bank_preset==5;
    // Resolve by the queued event's timbre, not by a later TIM selection.
    // Marker A keeps harmonics and expression live. Only envelope fields freeze.
    wire [135:0] event_local_patch={record_patch_current[135:124],event_envelope_target,
        record_patch_current[122:115],query_envelope,record_patch_current[50:0]};
    wire [135:0] live_patch=capture_recording&&!(record_source===1'b1) ? {4'hb,take_patch[131:0]} : event_local_patch;
    wire score_valid;wire signed [15:0] score_sample;
    audio_v2_bank #(.WITH_PRACTICE(WITH_PRACTICE),.OUT_W(MIX_W),.N(N),.PLUCK_N(PLUCK_N),.WITH_TF(WITH_TF),.WITH_SCORE(WITH_SCORE),.SCORE_N(SCORE_N)) bank(
        .practice_mode(WITH_PRACTICE&&practice_mode),.practice_clear_auto(practice_clear_auto),.practice_clear_live(practice_clear_live),.clk(clk),.rst(rst||clear_bank),.sample_ce(sample_ce),.loop_pause(tf_pause),.sequencer_busy(sequencer_busy),
        .event_valid(router_bank_valid&&(!practice_source_busy||router_flushing)),.event_ready(bank_ready),.event_off(router_bank_off),
        .event_token(router_bank_token),.event_note(router_bank_note),.event_timbre(router_bank_preset),
        // KEYBOARD_V2 has no velocity sensor; preserve the accepted full-level strike.
        // A floating input simulates as Z but Gowin ties it to zero: silence.
        .event_velocity(router_bank_velocity),
        .event_is_loop(router_bank_loop),.event_track(router_bank_track),.event_patch(router_bank_loop||router_source ? router_bank_patch : WITH_PRACTICE&&practice_mode ? practice_patch : live_patch),
        .event_layer(router_bank_layer),.event_force_release(router_bank_force_release),
        .expression_valid(router_expression_valid),.expression_kind(router_expression_kind),
        .expression_track(router_expression_track),.expression_layer(router_expression_layer),.expression_value(router_expression_value),
        .expression_reset_all(flush_all),.expression_reset_valid(flush_valid),
        .expression_reset_whole_track(flush_whole_track),.expression_reset_track(flush_track),.expression_reset_layer(flush_layer),
        .track_gains(track_gains),.pedal(WITH_PRACTICE&&practice_mode ? 1'b0 : effective_live_sustain),.sostenuto(WITH_PRACTICE&&practice_mode ? 1'b0 : sostenuto),
        .reference_release(reference_release),.glide_index(glide_index),.lead_attack_index(lead_attack_index),
        .bend_factor(expressive_bend_factor),.lead_bend_factor(lead_bend_factor),
        .envelope_override(override_env),.custom_hold(custom_hold),
        .adsr_attack(adsr_a),.adsr_decay(adsr_d),.adsr_sustain(adsr_s),.adsr_release(adsr_r),
        .coeff0(coeff0),.coeff1(coeff1),.coeff2(coeff2),.coeff3(coeff3),.ab_mix(blend_applied),
        .accepted(accepted),.rejected(rejected),.rejected_count(rejected_count),.unmatched_off_count(unmatched_count),
        .occupied(occupied),.held(held),.gated(gated),.sost_latched(sost_latched),
        .notes_snapshot(voice_notes),.presets_snapshot(voice_presets),.tokens_snapshot(voice_tokens),
        .envelopes_snapshot(voice_envelopes),.origins_snapshot(current_origins),.out_valid(bank_valid),.out_sample(bank_sample),
        .clipped(bank_clip),.deadline_missed(bank_deadline),
        .score_toggle(score_toggle),.score_safe(score_safe&&!(|occupied)&&!recording&&!flushing),.score_panic(score_panic),
        .score_size(score_size),.score_group(score_group),.score_probe(score_probe),
        .score_active(score_active),.shared_score_owner(shared_score_owner),.shared_score_read(shared_score_read),.shared_score_ra(shared_score_ra),.shared_score_state(shared_score_state),.shared_score_control(shared_score_control),.shared_score_state_we(shared_score_state_we),.shared_score_state_wa(shared_score_state_wa),.shared_score_state_wd(shared_score_state_wd),.shared_score_control_we(shared_score_control_we),.shared_score_control_wa(shared_score_control_wa),.shared_score_control_wd(shared_score_control_wd),.shared_score_ready(shared_score_ready),.score_valid(score_valid),.score_sample(score_sample),.score_status(score_status));
    // A mode request may complete between DAC sample edges. Keep the selected
    // renderer fixed for the whole frame, including its downstream completion.
    // Both renderers observe this same sample_ce edge before advancing state.
    reg score_frame;
    always @(posedge clk) begin
        if(rst) score_frame<=0;
        else if(sample_ce) score_frame<=score_active;
    end
    wire source_valid=score_frame ? score_valid : bank_valid;
    wire signed [MIX_W-1:0] source_sample=score_frame ? score_sample : bank_sample;
    wire room_valid,room_clip,room_ready,room_busy,room_overrun;
    wire signed [MIX_W-1:0] room_left,room_right;
    wire [8:0] wet_applied;
    generate if(WITH_FX)begin:room
      reg previous_score;
      always @(posedge clk)if(rst)previous_score<=0;else previous_score<=score_active;
      if(WITH_NEW_FX)begin:shared
       wire filter_valid,filter_overrun,space_overrun;wire signed[MIX_W-1:0]filtered;
       bus_filter #(.W(MIX_W)) filter(.clk(clk),.rst(rst||clear_bank),.in_valid(source_valid),.in_sample(source_sample),.force_dry(score_frame),
         .kind(filter_type),.cutoff(filter_cutoff),.out_valid(filter_valid),.out_sample(filtered),.overrun(filter_overrun));
       shared_space_fx #(.DATA_W(MIX_W)) effect(.clk(clk),.rst(rst||clear_bank),
         .flush_tail(previous_score!=score_active),.force_dry(score_frame),.in_valid(filter_valid),.in_sample(filtered),
         .fx_enable(space_type!=0),.space_type(space_type),.chorus_rate(chorus_rate),.chorus_depth(chorus_depth),.wet_q8({1'b0,effect_mix}),
         .out_valid(room_valid),.out_left(room_left),.out_right(room_right),.clip(room_clip),.ready(room_ready),.busy(room_busy),.overrun(space_overrun),.wet_applied(wet_applied));
       assign room_overrun=filter_overrun||space_overrun;
      end else begin:legacy
      short_room_reverb #(.DATA_W(MIX_W)) effect(.clk(clk),.rst(rst||clear_bank),
       .flush_tail(previous_score!=score_active),.force_dry(score_frame),
       .in_valid(source_valid),.in_sample(source_sample),
       .fx_enable(WITH_TF&&tf_owner ? tf_fx : effect_enable),.wet_q8({1'b0,(WITH_TF&&tf_owner ? tf_wet : effect_mix)}),
       .out_valid(room_valid),.out_left(room_left),.out_right(room_right),.clip(room_clip),
       .ready(room_ready),.busy(room_busy),.overrun(room_overrun),.wet_applied(wet_applied));
      end
    end else begin:no_room
      assign room_valid=source_valid;assign room_left=source_sample;assign room_right=source_sample;
      assign room_clip=0;assign room_ready=1;assign room_busy=0;assign room_overrun=0;assign wet_applied=0;
    end endgenerate
    // Retain the original fixed /2 and original CH0 scale. Wide music/room
    // survive this stage; PCM16 saturation is AFTER master, with clip telemetry.
    // Scoring output must be isolated from a previously armed drum/click tail.
    wire signed [15:0] scoring_auxiliary = score_frame ? 16'sd0 : auxiliary_sample;
    wire signed [MIX_W:0] pre_left=$signed(room_left)+$signed(scoring_auxiliary);
    wire signed [MIX_W:0] pre_right=$signed(room_right)+$signed(scoring_auxiliary);
    wire signed [MIX_W-1:0] headroom_left=pre_left>>>1;
    wire signed [MIX_W-1:0] headroom_right=pre_right>>>1;
    wire final_right_valid,left_gain_clip,right_gain_clip;
    wire output_clip=left_gain_clip||right_gain_clip;
    wide_knob_gain #(.IN_W(MIX_W)) left_gain(clk,rst,room_valid,headroom_left,muting ? 17'd0 : master_target,
        final_valid,final_left,gain_left,left_gain_clip);
    wide_knob_gain #(.IN_W(MIX_W)) right_gain(clk,rst,room_valid,headroom_right,muting ? 17'd0 : master_target,
        final_right_valid,final_right,gain_right,right_gain_clip);
    assign deadline_missed=bank_deadline||room_overrun||gesture_pitch_deadline;
    reg [9:0] snapshot_div;
    reg [31:0] snapshot_sequence;
    reg [31:0] frame_number;
    reg gain_pending;
    reg reset_gap_pending;
    reg [15:0] stream_reset_count;
    reg [15:0] meter_peak;
    reg meter_clipped;
    wire [15:0] left_absolute=final_left<0 ? -final_left : final_left;
    wire [15:0] right_absolute=final_right<0 ? -final_right : final_right;
    wire [15:0] current_peak=left_absolute>right_absolute ? left_absolute : right_absolute;
    wire [15:0] next_peak=current_peak>meter_peak ? current_peak : meter_peak;
    integer k;
    always @(posedge clk) begin
        if(rst) begin
            muting<=0;clear_bank<=0;prior_panel_overflow<=0;clip_seen<=0;fault_pending<=0;
            sample_index<=0;snapshot_valid<=0;snapshot_data<=0;snapshot_div<=0;snapshot_sequence<=0;
            snapshot_extension<=0;snapshot_keys<=0;voice_origins<=0;
            meter_peak<=0;meter_clipped<=0;
            frame_number<=0;gain_pending<=0;reset_gap_pending<=0;stream_reset_count<=0;
        end else begin
            prior_panel_overflow<=panel_overflow;
            if(fault||panel_fault) fault_pending<=1;
            else if(fault_pending&&local_ready) fault_pending<=0;
            clear_bank<=0;snapshot_valid<=0;
            if(sample_ce) frame_number<=frame_number+1'b1;
            gain_pending<=room_valid;
            if(gain_pending) sample_index<=frame_number-1'b1;
            if(clear_bank) begin reset_gap_pending<=1;stream_reset_count<=stream_reset_count+1'b1;end
            if(bank_clip||room_clip||output_clip) clip_seen<=1;
            if(bank_clip||room_clip||output_clip) meter_clipped<=1;
            if(panic||fault||panel_fault) muting<=1;
            else if(muting&&gain_left==0&&gain_right==0&&bank_valid) begin clear_bank<=1;muting<=0;end
            if(final_valid) begin
                reset_gap_pending<=0;
                snapshot_div<=snapshot_div+1'b1;
                meter_peak<=next_peak;
                if(snapshot_div==1023) begin
                    snapshot_valid<=1;snapshot_sequence<=snapshot_sequence+1'b1;
                    meter_peak<=0;meter_clipped<=0;
                    snapshot_data<=0;
                    snapshot_extension<=0;snapshot_keys<=keys;voice_origins<=current_origins;
                    snapshot_extension[31:0]<=sample_index;
                    snapshot_extension[47:32]<=adsr_a;snapshot_extension[63:48]<=adsr_d;
                    snapshot_extension[79:64]<=adsr_s;snapshot_extension[95:80]<=adsr_r;
                    snapshot_extension[107:96]<=raw1;snapshot_extension[119:108]<=raw2;
                    snapshot_extension[131:120]<=raw3;snapshot_extension[143:132]<=raw4;
                    snapshot_extension[145:144]<=lead_attack_index;
                    snapshot_extension[177:146]<=unmatched_count;
                    snapshot_extension[183:178]<=N>63 ? 63 : N;snapshot_extension[189:184]<=PLUCK_N;
                    snapshot_extension[197:190]<=8'd2;
                    snapshot_extension[205:198]<=8'd2;
                    snapshot_extension[213:206]<=N; // extended capacity, no 6-bit wrap
                    snapshot_extension[221:214]<=8'd3; // core extension version
                    snapshot_extension[222]<=output_clip;
                    snapshot_extension[226:223]<=envelope_edited;snapshot_extension[234:227]<=envelope_epoch;
                    snapshot_data[31:0]<=snapshot_sequence;
                    snapshot_data[63:32]<=revision;
                    snapshot_data[80:64]<=master_target;
                    snapshot_data[97:81]<=gain_left;
                    snapshot_data[100:98]<=selected_preset;
                    snapshot_data[101]<=sustain;snapshot_data[102]<=sostenuto;
                    snapshot_data[103]<=override_env;snapshot_data[104]<=custom_hold;
                    snapshot_data[105]<=effect_enable;snapshot_data[106]<=clip_seen;
                    snapshot_data[107]<=deadline_missed;snapshot_data[108]<=blocked;
                    snapshot_data[113:109]<=control_mode;
                    snapshot_data[120:114]<=left_base;snapshot_data[127:121]<=right_base;
                    snapshot_data[130:128]<=release_index;snapshot_data[133:131]<=glide_index;
                    snapshot_data[138:134]<=bend_index;snapshot_data[145:139]<=vibrato_depth;
                    snapshot_data[148:146]<=vibrato_speed;snapshot_data[156:149]<=effect_mix;
                    snapshot_data[165:157]<=wet_applied;snapshot_data[201:166]<={coeff3,coeff2,coeff1,coeff0};
                    snapshot_data[233:202]<=rejected_count;snapshot_data[265:234]<=fault_count;
                    snapshot_data[281:266]<=next_peak;snapshot_data[282]<=meter_clipped||bank_clip||room_clip||output_clip;
                    snapshot_data[283]<=adc_overrun;snapshot_data[284]<=harmonic_overrun;
                    snapshot_data[285]<=panel_overflow;snapshot_data[290:286]<=fader_acquired;
                    snapshot_data[291]<=room_ready;snapshot_data[292]<=muting;
                    snapshot_data[294]<=reset_gap_pending;snapshot_data[310:295]<=stream_reset_count;
                    snapshot_data[312:311]<=master_owner;snapshot_data[319:313]<=vibrato_depth_applied;
                    for(k=0;k<N;k=k+1) begin
                        snapshot_data[320+k*64+:32]<=voice_tokens[k*32+:32];
                        snapshot_data[352+k*64+:7]<=voice_notes[k*7+:7];
                        snapshot_data[359+k*64+:3]<=voice_presets[k*3+:3];
                        snapshot_data[362+k*64]<=occupied[k];snapshot_data[363+k*64]<=held[k];
                        snapshot_data[364+k*64]<=gated[k];snapshot_data[365+k*64]<=sost_latched[k];
                        snapshot_data[366+k*64+:16]<=voice_envelopes[k*16+:16];
                    end
                end
            end
        end
    end
    assign performance_view={7'd0,ensemble_maximum,ensemble_minimum,ensemble_mode,ensemble_style,raw4,raw3,raw2,raw1,master_owner,fader_acquired,
        vibrato_depth,effect_enable,sostenuto,sustain,bend_index,glide_index,release_index,
        coeff3,coeff2,coeff1,coeff0,gain_left,master_target};
endmodule
