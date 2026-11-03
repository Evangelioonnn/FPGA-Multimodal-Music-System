// V04 ROM-model recognizer plus GS2 sustained ordinary-pedal request. No CPU/host/DDR.
module p20_crop_live_top #(parameter POR_CYCLES=270000)(
    input wire clk27,hdmi_hpd,capture_n,size_n,position_n,
    inout wire cmos_scl,cmos_sda,cmos_reset_n,cmos_pwdn,
    input wire cmos_pclk,cmos_vsync,cmos_href,input wire [7:0] cmos_db,
    output wire cmos_xclk,uart_tx,gesture_tx,output reg led_n=1,
    output wire tmds_clk_p,tmds_clk_n,output wire [2:0] tmds_d_p,tmds_d_n);
    reg [31:0] por_count=0;reg por=1;
    always @(posedge clk27)if(por)begin if(por_count==POR_CYCLES-1)por<=0;else por_count<=por_count+1'b1;end
    wire pixel_clk,serial_clk,locked,serializer_reset;
    p20_video_clocks clocks(clk27,por,pixel_clk,serial_clk,locked,serializer_reset);
    wire reset_event=por || !locked;
    (* ASYNC_REG="TRUE" *) reg [1:0] sys_reset=3;
    always @(posedge clk27 or posedge reset_event)if(reset_event)sys_reset<=3;else sys_reset<={sys_reset[0],1'b0};
    wire rst=sys_reset[1];
    (* ASYNC_REG="TRUE" *) reg [3:0] video_reset=15;
    always @(posedge pixel_clk or posedge rst)if(rst)video_reset<=15;else video_reset<={video_reset[2:0],1'b0};
    wire vrst=video_reset[3];
    reg xclk=0;always @(posedge clk27)if(rst)xclk<=0;else xclk<=!xclk;
    assign cmos_xclk=xclk;
    wire scl_low,sda_low,reset_level,pwdn_level,configured,pclk_seen;
    wire [3:0] setup_error,nack;wire [15:0] progress;
    assign cmos_scl=scl_low ? 1'b0:1'bz;assign cmos_sda=sda_low ? 1'b0:1'bz;
    assign cmos_reset_n=reset_level ? 1'bz:1'b0;assign cmos_pwdn=pwdn_level ? 1'bz:1'b0;
    camera_capture_init #(.CLK_HZ(27000000),.BUS_HZ(90000),.TIMEOUT_CYCLES(270000),
        .POWER_CYCLES(810000),.RESET_CYCLES(540000),.BOOT_CYCLES(1350000)) setup(
        clk27,rst,cmos_scl,cmos_sda,scl_low,sda_low,reset_level,pwdn_level,configured,setup_error,nack,progress);
    wire [10:0] x,y;wire de,hs,vs,blank_start;
    p20_preview_timing raster(pixel_clk,vrst,x,y,de,hs,vs,blank_start);
    wire [14:0] pa,rpa,ua;wire [11:0] ma,rma;wire [9:0] ca;
    wire [7:0] pd,md,ud;wire [15:0] cd;
    wire have_frame,hold_frame,job_hold,track_hold;
    assign hold_frame=job_hold || track_hold;
    wire [31:0] displayed_frame,capture_frame;
    wire [8:0] desired_x,desired_side,displayed_x,displayed_side;
    wire [7:0] desired_y,displayed_y;
    p20_crop_controls roi_keys(pixel_clk,vrst,size_n,position_n,hold_frame,desired_x,desired_y,desired_side);
    wire aligned_vs,aligned_href;wire [7:0] aligned_data;
    p20_camera_input ingress(cmos_pclk,rst||!configured,cmos_vsync,cmos_href,cmos_db,aligned_vs,aligned_href,aligned_data);
    p20_crop_frames frames(clk27,pixel_clk,rst||!configured,cmos_pclk,aligned_vs,aligned_href,aligned_data,
        blank_start,hold_frame,desired_x,desired_y,desired_side,pa,pd,ma,md,ca,cd,
        have_frame,displayed_frame,displayed_x,displayed_y,displayed_side,pclk_seen,,,,,,,);
    (* ASYNC_REG="TRUE" *) reg [1:0] hpd_pipe=0;
    always @(posedge clk27)hpd_pipe<={hpd_pipe[0],hdmi_hpd};
    wire status_ready,status_valid,status_overrun;wire [26:0] status;
    snapshot_cdc #(.WIDTH(27)) video_status(clk27,rst,status_ready,
        {hpd_pipe[1],configured,pclk_seen,setup_error,nack,progress},status_ready,status_overrun,pixel_clk,vrst,status_valid,status);
    wire cfg=status[25];wire loading,result_pending,terminal_current;
    wire [9:0] inference_address;wire [511:0] result_payload;
    p20_crop_live_jobs jobs(pixel_clk,vrst,have_frame,cfg,status[23:20],displayed_frame,
        displayed_x,displayed_y,displayed_side,1'b1,track_hold,job_hold,loading,inference_address,cd,
        result_pending,terminal_current,result_payload);
    reg track_enable=0;
    always @(posedge pixel_clk)if(vrst)track_enable<=0;
      else track_enable<=desired_side==240 && displayed_side==240 &&
        desired_x==displayed_x && desired_y==displayed_y;
    wire track_port,track_initialized,track_valid,track_held,track_done;
    wire [9:0] track_address;wire [8:0] track_x;wire [7:0] track_y;
    wire [2:0] track_direction;wire [31:0] track_frame;
    wire [9:0] debug_address;wire debug_data;
    wire [10:0] skin_pixels,best_pixels,motion_pixels;
    wire [3:0] reject_reason;wire [31:0] analyzed_frame;
    // Position HOLD is an observer flag, never a new location measurement.
    // The RGB copy gets priority over a new CNN load; an active load finishes.
    p20_autoxy_tracker tracker(pixel_clk,vrst,track_enable,have_frame,cfg,status[23:20],displayed_frame,
      displayed_x,displayed_y,!loading,
      track_hold,track_port,track_address,cd,track_initialized,track_valid,track_held,
      track_x,track_y,track_direction,track_frame,track_done,
      debug_address,debug_data,skin_pixels,best_pixels,motion_pixels,reject_reason,analyzed_frame);
    assign pa=rpa;assign ma=rma;assign ca=track_port ? track_address:inference_address;
    assign uart_tx=1'b1;
    wire sustain_valid,sustain_request,sustain_unstable,sustain_fault;
    wire [1:0] sustain_pose;wire [7:0] link_sequence;wire link_busy;
    reg observation_event=0;reg [31:0] observation_frame=0;reg [1:0] observation_pose=0;
    wire roi_current=desired_side==displayed_side && desired_x==displayed_x && desired_y==displayed_y;
    // Register the qualified frame/pose atomically. Keep ROI permission live so
    // a key change cannot admit a delayed result from the previous region.
    always @(posedge pixel_clk)if(vrst)begin
      observation_event<=0;observation_frame<=0;observation_pose<=0;
    end else begin
      observation_event<=result_pending && terminal_current && result_payload[503:496]==1 && roi_current;
      if(result_pending && terminal_current)begin
        observation_frame<=displayed_frame;observation_pose<=result_payload[489:488];
      end
    end
    gs2_sustain_control policy(.clk(pixel_clk),.rst(vrst),
      .camera_ok(have_frame && cfg && status[23:20]==0),.observation_enable(roi_current),
      .observation_event(observation_event),.observation_frame(observation_frame),
      .observation_pose(observation_pose),.control_valid(sustain_valid),
      .sustain_request(sustain_request),.unstable(sustain_unstable),
      .camera_fault(sustain_fault),.diagnostic_pose(sustain_pose));
    wire effect_owned,effect_returning;wire [1:0] effect_axis;
    wire [7:0] effect_gain;wire signed [7:0] effect_bend;
    // Desired and displayed ROI must agree: a size key withdraws XY immediately.
    wire effect_maximum=desired_side==240 && displayed_side==240 && roi_current;
    xy_effect_control expressions(.clk(pixel_clk),.rst(vrst),.maximum_roi(effect_maximum),
      .camera_ok(have_frame && cfg && status[23:20]==0),.measurement_event(track_done),
      .track_valid(track_valid),.track_held(track_held),.measurement_frame(track_frame),
      .hand_x(track_x),.hand_y(track_y),.position_owned(effect_owned),.returning(effect_returning),
      .axis(effect_axis),.expression_gain(effect_gain),.bend_offset(effect_bend));
    gs2_ge3_sender sender(pixel_clk,vrst,sustain_valid,sustain_request,sustain_unstable,sustain_fault,
      sustain_pose,effect_owned,effect_returning,effect_axis,effect_gain,effect_bend,
      gesture_tx,link_sequence,link_busy);
    wire [23:0] rgb;wire od,oh,ov;
    p20_crop_live_render render(pixel_clk,vrst,x,y,de,hs,vs,have_frame,cfg,1'b0,status[23:20],displayed_frame,
        displayed_x,displayed_y,displayed_side,result_payload,track_enable,track_initialized,track_valid,track_x,track_y,track_direction,track_frame,track_held,sustain_valid,sustain_request,sustain_unstable,sustain_fault,rpa,rma,pd,md,rgb,od,oh,ov,
        debug_address,debug_data,skin_pixels,best_pixels,reject_reason,
        effect_owned,effect_returning,effect_axis,effect_gain,effect_bend);
    p20_hdmi_phy phy(pixel_clk,serial_clk,vrst,serializer_reset,od,oh,ov,rgb,
        tmds_clk_p,tmds_clk_n,tmds_d_p,tmds_d_n);
    reg [23:0] led_count=0;
    always @(posedge clk27)begin
        if(rst)begin led_count<=0;led_n<=1;end
        else if(led_count==13500000-1)begin led_count<=0;led_n<=!led_n;end
        else led_count<=led_count+1'b1;
    end
endmodule
