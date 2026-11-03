// One authoritative target state for local, host and coherent fader scans.
module audio_parameter_service #(
    parameter [16:0] DEFAULT_MASTER = 17'd8249,
    parameter [11:0] PICKUP_TOLERANCE = 12'd16
) (
    input wire clk,
    input wire rst,
    input wire sample_ce,input wire patch_locked,
    input wire local_valid,
    output wire local_ready,
    input wire [4:0] local_addr,
    input wire [31:0] local_value,
    input wire host_valid,
    output wire host_ready,
    input wire [4:0] host_addr,
    input wire [31:0] host_value,
    output reg ack_valid,
    output reg ack_source,
    output reg [4:0] ack_addr,
    output reg [31:0] ack_value,
    output reg ack_accepted,
    output reg ack_applied,
    input wire adc_valid,
    output wire adc_ready,
    input wire [11:0] adc_ch0,
    input wire [11:0] adc_ch1,
    input wire [11:0] adc_ch2,
    input wire [11:0] adc_ch3,
    input wire [11:0] adc_ch4,
    output reg adc_overrun,
    output reg [4:0] fader_acquired,
    output reg [1:0] master_owner,
    output reg [16:0] master_volume_target,
    output reg [2:0] selected_preset,
    output reg [1:0] wave_a,wave_b,output reg [11:0] raw_blend,
    output reg [1:0] ensemble_style,ensemble_minimum,ensemble_maximum,output reg ensemble_mode,
    output reg [6:0] zone_left,
    output reg [6:0] zone_right,
    output reg ordinary_sustain,
    output reg selective_sustain,
    output reg [2:0] release_index,
    output reg [2:0] glide_index,
    output reg signed [4:0] bend_index,
    output reg [1:0] lead_attack_index,
    output wire [15:0] adsr_attack,
    output wire [15:0] adsr_decay,
    output wire [15:0] adsr_sustain,
    output wire [15:0] adsr_release,
    output wire envelope_override,
    input wire [2:0] envelope_query_preset,
    input wire envelope_context_locked,
    output wire [63:0] envelope_query,output wire [3:0] envelope_edited,
    output reg [7:0] envelope_epoch,
    output reg custom_hold,
    output reg [6:0] vibrato_depth,
    output reg [2:0] vibrato_speed,
    output reg effect_enable,
    output reg [7:0] effect_mix,
    output reg [11:0] raw_ch1,
    output reg [11:0] raw_ch2,
    output reg [11:0] raw_ch3,
    output reg [11:0] raw_ch4,
    output reg harmonic_snapshot_valid,
    input wire harmonic_snapshot_ready,
    output reg [11:0] harmonic_snapshot_ch1,
    output reg [11:0] harmonic_snapshot_ch2,
    output reg [11:0] harmonic_snapshot_ch3,
    output reg [11:0] harmonic_snapshot_ch4,
    output reg panic_pulse,
    output reg params_updated,
    output reg [31:0] parameter_revision
);
    wire commit_cfg;
    reg request_legal;
    reg [4:0] pending_addr;
    // Address29: epoch[31:24], public timbre[23:20], item[19:18],
    // operation[17:16] (SET/RESET_ITEM/RESET_ALL/STEP), value[15:0].
    // STEP uses +1 / -1; the service computes from the last committed value.
    wire envelope_locked=patch_locked===1'b1 || envelope_context_locked===1'b1;
    reg previous_envelope_lock;
    wire env_legacy=pending_addr>=11 && pending_addr<=14;
    wire env_release=pending_addr==7 && envelope_override;
    wire env_attack=pending_addr==10 && envelope_override;
    wire env_disable=pending_addr==24 && !pending_value[0];
    wire [1:0] env_item=env_legacy ? pending_addr-11 : env_release ? 2'd3 : env_attack ? 2'd0 : pending_value[19:18];
    wire [1:0] env_op=env_legacy||env_release||env_attack ? 2'd0 : env_disable ? 2'd2 : pending_value[17:16];
    function [15:0] legacy_release;input[2:0] r;begin case(r)
     0:legacy_release=96;1:legacy_release=48;2:legacy_release=24;3:legacy_release=12;
     4:legacy_release=6;5:legacy_release=3;6:legacy_release=2;default:legacy_release=1;
    endcase end endfunction
    wire [15:0] env_value=env_release ? (selected_preset==4 ? legacy_release(pending_value[2:0])<<3 : legacy_release(pending_value[2:0])) :
     env_attack ? (16'd128<<pending_value[1:0]) : env_disable ? 16'd0 : pending_value[15:0];
    wire env_legal;
    wire env_write=pending_addr==29||env_legacy||env_release||env_attack||env_disable;
    timbre_envelope_parameters envelope_settings(
     .clk(clk),.rst(rst),.reset_all(commit_cfg&&request_legal&&pending_addr==31),
     .selected_preset(selected_preset),.query_preset(envelope_query_preset),
     .custom_hold(custom_hold),.lead_attack_index(lead_attack_index),.release_index(release_index),
     .commit(commit_cfg&&request_legal&&env_write),.item(env_item),.operation(env_op),.value(env_value),
     .supported(envelope_override),.edited(envelope_edited),
     .selected_adsr({adsr_release,adsr_sustain,adsr_decay,adsr_attack}),.query_adsr(envelope_query),.operation_legal(env_legal));
    always @(posedge clk)begin
     if(rst)begin envelope_epoch<=0;previous_envelope_lock<=0;end
     else begin
      previous_envelope_lock<=envelope_locked;
      if(previous_envelope_lock!=envelope_locked || (commit_cfg&&request_legal&&(pending_addr==0||pending_addr==31)))
       envelope_epoch<=envelope_epoch+1'b1;
     end
    end
    reg pending_cfg;
    reg pending_source;
    reg [31:0] pending_value;
    reg prefer_host;
    reg pending_adc;
    reg [11:0] scan [0:4];
    reg [11:0] previous_scan [0:4];
    reg have_scan_history;
    reg prefer_adc;
    wire harmonic_changed;

    wire source_choice = local_valid && host_valid ? prefer_host : host_valid;
    assign local_ready = !rst && !pending_cfg && !source_choice;
    assign host_ready = !rst && !pending_cfg && source_choice;
    assign adc_ready = !rst && !pending_adc;
    wire bundle_free = !harmonic_snapshot_valid || harmonic_snapshot_ready;
    wire cfg_needs_bundle = (pending_addr >= 5'd20 && pending_addr <= 5'd23) ||
                            pending_addr == 5'd31 || (pending_addr==28 && pending_value==32'h40000001);
    // Only these commands can require the harmonic snapshot slot. Other
    // command legality must not enter CFG/ADC arbitration or master gain.
    reg cfg_bundle_legal;
    always @*begin
        cfg_bundle_legal=0;
        case(pending_addr)
          20,21,22,23:cfg_bundle_legal=pending_value<=4095;
          31:cfg_bundle_legal=pending_value==1;
          28:cfg_bundle_legal=pending_value==32'h40000001 && selected_preset==5;
          default:cfg_bundle_legal=0;
        endcase
        if(patch_locked===1'b1)cfg_bundle_legal=0;
    end
    wire cfg_can_commit = pending_cfg &&
        (!cfg_bundle_legal || !cfg_needs_bundle || bundle_free);
    wire adc_can_commit = pending_adc && adc_eval_valid &&
        ((patch_locked===1'b1)==adc_eval_locked) && (!harmonic_changed || bundle_free);
    assign commit_cfg = sample_ce && cfg_can_commit &&
                      (!adc_can_commit || !prefer_adc);
    wire commit_adc = sample_ce && adc_can_commit &&
                      (!cfg_can_commit || prefer_adc);

    function legal_zone;
        input [31:0] value;
        begin
            legal_zone = value == 32'd24 || value == 32'd36 || value == 32'd48 ||
                         value == 32'd60 || value == 32'd72;
        end
    endfunction

    always @* begin
        request_legal = 1'b0;
        case (pending_addr)
            5'd0: request_legal = pending_value == 0 ||
                                     pending_value == 3 || pending_value == 4 ||
                                     pending_value == 5 || (pending_value>=7 && pending_value<=10);
            5'd1: request_legal = pending_value <= 32'd65536;
            5'd2: request_legal = $signed(pending_value) >= -32'sd65536 &&
                                   $signed(pending_value) <= 32'sd65536;
            5'd3: request_legal = legal_zone(pending_value) && pending_value >= (selected_preset==7 ? 24 : 36) && pending_value+12 <= zone_right;
            5'd4: request_legal = legal_zone(pending_value) && pending_value >= zone_left+12;
            5'd5,5'd6,5'd15,5'd24: request_legal = pending_value <= 1;
            5'd7,5'd17: request_legal = pending_value <= 7;
            5'd8: request_legal = pending_value <= 4;
            5'd9: request_legal = $signed(pending_value) >= -32'sd8 &&
                                   $signed(pending_value) <= 32'sd8;
            5'd10: request_legal = pending_value <= 3;
            5'd11,5'd12,5'd14: request_legal = pending_value >= 1 &&
                                             pending_value <= 32'd65535;
            5'd13: request_legal = pending_value <= 32'd65535;
            5'd16: request_legal = pending_value <= 64;
            5'd18: request_legal = pending_value<=1;
            5'd19: request_legal = pending_value<=128;
            5'd29: request_legal = !envelope_locked && pending_value[31:24]==envelope_epoch &&
                pending_value[23:20]=={1'b0,selected_preset} && env_legal;
            5'd20,5'd21,5'd22,5'd23: request_legal = pending_value <= 4095;
            5'd28: request_legal = pending_value[31:28]<=1 ? (selected_preset==1 && pending_value[27:0]<=3) :
                pending_value[31:28]==2 ? (selected_preset==1 && pending_value[27:0]<=4095) :
                pending_value==32'h30000001 ? selected_preset==1 : pending_value==32'h40000001 && selected_preset==5;
            5'd25: request_legal=pending_value<=1;
            5'd26,5'd27: request_legal=pending_value<=3;
            5'd30,5'd31: request_legal = pending_value == 1;
            default: request_legal = 1'b0;
        endcase
        if(env_legacy && (!envelope_override||envelope_locked)) request_legal=0;
        if(env_write && envelope_locked) request_legal=0;
        if(pending_addr==24 && (!envelope_override||envelope_locked)) request_legal=0;
        if(patch_locked===1'b1) case(pending_addr)
          0,7,8,10,11,12,13,14,15,17,20,21,22,23,24,25,26,27,28,29,31:request_legal=0;
          default:begin end
        endcase
    end

    wire signed [32:0] volume_sum =
        $signed({16'd0, master_volume_target}) +
        $signed({pending_value[31], pending_value});
    wire [16:0] relative_volume = volume_sum < 0 ? 17'd0 :
        volume_sum > 33'sd65536 ? 17'd65536 : volume_sum[16:0];
    wire [16:0] rounded_master = master_volume_target + 17'd8;
    wire [11:0] master_pickup_target = rounded_master >= 17'd65520 ?
        12'd4095 : rounded_master[15:4];

    function channel_pickup;
        input acquired;
        input [11:0] position;
        input [11:0] previous;
        input [11:0] target;
        input history;
        reg signed [12:0] signed_distance;
        reg [8:0] p_next_group,t_next_group;
        reg near_target;
        begin
            // A single signed subtraction avoids two subtractors and a mux
            // feeding the global sample-boundary commit arbitration.
            signed_distance = $signed({1'b0,position}) - $signed({1'b0,target});
            // Exact |position-target|<=16: same 16-code group, or adjacent
            // groups whose low nibbles overlap within the inclusive boundary.
            // Nine-bit increments prevent wrap at 0/4095. This removes a
            // subtract-then-two-compare carry chain from sample commit CE.
            p_next_group={1'b0,position[11:4]}+9'd1;
            t_next_group={1'b0,target[11:4]}+9'd1;
            if(PICKUP_TOLERANCE==16)
                near_target=(position[11:4]==target[11:4]) ||
                  ({1'b0,position[11:4]}==t_next_group && position[3:0]<=target[3:0]) ||
                  ({1'b0,target[11:4]}==p_next_group && target[3:0]<=position[3:0]);
            else near_target=(signed_distance >= -$signed({1'b0,PICKUP_TOLERANCE}) &&
                 signed_distance <= $signed({1'b0,PICKUP_TOLERANCE}));
            channel_pickup = acquired || near_target ||
                (history && ((previous <= target && position >= target) ||
                             (previous >= target && position <= target)));
        end
    endfunction

    function [16:0] volume_from_adc;
        input [11:0] position;
        begin
            volume_from_adc = position == 12'd4095 ? 17'd65536 :
                {1'b0,position,4'b0000} + {13'd0,position[11:8]};
        end
    endfunction

    wire acquire_master_calc = scan[0] == 0 ||
        channel_pickup(fader_acquired[0],scan[0],previous_scan[0],
                       master_pickup_target,have_scan_history);
    // Known registered preset chooses the result, never a 12-bit target
    // before the pickup comparators. Harmonic commit never needs the A/B target.
    wire acquire1_harmonic_calc = channel_pickup(fader_acquired[1],scan[1],previous_scan[1],
                                  raw_ch1,have_scan_history);
    wire acquire1_blend_calc = channel_pickup(fader_acquired[1],scan[1],previous_scan[1],
                                  raw_blend,have_scan_history);
    wire acquire1_calc = selected_preset==1 ? acquire1_blend_calc : acquire1_harmonic_calc;
    wire acquire2_calc = channel_pickup(fader_acquired[2],scan[2],previous_scan[2],
                                  raw_ch2,have_scan_history);
    wire acquire3_calc = channel_pickup(fader_acquired[3],scan[3],previous_scan[3],
                                  raw_ch3,have_scan_history);
    wire acquire4_calc = channel_pickup(fader_acquired[4],scan[4],previous_scan[4],
                                  raw_ch4,have_scan_history);
    wire custom_editable=selected_preset==5 && !(patch_locked===1'b1);
    wire [11:0] next_raw1_calc = custom_editable && acquire1_harmonic_calc ? scan[1] : raw_ch1;
    wire [11:0] next_raw2_calc = custom_editable && acquire2_calc ? scan[2] : raw_ch2;
    wire [11:0] next_raw3_calc = custom_editable && acquire3_calc ? scan[3] : raw_ch3;
    wire [11:0] next_raw4_calc = custom_editable && acquire4_calc ? scan[4] : raw_ch4;
    // Boolean equality before selection avoids four 12-bit mux -> compare paths.
    // Exactly the same predicate as next_raw != raw, in the same cycle.
    wire harmonic_changed_calc = custom_editable &&
        ((acquire1_harmonic_calc && scan[1] != raw_ch1) || (acquire2_calc && scan[2] != raw_ch2) ||
         (acquire3_calc && scan[3] != raw_ch3) || (acquire4_calc && scan[4] != raw_ch4));
    wire [16:0] next_master_calc = acquire_master_calc ? volume_from_adc(scan[0]) :
                                             master_volume_target;
    wire ab_editable=selected_preset==1 && !(patch_locked===1'b1);
    wire blend_changed_calc=ab_editable && acquire1_blend_calc && scan[1]!=raw_blend;
    wire fader_changed_calc = next_master_calc != master_volume_target || harmonic_changed_calc || blend_changed_calc;
    // Evaluation is valid only for a complete, unchanged scan/target epoch.
    // A CFG commit invalidates it; current lock is checked again at commit.
    reg adc_eval_valid,adc_eval_locked;
    reg [5:0] acquire_q;
    reg harmonic_changed_q,blend_changed_q,fader_changed_q;
    reg [16:0] next_master_q;reg [47:0] next_raw_q;
    always @(posedge clk)begin
        if(rst)begin adc_eval_valid<=0;adc_eval_locked<=0;end
        else begin
            adc_eval_valid<=pending_adc&&!commit_cfg&&!commit_adc;
            adc_eval_locked<=(patch_locked===1'b1);
        end
        acquire_q<={acquire1_blend_calc,acquire4_calc,acquire3_calc,acquire2_calc,acquire1_harmonic_calc,acquire_master_calc};
        harmonic_changed_q<=harmonic_changed_calc;blend_changed_q<=blend_changed_calc;fader_changed_q<=fader_changed_calc;
        next_master_q<=next_master_calc;next_raw_q<={next_raw4_calc,next_raw3_calc,next_raw2_calc,next_raw1_calc};
    end
    wire acquire_master=acquire_q[0],acquire1_harmonic=acquire_q[1],acquire1_blend=acquire_q[5];
    wire acquire1=selected_preset==1 ? acquire1_blend : acquire1_harmonic;
    wire acquire2=acquire_q[2],acquire3=acquire_q[3],acquire4=acquire_q[4];
    wire [11:0] next_raw1=next_raw_q[11:0],next_raw2=next_raw_q[23:12],next_raw3=next_raw_q[35:24],next_raw4=next_raw_q[47:36];
    wire [16:0] next_master=next_master_q;
    assign harmonic_changed=harmonic_changed_q;
    wire blend_changed=blend_changed_q,fader_changed=fader_changed_q;
    // CFG/ADC commits are mutually exclusive. Give the master register an
    // explicit one-hot data network instead of CFG-case + ADC priority muxes.
    // No added state, sample, handshake cycle, curve or owner change.
    wire master_abs_write=commit_cfg&&pending_addr==1&&pending_value<=65536;
    wire master_rel_write=commit_cfg&&pending_addr==2&&$signed(pending_value)>=-65536&&$signed(pending_value)<=65536;
    wire master_reset_write=commit_cfg&&pending_addr==31&&pending_value==1&&!(patch_locked===1'b1);
    wire master_adc_write=commit_adc&&acquire_master;
    wire master_write=master_abs_write||master_rel_write||master_reset_write||master_adc_write;
    wire [16:0] master_data=({17{master_abs_write}}&pending_value[16:0]) |
        ({17{master_rel_write}}&relative_volume) |
        ({17{master_reset_write}}&DEFAULT_MASTER) |
        ({17{master_adc_write}}&next_master);
    always @(posedge clk)begin
        if(rst)master_volume_target<=DEFAULT_MASTER;
        else if(master_write)master_volume_target<=master_data;
    end
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            pending_cfg <= 0;
            pending_source <= 0;
            pending_addr <= 0;
            pending_value <= 0;
            prefer_host <= 0;
            pending_adc <= 0;
            prefer_adc <= 0;
            have_scan_history <= 0;
            for (i=0;i<5;i=i+1) begin scan[i] <= 0; previous_scan[i] <= 0; end
            ack_valid <= 0;
            ack_source <= 0;
            ack_addr <= 0;
            ack_value <= 0;
            ack_accepted <= 0;
            ack_applied <= 0;
            adc_overrun <= 0;
            fader_acquired <= 0;
            master_owner <= 0;
            selected_preset <= 0;wave_a<=1;wave_b<=2;raw_blend<=2048;ensemble_style<=0;ensemble_mode<=0;ensemble_minimum<=1;ensemble_maximum<=1;
            zone_left <= 48;
            zone_right <= 60;
            ordinary_sustain <= 0;
            selective_sustain <= 0;
            release_index <= 5;
            glide_index <= 0;
            bend_index <= 0;
            lead_attack_index <= 2;
            custom_hold <= 0;
            vibrato_depth <= 0;
            vibrato_speed <= 0;
            effect_enable <= 0;
            effect_mix <= 64;
            raw_ch1 <= 4095;
            raw_ch2 <= 1024;
            raw_ch3 <= 512;
            raw_ch4 <= 256;
            harmonic_snapshot_valid <= 1;
            harmonic_snapshot_ch1 <= 4095;
            harmonic_snapshot_ch2 <= 1024;
            harmonic_snapshot_ch3 <= 512;
            harmonic_snapshot_ch4 <= 256;
            panic_pulse <= 0;
            params_updated <= 0;
            parameter_revision <= 0;
        end else begin
            ack_valid <= 0;
            panic_pulse <= 0;
            params_updated <= 0;
            if (harmonic_snapshot_valid && harmonic_snapshot_ready)
                harmonic_snapshot_valid <= 0;
            if (!pending_cfg && (local_valid || host_valid)) begin
                pending_cfg <= 1;
                pending_source <= source_choice;
                pending_addr <= source_choice ? host_addr : local_addr;
                pending_value <= source_choice ? host_value : local_value;
                prefer_host <= !source_choice;
            end
            if (adc_valid) begin
                if (adc_ready) begin
                    pending_adc <= 1;
                    scan[0] <= adc_ch0;
                    scan[1] <= adc_ch1;
                    scan[2] <= adc_ch2;
                    scan[3] <= adc_ch3;
                    scan[4] <= adc_ch4;
                end else adc_overrun <= 1;
            end
            if (commit_cfg) begin
                pending_cfg <= 0;
                prefer_adc <= 1;
                ack_valid <= 1;
                ack_source <= pending_source;
                ack_addr <= pending_addr;
                ack_value <= pending_addr == 2 ? {15'd0,relative_volume} : pending_value;
                ack_accepted <= request_legal;
                ack_applied <= request_legal;
                if (request_legal) begin
                    params_updated <= 1;
                    parameter_revision <= parameter_revision + 1'b1;
                    case (pending_addr)
                        5'd0: begin
                            selected_preset <= pending_value==10 ? 3'd1 : pending_value>=7 ? 3'd7 : pending_value[2:0];
                            if(pending_value<7 || pending_value==10) begin if(zone_left<36) begin zone_left<=36;if(zone_right<48) zone_right<=48;end end
                            if(pending_value>=7 && pending_value<=9) begin ensemble_style<=pending_value-7;ensemble_mode<=pending_value==8;end
                            if(pending_value==10) ensemble_mode<=1;
                            if ((pending_value == 5 && selected_preset != 5) || (pending_value==10 && selected_preset!=1) || (selected_preset==1 && pending_value!=10))
                                fader_acquired[4:1] <= 0;
                        end
                        5'd1,5'd2: begin
                            master_owner <= pending_source ? 2'd2 : 2'd1;
                            fader_acquired[0] <= 0;
                        end
                        5'd3: zone_left <= pending_value[6:0];
                        5'd4: zone_right <= pending_value[6:0];
                        5'd5: ordinary_sustain <= pending_value[0];
                        5'd6: selective_sustain <= pending_value[0];
                        5'd7: if(!envelope_override) release_index <= pending_value[2:0];
                        5'd8: glide_index <= pending_value[2:0];
                        5'd9: bend_index <= pending_value[4:0];
                        5'd10: if(!envelope_override) lead_attack_index <= pending_value[1:0];
                        5'd11,5'd12,5'd13,5'd14,5'd29:begin end // envelope_settings owns these writes
                        5'd15: custom_hold <= pending_value[0];
                        5'd16: vibrato_depth <= pending_value[6:0];
                        5'd17: vibrato_speed <= pending_value[2:0];
                        5'd18: effect_enable <= pending_value[0];
                        5'd19: effect_mix <= pending_value[7:0];
                        5'd20,5'd21,5'd22,5'd23: begin
                            case (pending_addr)
                                5'd20: begin raw_ch1 <= pending_value[11:0]; fader_acquired[1] <= 0; end
                                5'd21: begin raw_ch2 <= pending_value[11:0]; fader_acquired[2] <= 0; end
                                5'd22: begin raw_ch3 <= pending_value[11:0]; fader_acquired[3] <= 0; end
                                5'd23: begin raw_ch4 <= pending_value[11:0]; fader_acquired[4] <= 0; end
                            endcase
                            harmonic_snapshot_valid <= 1;
                            harmonic_snapshot_ch1 <= pending_addr == 20 ? pending_value[11:0] : raw_ch1;
                            harmonic_snapshot_ch2 <= pending_addr == 21 ? pending_value[11:0] : raw_ch2;
                            harmonic_snapshot_ch3 <= pending_addr == 22 ? pending_value[11:0] : raw_ch3;
                            harmonic_snapshot_ch4 <= pending_addr == 23 ? pending_value[11:0] : raw_ch4;
                        end
                        5'd28:case(pending_value[31:28])
                            0:wave_a<=pending_value[1:0];
                            1:wave_b<=pending_value[1:0];
                            2:begin raw_blend<=pending_value[11:0];fader_acquired[1]<=0;end
                            3:begin wave_a<=1;wave_b<=2;raw_blend<=2048;ensemble_mode<=1;ensemble_minimum<=1;ensemble_maximum<=1;fader_acquired[1]<=0;end
                            4:begin raw_ch1<=4095;raw_ch2<=1024;raw_ch3<=512;raw_ch4<=256;fader_acquired[4:1]<=0;
                             harmonic_snapshot_valid<=1;harmonic_snapshot_ch1<=4095;harmonic_snapshot_ch2<=1024;harmonic_snapshot_ch3<=512;harmonic_snapshot_ch4<=256;end
                            default:begin end
                        endcase
                        5'd25:ensemble_mode<=pending_value[0];
                        5'd26:ensemble_minimum<=pending_value[1:0];
                        5'd27:ensemble_maximum<=pending_value[1:0];
                        5'd24:begin end // disabled override resets this timbre only
                        5'd30: begin
                            panic_pulse <= 1;
                            ordinary_sustain <= 0;
                            selective_sustain <= 0;
                            bend_index <= 0;
                        end
                        5'd31: begin
                                            master_owner <= 0;
                            selected_preset <= 0;wave_a<=1;wave_b<=2;raw_blend<=2048;ensemble_style<=0;ensemble_mode<=0;ensemble_minimum<=1;ensemble_maximum<=1;
                            zone_left <= 48;
                            zone_right <= 60;
                            ordinary_sustain <= 0;
                            selective_sustain <= 0;
                            release_index <= 5;
                            glide_index <= 0;
                            bend_index <= 0;
                            lead_attack_index <= 2;
                            custom_hold <= 0;
                            vibrato_depth <= 0;
                            vibrato_speed <= 0;
                            effect_enable <= 0;
                            effect_mix <= 64;
                            raw_ch1 <= 4095;
                            raw_ch2 <= 1024;
                            raw_ch3 <= 512;
                            raw_ch4 <= 256;
                            fader_acquired <= 0;
                            have_scan_history <= 0;
                            harmonic_snapshot_valid <= 1;
                            harmonic_snapshot_ch1 <= 4095;
                            harmonic_snapshot_ch2 <= 1024;
                            harmonic_snapshot_ch3 <= 512;
                            harmonic_snapshot_ch4 <= 256;
                        end
                    endcase
                end
            end
            // commit_cfg and commit_adc are mutually exclusive by arbitration.
            // Independent enables remove an unnecessary global CFG priority
            // mux from the coherent ADC payload path; no added state or cycle.
            if (commit_adc) begin
                pending_adc <= 0;
                prefer_adc <= 0;
                have_scan_history <= 1;
                for (i=0;i<5;i=i+1) previous_scan[i] <= scan[i];
                fader_acquired[0] <= acquire_master;
                if(ab_editable) begin fader_acquired[1]<=acquire1;if(acquire1) raw_blend<=scan[1];end
                if (selected_preset == 5) begin
                    fader_acquired[1] <= acquire1;
                    fader_acquired[2] <= acquire2;
                    fader_acquired[3] <= acquire3;
                    fader_acquired[4] <= acquire4;
                end
                if (acquire_master) master_owner <= 3;
                if (fader_changed) begin
                    params_updated <= 1;
                    parameter_revision <= parameter_revision + 1'b1;
                end
                if (harmonic_changed) begin
                    raw_ch1 <= next_raw1;
                    raw_ch2 <= next_raw2;
                    raw_ch3 <= next_raw3;
                    raw_ch4 <= next_raw4;
                    harmonic_snapshot_valid <= 1;
                    harmonic_snapshot_ch1 <= next_raw1;
                    harmonic_snapshot_ch2 <= next_raw2;
                    harmonic_snapshot_ch3 <= next_raw3;
                    harmonic_snapshot_ch4 <= next_raw4;
                end
            end
        end
    end
endmodule
