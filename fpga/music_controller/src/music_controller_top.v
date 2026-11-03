// One physical candidate: existing KEYBOARD_V2 wiring plus the proven TMDS pins.
module control_ui_v24_top(input wire sys_clk,reset_n,panic_n,calibrate_n,
 input wire [5:0] col_n,output wire [5:0] row_n,
 input wire [2:0] enc_a,enc_b,enc_button_n,
 input wire gesture_rx,uart_rx,bt_state,vel_rx,output wire uart_tx,vel_tx,
 input wire adc_miso,output wire adc_sclk,adc_mosi,adc_cs_n,
 output wire [3:0] status_led,output wire rgb_data,hp_bck,hp_ws,hp_din,pa_en,
 output wire i2s_bck,i2s_lrck,i2s_din,
 output wire tmds_clk_n_0,tmds_clk_p_0,output wire [2:0] tmds_d_n_0,tmds_d_p_0);
 wire[15:0]gesture_status;wire[31:0]gesture_expression_status;wire[191:0]library_status;wire[319:0]library_title;
 wire pixel_clk,serial_clk,locked,ui_rst,pixel_rst;wire[63:0]dd_status,v18_status;
 assign vel_tx=1'b1;
 wire [10:0] x,y;wire de,hs,vs,frame_start;
 wire[511:0]practice_status;wire[127:0]record_status;wire[383:0]song_title;
 wire[8:0]practice_map_address;wire[63:0]practice_map_data;wire[415:0]practice_visible;
 wire state_valid,pcm_valid,pcm_sample_ce,audio_rst;
 wire [127:0] score_status;wire [95:0] guide_status;
 wire [639:0] state_data;wire [255:0] controller_state;wire [95:0] adc_raw;
 wire [63:0] navigation,layer_timbres,synth_status;
 wire [119:0] envelope_status;wire [159:0] audio_status;wire [47:0] harmonic_targets;wire view;
 wire signed [15:0] left,right;
 wire[255:0]storage_status;
 // User-approved music/workbench only. No SD physical drivers are instantiated;
 // MCU persistent library reuses the original single-song RAM and audio path.
 control_audio_system #(.WITH_LIBRARY(1),.WITH_GESTURE(1),.WITH_LOOP_EXPORT(0),.WITH_NEW_FX(0),.WITH_V18(1),.WITH_DD(1),.AUDIO_N(64),.WITH_PRACTICE(1),.WITH_TF(0),.WITH_SCORE(1),.SCORE_N(512)) system(.sys_clk(sys_clk),.reset_n(reset_n),.panic_n(panic_n),.calibrate_n(calibrate_n),
  .ui_library_status(library_status),.ui_library_title(library_title),.gesture_rx(gesture_rx),.ui_gesture_status(gesture_status),.ui_gesture_expression_status(gesture_expression_status),.dd_rx(vel_rx),.dd_swap(1'b0),.dd_reload(1'b0),.record_source(1'b0),.ui_dd_status(dd_status),.ui_v18_status(v18_status),
  .uart_rx(uart_rx),.bt_state(bt_state),.uart_tx(uart_tx),
  .ui_practice_status(practice_status),.ui_record_status(record_status),.ui_song_title(song_title),
  .pixel_clk(pixel_clk),.pixel_rst(pixel_rst),.frame_start(frame_start),.practice_map_address(practice_map_address),.practice_map_data(practice_map_data),.practice_visible(practice_visible),
  .sd_miso(1'b1),.sd_sclk(),.sd_mosi(),.sd_cs_n(),.ui_storage_status(storage_status),
  .col_n(col_n),.row_n(row_n),.enc_a(enc_a),.enc_b(enc_b),.enc_button_n(enc_button_n),
  .adc_miso(adc_miso),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs_n(adc_cs_n),
  .status_led(status_led),.rgb_data(rgb_data),.hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.pa_en(pa_en),
  .ui_score_status(score_status),.ui_guide_status(guide_status),.state_valid(state_valid),.state_data(state_data),.controller_state(controller_state),.adc_raw(adc_raw),
  .pcm_valid(pcm_valid),.pcm_sample_ce(pcm_sample_ce),.pcm_left(left),.pcm_right(right),.reset_active(audio_rst),
  .ui_envelope_status(envelope_status),.ui_synth_status(synth_status),.ui_layer_timbres(layer_timbres),.ui_audio_status(audio_status),.ui_harmonics(harmonic_targets),.ui_view(view),.ui_navigation_state(navigation));
 i2s_pcm5102_tx i2s_output(.clk(sys_clk),.rst(audio_rst),.frame_ce(pcm_sample_ce),
  .sample_left(left),.sample_right(right),.i2s_bck(i2s_bck),.i2s_lrck(i2s_lrck),.i2s_din(i2s_din));
 Gowin_PLL pll(.clkin(sys_clk),.mdclk(sys_clk),.clkout0(pixel_clk),.clkout1(serial_clk),.lock(locked));
 wire observation_reset=audio_rst||!locked;
 audio_transport_reset ui_reset(sys_clk,observation_reset,ui_rst);
 audio_transport_reset video_reset(pixel_clk,observation_reset,pixel_rst);
 av_timing timing(pixel_clk,pixel_rst,x,y,de,hs,vs,frame_start);
 wire tw,tp,tr,tv,tc;wire [10:0] ta,ra;wire [31:0] td,rd;
 wire cw,cp;wire[7:0]ca,cra;wire[23:0]cd,crd;
 reg observation_busy,text_done,curve_done;reg[63:0]observation_identity;wire[63:0]visible_identity;
 wire observation_start=state_valid&&tr&&!observation_busy;
 wire observation_publish=observation_busy&&(text_done||tp)&&(curve_done||cp);
 always @(posedge sys_clk) begin
  if(ui_rst) begin observation_identity<=0;observation_busy<=0;text_done<=0;curve_done<=0;end
  else begin
   if(observation_start) begin observation_identity<={practice_status[95:64],practice_status[63:32]};observation_busy<=1;text_done<=0;curve_done<=0;end
   if(tp) text_done<=1;if(cp)curve_done<=1;
   if(observation_publish) observation_busy<=0;
  end
 end
 ui_page_writer #(.WITH_LIBRARY(1),.WITH_GESTURE(1),.WITH_LOOP_EXPORT(0),.WITH_NEW_FX(0),.WITH_V18(1),.WITH_SYNTH_PREVIEW(1)) page(.clk(sys_clk),.rst(ui_rst),.ready(tr),.snapshot_valid(observation_start),
  .library_status(library_status),.library_title(library_title),.gesture_status(gesture_status),.gesture_expression_status(gesture_expression_status),.dd_status(dd_status),.v18_status(v18_status),.score_status(score_status),.guide_status(guide_status),.snapshot(state_data),.controller(controller_state),.audio_status(audio_status),
  .envelope_status(envelope_status),.layer_timbres(layer_timbres),.synth_status(synth_status),.harmonics(harmonic_targets),.adc_raw(adc_raw),.navigation(navigation),
  .practice_status(practice_status),.record_status(record_status),.song_title(song_title),.storage_status(storage_status),.wr_en(tw),.wr_addr(ta),.wr_data(td),.publish(tp));
 synth_curve_builder preview(.clk(sys_clk),.rst(ui_rst),.start(observation_start),
  .ab(navigation[4:3]==2),.synth_status(synth_status),
  .coefficients({state_data[360:352],state_data[346:338],state_data[337:329],state_data[328:320]}),
  .wr_en(cw),.wr_addr(ca),.wr_data(cd),.done(cp));
 synth_frame_ram #(.WITH_IDENTITY(1),.WITH_CURVE(1)) text_frames(.src_clk(sys_clk),.src_rst(ui_rst),.dst_clk(pixel_clk),.dst_rst(pixel_rst),
  .text_we(tw),.text_wa(ta),.text_wd(td),.curve_we(cw),.curve_wa(ca),.curve_wd(cd),
  .source_identity(observation_identity),.visible_identity(visible_identity),.publish(observation_publish),.ready(tr),.frame_start(frame_start),
  .text_ra(ra),.text_rd(rd),.curve_ra(cra),.curve_rd(crd),.have_frame(tv),.frame_changed(tc));
 wire sw,sp,sr,sv,sc;wire [8:0] sa,sra;wire [17:0] sd,srd;
 wire [1:0] analysis_mode=navigation[2:0]==3 ? navigation[4:3]+2'd1 : 2'd0;
 wire [1:0] committed_analysis=rd[17:16];wire [1:0] result_mode;
 wire analysis_valid=sv&&result_mode==committed_analysis;
 pcb_analysis_capture capture(sys_clk,ui_rst,analysis_mode,sr,pcm_sample_ce,left,right,sw,sa,sd,sp);
 pcb_analysis_bank scope_frames(sys_clk,ui_rst,pixel_clk,pixel_rst,
  sw,sa,sd,analysis_mode,sp,sr,frame_start,sra,srd,result_mode,sv,sc);
 wire [39:0] scope_data={4'hA,4'd0,srd[15:8],8'd0,srd[7:0],8'd0};
 wire [8:0] wave_address,analysis_address;
 wire [23:0] analysis_rgb;wire analysis_mask;reg [11:0] analysis_visible=0;
 always @(posedge pixel_clk)if(pixel_rst)analysis_visible<=0;
  else analysis_visible<={analysis_visible[10:0],tv&&committed_analysis>=2};
 assign sra=committed_analysis==1 ? wave_address : analysis_address;
 pcb_analysis_plot graph(pixel_clk,pixel_rst,committed_analysis,x,y,de,
  analysis_valid&&tv,analysis_address,srd,analysis_rgb,analysis_mask);
 reg [23:0] analysis_delay0,analysis_delay1,analysis_delay2;reg [2:0] analysis_mask_delay=0;
 always @(posedge pixel_clk)begin
  analysis_delay0<=analysis_rgb;analysis_delay1<=analysis_delay0;analysis_delay2<=analysis_delay1;
  if(pixel_rst)analysis_mask_delay<=0;else analysis_mask_delay<={analysis_mask_delay[1:0],analysis_mask};
 end
 wire [23:0] rgb,background,with_synth;wire vd,vh,vv;
 av_display renderer(pixel_clk,pixel_rst,tv&&committed_analysis==1,x,y,de,hs,vs,tv,analysis_valid,tc,sc,frame_start,
  ra,rd[12:0],rd[31:16],wave_address,scope_data,background,vd,vh,vv);
 synth_overlay overlay(pixel_clk,pixel_rst,rd[19:18],tv,x,y,cra,crd,background,with_synth);
 wire practice_roll_mask;wire[23:0]practice_roll_rgb;
 reg map_generation_matches,map_run_matches;
 always @(posedge pixel_clk)begin
  if(pixel_rst)begin map_generation_matches<=0;map_run_matches<=0;end
  else begin map_generation_matches<=visible_identity[31:0]==practice_visible[189:158];map_run_matches<=visible_identity[63:32]==practice_visible[375:344];end
 end
 practice_roll_renderer practice_roll(pixel_clk,pixel_rst,x,y,de,tv&&rd[24:22]==5&&rd[26:25]==1&&map_generation_matches&&map_run_matches,
  practice_visible,practice_map_address,practice_map_data,practice_roll_mask,practice_roll_rgb);
 assign rgb=practice_roll_mask ? practice_roll_rgb : (analysis_visible[11]&&analysis_mask_delay[2]) ? analysis_delay2 : with_synth;
 av_dvi_tx transport(.sys_clk(sys_clk),.startup_reset(ui_rst),.pixel_clock(pixel_clk),.ddr_bit_clock(serial_clk),
  .rstn(!pixel_rst),.den(vd),.hsync(vh),.vsync(vv),.pixel_data(rgb),
  .tmds_clk({tmds_clk_p_0,tmds_clk_n_0}),.tmds_d0({tmds_d_p_0[0],tmds_d_n_0[0]}),
  .tmds_d1({tmds_d_p_0[1],tmds_d_n_0[1]}),.tmds_d2({tmds_d_p_0[2],tmds_d_n_0[2]}));
endmodule
