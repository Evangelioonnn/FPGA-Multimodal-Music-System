module dcl_uart_rx #(parameter CPB=50)(input wire clk,rst,rx,
 output reg valid,output reg[7:0] data,output reg error);
 (* async_reg="true" *)reg r0=1,r1=1;reg previous=1;reg[2:0]state;reg[15:0]count;reg[2:0]bitno;reg[7:0]word;
 always @(posedge clk)begin
  r0<=rx;r1<=r0;previous<=r1;
  if(rst)begin state<=0;count<=0;valid<=0;error<=0;data<=0;word<=0;bitno<=0;end
  else begin valid<=0;error<=0;
   case(state)
    0:if(previous&&!r1)begin count<=CPB/2-1;state<=1;end
    1:if(count!=0)count<=count-1'b1;else if(!r1)begin state<=2;count<=CPB-1;bitno<=0;end else state<=0;
    2:if(count!=0)count<=count-1'b1;else begin word[bitno]<=r1;count<=CPB-1;if(bitno==7)state<=3;else bitno<=bitno+1'b1;end
    3:if(count!=0)count<=count-1'b1;else begin state<=0;if(r1)begin data<=word;valid<=1;end else error<=1;end
   endcase
  end
 end
endmodule

module dcl_uart_tx #(parameter CPB=50)(input wire clk,rst,valid,input wire[7:0]data,
 output wire ready,output wire tx);
 reg busy;reg[9:0]shift;reg[15:0]count;reg[3:0]bits;
 assign ready=!busy;assign tx=busy?shift[0]:1'b1;
 always @(posedge clk)begin
  if(rst)begin busy<=0;shift<=10'h3ff;count<=0;bits<=0;end
  else if(!busy)begin if(valid)begin busy<=1;shift<={1'b1,data,1'b0};count<=CPB-1;bits<=0;end end
  else if(count!=0)count<=count-1'b1;
  else if(bits==9)busy<=0;
  else begin shift<={1'b1,shift[9:1]};bits<=bits+1'b1;count<=CPB-1;end
 end
endmodule
