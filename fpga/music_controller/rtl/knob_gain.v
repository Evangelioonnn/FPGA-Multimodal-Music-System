module knob_gain(
    input wire clk,rst,in_valid,input wire signed [15:0] in_sample,
    input wire [16:0] target,
    output reg out_valid,output reg signed [15:0] out_sample,
    output reg [16:0] gain
);
    wire [16:0] bounded=target>65536 ? 17'd65536 : target;
    wire [16:0] next_gain=gain<bounded ? (bounded-gain<=128 ? bounded : gain+17'd128) :
        (gain-bounded<=128 ? bounded : gain-17'd128);
    reg signed [33:0] product;
    reg pending;
    wire signed [33:0] scaled=product<0 ? -((-product)>>>16) : product>>>16;
    always @(posedge clk) begin
        if(rst) begin gain<=65536;product<=0;pending<=0;out_valid<=0;out_sample<=0;end
        else begin
            pending<=in_valid;out_valid<=pending;
            if(in_valid) begin gain<=next_gain;product<=in_sample*$signed({1'b0,next_gain});end
            if(pending) out_sample<=scaled[15:0];
        end
    end
endmodule

// V11: wide input through the unchanged128/sample master slew. Only here is
// the complete mix converted to PCM16. Explicit overload saturates, never wraps.
module wide_knob_gain #(parameter IN_W=18)(
 input wire clk,rst,in_valid,input wire signed [IN_W-1:0] in_sample,
 input wire [16:0] target,output reg out_valid,
 output reg signed [15:0] out_sample,output reg [16:0] gain,output reg clip);
 wire [16:0] bounded=target>65536 ? 17'd65536 : target;
 wire [16:0] next_gain=gain<bounded ? (bounded-gain<=128 ? bounded : gain+17'd128) :
  (gain-bounded<=128 ? bounded : gain-17'd128);
 reg signed [IN_W+17:0] product;reg pending;
 wire signed [IN_W+17:0] scaled=product<0 ? -((-product)>>>16) : product>>>16;
 always @(posedge clk)begin
  if(rst)begin gain<=65536;product<=0;pending<=0;out_valid<=0;out_sample<=0;clip<=0;end
  else begin
   pending<=in_valid;out_valid<=pending;clip<=0;
   if(in_valid)begin gain<=next_gain;product<=in_sample*$signed({1'b0,next_gain});end
   if(pending)begin
    if(scaled>32767)begin out_sample<=32767;clip<=1;end
    else if(scaled< -32768)begin out_sample<=-32768;clip<=1;end
    else out_sample<=scaled[15:0];
   end
  end
 end
endmodule
