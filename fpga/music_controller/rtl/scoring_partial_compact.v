// COMPACT EXPERIMENT: every partial still owns phase/frequency/env/target;
// attack/release slopes are global parameters latched only at frame start.
// One independent phase/frequency/envelope record per partial, one issue per clock.
// Configuration and rendering are mutually exclusive. All configuration accepted
// before sample_ce is reflected in that frame; busy sample_ce is rejected, never
// restarts the scan. Unsaturated raw sine16 * unsigned envelope16 accumulation.
module scoring_partial_compact #(
    parameter N = 512,SHARED_MEMORY=0,
    parameter AW = (N > 1 ? $clog2(N) : 1),
    parameter CW = $clog2(N + 1),
    parameter ACC_W = 48
)(
    input wire clk, rst, sample_ce,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [AW-1:0] cfg_index,
    input wire cfg_retrigger,
    input wire [31:0] cfg_phase, cfg_freq,
    input wire [15:0] cfg_env, cfg_target,
    input wire [15:0] global_attack, global_release,
    output reg init_done, busy, frame_valid,
    output reg signed [ACC_W-1:0] sample_sum,
    output reg [CW-1:0] active_count,
    output reg [15:0] render_cycles,
    output reg deadline_miss,
    output wire [31:0] backend_phase,output wire [15:0] backend_env,
    input wire signed [47:0] backend_sum_next,
    output wire backend_accumulate,
 input wire shared_score_owner,
 output wire shared_score_read,output wire[8:0]shared_score_ra,
 input wire[47:0]shared_score_state,shared_score_control,
 output wire shared_score_state_we,output wire[8:0]shared_score_state_wa,output wire[47:0]shared_score_state_wd,
 output wire shared_score_control_we,output wire[8:0]shared_score_control_wa,output wire[47:0]shared_score_control_wd,
 output wire shared_score_ready
);
    // phase_env = {phase32, envelope16}; control = {freq32,target16}; slopes are frame-latched globals.
    // Reset uses one memory write per clock instead of resetting every RAM bit.

    reg [AW-1:0] clear_index, issue_index;
    reg issuing;
    wire [47:0] state_q;
    wire [47:0] control_q;
    reg [15:0] frame_attack, frame_release;
    reg q_valid, q_last;
    reg [AW-1:0] q_index;

    assign cfg_ready = memory_enabled && init_done && !busy && !sample_ce;
    wire cfg_accept = cfg_valid && cfg_ready && (cfg_index < N);

    wire [31:0] next_phase = state_q[47:16] + control_q[47:16];
    wire [15:0] current_env = state_q[15:0];
    wire [15:0] target_env = control_q[15:0];
    wire [15:0] attack_step = frame_attack;
    wire [15:0] release_step = frame_release;
    wire [16:0] attack_sum = {1'b0,current_env} + {1'b0,attack_step};
    wire [16:0] release_limit = {1'b0,target_env} + {1'b0,release_step};
    // Zero slew means immediate arrival. Nonzero slew clamps at target and cannot
    // wrap at 65535, underflow at zero, or leave a decaying partial permanently on.
    wire [15:0] next_env = current_env < target_env ?
        ((attack_step == 0 || attack_sum >= {1'b0,target_env}) ? target_env : attack_sum[15:0]) :
        current_env > target_env ?
        ((release_step == 0 || {1'b0,current_env} <= release_limit) ? target_env : current_env-release_step) : current_env;

    reg p_valid, p_last, p_active;
    reg [31:0] p_phase;
    reg [15:0] p_env;
    assign backend_phase=p_phase;
    assign backend_env=s_env;
    assign backend_accumulate=m_valid;
    reg s_valid, s_last, s_active;
    reg [15:0] s_env;
    reg m_valid, m_last, m_active;

    reg [CW-1:0] count_work;
    reg [15:0] elapsed;
    wire signed [ACC_W-1:0] sum_next=backend_sum_next;

    wire memory_enabled=!SHARED_MEMORY || shared_score_owner;
    assign shared_score_ready=init_done;
    assign shared_score_read=issuing && init_done;
    assign shared_score_ra=issue_index;
    assign shared_score_state_we=memory_enabled && !rst && (!init_done || q_valid || (cfg_accept && cfg_retrigger));
    assign shared_score_state_wa=!init_done ? clear_index : q_valid ? q_index : cfg_index;
    assign shared_score_state_wd=!init_done ? 48'd0 : q_valid ? {next_phase,next_env} : {cfg_phase,cfg_env};
    assign shared_score_control_we=memory_enabled && !rst && (!init_done || cfg_accept);
    assign shared_score_control_wa=!init_done ? clear_index : cfg_index;
    assign shared_score_control_wd=!init_done ? 48'd0 : {cfg_freq,cfg_target};
    generate if(SHARED_MEMORY)begin: shared
      assign state_q=shared_score_state;assign control_q=shared_score_control;
    end else begin: independent_test
      (* syn_ramstyle="block_ram" *)reg[47:0]phase_env_ram[0:N-1],control_ram[0:N-1];
      reg[47:0]sq,cq;assign state_q=sq;assign control_q=cq;
      always @(posedge clk)begin
       if(issuing&&init_done)begin sq<=phase_env_ram[issue_index];cq<=control_ram[issue_index];end
       if(shared_score_state_we)phase_env_ram[shared_score_state_wa]<=shared_score_state_wd;
       if(shared_score_control_we)control_ram[shared_score_control_wa]<=shared_score_control_wd;
      end
    end endgenerate

    always @(posedge clk) begin
        if (rst || !memory_enabled) begin
            init_done<=0;clear_index<=0;busy<=0;issuing<=0;issue_index<=0;frame_attack<=0;frame_release<=0;
            q_valid<=0;q_last<=0;q_index<=0;
            p_valid<=0;p_last<=0;p_active<=0;p_phase<=0;p_env<=0;
            s_valid<=0;s_last<=0;s_active<=0;s_env<=0;
            m_valid<=0;m_last<=0;m_active<=0;
            count_work<=0;elapsed<=0;sample_sum<=0;
            active_count<=0;render_cycles<=0;deadline_miss<=0;frame_valid<=0;
        end else begin
            frame_valid<=0;
            if (!init_done) begin
                if (clear_index == N-1) begin init_done<=1;clear_index<=0;end
                else clear_index<=clear_index+1'b1;
                if (sample_ce) deadline_miss<=1;
            end else begin
                q_valid <= issuing;
                if (issuing) begin
                    q_index<=issue_index;q_last<=issue_index == N-1;
                    if (issue_index == N-1) issuing<=0;
                    else issue_index<=issue_index+1'b1;
                end
                p_valid<=q_valid;
                if (q_valid) begin
                    p_phase<=next_phase;p_env<=next_env;p_last<=q_last;
                    p_active<=next_env != 0 && control_q[47:16] != 0;
                end
                // sine_q is generated at the same edge as these sideband stages.
                s_valid<=p_valid;
                if (p_valid) begin s_env<=p_env;s_last<=p_last;s_active<=p_active;end
                m_valid<=s_valid;
                if (s_valid) begin
                    m_last<=s_last;m_active<=s_active;
                end
                if (m_valid) begin
                    if (m_active) count_work<=count_work+1'b1;
                    if (m_last) begin
                        sample_sum<=sum_next;
                        active_count<=count_work + (m_active ? 1'b1 : 1'b0);
                        render_cycles<=elapsed+1'b1;
                        frame_valid<=1;busy<=0;
                    end
                end
                if (busy) elapsed<=elapsed+1'b1;
                if (sample_ce) begin
                    if (busy) deadline_miss<=1;
                    else begin
                        busy<=1;issuing<=1;issue_index<=0;frame_attack<=global_attack;frame_release<=global_release;
                        count_work<=0;elapsed<=0;
                    end
                end
            end
        end
    end
endmodule
