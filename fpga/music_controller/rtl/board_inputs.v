// Input-only logical adapter. Physical rows use 0/Z in the board top.
module board_inputs #(parameter ROW_CYCLES=2500,DEBOUNCE_FRAMES=4,
    ENC_CYCLES=2500,BUTTON_SAMPLES=60,LONG_CYCLES=50000000)(
 input wire clk,rst,input wire [5:0] col_n,output wire [5:0] row_low,
 input wire [2:0] enc_a,enc_b,enc_button_n,
 output wire [35:0] matrix_keys,output wire frame_valid,changed,
 output wire [24:0] performance_keys,output wire [10:0] function_keys,
 output wire [2:0] step_valid,pressed,short_press,long_press,invalid_transition,
 output wire [5:0] steps,output wire [47:0] positions,output wire performance_released);
 wire ghost,all_released;wire [2:0] button_changed;
 matrix_scanner #(.ROWS(6),.COLS(6),.ROW_CYCLES(ROW_CYCLES),
  .DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),.HAS_DIODES(1),.DEBOUNCED_RELEASE_MASK(36'h001ffffff)) scanner(
  .clk(clk),.rst(rst),.col_n(col_n),.row_low(row_low),.keys(matrix_keys),
  .frame_valid(frame_valid),.changed(changed),.ghost(ghost),.all_released(all_released));
 // The scanner commits this bit on the same edge as matrix_keys[24:0].
 assign performance_released=all_released;
 // Frozen R3 net map: KEY12..KEY36 are performance identity indices0..24; pitch layout is configurable.
 assign function_keys[0]=matrix_keys[27]; // KEY1
 assign function_keys[1]=matrix_keys[25]; // KEY2
 assign function_keys[2]=matrix_keys[26]; // KEY3
 assign function_keys[3]=matrix_keys[28]; // KEY4
 assign function_keys[4]=matrix_keys[29]; // KEY5
 assign function_keys[5]=matrix_keys[30]; // KEY6
 assign function_keys[6]=matrix_keys[31]; // KEY7
 assign function_keys[7]=matrix_keys[32]; // KEY8
 assign function_keys[8]=matrix_keys[33]; // KEY9
 assign function_keys[9]=matrix_keys[34]; // KEY10
 assign function_keys[10]=matrix_keys[35]; // KEY11
 assign performance_keys[0]=matrix_keys[0]; // KEY12
 assign performance_keys[1]=matrix_keys[1]; // KEY13
 assign performance_keys[2]=matrix_keys[2]; // KEY14
 assign performance_keys[3]=matrix_keys[3]; // KEY15
 assign performance_keys[4]=matrix_keys[4]; // KEY16
 assign performance_keys[5]=matrix_keys[5]; // KEY17
 assign performance_keys[6]=matrix_keys[6]; // KEY18
 assign performance_keys[7]=matrix_keys[7]; // KEY19
 assign performance_keys[8]=matrix_keys[8]; // KEY20
 assign performance_keys[9]=matrix_keys[9]; // KEY21
 assign performance_keys[10]=matrix_keys[10]; // KEY22
 assign performance_keys[11]=matrix_keys[11]; // KEY23
 assign performance_keys[12]=matrix_keys[12]; // KEY24
 assign performance_keys[13]=matrix_keys[13]; // KEY25
 assign performance_keys[14]=matrix_keys[14]; // KEY26
 assign performance_keys[15]=matrix_keys[15]; // KEY27
 assign performance_keys[16]=matrix_keys[16]; // KEY28
 assign performance_keys[17]=matrix_keys[17]; // KEY29
 assign performance_keys[18]=matrix_keys[18]; // KEY30
 assign performance_keys[19]=matrix_keys[19]; // KEY31
 assign performance_keys[20]=matrix_keys[20]; // KEY32
 assign performance_keys[21]=matrix_keys[21]; // KEY33
 assign performance_keys[22]=matrix_keys[22]; // KEY34
 assign performance_keys[23]=matrix_keys[23]; // KEY35
 assign performance_keys[24]=matrix_keys[24]; // KEY36
 genvar g;
 generate for(g=0;g<3;g=g+1) begin: encoders
  reg [25:0] duration;reg fired;reg short_q,long_q;reg signed [15:0] position;
  assign short_press[g]=short_q;assign long_press[g]=long_q;
  assign positions[g*16+:16]=position;
  board_ec11 #(.SAMPLE_CYCLES(ENC_CYCLES),.AB_SAMPLES(2),.BUTTON_SAMPLES(BUTTON_SAMPLES)) filter(
   .clk(clk),.rst(rst),.a(enc_a[g]),.b(enc_b[g]),.button_n(enc_button_n[g]),
   .step_valid(step_valid[g]),.step(steps[g*2+:2]),.pressed(pressed[g]),
   .button_changed(button_changed[g]),.invalid_transition(invalid_transition[g]));
  always @(posedge clk) begin
   if(rst) begin duration<=0;fired<=0;short_q<=0;long_q<=0;position<=0;end
   else begin
    short_q<=0;long_q<=0;
    if(step_valid[g]) position<=position+$signed(steps[g*2+:2]);
    if(pressed[g]) begin
     if(!fired) begin
      if(duration==LONG_CYCLES-1) begin long_q<=1;fired<=1;end
      else duration<=duration+1'b1;
     end
    end else begin
     if(button_changed[g] && !fired) short_q<=1;
     duration<=0;fired<=0;
    end
   end
  end
 end endgenerate
endmodule
