// Leased logical key state. Replays never renew the lease; only a fresh STATE does.
module bt_live_keys #(parameter LEASE_CYCLES=50000000,
 parameter CW=(LEASE_CYCLES>1?$clog2(LEASE_CYCLES+1):1))(
 input wire clk,rst,kill,new_session,safe_open,
 input wire command_valid,input wire[7:0]action,requested_preset,input wire[31:0]requested_keys,
 output reg active,output reg[24:0]keys,output reg[3:0]preset,output reg[7:0]error);
 reg[CW-1:0]remaining;
 function[2:0]count5;input[4:0]x;begin
  count5=({2'd0,x[0]}+{2'd0,x[1]})+({2'd0,x[2]}+{2'd0,x[3]})+{2'd0,x[4]};
 end endfunction
 wire[3:0]left_count={1'b0,count5(requested_keys[4:0])}+{1'b0,count5(requested_keys[9:5])};
 wire[3:0]right_count={1'b0,count5(requested_keys[14:10])}+{1'b0,count5(requested_keys[19:15])};
 wire[4:0]held_count=({1'b0,left_count}+{1'b0,right_count})+{2'd0,count5(requested_keys[24:20])};
 wire legal_preset=requested_preset==0||requested_preset==3||requested_preset==7||requested_preset==8||requested_preset==9;
 always @* begin
  error=0;
  if(action>2||requested_keys[31:25]!=0||held_count>4||((action==0||action==2)&&requested_keys!=0))error=2;
  else if(kill||new_session)error=3;
  else if(action==0)begin
   if(!legal_preset)error=2;else if(active||!safe_open)error=3;
  end else if(action==1)begin
   if(!active||remaining<=1)error=4;
   else if(requested_preset!={4'd0,preset})error=2;
  end
 end
 always @(posedge clk)begin
  if(rst||kill||new_session)begin active<=0;keys<=0;preset<=0;remaining<=0;end
  else begin
   if(active)begin
    if(remaining<=1)begin active<=0;keys<=0;remaining<=0;end
    else remaining<=remaining-1'b1;
   end
   if(command_valid&&error==0)case(action)
    0:begin active<=1;keys<=0;preset<=requested_preset[3:0];remaining<=LEASE_CYCLES;end
    1:begin keys<=requested_keys[24:0];remaining<=LEASE_CYCLES;end
    2:begin active<=0;keys<=0;remaining<=0;end
   endcase
  end
 end
endmodule
