// Reset is released with both serializer clocks stopped. At 50 MHz each
// guard is 320 ns: far longer than clock-gate latency and reset routing.
module av_serializer_start(input wire clk, input wire rst,
 output wire clocks_enable, output reg serializer_reset=1,
 output wire pixel_clocks_enable);
 // Separate preserved50MHz drivers for two physically distinct clock gates.
 // Both bits make exactly the same transitions; no delay/clock/guard change.
 (* syn_preserve=1, syn_keep=1 *)reg clocks_enable_q=0;
 (* syn_preserve=1, syn_keep=1 *)reg pixel_enable_q=0;
 assign clocks_enable=clocks_enable_q;
 assign pixel_clocks_enable=pixel_enable_q;
 reg [5:0] wait_count=0;
 always @(posedge clk or posedge rst) begin
  if(rst) begin wait_count<=0;clocks_enable_q<=0;pixel_enable_q<=0;serializer_reset<=1;end
  else if(!clocks_enable_q) begin
   wait_count<=wait_count+1'b1;
   if(wait_count==6'd15) serializer_reset<=0;
   if(wait_count==6'd31) begin clocks_enable_q<=1;pixel_enable_q<=1;end
  end
 end
endmodule
