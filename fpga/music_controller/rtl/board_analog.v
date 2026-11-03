// Coherent ADC scans feed seven targets. Smoothing runs at audio sample_ce.
module board_analog #(parameter SLEW=16,JITTER=4,DEADZONE=96,STALE_CYCLES=250000)(
 input wire clk,rst,sample_ce,scan_valid,calibrate,input wire [95:0] scan_data,
 output wire scan_ready,output reg [95:0] raw,
 output wire [83:0] smooth,output reg [23:0] centers,
 output reg [31:0] scans,output wire stale,
 output wire signed [4:0] bend,output wire [6:0] vibrato,
 output wire signed [12:0] x_expression,y_expression);
 reg [11:0] target[0:6],filtered[0:6];reg [31:0] age;
 integer i;reg [12:0] delta;
 assign scan_ready=!rst;assign stale=age>=STALE_CYCLES;
 genvar g;generate for(g=0;g<7;g=g+1) begin: values
  assign smooth[g*12+:12]=filtered[g];
 end endgenerate
 // Two real clocks isolate calibration/subtraction from command arbitration.
 // Raw scans and smoothing keep their old timing; expression is delayed40ns.
 reg signed [12:0] dx,dy;
 reg signed [12:0] x_q,y_q;
 reg signed [4:0] bend_q;reg [6:0] vibrato_q;
 wire [12:0] ax=dx<0 ? -dx : dx,ay=dy<0 ? -dy : dy;
 assign x_expression=x_q;assign y_expression=y_q;
 wire [12:0] bend_mag=ax<=DEADZONE ? 0 : (ax-DEADZONE+127)>>8;
 wire [4:0] bounded_bend=bend_mag>8 ? 5'd8 : bend_mag[4:0];
 assign bend=bend_q;
 wire [12:0] vib_mag=ay<=DEADZONE ? 0 : (ay-DEADZONE)>>5;
 assign vibrato=vibrato_q;
 always @(posedge clk)begin
  if(rst)begin dx<=0;dy<=0;x_q<=0;y_q<=0;bend_q<=0;vibrato_q<=0;end
  else begin
   dx<=$signed({1'b0,filtered[5]})-$signed({1'b0,centers[11:0]});
   dy<=$signed({1'b0,filtered[6]})-$signed({1'b0,centers[23:12]});
   x_q<=ax<=DEADZONE ? 13'sd0 : dx;y_q<=ay<=DEADZONE ? 13'sd0 : dy;
   bend_q<=dx<0 ? -$signed(bounded_bend) : $signed(bounded_bend);
   vibrato_q<=vib_mag>64 ? 7'd64 : vib_mag[6:0];
  end
 end
 always @(posedge clk) begin
  if(rst) begin
   raw<=0;scans<=0;age<=STALE_CYCLES;centers<={12'd2048,12'd2048};
   for(i=0;i<7;i=i+1) begin target[i]<=i>=5 ? 2048 : 0;filtered[i]<=i>=5 ? 2048 : 0;end
  end else begin
   if(age<STALE_CYCLES) age<=age+1'b1;
   if(scan_valid && scan_ready) begin
    raw<=scan_data;scans<=scans+1'b1;age<=0;
    for(i=0;i<7;i=i+1) begin
     delta=scan_data[i*12+:12]>target[i] ? scan_data[i*12+:12]-target[i] : target[i]-scan_data[i*12+:12];
     if(delta>=JITTER) target[i]<=scan_data[i*12+:12];
    end
   end
   if(calibrate && scans!=0 && !stale) centers<=raw[83:60];
   if(sample_ce) for(i=0;i<7;i=i+1) begin
    if(filtered[i]<target[i]) filtered[i]<=target[i]-filtered[i]>SLEW ? filtered[i]+SLEW : target[i];
    else if(filtered[i]>target[i]) filtered[i]<=filtered[i]-target[i]>SLEW ? filtered[i]-SLEW : target[i];
   end
  end
 end
endmodule
