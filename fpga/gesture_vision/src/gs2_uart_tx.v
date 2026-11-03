module gs2_uart_tx #(parameter CLK_HZ=74250000,BAUD=115200)(
 input clk,rst,input[7:0]data,input valid,output wire ready,output reg tx);
 localparam DIV=(CLK_HZ+BAUD/2)/BAUD;
 reg busy;reg[9:0]shift;reg[15:0]count;reg[3:0]bit_index;
 assign ready=!busy;
 always @(posedge clk)begin
  if(rst)begin busy<=0;shift<=1023;count<=0;bit_index<=0;tx<=1;end
  else if(!busy)begin
   tx<=1;
   if(valid)begin shift<={1'b1,data,1'b0};count<=DIV-1;bit_index<=0;busy<=1;tx<=0;end
  end else if(count==0)begin
   count<=DIV-1;shift<={1'b1,shift[9:1]};
   if(bit_index==9)begin busy<=0;tx<=1;end
   else begin bit_index<=bit_index+1'b1;tx<=shift[1];end
  end else count<=count-1'b1;
 end
endmodule
