// Real audio/controller/ADC/transport integration; consumer is supplied by C.
// Logical API only. This module does not assign J13 or display pins.
module session_link #(parameter ROW_CYCLES=2500,DEBOUNCE_FRAMES=8,BUTTON_CYCLES=150000,
    LONG_CYCLES=50000000,ENCODER_CYCLES=2500,AUDIO_N=32,PLUCK_N=0,WITH_FULL_STATE=0)(
    input wire sys_clk,observer_clk,arst,enc_a,enc_b,
    input wire [2:0] button_n,input wire [3:0] matrix_col_n,output wire [3:0] matrix_row_n,
    output wire hp_bck,hp_ws,hp_din,pa_en,status_led,
    input wire adc_miso,output wire adc_sclk,adc_mosi,adc_cs_n,
    input wire client_valid,output wire client_ready,input wire [7:0] client_addr,
    input wire [31:0] client_value,input wire [15:0] client_tag,
    output wire reply_valid,input wire reply_ready,output wire [7:0] reply_addr,
    output wire [31:0] reply_value,output wire [15:0] reply_tag,output wire reply_accepted,reply_applied,output wire [7:0] reply_reason,
    output wire ui_valid,input wire ui_ready,output wire [31:0] ui_data,output wire [4:0] ui_index,
    output wire ui_first,ui_last,ui_session_start,output wire [31:0] ui_drops,
    output wire state_valid,input wire state_ready,output wire [63:0] state_data,
    output wire [5:0] state_word_index,output wire state_first,state_last,state_session_start,
    output wire pcm_valid,input wire pcm_ready,output wire signed [15:0] pcm_left,pcm_right,
    output wire [31:0] pcm_index,output wire pcm_gap,pcm_session_start,
    output wire [31:0] state_drops,pcm_drops,adc_skipped,output wire pcm_overflow,protocol_error
);
    localparam SNAPSHOT_W=320+AUDIO_N*64+512;
    wire rst,scan_valid,scan_ready,adc_valid,adc_ready,mixer_valid,mixer_ready,mix_mode;
    wire [95:0] scan_data;wire [59:0] adc_data;wire [67:0] mixer_data,mixer_targets;
    wire [47:0] harmonic_targets;wire [3:0] invalidate,acquired;
    wire host_valid,host_ready,ack_valid,ack_accepted,ack_applied;
    wire [7:0] host_addr,ack_addr;wire [7:0] ack_reason;wire [31:0] host_value,ack_value;
    wire action_valid,action_ready,action_ack,action_accepted,action_applied,drums_commit;
    wire [7:0] action_addr,action_reason;wire [31:0] action_value;
    wire remote_valid,remote_ready,remote_ack_valid,remote_accepted,remote_applied;
    wire [4:0] remote_addr,remote_ack_addr;wire [31:0] remote_value,remote_ack_value;
    wire action_protocol_error,cdc_protocol_error;
    wire raw_ui_valid;wire [639:0] raw_ui;
    wire raw_state_valid;wire [SNAPSHOT_W-1:0] raw_state;wire [255:0] extension;
    wire [15:0] keys;wire [127:0] capabilities;
    wire raw_pcm_valid;wire signed [15:0] raw_left,raw_right;wire [31:0] raw_index;
    mcp3208_reader adc(.clk(sys_clk),.rst(rst),.miso(adc_miso),.sclk(adc_sclk),.mosi(adc_mosi),.cs_n(adc_cs_n),
        .scan_valid(scan_valid),.scan_ready(scan_ready),.scan_data(scan_data),.sequence(),.skipped_scans(adc_skipped));
    fader_mode_adapter faders(.clk(sys_clk),.rst(rst),.mix_mode(mix_mode),.scan_valid(scan_valid),.scan_ready(scan_ready),
        .scan_data(scan_data[59:0]),.harmonic_targets(harmonic_targets),.mixer_targets(mixer_targets),.invalidate(invalidate),
        .adc_valid(adc_valid),.adc_ready(adc_ready),.adc_data(adc_data),
        .mixer_valid(mixer_valid),.mixer_ready(mixer_ready),.mixer_data(mixer_data),.acquired(acquired));
    looper_platform #(.ROW_CYCLES(ROW_CYCLES),.DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),.BUTTON_CYCLES(BUTTON_CYCLES),
        .LONG_CYCLES(LONG_CYCLES),.ENCODER_CYCLES(ENCODER_CYCLES),.AUDIO_N(AUDIO_N),.PLUCK_N(PLUCK_N)) platform(
        .sys_clk(sys_clk),.reset_request(arst),.reset_active(rst),.enc_a(enc_a),.enc_b(enc_b),.button_n(button_n),
        .matrix_col_n(matrix_col_n),.matrix_row_n(matrix_row_n),.hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.pa_en(pa_en),.status_led(status_led),
        .adc_valid(adc_valid),.adc_ready(adc_ready),.adc_data(adc_data),.mixer_valid(mixer_valid),.mixer_ready(mixer_ready),.mixer_data(mixer_data),
        .ui_valid(action_valid),.ui_ready(action_ready),.ui_addr(action_addr),.ui_value(action_value),
        .ui_ack(action_ack),.ui_accepted(action_accepted),.ui_applied(action_applied),.ui_reason(action_reason),
        .menu_drums_commit(drums_commit),.ui_mixer_pickup(acquired),.ui_snapshot_valid(raw_ui_valid),.ui_snapshot_data(raw_ui),
        .remote_valid(remote_valid),.remote_ready(remote_ready),.remote_addr(remote_addr),.remote_value(remote_value),
        .remote_ack_valid(remote_ack_valid),.remote_ack_addr(remote_ack_addr),.remote_ack_value(remote_ack_value),
        .remote_ack_accepted(remote_accepted),.remote_ack_applied(remote_applied),
        .snapshot_valid(raw_state_valid),.snapshot_data(raw_state),.snapshot_extension(extension),.snapshot_keys(keys),.capabilities(capabilities),
        .pcm_valid(raw_pcm_valid),.pcm_left(raw_left),.pcm_right(raw_right),.pcm_index(raw_index),
        .mix_mode(mix_mode),.harmonic_targets(harmonic_targets),.mixer_targets(mixer_targets),.fader_invalidate(invalidate));
    session_ui_bridge ui_bridge(.src_clk(sys_clk),.dst_clk(observer_clk),.arst(rst),
        .src_valid(raw_ui_valid),.src_data(raw_ui),.src_drops(ui_drops),.dst_valid(ui_valid),.dst_ready(ui_ready),
        .dst_data(ui_data),.dst_index(ui_index),.dst_first(ui_first),.dst_last(ui_last),.dst_session_start(ui_session_start));
    generate if(WITH_FULL_STATE) begin: detailed_state
    refinement_snapshot_bridge #(.SNAPSHOT_W(SNAPSHOT_W),.KEYS(16)) state_bridge(
        .src_clk(sys_clk),.dst_clk(observer_clk),.arst(rst),.src_snapshot_valid(raw_state_valid),.src_snapshot_data(raw_state),
        .src_snapshot_extension(extension),.src_snapshot_keys(keys),.src_capabilities(capabilities),
        .src_busy(),.src_drop_count(state_drops),.dst_valid(state_valid),.dst_ready(state_ready),.dst_data(state_data),
        .dst_word_index(state_word_index),.dst_first(state_first),.dst_last(state_last),.dst_session_start(state_session_start));
    end else begin
        assign state_valid=0;assign state_data=0;assign state_word_index=0;
        assign state_first=0;assign state_last=0;assign state_session_start=0;assign state_drops=0;
    end endgenerate
    session_dispatcher dispatcher(.clk(sys_clk),.rst(rst),.host_valid(host_valid),.host_ready(host_ready),
        .host_addr(host_addr),.host_value(host_value),.ack_valid(ack_valid),.ack_addr(ack_addr),.ack_value(ack_value),
        .ack_accepted(ack_accepted),.ack_applied(ack_applied),.ack_reason(ack_reason),
        .audio_valid(remote_valid),.audio_ready(remote_ready),.audio_addr(remote_addr),.audio_value(remote_value),
        .audio_ack_valid(remote_ack_valid),.audio_ack_addr(remote_ack_addr),.audio_ack_value(remote_ack_value),
        .audio_ack_accepted(remote_accepted),.audio_ack_applied(remote_applied),
        .ui_valid(action_valid),.ui_ready(action_ready),.ui_addr(action_addr),.ui_value(action_value),
        .ui_ack(action_ack),.ui_accepted(action_accepted),.ui_applied(action_applied),.ui_reason(action_reason),
        .menu_drums_commit(drums_commit),.protocol_error(action_protocol_error));
    assign protocol_error=action_protocol_error||cdc_protocol_error;
    audio_pcm_bridge waveform(.src_clk(sys_clk),.dst_clk(observer_clk),.arst(rst),.src_valid(raw_pcm_valid),
        .src_left(raw_left),.src_right(raw_right),.src_index(raw_index),.src_drop_count(pcm_drops),.src_overflow(pcm_overflow),
        .dst_valid(pcm_valid),.dst_ready(pcm_ready),.dst_left(pcm_left),.dst_right(pcm_right),.dst_index(pcm_index),.dst_gap(pcm_gap),.dst_session_start(pcm_session_start));
    session_command_bridge commands(.client_clk(observer_clk),.audio_clk(sys_clk),.arst(rst),
        .client_valid(client_valid),.client_ready(client_ready),.client_addr(client_addr),.client_value(client_value),.client_tag(client_tag),
        .reply_valid(reply_valid),.reply_ready(reply_ready),.reply_addr(reply_addr),.reply_value(reply_value),.reply_tag(reply_tag),
        .reply_accepted(reply_accepted),.reply_applied(reply_applied),.reply_reason(reply_reason),.host_valid(host_valid),.host_ready(host_ready),.host_addr(host_addr),.host_value(host_value),
        .ack_valid(ack_valid),.ack_source(1'b1),.ack_addr(ack_addr),.ack_value(ack_value),.ack_accepted(ack_accepted),.ack_applied(ack_applied),.ack_reason(ack_reason),
        .audio_protocol_error(cdc_protocol_error));
endmodule
