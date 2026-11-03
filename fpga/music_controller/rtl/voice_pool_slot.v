// Local playable-gallery fork; baseline sources remain unchanged.
// One product voice. Harmonic voice keeps the validated clean candidate;
// pluck voice keeps its natural decay and deliberately ignores sustain.
module audio_v2_pool_slot #(parameter PROFILE=6, parameter PLUCK_ONLY=0,
    parameter PLUCK_MIN_SAMPLES=12000,
    parameter PLUCK_QUIET_SAMPLES=4096,
    parameter PLUCK_MAX_SAMPLES=1442308
)(
    input wire clk,rst,sample_ce,start,stop,
    input wire [6:0] note,
    input wire [2:0] timbre,
    input wire [31:0] new_step, input wire [9:0] new_length,
    input wire [15:0] new_fraction, input wire [24:0] new_reciprocal,
    input wire [31:0] glide_start_step,input wire [2:0] glide_index,
    input wire signed [19:0] harmonic_sample, input wire harmonic_valid,
    output wire [31:0] tone_phase, output wire [15:0] tone_envelope, tone_brightness,
    output wire [6:0] tone_note,
    output wire [2:0] voice_timbre,output wire [31:0] current_step,
    input wire pedal,sostenuto,
    input wire [15:0] reference_release,
    input wire [16:0] bend_factor,
    input wire [16:0] lead_bend_factor,
    input wire [1:0] lead_attack_index,
    input wire envelope_override,custom_hold,
    input wire [15:0] adsr_attack,adsr_decay,adsr_sustain,adsr_release,
    output wire busy,held,
    output wire gated,sost_latched,
    output reg signed [19:0] sample, input wire proc_ce,
    input wire [48:0] shared_bend_product, output wire [16:0] current_slew,
    output wire math_request,output wire signed [33:0] math_operand,
    output wire signed [25:0] math_factor,input wire math_grant,
    input wire signed [59:0] shared_math_product
);
    localparam IDLE=0,RESET_VOICE=1,START_VOICE=2,HELD=3,
               SEND_OFF=4,RELEASING=5,DRAIN=6;
    reg [2:0] state;
    reg [6:0] held_note;
    reg [2:0] held_timbre;
    reg key_down,drain_wait;
    reg [20:0] age;
    reg [12:0] quiet_samples;
    reg [15:0] release_step;
    wire voice_rst=rst || state==IDLE || state==RESET_VOICE;
    wire on_cmd=state==START_VOICE && !sample_ce;
    wire off_cmd=state==SEND_OFF && !sample_ce;
    reg [31:0] phase_step;
    reg [31:0] glide_source_step;
    reg [2:0] held_glide_index;
    reg [1:0] held_attack_index;
    reg held_override,held_custom_hold;
    reg [15:0] held_attack,held_decay,held_sustain;
    reg [9:0] length; reg [15:0] fraction; reg [24:0] reciprocal;
    reg signed [15:0] prior_a, prior_b;
    wire signed [18:0] warm_sum = $signed(pluck_sample) + ($signed(prior_a) * 19'sd2) + $signed(prior_b);
    wire signed [15:0] pluck_sample;
    wire pluck_valid,pluck_ready,pluck_active;
    wire [2:0] harmonic_state;
    wire harmonic_active=harmonic_state!=0;
    wire selected_pluck=PLUCK_ONLY!=0;
    wire ready=selected_pluck ? pluck_ready : 1'b1;
    wire active=selected_pluck ? pluck_active : harmonic_active;
    wire valid=selected_pluck ? pluck_valid : harmonic_valid;
    wire signed [15:0] raw=pluck_sample;
    wire signed [15:0] attenuated=raw>>>5;
    reg sostenuto_prev,sostenuto_latched;
    assign busy=state!=IDLE;
    assign held=busy && key_down;
    assign gated=busy && state!=RELEASING && state!=DRAIN;
    assign sost_latched=sostenuto_latched;
    assign tone_note=held_note;
    assign voice_timbre=held_timbre;

    generate if(!PLUCK_ONLY) begin: harmonic_path
    audio_v2_state #(.PROFILE(PROFILE)) harmonic(clk,voice_rst,proc_ce,
        on_cmd,off_cmd,phase_step,glide_source_step,held_glide_index,held_timbre,release_step,
        held_timbre==4 ? lead_bend_factor : bend_factor,held_attack_index,
        held_override,held_custom_hold,held_attack,held_decay,held_sustain,
        tone_phase,tone_envelope,tone_brightness,harmonic_state,current_step,
        shared_bend_product,current_slew);
    assign pluck_sample=0;assign pluck_valid=0;assign pluck_ready=1;assign pluck_active=0;
    end else begin: pluck_path
    assign tone_phase=0;assign tone_envelope=0;assign tone_brightness=0;
    assign harmonic_state=0;assign current_step=0;assign current_slew=65536;
    audio_v2_pluck #(.LOGIC_SCALE(1)) pluck(clk,voice_rst,sample_ce,
        (on_cmd||off_cmd),off_cmd ? 2'd1 : 2'd0,
        held_note,9'd256,32'h12345678,length,fraction,reciprocal,pluck_ready,,pluck_active,
        pluck_sample,pluck_valid,math_request,math_operand,math_factor,
        math_grant,shared_math_product);
    end endgenerate

    always @(posedge clk) begin
        if(rst) begin
            phase_step<=0;glide_source_step<=0;held_glide_index<=0;held_attack_index<=2;
            held_override<=0;held_custom_hold<=0;held_attack<=68;held_decay<=6;held_sustain<=32768;
            length<=0;fraction<=0;reciprocal<=0;prior_a<=0;prior_b<=0;
            state<=IDLE;held_note<=60;held_timbre<=0;key_down<=0;
            sostenuto_prev<=0;sostenuto_latched<=0;
            drain_wait<=0;age<=0;quiet_samples<=0;release_step<=3;sample<=0;
        end else begin
            sostenuto_prev<=sostenuto;
            if(!sostenuto || state==IDLE) sostenuto_latched<=0;
            else if(!sostenuto_prev)
                sostenuto_latched<=busy && key_down && (held_timbre==0 || held_timbre==4 || held_timbre==5);
            if(stop && busy) key_down<=0;
            if(valid && !voice_rst) begin
                if(!selected_pluck) sample<=harmonic_sample;
                else if(held_timbre==2) sample<=warm_sum >>> 3;
                else if(attenuated>511) sample<=20'sd8176;
                else if(attenuated < -512) sample<=-20'sd8192;
                else sample<=$signed({attenuated,4'b0});
                if(selected_pluck) begin prior_b<=prior_a;prior_a<=raw;end
                if(selected_pluck && state==HELD) begin
                    if(age<PLUCK_MAX_SAMPLES) age<=age+1'b1;
                    if(age>=PLUCK_MIN_SAMPLES && raw>-32 && raw<32) begin
                        if(quiet_samples<PLUCK_QUIET_SAMPLES)
                            quiet_samples<=quiet_samples+1'b1;
                    end else quiet_samples<=0;
                end
            end
            case(state)
                IDLE: begin
                    sample<=0;key_down<=0;age<=0;quiet_samples<=0;prior_a<=0;prior_b<=0;
                    if(start) begin
                        held_note<=note;held_timbre<=timbre;key_down<=1;
                        phase_step<=new_step;held_glide_index<=glide_index;
                        held_attack_index<=lead_attack_index;
                        held_override<=envelope_override;held_custom_hold<=custom_hold;
                        held_attack<=adsr_attack;held_decay<=adsr_decay;held_sustain<=adsr_sustain;
                        glide_source_step<=glide_start_step!=0 ? glide_start_step : new_step;
                        length<=new_length;fraction<=new_fraction;reciprocal<=new_reciprocal;
                        state<=RESET_VOICE;
                    end
                end
                RESET_VOICE: state<=START_VOICE;
                START_VOICE: if(on_cmd && ready) state<=HELD;
                HELD: begin
                    if(selected_pluck) begin
                        if(quiet_samples>=PLUCK_QUIET_SAMPLES || age>=PLUCK_MAX_SAMPLES)
                            state<=SEND_OFF;
                    end else if(!key_down &&
                        (held_timbre==3 || !(pedal || (sostenuto && sostenuto_latched)))) begin
                        release_step<=held_override ? adsr_release :
                            held_timbre==4 ? (reference_release<<3) : reference_release;
                        state<=SEND_OFF;
                    end
                end
                SEND_OFF: if(off_cmd && ready) state<=RELEASING;
                RELEASING: if(!active) begin state<=DRAIN;drain_wait<=0;end
                DRAIN: if(sample_ce) begin
                    if(drain_wait) begin state<=IDLE;sample<=0;end
                    else drain_wait<=1;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
