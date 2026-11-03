// Independent-component bench sharing the product's reverb, master and DAC.
// Entry is explicit and requires a stopped/quiet instrument. Recordings stay intact.
// Fixed gain is independent of active component count. No active-count AGC.
module scoring_session #(
 parameter N=512,SHARED_MEMORY=0, AW=$clog2(N), CW=$clog2(N+1)
)(input wire clk,rst,sample_ce,toggle_request,safe_enter,panic,
 input wire [2:0] requested_size,input wire [1:0] requested_group,input wire probe,
 output reg active,output wire out_valid,output wire signed [15:0] out_sample,
 output wire [127:0] status,
 output wire [31:0] backend_phase,output wire [15:0] backend_env,
 input wire signed [47:0] backend_sum_next,output wire backend_accumulate,
 input wire shared_score_owner,
 output wire shared_score_read,output wire[8:0]shared_score_ra,
 input wire[47:0]shared_score_state,shared_score_control,
 output wire shared_score_state_we,output wire[8:0]shared_score_state_wa,output wire[47:0]shared_score_state_wd,
 output wire shared_score_control_we,output wire[8:0]shared_score_control_wa,output wire[47:0]shared_score_control_wd,
 output wire shared_score_ready
);
 wire init_done,busy,frame_valid,ready,deadline;
 wire signed [47:0] raw_sum;wire [CW-1:0] nonzero;
 wire [15:0] cycles;
 reg configuring,first_config,closing,denied;
 reg [AW-1:0] index;reg [2:0] size;reg [1:0] group;reg probe_applied;
 reg [15:0] peak;reg clip_seen;reg [15:0] change_sequence;
 wire [15:0] configured=16'd32<<(active ? size : requested_size);
 wire selected=index<configured && (group==0 || (group==1 && !index[0]) ||
   (group==2 && index[0]) || (group==3 && index==0));
 // Coherent 65536-sample bins, distinct frequencies below Nyquist at every size.
 wire [31:0] bin=32'd91+index*32'd7+((probe_applied&&index==0) ? 32'd3 : 32'd0);
 wire [31:0] frequency=bin<<16;
 wire [31:0] initial_phase={index,{(32-AW){1'b0}}};
 localparam NORMALIZE=15+$clog2(N);
 wire signed [47:0] scaled=raw_sum<0 ? -((-raw_sum)>>>NORMALIZE) : raw_sum>>>NORMALIZE;
 wire clipped=scaled>32767 || scaled< -32768;
 assign out_sample=scaled>32767 ? 16'sh7fff : scaled< -32768 ? 16'sh8000 : scaled[15:0];
 assign out_valid=active&&frame_valid;
 // Diagnostics trail output by two50MHz clocks. The audio data/valid path is
 // unchanged; do not chain48-bit scaling, absolute value and peak compare.
 reg signed [15:0] diagnostic_sample;
 reg [15:0] absolute_sample;
 reg diagnostic_valid,absolute_valid,diagnostic_clip,absolute_clip;
 always @(posedge clk)begin
  diagnostic_sample<=out_sample;diagnostic_clip<=clipped;
  absolute_sample<=diagnostic_sample<0 ? -diagnostic_sample : diagnostic_sample;
  absolute_clip<=diagnostic_clip;
  if(rst)begin diagnostic_valid<=0;absolute_valid<=0;end
  else begin diagnostic_valid<=out_valid;absolute_valid<=diagnostic_valid;end
 end
 wire [15:0] nonzero16=nonzero;
 localparam [15:0] CAPACITY=N;
 assign status={change_sequence,peak,16'd1040,CAPACITY,cycles,nonzero16,configured,
   4'd0,probe_applied,group,3'd0,denied,clip_seen,deadline,configuring,closing,active};
 scoring_partial_compact #(.N(N),.SHARED_MEMORY(SHARED_MEMORY)) engine(.clk(clk),.rst(rst),.sample_ce(sample_ce&&active&&init_done),
  .cfg_valid(configuring),.cfg_ready(ready),.cfg_index(index),.cfg_retrigger(first_config),
  .cfg_phase(initial_phase),.cfg_freq(frequency),.cfg_env(16'd0),
  .cfg_target((!closing&&selected) ? 16'd32768 : 16'd0),.global_attack(16'd128),.global_release(16'd128),
  .init_done(init_done),.busy(busy),.frame_valid(frame_valid),.sample_sum(raw_sum),
  .active_count(nonzero),.render_cycles(cycles),.deadline_miss(deadline),.backend_phase(backend_phase),.backend_env(backend_env),
  .backend_sum_next(backend_sum_next),.backend_accumulate(backend_accumulate),.shared_score_owner(shared_score_owner),.shared_score_read(shared_score_read),.shared_score_ra(shared_score_ra),.shared_score_state(shared_score_state),.shared_score_control(shared_score_control),.shared_score_state_we(shared_score_state_we),.shared_score_state_wa(shared_score_state_wa),.shared_score_state_wd(shared_score_state_wd),.shared_score_control_we(shared_score_control_we),.shared_score_control_wa(shared_score_control_wa),.shared_score_control_wd(shared_score_control_wd),.shared_score_ready(shared_score_ready));
 always @(posedge clk) begin
  if(rst)begin
   active<=0;configuring<=0;first_config<=0;closing<=0;denied<=0;index<=0;
   size<=0;group<=0;probe_applied<=0;peak<=0;clip_seen<=0;change_sequence<=0;
  end else begin
   if(absolute_valid)begin
    if(absolute_sample>peak)peak<=absolute_sample;
    if(absolute_clip)clip_seen<=1;
   end
   if(toggle_request&&!active) begin
    if(safe_enter&&init_done)begin
     active<=1;closing<=0;configuring<=1;first_config<=1;index<=0;denied<=0;
     size<=requested_size>($clog2(N)-5) ? ($clog2(N)-5) : requested_size;group<=requested_group;probe_applied<=probe;
     peak<=0;clip_seen<=0;change_sequence<=change_sequence+1'b1;
    end else denied<=1;
   end else if((toggle_request||panic)&&active&&!closing)begin
    closing<=1;configuring<=1;first_config<=0;index<=0;
   end else if(active&&!closing&&!configuring&&
    (group!=requested_group || probe_applied!=probe))begin
    configuring<=1;first_config<=0;index<=0;group<=requested_group;probe_applied<=probe;
    change_sequence<=change_sequence+1'b1;
   end else if(configuring&&ready)begin
    if(index==N-1)begin configuring<=0;first_config<=0;end
    else index<=index+1'b1;
   end
   if(closing&&!configuring&&frame_valid&&nonzero==0)begin active<=0;closing<=0;end
  end
 end
endmodule
