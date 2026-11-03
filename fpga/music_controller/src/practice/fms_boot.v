// Internal original demo uses exactly the same raw-FMS validator as SD/UART.
module fms_boot(input wire clk,rst,output wire busy,output wire start,output reg abort,commit,
 output wire [31:0] size,crc,output wire byte_valid,input wire byte_ready,output wire [7:0] byte_data,
 input wire store_busy,store_done,staged,input wire [7:0] error);
 `include "fms_demo_constants.vh"
 reg [3:0] state;reg [9:0] address;
 assign busy=state!=7;assign start=state==1;assign size=DEMO_SIZE;assign crc=DEMO_CRC;
 assign byte_valid=state==4;
 fms_demo_rom rom(clk,address,byte_data);
 always @(posedge clk)begin
  if(rst)begin state<=0;address<=0;abort<=0;commit<=0;end
  else begin
   abort<=0;commit<=0;
   case(state)
    0:state<=1;
    1:state<=2;
    2:if(error!=0)begin abort<=1;state<=6;end else if(store_busy)state<=3;
    3:state<=4;
    4:if(error!=0)begin abort<=1;state<=6;end else if(byte_ready)begin
     if(address==1023)state<=5;else begin address<=address+1'b1;state<=3;end
    end
    5:if(store_done || !store_busy)begin if(staged)commit<=1;else abort<=1;state<=6;end
    6:state<=7;
   endcase
  end
 end
endmodule
