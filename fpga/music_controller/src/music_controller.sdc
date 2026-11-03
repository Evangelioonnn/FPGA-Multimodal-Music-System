create_clock -name sys_clk -period 20.000 -waveform {0 10} [get_ports {sys_clk}]
set_false_path -from [get_ports {enc_a[*] enc_b[*] enc_button_n[*] reset_n panic_n calibrate_n col_n[*] adc_miso}]
# Only first-stage scalar toggle synchronizers are asynchronous.
set_false_path -to [get_regs {*text_frames/ack_meta* *text_frames/request_meta* *scope_frames/ack_meta* *scope_frames/request_meta*}]
# Dual-clock RAM banks are held stable until frame-boundary acknowledgment.
# No wide register-bus CDC or blanket clock-group timing exceptions.

# V16 actual mapped text_rd retains9 scene bits: analysis/synth16..19, tab22..24, practice sub25..26.
# Feedback20..21 and focus/browse27..31 are swept in this piano-only build.
# Constrain actual payload registers only; no dummy logic to keep absent targets.
# V13 per-bank frame descriptors: stable bundled payload, protected by
# request/ack bank ownership (see CDC_TIMING.md). First use is >=2 pixel periods
# after launch and reuse follows the returning two-stage ACK. Bound the actual
# payload paths to6ns; their same-edge HOLD relationship is not a functional
# capture. Keep SETUP/max-delay checks and every other same/cross-domain path.
set_max_delay -from [get_regs {text_frames/mode0_* text_frames/mode1_*}] -to [get_regs {text_frames/text_rd_16_* text_frames/text_rd_17_* text_frames/text_rd_18_* text_frames/text_rd_19_* text_frames/text_rd_22_* text_frames/text_rd_23_* text_frames/text_rd_24_* text_frames/text_rd_25_* text_frames/text_rd_26_*}] 6.000
set_false_path -hold -from [get_regs {text_frames/mode0_* text_frames/mode1_*}] -to [get_regs {text_frames/text_rd_16_* text_frames/text_rd_17_* text_frames/text_rd_18_* text_frames/text_rd_19_* text_frames/text_rd_22_* text_frames/text_rd_23_* text_frames/text_rd_24_* text_frames/text_rd_25_* text_frames/text_rd_26_*}]
set_max_delay -from [get_regs {scope_frames/mode0_* scope_frames/mode1_*}] -to [get_regs {scope_frames/rd_mode_0_* scope_frames/rd_mode_1_*}] 6.000
set_false_path -hold -from [get_regs {scope_frames/mode0_* scope_frames/mode1_*}] -to [get_regs {scope_frames/rd_mode_0_* scope_frames/rd_mode_1_*}]

# Sequenced-reset exception: OSER10 clocks are gated off for 320 ns before
# RESET falls and stay off for another 320 ns afterwards. This is NOT a
# running-clock asynchronous release. See av_serializer_start and PHY test.
set_false_path -from [get_regs {*transport/startup/serializer_reset*}] -to [get_pins {*transport/lanes_gen*.serializer/RESET}]

# DHCE has a four-negedge internal synchronization chain in the GW5A model.
# Its CEN receives a persistent asynchronous enable request, not cycle data.
set_false_path -from [get_regs {*transport/startup/clocks_enable*}] -to [get_pins {transport/serial_gate/CEN}]
# Async assertion / two-pixel-clock synchronous release synchronizer ONLY.
# Keep both stages' D paths and the released reset fanout timed normally.
set_false_path -to [get_pins {video_reset/release_pipe*/PRESET}]

# SUG940 report-only commands: expose multiple actual bottlenecks together.
# These do not modify launch/capture requirements or create exceptions.
report_timing -setup -max_paths 200
report_timing -hold -max_paths 100

# UART/STATE scalar asynchronous pins: only their first synchronizer stages.
set_false_path -from [get_ports {uart_rx}] -to [get_regs {*frontend/receiver/rx_meta*}]
set_false_path -from [get_ports {bt_state}] -to [get_regs {*frontend/bt_meta*}]
# DD input is asynchronous only at its first UART sampling FF; r0->r1 stays timed.
set_false_path -from [get_ports {vel_rx}] -to [get_regs {*keyboard/uart/r0*}]
# C practice frame bank/payload: held until frame-boundary two-stage ACK.
set_false_path -to [get_regs {*frontend/frames/ack_meta* *frontend/frames/request_meta*}]
set_max_delay -from [get_regs {*frontend/frames/payload*}] -to [get_regs {*frontend/frames/visible*}] 6.000
set_false_path -hold -from [get_regs {*frontend/frames/payload*}] -to [get_regs {*frontend/frames/visible*}]

# Same-clock matched ODDR outputs; real 0..20ns clock-to-pad budget.
set_max_delay -to [get_ports {i2s_bck i2s_lrck i2s_din}] 20.000
set_min_delay -to [get_ports {i2s_bck i2s_lrck i2s_din}] 0.000
report_timing -setup -to [get_ports {i2s_bck i2s_lrck i2s_din}] -max_paths 12
report_timing -hold -to [get_ports {i2s_bck i2s_lrck i2s_din}] -max_paths 12

# Asynchronous UART input stops only at the actual first synchronizer stage.
set_false_path -from [get_ports {gesture_rx}] -to [get_regs {*gesture*receiver*uart*rx_meta*}]

# V23 text/graph identity: same request/ACK as text bank publication; held
# through destination VBlank capture and returning two-stage ACK. Bound this
# new bundled payload to6ns; only meaningless asynchronous HOLD is excluded.
set_max_delay -from [get_regs {*text_frames/*identity*held*}] -to [get_regs {*text_frames/*identity*visible*}] 6.000
set_false_path -hold -from [get_regs {*text_frames/*identity*held*}] -to [get_regs {*text_frames/*identity*visible*}]
