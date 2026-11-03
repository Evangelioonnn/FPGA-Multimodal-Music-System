// Only source ownership. The original bank retains note/envelope semantics.
module gesture_pedal_control(input wire clk,rst,sample_ce,toggle,allowed,panic,
 input wire manual_write,manual_pedal,control_valid,request,
 input wire packet_valid,packet_control_valid,packet_request,
 output reg enabled,active,rearm,output wire effective);
 reg observed,requested;
 assign effective=active ? requested:manual_pedal;
 always @(posedge clk)begin
  if(rst)begin enabled<=0;active<=0;rearm<=0;observed<=0;requested<=0;end
  else begin
   if(enabled&&!allowed)begin rearm<=1;end
   if(enabled&&allowed&&packet_valid)begin
    observed<=1;
    if(packet_control_valid&&!packet_request)rearm<=0;
   end
   if(sample_ce)begin
    active<=enabled&&allowed&&!rearm&&observed&&control_valid;
    requested<=request;
   end
   if(toggle)begin
    enabled<=!enabled;active<=0;observed<=0;requested<=0;rearm<=!allowed;
   end
   if(manual_write)begin enabled<=0;active<=0;observed<=0;requested<=0;rearm<=0;end
   // Panic cannot enable an Off context. A simultaneous explicit disable or
   // committed manual write stays disabled; otherwise require a fresh OPEN.
   if(panic)begin
    active<=0;observed<=0;requested<=0;
    enabled<=enabled&&!toggle&&!manual_write;
    rearm<=enabled&&!toggle&&!manual_write;
   end
  end
 end
endmodule
