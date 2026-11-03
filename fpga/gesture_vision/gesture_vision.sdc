create_clock -name sys27 -period 37.037 -waveform {0 18.5185} [get_ports {clk27}]
create_clock -name cam_pclk -period 16 [get_ports {cmos_pclk}]
create_generated_clock -name xclk135 -source [get_ports {clk27}] -divide_by 2 [get_ports {cmos_xclk}]
create_generated_clock -name serial37125 -source [get_ports {clk27}] -divide_by 4 -multiply_by 55 [get_pins {clocks/pll/rpll_inst/CLKOUT}]
create_generated_clock -name pixel7425 -source [get_pins {clocks/pll/rpll_inst/CLKOUT}] -divide_by 5 [get_pins {clocks/pixel_div/CLKOUT}]
# PCLK is independent; banks and bundled-data mailboxes transfer ownership.
set_clock_groups -asynchronous -group [get_clocks {cam_pclk}] -group [get_clocks {sys27 xclk135 pixel7425 serial37125}]
# Camera input design envelope:62.5MHz/0..10ns, physical waveforms unmeasured.
set_input_delay -clock cam_pclk -max 10 [get_ports {cmos_db[*] cmos_href cmos_vsync}]
set_input_delay -clock cam_pclk -min 0 [get_ports {cmos_db[*] cmos_href cmos_vsync}]
set_false_path -from [get_ports {hdmi_hpd cmos_scl cmos_sda capture_n size_n position_n}]
set_false_path -from [get_pins {clocks/pll/rpll_inst/LOCK}]
# C01 clock startup keeps both serializer clocks stopped across OSER reset release.
set_false_path -to [get_pins {phy/*/RESET}]
set_false_path -to [get_pins {clocks/serial_gate/CE clocks/pixel_div/RESETN}]
# System/video status uses held payload until two-stage request/ack returns.
set_false_path -to [get_regs {video_status/req1* video_status/ack1*}]
set_false_path -from [get_regs {video_status/held*}] -to [get_regs {video_status/dst_data*}]
# Asynchronously asserted, locally synchronized reset release. Only PRESET pins
# of the synchronizer chains are excluded; data and downstream reset timing remain.
set_false_path -to [get_pins {frames/v_reset*/PRESET video_reset*/PRESET}]

set_false_path -to [get_ports {uart_tx led_n tmds_clk_p tmds_clk_n tmds_d_p[*] tmds_d_n[*] cmos_scl cmos_sda cmos_reset_n cmos_pwdn cmos_xclk}]
# No asynchronous clock-group cut between pixel and serial clocks.

# External UART sink is asynchronous; protocol tested separately.
set_false_path -to [get_ports {gesture_tx}]
