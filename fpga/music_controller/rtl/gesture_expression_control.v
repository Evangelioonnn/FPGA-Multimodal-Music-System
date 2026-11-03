// Independent GE3 lease/rearm. A fresh neutral snapshot is needed after withdrawal.
module gesture_expression_control(input wire clk,rst,enabled,allowed,panic,
 input wire linked,packet_valid,position_owned,returning,
 input wire[7:0]gain,input wire signed[7:0]bend,
 output wire active,output reg rearm,output wire[6:0]depth,
 output wire signed[7:0]bend_applied);
 reg seen;
 wire[8:0]inverse_gain=9'd256-{1'b0,gain};
 assign active=enabled&&allowed&&!panic&&!rearm&&seen&&linked&&(position_owned||returning);
 assign depth=active ? inverse_gain[7:1]:7'd0;
 assign bend_applied=active ? bend:8'sd0;
 always @(posedge clk)begin
  if(rst)begin rearm<=1;seen<=0;end
  else if(!enabled||!allowed||panic||!linked)begin rearm<=1;seen<=0;end
  else if(packet_valid)begin
   seen<=1;
   if(gain==255&&bend==0)rearm<=0;
  end
 end
endmodule
