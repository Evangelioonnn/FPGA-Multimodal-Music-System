// Music pipeline experiment: exact legacy tone arithmetic; tagged overlap.
// Shared state datapath, independent strike storage and a bounded pluck pool.
module audio_v2_bank #(parameter WITH_TF=0,WITH_PRACTICE=0,WITH_SCORE=0,SCORE_N=512,N=32,FRAME_CLOCKS=1040,MIX_SHIFT=6,OUT_W=16,PLUCK_N=0,PN=(PLUCK_N>0?PLUCK_N:1),SW=(N>1?$clog2(N):1),PATCH_W=136)(
    input wire clk,rst,sample_ce,event_valid,output wire event_ready,input wire loop_pause,output wire sequencer_busy,
    input wire event_off,input wire [31:0] event_token,input wire [6:0] event_note,
    input wire [2:0] event_timbre,input wire event_is_loop,input wire [2:0] event_track,
    input wire [PATCH_W-1:0] event_patch,input wire [67:0] track_gains,
    input wire [1:0] event_layer,input wire event_force_release,
    input wire expression_valid,input wire [1:0] expression_kind,expression_track,expression_layer,
    input wire [16:0] expression_value,
    input wire expression_reset_all,expression_reset_valid,expression_reset_whole_track,
    input wire [1:0] expression_reset_track,expression_reset_layer,
    input wire pedal,sostenuto,
    input wire [15:0] reference_release,input wire [2:0] glide_index,
    input wire [1:0] lead_attack_index,input wire [16:0] bend_factor,lead_bend_factor,
    input wire envelope_override,custom_hold,
    input wire [15:0] adsr_attack,adsr_decay,adsr_sustain,adsr_release,
    input wire [8:0] coeff0,coeff1,coeff2,coeff3,input wire [16:0] ab_mix,
    output reg accepted,rejected,output reg [31:0] rejected_count,unmatched_off_count,
    output wire [N-1:0] occupied,held,gated,sost_latched,
    output wire [N*7-1:0] notes_snapshot,output wire [N*3-1:0] presets_snapshot,
    output wire [N*32-1:0] tokens_snapshot,output wire [N*5-1:0] origins_snapshot,
    output wire [N*16-1:0] envelopes_snapshot,
    output reg out_valid,output reg signed [OUT_W-1:0] out_sample,
    output reg clipped,deadline_missed,
    input wire [7:0] event_velocity,
    input wire score_toggle,score_safe,score_panic,
    input wire [2:0] score_size,input wire [1:0] score_group,input wire score_probe,
    output wire score_active,score_valid,output wire signed [15:0] score_sample,
    output wire [127:0] score_status,
 input wire shared_score_owner,
 output wire shared_score_read,output wire[8:0]shared_score_ra,
 input wire[47:0]shared_score_state,shared_score_control,
 output wire shared_score_state_we,output wire[8:0]shared_score_state_wa,output wire[47:0]shared_score_state_wd,
 output wire shared_score_control_we,output wire[8:0]shared_score_control_wa,output wire[47:0]shared_score_control_wd,
 output wire shared_score_ready,input wire practice_mode,input wire practice_clear_auto,practice_clear_live
);
    wire music_ce=sample_ce&&!score_active;
    reg score_frame;
    always @(posedge clk)if(rst)score_frame<=0;else if(sample_ce)score_frame<=score_active;
    wire [31:0] score_phase;wire [15:0] score_env;
    wire score_accumulate;wire signed [47:0] common_sum,common_sum_next;
    generate if(WITH_SCORE)begin: scoring_frontend
      scoring_session #(.N(SCORE_N),.SHARED_MEMORY(WITH_PRACTICE)) scoring(.clk(clk),.rst(rst),.sample_ce(sample_ce),
        .toggle_request(score_toggle),.safe_enter(score_safe),.panic(score_panic),
        .requested_size(score_size),.requested_group(score_group),.probe(score_probe),
        .active(score_active),.out_valid(score_valid),.out_sample(score_sample),.status(score_status),
        .backend_phase(score_phase),.backend_env(score_env),.backend_accumulate(score_accumulate),.backend_sum_next(common_sum_next),.shared_score_owner(shared_score_owner),.shared_score_read(shared_score_read),.shared_score_ra(shared_score_ra),.shared_score_state(shared_score_state),.shared_score_control(shared_score_control),.shared_score_state_we(shared_score_state_we),.shared_score_state_wa(shared_score_state_wa),.shared_score_state_wd(shared_score_state_wd),.shared_score_control_we(shared_score_control_we),.shared_score_control_wa(shared_score_control_wa),.shared_score_control_wd(shared_score_control_wd),.shared_score_ready(shared_score_ready));
    end else begin: no_scoring
      assign shared_score_read=0;assign shared_score_ra=0;assign shared_score_state_we=0;assign shared_score_state_wa=0;assign shared_score_state_wd=0;assign shared_score_control_we=0;assign shared_score_control_wa=0;assign shared_score_control_wd=0;assign shared_score_ready=0;
      assign score_phase=0;assign score_env=0;assign score_accumulate=0;assign score_active=0;
      assign score_valid=0;assign score_sample=0;assign score_status=0;
    end endgenerate

    localparam IDLE=0,E_SCAN=1,E_COMMIT=2,R_READ=3,R_MULT=4,R_WRITE=5,
               T_START=6,T_WAIT=7,P_MIX=8,FINISH=9,E_READ=10,E_CHECK=11,P_GAIN=12,R_FETCH=13,E_FETCH=14,R_DRAIN=15,E_REFRESH_READ=16,E_REFRESH_FETCH=17,E_LEAD_READ=18,E_LEAD_FETCH=19;
    reg [16:0] track_gain_q,track_input_q,velocity_input_q;
    reg [4:0] state;reg match_refreshed,lead_refreshed;reg [SW-1:0] lead_slot;
    // Constant rational legacy tick. Audio phase/output advance every frame;
    // envelope/glide/slew/age keep their accepted physical timing at higher Fs.
    reg [10:0] control_phase;reg frame_control_tick;
    wire [11:0] control_sum={1'b0,control_phase}+FRAME_CLOCKS;
    always @(posedge clk)if(rst)begin control_phase<=0;frame_control_tick<=1;end
    else if(music_ce)begin
        frame_control_tick<=FRAME_CLOCKS==1040 || control_sum>=1040;
        control_phase<=FRAME_CLOCKS==1040 ? 11'd0 : control_sum>=1040 ? control_sum-1040 : control_sum;
    end
    reg [SW-1:0] index,scan_index,free_slot,match_slot;
    reg [N-1:0] hbusy,hheld,hgated,hsost,override_mask;
    reg [PN-1:0] pstart,pstop;
    wire [PN-1:0] pbusy,pheld,pgated,psost;
    wire [PN*20-1:0] psamples;
    wire [PN-1:0] release_request;
    wire [PN*34-1:0] release_operands;
    wire [PN*26-1:0] release_factors;
    reg [PN-1:0] release_grants;
    reg [2:0] release_state;
    reg [SW-1:0] release_index;
    reg signed [33:0] release_operand;
    reg signed [25:0] release_factor;
    reg signed [59:0] release_product;
    wire signed [59:0] release_next=release_operand*release_factor;
    always @(posedge clk) begin
        if(rst) begin
            release_state<=0;release_index<=0;release_grants<=0;
            release_operand<=0;release_factor<=0;release_product<=0;
        end else begin
            release_grants<=0;
            case(release_state)
                0:if(release_request[release_index]) begin
                    release_operand<=release_operands[release_index*34+:34];
                    release_factor<=release_factors[release_index*26+:26];release_state<=1;
                end else release_index<=release_index==PLUCK_N-1 ? 0 : release_index+1'b1;
                1:begin release_product<=release_next;release_state<=2;end
                2:begin release_grants[release_index]<=1;release_state<=3;end
                3:begin release_index<=release_index==PLUCK_N-1 ? 0 : release_index+1'b1;release_state<=0;end
                default:release_state<=0;
            endcase
        end
    end
    reg [SW-1:0] powner[0:PN-1];
    reg [2:0] ptrack[0:PN-1];
    // Allocation already spends E_READ before each E_SCAN. Use that cycle
    // for a synchronous token lookup instead of a64x32 register mux.
    (* syn_ramstyle="block_ram" *) reg [31:0] tokens[0:N-1];
    reg [31:0] scan_token_q;reg [N-1:0] token_written;
    wire [2:0] presets[0:N-1];
    reg [2:0] tracks[0:N-1];
    reg [1:0] layers[0:N-1];
    reg [15:0] loop_pedal,loop_sost;
    wire [16:0] loop_bend[0:15];
    (* syn_ramstyle="block_ram" *)reg[16:0] loop_bend_memory[0:15];
    reg[15:0]loop_bend_written;
    reg bend_pending;reg[3:0]bend_pending_lane;reg[16:0]bend_pending_value;
    reg[16:0]bend_loop_q,bend_live_q;reg bend_loop_valid_q,bend_from_loop_q,bend_latch;
    // Delay only the physical write. Logical observations forward it immediately.
    always @(posedge clk)begin
      if(!rst&&bend_pending)loop_bend_memory[bend_pending_lane]<=bend_pending_value;
      bend_loop_q<=bend_pending&&bend_pending_lane==render_lane ? bend_pending_value : loop_bend_memory[render_lane];
      bend_loop_valid_q<=loop_bend_written[render_lane];
    end
    always @(posedge clk)begin
      if(rst)begin bend_pending<=0;bend_pending_lane<=0;bend_pending_value<=65536;bend_from_loop_q<=0;bend_live_q<=65536;bend_latch<=0;end
      else begin
        bend_pending<=expression_valid===1'b1&&expression_kind==2;
        if(expression_valid===1'b1&&expression_kind==2)begin bend_pending_lane<=expression_lane;bend_pending_value<=expression_value;end
        if(!music_ce&&state==R_READ)begin
          bend_live_q<=practice_fixed ? 17'd65536 : (owner_read[9:7]==4||owner_read[9:7]==7||owner_read[9:7]==1) ? lead_bend_factor : bend_factor;
          bend_from_loop_q<=!practice_fixed&&is_loop_w;bend_latch<=1;
        end else if(state==R_FETCH&&bend_latch)bend_latch<=0;
      end
    end
    genvar bl;
    generate for(bl=0;bl<16;bl=bl+1)begin: bend_layer
      assign loop_bend[bl]=!loop_bend_written[bl] ? 17'd65536 : bend_pending&&bend_pending_lane==bl ? bend_pending_value : loop_bend_memory[bl];
      always @(posedge clk)begin
        if(rst)loop_bend_written[bl]<=0;
        else begin
          if(expression_valid===1'b1&&expression_kind==2&&expression_lane==bl)loop_bend_written[bl]<=1;
          if(expression_reset_all===1'b1 || (expression_reset_valid===1'b1&&bl/4==expression_reset_track&&(expression_reset_whole_track||bl%4==expression_reset_layer)))loop_bend_written[bl]<=0;
        end
      end
    end endgenerate
    wire [3:0] expression_lane={expression_track,expression_layer};
    wire [3:0] render_lane={tracks[index][1:0],layers[index]};
    // R20: immutable ownership is stable throughout one existing render read.
    // No extra microstate and no early capture of live pedal/ADSR/coefficients.
    reg render_is_loop_q,render_fixed_q;reg[3:0]render_lane_q;
    always @(posedge clk)begin
      if(rst)begin render_is_loop_q<=0;render_fixed_q<=0;render_lane_q<=0;end
      else if(!music_ce&&state==R_READ)begin
        render_is_loop_q<=loop_mask[index];
        render_fixed_q<=loop_mask[index]||patch_frozen[index];
        render_lane_q<={tracks[index][1:0],layers[index]};
      end
    end
    // synthesis translate_off
    always @(posedge clk)if(!rst&&!music_ce&&
      (state==R_MULT||state==R_WRITE||(state==R_FETCH&&state_read_valid)))begin
      if({render_is_loop_q,render_fixed_q,render_lane_q}!==
         {loop_mask[index],(loop_mask[index]||patch_frozen[index]),render_lane})
        $fatal(1,"R20 immutable render metadata changed during read");
    end
    // synthesis translate_on
    wire [3:0] match_lane={tracks[match_slot][1:0],layers[match_slot]};
    reg [N-1:0] loop_mask,patch_frozen;
    // Practice patches are fixed: ordinary live/Looper expression is retained
    // for scene return, but must not alter practice pitch or occupy held tails.
    wire practice_fixed=WITH_PRACTICE && practice_mode;
    wire applied_pedal=!practice_fixed && (render_is_loop_q ? loop_pedal[render_lane_q] : pedal);
    wire applied_sost=!practice_fixed && (render_is_loop_q ? loop_sost[render_lane_q] : sostenuto);
    wire matched_pedal=!practice_fixed && (loop_mask[match_slot] ? loop_pedal[match_lane] : pedal);
    wire matched_sost=!practice_fixed && (loop_mask[match_slot] ? loop_sost[match_lane] : sostenuto);
    reg matched_pedal_q,matched_sost_q;
    
    wire [PATCH_W-1:0] patch_work;wire [PATCH_W-1:0] patch_match=patch_work;
    // One synchronous read and one synchronous write. Invalid slots are masked;
    // each strike writes a complete initial record, so RAM needs no bulk reset.
    wire [350:0] work_data;wire [350:0] match_data=work_data;wire state_read_valid;
    reg mem_write;
    reg [SW-1:0] mem_index;
    reg [350:0] mem_data;
    wire scan_needs_data;
    wire [SW-1:0] read_index=(state==E_READ||state==E_FETCH) ? scan_index : (state==E_REFRESH_READ||state==E_REFRESH_FETCH) ? match_slot : (state==E_LEAD_READ||state==E_LEAD_FETCH) ? lead_slot : index;
    voice_record_ram #(.N(N),.AW(SW)) state_store(.clk(clk),.rst(rst),
      .read_enable((state==E_READ && scan_needs_data)||state==R_READ||state==E_REFRESH_READ||state==E_LEAD_READ),.read_index(read_index),
      .read_valid(state_read_valid),.read_data(work_data),
      .write_enable(mem_write&&!rst&&!music_ce),.write_index(mem_index),.write_data(mem_data));
    wire [6:0] notes[0:N-1];
    reg [N-1:0] pmapped,pmapped_held,pmapped_gated,pmapped_sost;
    integer map_i,reset_i;
    always @* begin
        pmapped=0;pmapped_held=0;pmapped_gated=0;pmapped_sost=0;
        for(map_i=0;map_i<PLUCK_N;map_i=map_i+1)
            if(pbusy[map_i] || pstart[map_i]) begin
                pmapped[powner[map_i]]=1;pmapped_held[powner[map_i]]=pheld[map_i];
                pmapped_gated[powner[map_i]]=pgated[map_i];pmapped_sost[powner[map_i]]=psost[map_i];
            end
    end
    assign occupied=hbusy|pmapped;
    assign sequencer_busy=|(hbusy&loop_mask);
    assign held=hheld|pmapped_held;
    assign gated=hgated|pmapped_gated;
    assign sost_latched=hsost|pmapped_sost;
    reg [N*32-1:0] phases;
    reg [N*16-1:0] envs;
    genvar g;
    generate for(g=0;g<N;g=g+1) begin: observation
        // Parallel diagnostic observers retain exact old reset semantics.
        // Production's unused full token bus is swept before RAM inference.
        assign tokens_snapshot[g*32+:32]=token_written[g] ? tokens[g] : 32'd0;
        assign notes_snapshot[g*7+:7]=notes[g];
        assign presets_snapshot[g*3+:3]=presets[g];
        assign envelopes_snapshot[g*16+:16]=envs[g*16+:16];
    end endgenerate
    reg command_pending,command_off,free_found,match_found,lead_found;
    // Each note owns its ON velocity throughout release; OFF never overwrites it.
    // All integration sites must drive this input explicitly. Never use X/Z
    // detection to invent a hardware default for a missing connection.
    reg [7:0] command_velocity;

    wire [7:0] event_velocity_valid=event_velocity;
    // synthesis translate_off
    always @(posedge clk) if(!rst&&event_valid&&event_ready&&(^event_velocity)===1'bx)
        $fatal(1,"Melodic event_velocity must be explicitly driven");
    // synthesis translate_on
    function [16:0] velocity_q16;
        input [7:0] value;
        begin velocity_q16=({9'd0,value}<<8)+{9'd0,value}+value[7];end
    endfunction
    reg [31:0] command_token,latest_token,latest_step;
    reg [6:0] command_note;
    reg [2:0] command_timbre,command_track;
    reg command_loop;
    reg [1:0] command_layer;reg command_force_release;
    reg [PATCH_W-1:0] command_patch;
    // Allocation scans only immutable owner metadata. All records that can
    // affect commit (matched note or newest glide source) are refreshed below.
    // Avoid N synchronous-record reads merely to choose the newest token.
    assign scan_needs_data=1'b0;

    function [15:0] release_rate;
        input [2:0] r;
        begin case(r) 0:release_rate=96;1:release_rate=48;2:release_rate=24;
            3:release_rate=12;4:release_rate=6;5:release_rate=3;
            6:release_rate=2;default:release_rate=1;endcase end
    endfunction
    wire command_fixed=command_loop||command_patch[135:132]==4'hb;
    wire command_envelope_target=command_timbre==0||command_timbre==4||command_timbre==5;
    wire c_envelope_fixed=command_fixed||command_envelope_target;
    wire c_override=c_envelope_fixed ? command_patch[123] : envelope_override;
    wire c_hold=c_envelope_fixed ? command_patch[124] : custom_hold;
    wire [15:0] c_a=c_envelope_fixed ? command_patch[66:51] : adsr_attack;
    wire [15:0] c_d=c_envelope_fixed ? command_patch[82:67] : adsr_decay;
    wire [15:0] c_s=c_envelope_fixed ? command_patch[98:83] : adsr_sustain;
    wire [15:0] c_r=c_envelope_fixed ? command_patch[114:99] : adsr_release;
    wire [1:0] c_lead_attack=c_envelope_fixed ? command_patch[119:118] : lead_attack_index;
    wire [2:0] c_glide=c_envelope_fixed ? command_patch[122:120] : glide_index;
    wire [15:0] c_release=c_envelope_fixed ? release_rate(command_patch[117:115]) : reference_release;
    wire is_loop_w=loop_mask[index];
    wire render_fixed=render_fixed_q;
    wire [15:0] applied_release=render_fixed ? release_rate(patch_work[117:115]) : reference_release;
    wire [15:0] applied_adsr_release=render_fixed ? patch_work[114:99] : adsr_release;
    wire loop_match=loop_mask[match_slot];
    wire match_fixed=loop_match||patch_frozen[match_slot];
    wire [15:0] match_release=match_fixed ? release_rate(patch_match[117:115]) : reference_release;
    wire [15:0] match_adsr_release=match_fixed ? patch_match[114:99] : adsr_release;
    wire [8:0] render_c0=render_fixed ? patch_work[11:3] : coeff0;
    wire [8:0] render_c1=render_fixed ? patch_work[23:15] : coeff1;
    wire [8:0] render_c2=render_fixed ? patch_work[35:27] : coeff2;
    wire [8:0] render_c3=render_fixed ? patch_work[47:39] : coeff3;
    reg pluck_free_found;
    integer pluck_free_slot,free_i;
    always @* begin
        pluck_free_found=0;pluck_free_slot=0;
        for(free_i=0;free_i<PLUCK_N;free_i=free_i+1)
            if(!pbusy[free_i] && !pstart[free_i] && !pluck_free_found) begin
                pluck_free_found=1;pluck_free_slot=free_i;
            end
    end
    assign event_ready=!rst && !score_active && !music_ce && state==IDLE && !command_pending && !(|pstart);
    reg [31:0] lookup_step;
    wire [31:0] lookup_step_comb,legacy_step,ensemble_step;
    ensemble_notes ensemble_lookup(command_note,ensemble_step);
    assign lookup_step_comb=command_timbre==7 ? ensemble_step : legacy_step;
    reg [9:0] lookup_length;wire [9:0] lookup_length_comb;
    reg [15:0] lookup_fraction;wire [15:0] lookup_fraction_comb;
    reg [24:0] lookup_reciprocal;wire [24:0] lookup_reciprocal_comb;
    note_table note_lookup(command_note,legacy_step);
    pluck_note_table pluck_lookup(command_note,lookup_length_comb,lookup_fraction_comb,lookup_reciprocal_comb);
    // The command is already stable during the allocation scan. Register its
    // tables on E_READ; E_COMMIT timing and final legacy PCM stay unchanged.
    always @(posedge clk) if(state==E_READ) begin
        lookup_step<=lookup_step_comb;lookup_length<=lookup_length_comb;
        lookup_fraction<=lookup_fraction_comb;lookup_reciprocal<=lookup_reciprocal_comb;
    end
    reg [6:0] new_note;
    reg [31:0] new_step;
    reg [9:0] new_length;
    reg [15:0] new_fraction;
    reg [24:0] new_reciprocal;
    reg sostenuto_prev;
    reg [N-1:0] sost_eligible;
    // Preset eligibility is one bit per slot. Immutable pitch/preset use a
    // synchronous10-bit record, with reads hidden in E_READ and T_START.
    (* syn_ramstyle="block_ram" *)reg[9:0] owner_words[0:N-1];
    reg[9:0] owner_q;reg owner_valid_q;reg[2:0] match_preset;reg[6:0] render_note_meta;
    wire[SW-1:0] owner_ra=music_ce?{SW{1'b0}}:state==T_START?(index==N-1?{SW{1'b0}}:index+1'b1):state==E_READ?scan_index:index;
    wire[9:0] owner_read=owner_valid_q?owner_q:{3'd0,7'd60};
    always @(posedge clk)begin
      owner_q<=owner_words[owner_ra];owner_valid_q<=token_written[owner_ra];
      if(!rst&&!music_ce&&state==E_COMMIT&&!command_off&&legal_on)owner_words[free_slot]<={command_timbre,command_note};
      if(rst)begin match_preset<=0;render_note_meta<=60;end
      else begin
        if(!music_ce&&state==E_SCAN&&occupied[scan_index]&&scan_token_q==command_token)match_preset<=owner_read[9:7];
        if(!music_ce&&state==R_READ)render_note_meta<=owner_read[6:0];
      end
    end
    genvar meta;
    generate for(meta=0;meta<N;meta=meta+1)begin: owner_observation
      // Parallel observation ports are swept in the physical top, just like
      // the established token-RAM observer. Reset semantics remain explicit.
      assign notes[meta]=token_written[meta]?owner_words[meta][6:0]:7'd60;
      assign presets[meta]=token_written[meta]?owner_words[meta][9:7]:3'd0;
    end endgenerate
    wire [31:0] phase_w=work_data[260:229];
    wire [31:0] step_w,target_w,delta_w,bent_w;
    wire [16:0] slew_w;
    wire [13:0] glide_w;
    wire [23:0] level_w=work_data[284:261];
    wire [15:0] bright_w=work_data[300:285];
    wire [15:0] attack_w,decay_w,sustain_w,release_w;
    wire [2:0] env_w;
    reg [2:0] preset_w;
    wire [1:0] drain_w;
    wire override_w;
    wire render_envelope_target=preset_w==0||preset_w==4||preset_w==5;
    wire [15:0] deferred_release=render_envelope_target ? release_w : override_w ? applied_adsr_release :
        preset_w==4 ? (applied_release<<3) : applied_release;
    assign {override_w,drain_w,env_w,release_w,sustain_w,decay_w,attack_w,
            glide_w,slew_w,bent_w,delta_w,target_w,step_w}=work_data[228:0];
    reg [48:0] bend_product;
    wire [48:0] bend_next=step_w*slew_w;
    // Select the per-layer target during the existing read cycle. Its RAM/mux
    // must not cascade through two slew comparisons into the state RAM write.
    reg [16:0] bend_target_q,next_slew_q;
    reg [16:0] slew_plus_q,slew_minus_q,slew_current_q,slew_target_q,target_plus_q;
    wire [16:0] bend_target_read=practice_fixed ? 17'd65536 : is_loop_w ? loop_bend[render_lane] :
        (owner_read[9:7]==4||owner_read[9:7]==7||owner_read[9:7]==1) ? lead_bend_factor : bend_factor;
    // R_FETCH spans both RAM words. The low-word slew is stable before
    // read_valid completion, leaving an existing cycle for the adders.
    // Preserve the legacy 17-bit arithmetic, including wrap boundaries.
    always @(posedge clk) if(state==R_FETCH) begin
        slew_plus_q<=slew_w+17'd64;slew_minus_q<=slew_w-17'd64;
        slew_current_q<=slew_w;slew_target_q<=bend_target_q;
        target_plus_q<=bend_target_q+17'd64;
    end
    wire [16:0] slew_next=slew_plus_q<slew_target_q ? slew_plus_q :
        slew_current_q>target_plus_q ? slew_minus_q : slew_target_q;
    wire [31:0] phase_next=phase_w+(preset_w!=3 && slew_w!=65536 ? bent_w : step_w);
    wire [16:0] attack_sum={1'b0,level_w[15:0]}+{1'b0,attack_w};
    wire [16:0] decay_floor={1'b0,sustain_w}+{1'b0,decay_w};
    wire [24:0] natural_attack={1'b0,level_w}+25'd200000;
    wire [24:0] natural_loss={15'd0,level_w[23:14]}+1'b1;
    wire [24:0] natural_release={9'd0,release_w}<<9;
    wire [25:0] natural_total_loss={1'b0,natural_loss}+{1'b0,natural_release};
    reg [23:0] next_level;
    reg [2:0] next_env;
    reg [23:0] next_level_q;
    reg [2:0] next_env_q;
    always @* begin
        next_level=level_w;next_env=env_w;
        if(preset_w==3) case(env_w)
            0:next_level=0;
            1:if(natural_attack>=25'd16777215) begin next_level=24'hffffff;next_env=2;end
              else next_level=natural_attack[23:0];
            2:if(level_w<=natural_loss) begin next_level=0;next_env=0;end
              else next_level=level_w-natural_loss;
            4:if({2'd0,level_w}<=natural_total_loss) begin next_level=0;next_env=0;end
              else next_level=level_w-natural_loss-natural_release;
            default:begin next_level=0;next_env=0;end
        endcase else case(env_w)
            0:next_level=0;
            1:if(attack_sum>=65535) begin next_level=65535;next_env=2;end
              else next_level={8'd0,attack_sum[15:0]};
            2:if({1'b0,level_w[15:0]}<=decay_floor) begin next_level={8'd0,sustain_w};next_env=3;end
              else next_level={8'd0,level_w[15:0]-decay_w};
            3:next_level={8'd0,sustain_w};
            4:if(level_w[15:0]<=release_w) begin next_level=0;next_env=0;end
              else next_level={8'd0,level_w[15:0]-release_w};
            default:begin next_level=0;next_env=0;end
        endcase
        if(hgated[index] && !hheld[index] &&
           (preset_w==3 || !(applied_pedal || (applied_sost && hsost[index])))) begin
            next_env=env_w!=0 && level_w[15:0]>deferred_release ? 3'd4 : 3'd0;
            next_level=env_w!=0 && level_w[15:0]>deferred_release ?
                {8'd0,level_w[15:0]-deferred_release} : 24'd0;
        end
    end
    wire [19:0] ensemble_age=work_data[320:301];wire [19:0] next_ensemble_age;
    wire [15:0] next_accent,next_body,ensemble_body,ensemble_accent;
    wire [2:0] ensemble_stage,ensemble_base_stage;
    wire [4:0] ensemble_shift;wire [15:0] ensemble_floor;
    reg [19:0] ensemble_age_q;reg [15:0] ensemble_body_q,ensemble_accent_q,ensemble_floor_q;
    reg [2:0] ensemble_stage_q;reg [4:0] ensemble_shift_q;
    ensemble_envelope lifecycle(.age(frame_control_tick||ensemble_age==0 ? ensemble_age : ensemble_age-1'b1),.body(level_w[15:0]),.accent(work_data[336:321]),
      .stage(env_w),.held(hheld[index]),.pedal(applied_pedal||(applied_sost&&hsost[index])),.forced(work_data[342]),
      .mode(patch_work[127]),.minimum_index(patch_work[129:128]),.maximum_index(patch_work[131:130]),
      .release_index(patch_work[117:115]),.release_shift(work_data[341:337]),
      .next_age(next_ensemble_age),.next_body(next_body),.next_accent(next_accent),
      .next_stage(ensemble_stage),.next_shift(ensemble_shift),.render_body(ensemble_body),.render_accent(ensemble_accent),
      .protected_level(),.base_stage(ensemble_base_stage));
    ensemble_floor_pipeline floor_pipeline(.clk(clk),.ce(state==R_FETCH&&state_read_valid),
      .age(frame_control_tick||ensemble_age==0 ? ensemble_age : ensemble_age-1'b1),
      .mode(patch_work[127]),.forced(work_data[342]),.minimum_index(patch_work[129:128]),
      .release_index(patch_work[117:115]),.level(ensemble_floor));
    wire [2:0] ensemble_committed_stage=!frame_control_tick ? ensemble_stage_q : ensemble_body_q==0&&ensemble_accent_q==0&&ensemble_floor_q==0 ? 3'd0 : ensemble_stage_q;
    reg tone_ce;

    wire signed [19:0] tone_sample;
    reg [SW-1:0] render_slot;reg [2:0] render_timbre;reg [6:0] render_note;
    reg [8:0] render_coeff0,render_coeff1,render_coeff2,render_coeff3;
    reg [1:0] render_wave_a,render_wave_b,render_style;reg [16:0] render_mix;
    wire [SW+16:0] result_tag;
    reg [SW+1:0] render_pending;
    wire tone_launch=tone_ce;
    wire tone_valid,tone_ready;
    wire ab_valid=tone_valid&&render_timbre==1;
    wire ensemble_valid=tone_valid&&render_timbre==7;
    wire tone_deadline=1'b0;
    reg [31:0] render_phase;
    reg [15:0] render_env,render_bright,render_accent;
    wire [16:0] render_ab_mix=render_fixed ? patch_work[23:7] : ab_mix;
    wire music_add=tone_valid||(state==P_MIX&&pluck_busy_q);
    wire signed [31:0] music_addend=tone_valid ? tone_gain_term : (pluck_gain_q<<<2);
    unified_renderer_backend #(.TAG_W(SW+17)) renderer(
      .clk(clk),.rst(rst),.frame_clear(sample_ce),.score_frame(score_frame),
      .start(tone_ce),.ready(tone_ready),.phase(render_phase),.envelope(render_env),.brightness(render_bright),
      .accent(render_accent),.timbre(render_timbre),.coeff0(render_coeff0),.coeff1(render_coeff1),
      .coeff2(render_coeff2),.coeff3(render_coeff3),.style(render_style),.wave_a(render_wave_a),.wave_b(render_wave_b),
      .mix(render_mix),.note(render_note),.tag({render_slot,track_gain_q}),
      .valid(tone_valid),.sample(tone_sample),.result_tag(result_tag),
      .score_phase(score_phase),.score_envelope(score_env),.score_sine(),.score_product(),
      .score_accumulate(score_accumulate),.music_accumulate(music_add),.music_term(music_addend),
      .accumulator_value(common_sum),.accumulator_next(common_sum_next));
    generate for(g=0;g<PLUCK_N;g=g+1) begin: plucks
        audio_v2_pool_slot #(.PLUCK_ONLY(1)) slot(.clk(clk),.rst(rst),.sample_ce(music_ce),
            .start(pstart[g]),.stop(pstop[g]),.note(new_note),.timbre(3'd2),
            .new_step(new_step),.new_length(new_length),.new_fraction(new_fraction),.new_reciprocal(new_reciprocal),
            .glide_start_step(32'd0),.glide_index(3'd0),.harmonic_sample(20'sd0),.harmonic_valid(1'b0),
            .pedal(pedal),.sostenuto(sostenuto),.reference_release(reference_release),
            .bend_factor(bend_factor),.lead_bend_factor(lead_bend_factor),.lead_attack_index(lead_attack_index),
            .envelope_override(envelope_override),.custom_hold(custom_hold),
            .adsr_attack(adsr_attack),.adsr_decay(adsr_decay),.adsr_sustain(adsr_sustain),.adsr_release(adsr_release),
            .busy(pbusy[g]),.held(pheld[g]),.gated(pgated[g]),.sost_latched(psost[g]),
            .sample(psamples[g*20+:20]),.proc_ce(1'b0),.shared_bend_product(49'd0),
            .math_request(release_request[g]),.math_operand(release_operands[g*34+:34]),
            .math_factor(release_factors[g*26+:26]),.math_grant(release_grants[g]),
            .shared_math_product(release_product),.tone_phase(),.tone_envelope(),.tone_brightness(),
            .tone_note(),.voice_timbre(),.current_step(),.current_slew());
    end
    if(PLUCK_N==0) begin: no_pluck
      assign pbusy=0;assign pheld=0;assign pgated=0;assign psost=0;assign psamples=0;
      assign release_request=0;assign release_operands=0;assign release_factors=0;
    end endgenerate
    // Retained only by equivalence benches; physical top does not consume this.
    reg [N*20-1:0] hsamples;
    wire signed [31:0] sum=common_sum[31:0];
    wire signed [19:0] pluck_term=psamples[index*20+:20];
    wire signed [31:0] pluck_extended={{12{pluck_term[19]}},pluck_term};
    wire [16:0] current_track_raw = loop_mask[index] && tracks[index] < 4 ? track_gains[tracks[index]*17+:17] : 17'd65536;
    wire [16:0] current_track_gain=current_track_raw>65536 ? 17'd65536 : current_track_raw;
    // Track gains are music_ce-smoothed by the production controller and
    // stable throughout this render. Select before the tone multiplier.
    reg [33:0] combined_gain_product_q;
    // One shared 17x17 multiplier, independent of N. Use existing read/fetch/
    // math clocks; tone launch and the seven-clock issue interval do not move.
    // Q16 velocity is exact nearest round(v*65536/255), including255=65536.
    always @(posedge clk) begin
        scan_token_q<=tokens[scan_index];
        if(!rst&&!music_ce&&state==E_COMMIT&&!command_off&&legal_on)
            tokens[free_slot]<=command_token;
    end
    always @(posedge clk) begin
        if(state==R_READ)track_input_q<=current_track_gain;
        if(state==R_FETCH)velocity_input_q<=hbusy[index] ? velocity_q16(work_data[350:343]) : 17'd65536;
        if(state==R_MULT)combined_gain_product_q<=track_input_q*velocity_input_q;
        if(state==R_WRITE)track_gain_q<=combined_gain_product_q[32:16];
    end
    wire signed [37:0] tone_gain_product = $signed(tone_sample) * $signed({1'b0,result_tag[16:0]});
    wire signed [31:0] tone_gain_term = tone_gain_product >>> 16;
    wire [16:0] pluck_track_raw = index < PLUCK_N && ptrack[index] < 4 ?
        track_gains[ptrack[index]*17+:17] : 17'd65536;
    wire [16:0] pluck_track_gain=pluck_track_raw>65536 ? 17'd65536 : pluck_track_raw;
    wire signed [37:0] pluck_gain_product = $signed(pluck_term) * $signed({1'b0,pluck_track_gain});
    wire signed [31:0] pluck_gain_term = pluck_gain_product >>> 16;
    wire signed [31:0] rounded_sum=sum<0 ? -(((-sum)+(32'sd1<<(MIX_SHIFT-1)))>>>MIX_SHIFT) : (sum+(32'sd1<<(MIX_SHIFT-1)))>>>MIX_SHIFT;
    wire [31:0] source_step=command_timbre==4 && c_glide!=0 && lead_found ? latest_step : lookup_step;
    wire signed [32:0] start_difference=$signed({1'b0,lookup_step})-$signed({1'b0,source_step});
    wire sustained_shape=command_timbre==1 || command_timbre==4 || (command_timbre==5 && c_hold);
    wire legal_on_next=free_found && !match_found && command_token!=0 && (command_note>=36 || (command_timbre==7&&command_note>=24)) && command_note<=84 &&
        (command_timbre==1 || command_timbre==0 || command_timbre==2 || command_timbre==3 || command_timbre==4 || command_timbre==5 || command_timbre==7) &&
        (command_timbre!=2 || pluck_free_found) &&
        (command_timbre!=7 || ((command_patch[135:132]==4'ha||command_patch[135:132]==4'hb)&&command_patch[126:125]<=2));
    // Finish table/range/allocation checks before the high-fanout commit CE.
    reg legal_on;
    reg signed [31:0] pluck_gain_q;
    reg pluck_busy_q;
    wire [15:0] start_attack=c_override ? c_a : sustained_shape ?
        (c_lead_attack==0 ? 16'd128 : c_lead_attack==1 ? 16'd256 : c_lead_attack==2 ? 16'd512 : 16'd1024) : 16'd68;
    wire [15:0] start_decay=c_override ? c_d : sustained_shape ? 16'd2 : 16'd6;
    wire [15:0] start_sustain=c_override ? c_s : sustained_shape ? 16'd56000 : 16'd32768;
    wire [31:0] start_delta=start_difference >>> (9+c_glide);
    wire [13:0] start_glide=command_timbre==4 && c_glide!=0 && source_step!=lookup_step ? (14'd1 << (9+c_glide)) : 0;
    // Immutable136-bit patch: four34-bit beats overlap the existing4-beat
    // state fetch. Same musical frame schedule, two physicalRAM instead of4.
    voice_patch_ram #(.N(N),.AW(SW)) patch_store(.clk(clk),.rst(rst),
      .read_enable((state==E_READ&&scan_needs_data)||state==R_READ||state==E_REFRESH_READ||state==E_LEAD_READ),
      .read_index(read_index),.read_valid(),.read_data(patch_work),
      .write_enable(!music_ce&&state==E_COMMIT&&!command_off&&legal_on),.write_index(free_slot),.write_data(command_patch));
    always @* begin
        mem_write=0;mem_index=index;mem_data=work_data;
        if(state==E_COMMIT) begin
            if(!command_off && legal_on && command_timbre!=2) begin
                mem_write=1;mem_index=free_slot;
                mem_data={42'd0,16'd65535,24'd0,32'd0,c_override,2'd0,3'd1,(c_override ? c_r : command_timbre==4 ? c_release<<3 : c_release),start_sustain,start_decay,start_attack,
                    start_glide,17'd65536,source_step,start_delta,lookup_step,source_step};
                mem_data[350:343]=command_velocity;
            end else if(command_off && match_found && command_token!=0 && (match_preset==7||match_preset==1) && command_force_release) begin
                mem_write=1;mem_index=match_slot;mem_data=match_data;mem_data[342]=1;
            end else if(command_off && match_found && command_token!=0 && match_preset!=2 && match_preset!=7 && match_preset!=1 &&
                (command_force_release || match_preset==3 || !(matched_pedal_q || (matched_sost_q && hsost[match_slot])))) begin
                mem_write=1;mem_index=match_slot;mem_data=match_data;
                mem_data[225:223]=match_data[225:223]!=0 ? 3'd4 : 3'd0;
                mem_data[222:207]=(match_preset==0||match_preset==4||match_preset==5) ? match_data[222:207] : match_data[228] ? match_adsr_release :
                    match_preset==4 ? (match_release<<3) : match_release;
            end
        end else if(state==R_WRITE && hbusy[index]) begin
            mem_write=1;
            mem_data[260:229]=phase_next;
            mem_data[300:285]=frame_control_tick && preset_w==3 && bright_w!=0 ? bright_w-((bright_w>>11)+1'b1) : bright_w;
            mem_data[127:96]=bend_product[47:16];
            mem_data[144:128]=next_slew_q;
            if(frame_control_tick && glide_w!=0) begin
                mem_data[158:145]=glide_w-1'b1;mem_data[31:0]=glide_w==1 ? target_w : step_w+delta_w;
            end
            if(frame_control_tick && preset_w!=7 && preset_w!=1 && hgated[index] && !hheld[index] && (preset_w==3 || !(applied_pedal || (applied_sost && hsost[index])))) begin
                // Pedal-up arrives between frames in the original parallel path.
                // Perform that first release sample here, without adding a plateau.
                mem_data[222:207]=deferred_release;
            end
            mem_data[225:223]=next_env_q;mem_data[284:261]=next_level_q;
            if(preset_w==7||preset_w==1) begin
              mem_data[320:301]=ensemble_age_q;mem_data[336:321]=ensemble_accent_q;mem_data[341:337]=ensemble_shift_q;
              mem_data[225:223]=ensemble_committed_stage;mem_data[284:261]={8'd0,ensemble_body_q};
            end
            if(frame_control_tick && preset_w!=7 && preset_w!=1 && !hgated[index] && next_env_q==0) begin
                mem_data[227:226]=drain_w+1'b1;
                if(drain_w==2) begin mem_data[260:229]=0;mem_data[284:261]=0;end
            end
            if(WITH_TF&&loop_pause&&loop_mask[index])begin
                // Pause musical age/envelope/glide while phase keeps moving
                // under the short gain fade. Resume without re-triggering.
                mem_data=work_data;mem_data[260:229]=phase_next;
            end
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;index<=0;scan_index<=0;free_slot<=0;match_slot<=0;match_refreshed<=0;lead_refreshed<=0;lead_slot<=0;

            pstart<=0;pstop<=0;sostenuto_prev<=0;command_pending<=0;
            command_off<=0;command_token<=0;command_note<=60;command_timbre<=0;command_track<=4;command_loop<=0;command_patch<=0;
            command_layer<=0;command_force_release<=0;loop_pedal<=0;loop_sost<=0;
            free_found<=0;match_found<=0;lead_found<=0;latest_token<=0;latest_step<=0;
            new_note<=60;new_step<=0;new_length<=0;new_fraction<=0;new_reciprocal<=0;
            preset_w<=0;bend_product<=0;bend_target_q<=65536;next_slew_q<=65536;
            next_level_q<=0;next_env_q<=0;
            tone_ce<=0;hsamples<=0;accepted<=0;rejected<=0;phases<=0;envs<=0;
            render_phase<=0;render_env<=0;render_accent<=0;render_bright<=65535;render_slot<=0;render_timbre<=0;render_note<=0;render_pending<=0;render_coeff0<=0;render_coeff1<=0;render_coeff2<=0;render_coeff3<=0;render_wave_a<=0;render_wave_b<=0;render_style<=0;render_mix<=0;
            ensemble_age_q<=0;ensemble_body_q<=0;ensemble_accent_q<=0;ensemble_floor_q<=0;ensemble_stage_q<=0;ensemble_shift_q<=0;
            rejected_count<=0;unmatched_off_count<=0;
            out_valid<=0;out_sample<=0;clipped<=0;deadline_missed<=0;
            legal_on<=0;matched_pedal_q<=0;matched_sost_q<=0;pluck_gain_q<=0;pluck_busy_q<=0;

            
            for(reset_i=0;reset_i<PLUCK_N;reset_i=reset_i+1) begin powner[reset_i]<=0;ptrack[reset_i]<=4;end
        end else begin
            pstart<=0;pstop<=0;tone_ce<=0;accepted<=0;rejected<=0;out_valid<=0;clipped<=0;
            sostenuto_prev<=sostenuto;

            if(expression_valid===1'b1) begin
                case(expression_kind)
                    0:loop_pedal[expression_lane]<=expression_value[0];
                    1:begin
                        loop_sost[expression_lane]<=expression_value[0];

                    end
                    2:begin end
                endcase
            end
            if(expression_reset_all===1'b1 || expression_reset_valid===1'b1) begin
                for(reset_i=0;reset_i<16;reset_i=reset_i+1)
                    if(expression_reset_all===1'b1 || (reset_i/4==expression_reset_track &&
                       (expression_reset_whole_track || reset_i%4==expression_reset_layer))) begin
                        loop_pedal[reset_i]<=0;loop_sost[reset_i]<=0;
                    end

            end
            // Only the coordinator emits this while IDLE and mappings drained.
            // State RAM need not be erased: hbusy is its semantic validity.

            case({tone_launch,tone_valid})
                2'b10:render_pending<=render_pending+1'b1;
                2'b01:render_pending<=render_pending-1'b1;
            endcase
            if(tone_valid) begin
                hsamples[result_tag[SW+16:17]*20+:20]<=tone_sample;
            end
            if(tone_deadline) deadline_missed<=1;
            if(state==R_FETCH&&bend_latch)
              bend_target_q<=bend_from_loop_q ? (bend_loop_valid_q ? bend_loop_q : 17'd65536) : bend_live_q;
            if(music_ce) begin
                if((state>=R_READ && state<=FINISH)||state==P_GAIN||state==R_FETCH||state==R_DRAIN) deadline_missed<=1;
                if(command_pending)begin match_refreshed<=0;lead_refreshed<=0;end
                state<=R_READ;index<=0;
            end else case(state)
                IDLE:if(event_valid && event_ready) begin
                    command_pending<=1;command_off<=event_off;command_token<=event_token;
                    command_note<=event_note;command_timbre<=event_timbre;
                    command_track<=event_track;command_loop<=event_is_loop;command_patch<=event_patch;
                    // Resolve and capture at admission, before a multi-cycle allocation
                    // scan can cross a parameter commit. Ordinary target envelopes are
                    // immutable per note, while patch_frozen remains false.
                    if(!event_is_loop && event_patch[135:132]!=4'hb &&
                       (event_timbre==0||event_timbre==4||event_timbre==5))begin
                      if(!(event_patch[135:132]==4'ha && event_patch[123]))begin
                        command_patch[123]<=1;
                        command_patch[124]<=custom_hold;
                        command_patch[119:118]<=lead_attack_index;
                        command_patch[122:120]<=glide_index;
                        command_patch[117:115]<=3'd5;
                        command_patch[66:51]<=envelope_override ? adsr_attack :
                         (event_timbre==4||(event_timbre==5&&custom_hold)) ? (16'd128<<lead_attack_index) : 16'd68;
                        command_patch[82:67]<=envelope_override ? adsr_decay :
                         (event_timbre==4||(event_timbre==5&&custom_hold)) ? 16'd2 : 16'd6;
                        command_patch[98:83]<=envelope_override ? adsr_sustain :
                         (event_timbre==4||(event_timbre==5&&custom_hold)) ? 16'd56000 : 16'd32768;
                        command_patch[114:99]<=envelope_override ? adsr_release : event_timbre==4 ? reference_release<<3 : reference_release;
                      end
                    end
                    command_velocity<=event_velocity_valid;
                    command_layer<=(^event_layer)!==1'bx ? event_layer : 2'd0;
                    command_force_release<=event_force_release===1'b1;
                    scan_index<=0;free_found<=0;match_found<=0;lead_found<=0;latest_token<=0;match_refreshed<=0;lead_refreshed<=0;state<=E_READ;
                end
                E_READ:state<=scan_needs_data ? E_FETCH : E_SCAN;
                E_FETCH:if(state_read_valid) state<=E_SCAN;
                E_SCAN:begin
                    if(!occupied[scan_index] && !free_found && (!WITH_PRACTICE || !practice_mode || scan_index<16)) begin free_found<=1;free_slot<=scan_index;end
                    if(occupied[scan_index] && scan_token_q==command_token) begin match_found<=1;match_slot<=scan_index;end
                    if(command_timbre==4 && c_glide!=0 && hheld[scan_index] && owner_read[9:7]==4 &&
                       (command_loop ? loop_mask[scan_index] && tracks[scan_index]==command_track : !loop_mask[scan_index]) && (!lead_found || scan_token_q>latest_token)) begin
                        lead_found<=1;lead_slot<=scan_index;latest_token<=scan_token_q;latest_step<=step_w;
                    end
                    if(scan_index==N-1) state<=E_CHECK;else begin scan_index<=scan_index+1'b1;state<=E_READ;end
                end
                E_CHECK:begin
                    if(match_found&&!match_refreshed)state<=E_REFRESH_READ;
                    else if(!command_off&&lead_found&&command_timbre==4&&c_glide!=0&&!lead_refreshed)state<=E_LEAD_READ;
                    else begin legal_on<=legal_on_next;
                        matched_pedal_q<=matched_pedal;matched_sost_q<=matched_sost;state<=E_COMMIT;end
                end
                E_REFRESH_READ:state<=E_REFRESH_FETCH;
                E_REFRESH_FETCH:if(state_read_valid)begin
                    match_refreshed<=1;state<=E_CHECK;end
                E_LEAD_READ:state<=E_LEAD_FETCH;
                E_LEAD_FETCH:if(state_read_valid)begin latest_step<=step_w;lead_refreshed<=1;state<=E_CHECK;end
                E_COMMIT:begin
                    command_pending<=0;state<=IDLE;
                    if(command_off) begin
                        if(match_found && command_token!=0) begin
                            if(match_preset==2) begin
                                for(reset_i=0;reset_i<PLUCK_N;reset_i=reset_i+1)
                                    if(pbusy[reset_i] && powner[reset_i]==match_slot) pstop[reset_i]<=1;
                            end else begin

                            end
                            accepted<=1;
                        end else begin unmatched_off_count<=unmatched_off_count+1'b1;accepted<=1;end
                    end else if(legal_on) begin


                        if(command_timbre==2) begin
                            pstart[pluck_free_slot]<=1;powner[pluck_free_slot]<=free_slot;
                            ptrack[pluck_free_slot]<=command_loop ? command_track : 3'd4;
                            new_note<=command_note;new_step<=lookup_step;new_length<=lookup_length;
                            new_fraction<=lookup_fraction;new_reciprocal<=lookup_reciprocal;
                        end else begin

                            phases[free_slot*32+:32]<=0;envs[free_slot*16+:16]<=0;

                        end
                        accepted<=1;
                    end else begin rejected<=1;rejected_count<=rejected_count+1'b1;end
                end
                R_READ:begin
                    preset_w<=owner_read[9:7];
                    
                    state<=R_FETCH;
                end
                R_FETCH:if(state_read_valid) begin
                    state<=R_MULT;
                end
                R_MULT:begin
                    bend_product<=bend_next;next_level_q<=frame_control_tick ? next_level : level_w;next_env_q<=frame_control_tick ? next_env : env_w;
                    next_slew_q<=frame_control_tick ? slew_next : slew_w;
                    ensemble_age_q<=frame_control_tick ? next_ensemble_age : ensemble_age;ensemble_body_q<=frame_control_tick ? next_body : level_w[15:0];ensemble_accent_q<=frame_control_tick ? next_accent : work_data[336:321];
                    ensemble_floor_q<=!frame_control_tick&&ensemble_age==0 ? 0 : ensemble_floor;ensemble_stage_q<=frame_control_tick ? ensemble_base_stage : env_w;ensemble_shift_q<=frame_control_tick ? ensemble_shift : work_data[341:337];
                    state<=R_WRITE;
                end
                R_WRITE:begin
                    render_slot<=index;render_timbre<=preset_w;render_note<=render_note_meta;
                    render_coeff0<=render_c0;render_coeff1<=render_c1;render_coeff2<=render_c2;render_coeff3<=render_c3;
                    render_wave_a<=patch_work[4:3];render_wave_b<=patch_work[6:5];render_style<=patch_work[126:125];render_mix<=render_ab_mix;
                    render_phase<=hbusy[index] ? mem_data[260:229] : 32'd0;
                    render_env<=hbusy[index] ? (preset_w==3 ? mem_data[284:269] : mem_data[276:261]) : 16'd0;
                    if(preset_w==7||preset_w==1) begin
                      render_env<=!hbusy[index] ? 0 : ensemble_body_q>ensemble_floor_q ? ensemble_body_q : ensemble_floor_q;
                      render_accent<=hbusy[index] ? ensemble_accent_q : 0;

                    end
                    render_bright<=hbusy[index] ? mem_data[300:285] : 16'd65535;
                    envs[index*16+:16]<=hbusy[index] ? (preset_w==3 ? mem_data[284:269] : mem_data[276:261]) : 16'd0;
                    phases[index*32+:32]<=hbusy[index] ? mem_data[260:229] : 32'd0;

                    state<=T_START;
                end
                T_START:if(tone_ready&&!tone_ce) begin
                    tone_ce<=1;
                    if(index==N-1)state<=R_DRAIN;
                    else begin index<=index+1'b1;state<=R_READ;end
                end
                T_WAIT:if(ab_valid||ensemble_valid) begin
                    if(index==N-1)state<=R_DRAIN;
                    else begin index<=index+1'b1;state<=R_READ;end
                end
                R_DRAIN:if(render_pending==0&&!tone_ce) begin index<=0;state<=PLUCK_N==0 ? FINISH : P_GAIN;end
                P_GAIN:begin
                    pluck_gain_q<=pluck_gain_term;pluck_busy_q<=pbusy[index];state<=P_MIX;
                end
                P_MIX:begin
                    // Pluck is Q4 while the harmonic accumulator is Q6.
                    // Preserve V2's x4 unit conversion after track gain.
                    // Shared backend accumulates this pluck term (disabled in V9).
                    if(index==PLUCK_N-1) state<=FINISH;else begin index<=index+1'b1;state<=P_GAIN;end
                end
                FINISH:begin
                    if(rounded_sum>((32'sd1<<(OUT_W-1))-1)) begin out_sample<=(32'sd1<<(OUT_W-1))-1;clipped<=1;end
                    else if(rounded_sum< -(32'sd1<<(OUT_W-1))) begin out_sample<=-(32'sd1<<(OUT_W-1));clipped<=1;end
                    else out_sample<=rounded_sum[OUT_W-1:0];
                    out_valid<=1;state<=command_pending ? E_READ : IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end

    // Common operations decoded once; each slot has a constant write address.
    // This avoids merging whole-vector and indexed nonblocking assignments
    // into wide feedback/mask networks. Priority is exactly the former order.
    wire slot_commit=!music_ce&&state==E_COMMIT;
    wire slot_allocate=slot_commit&&!command_off&&legal_on;
    wire slot_release=slot_commit&&command_off&&match_found&&command_token!=0;
    wire slot_render=!music_ce&&state==R_WRITE;
    wire slot_natural_end=(preset_w==7||preset_w==1)&&ensemble_committed_stage==0;
    wire slot_decay_end=frame_control_tick&&preset_w!=7&&preset_w!=1&&next_env_q==0&&drain_w==2;
    wire slot_pedal_release=frame_control_tick&&preset_w!=7&&preset_w!=1&&
      (preset_w==3||!(applied_pedal||(applied_sost&&hsost[index])));
    wire slot_off_gate=match_preset!=7&&match_preset!=1&&
      (command_force_release||match_preset==3||!(matched_pedal_q||(matched_sost_q&&hsost[match_slot])));
    genvar owner;
    generate for(owner=0;owner<N;owner=owner+1)begin: slot_metadata
      wire allocated=slot_allocate&&free_slot==owner;
      wire released=slot_release&&match_slot==owner;
      wire rendered=slot_render&&index==owner&&!(WITH_TF&&loop_pause&&loop_mask[owner]);
      always @(posedge clk)begin
        if(rst)begin
          hbusy[owner]<=0;hheld[owner]<=0;hgated[owner]<=0;hsost[owner]<=0;override_mask[owner]<=0;
          loop_mask[owner]<=0;patch_frozen[owner]<=0;token_written[owner]<=0;
          sost_eligible[owner]<=1;layers[owner]<=0;
        end else begin
          if(!sostenuto)hsost[owner]<=hsost[owner]&loop_mask[owner];
          else if(!sostenuto_prev)hsost[owner]<=(hheld[owner]&hbusy[owner]&sost_eligible[owner]&~loop_mask[owner])|(hsost[owner]&loop_mask[owner]);
          else hsost[owner]<=hsost[owner]&hbusy[owner];
          if(expression_valid===1'b1&&expression_kind==1&&loop_mask[owner]&&
             tracks[owner][1:0]==expression_track&&layers[owner]==expression_layer)begin
            if(!expression_value[0])hsost[owner]<=0;
            else if(!loop_sost[expression_lane])hsost[owner]<=hheld[owner]&hbusy[owner]&sost_eligible[owner];
          end
          if((expression_reset_all===1'b1||expression_reset_valid===1'b1)&&loop_mask[owner]&&
            (expression_reset_all===1'b1||(tracks[owner][1:0]==expression_reset_track&&
              (expression_reset_whole_track||layers[owner]==expression_reset_layer))))hsost[owner]<=0;
          if(WITH_PRACTICE&&(practice_clear_auto||practice_clear_live)&&
             (loop_mask[owner]?practice_clear_auto:practice_clear_live))begin
            hbusy[owner]<=0;hheld[owner]<=0;hgated[owner]<=0;hsost[owner]<=0;
          end
          if(released&&match_preset!=2)begin
            hheld[owner]<=0;if(slot_off_gate)hgated[owner]<=0;
          end
          if(allocated)begin
            token_written[owner]<=1;sost_eligible[owner]<=command_timbre==1||command_timbre==0||command_timbre==4||command_timbre==5||command_timbre==7;
            tracks[owner]<=command_loop?command_track:3'd4;loop_mask[owner]<=command_loop;
            patch_frozen[owner]<=command_patch[135:132]==4'hb;layers[owner]<=command_layer;hsost[owner]<=0;
            if(command_timbre!=2)begin hbusy[owner]<=1;hheld[owner]<=1;hgated[owner]<=1;override_mask[owner]<=c_override;end
          end
          if(rendered)begin
            if(slot_natural_end)begin hbusy[owner]<=0;hgated[owner]<=0;hheld[owner]<=0;end
            if(hbusy[owner])begin
              if(slot_pedal_release&&hgated[owner]&&!hheld[owner])hgated[owner]<=0;
              if(slot_decay_end&&!hgated[owner])begin hbusy[owner]<=0;hheld[owner]<=0;end
            end
          end
        end
      end
    end endgenerate

genvar origin_index;
    generate for(origin_index=0;origin_index<N;origin_index=origin_index+1) begin: origins
        assign origins_snapshot[origin_index*5+:5]={loop_mask[origin_index],tracks[origin_index][1:0],layers[origin_index]};
    end endgenerate
endmodule

// V15:136-bit immutable patch as4x34 bits; overlaps the existing state read.
// Request-edge forwarding preserves read-after-write while physical writes
// drain. The bank never issues overlapping writes (checked by regression).
module voice_patch_ram #(parameter N=32,AW=(N>1?$clog2(N):1))(
 input wire clk,rst,read_enable,input wire [AW-1:0] read_index,
 output reg read_valid,output wire [135:0] read_data,
 input wire write_enable,input wire [AW-1:0] write_index,input wire [135:0] write_data);
 (* syn_ramstyle="block_ram" *) reg [33:0] ram[0:N*4-1];
 reg reading,writing;reg [1:0] phase,write_phase;
 reg [AW-1:0] read_slot,write_slot;
 reg [135:0] read_record,write_record;
 reg [33:0] q;reg forward,forward_new;
 wire[1:0]read_word=read_enable ? 2'd0 : phase+2'd1;
 assign read_data=read_record;
 always @(posedge clk) begin
  q<=ram[{read_enable ? read_index : read_slot,read_word}];
  if(!rst&&writing)case(write_phase)
   0:ram[{write_slot,2'd0}]<=write_record[33:0];
   1:ram[{write_slot,2'd1}]<=write_record[67:34];
   2:ram[{write_slot,2'd2}]<=write_record[101:68];
   3:ram[{write_slot,2'd3}]<=write_record[135:102];
  endcase
 end
 always @(posedge clk) begin
  if(rst) begin reading<=0;writing<=0;phase<=0;write_phase<=0;read_slot<=0;write_slot<=0;
   read_valid<=0;forward<=0;forward_new<=0;end
  else begin
   read_valid<=0;
   if(writing)begin write_phase<=write_phase+1'b1;if(write_phase==3)writing<=0;end
   if(write_enable)begin write_record<=write_data;write_slot<=write_index;write_phase<=0;writing<=1;end
   if(read_enable) begin
    read_slot<=read_index;phase<=0;reading<=1;
    forward<=(write_enable&&write_index==read_index)||(writing&&write_slot==read_index);
    forward_new<=write_enable&&write_index==read_index;
    read_record<=write_record;
   end else if(reading) begin
    phase<=phase+1'b1;
    if(phase==0&&forward_new)read_record<=write_record;
    else if(forward)begin end
    else case(phase)
     0:read_record[33:0]<=q;
     1:read_record[67:34]<=q;
     2:read_record[101:68]<=q;
     3:read_record[135:102]<=q;
    endcase
    if(phase==3)begin reading<=0;read_valid<=1;end
   end
  end
 end
endmodule
