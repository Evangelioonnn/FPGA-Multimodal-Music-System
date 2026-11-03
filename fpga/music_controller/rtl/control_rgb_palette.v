module control_rgb_palette(input wire [24:0] keys,input wire [3:0] timbre,output reg [599:0] frame);
 wire [599:0] mapped;board_rgb_map map(keys,5'd0,1'b0,mapped);
 reg [23:0] base,pressed;integer i;
 always @* begin
  case(timbre) // SK6812 GRB: dim base, contrasting held keys.
   0:begin base=24'h020004;pressed=24'h001810;end
   3:begin base=24'h030200;pressed=24'h000818;end
   4:begin base=24'h000302;pressed=24'h180008;end
   5:begin base=24'h000203;pressed=24'h180c00;end
   6:begin base=24'h020300;pressed=24'h001018;end
   7:begin base=24'h040000;pressed=24'h001018;end
   8:begin base=24'h000400;pressed=24'h180010;end
   9:begin base=24'h030003;pressed=24'h001800;end
   10:begin base=24'h010304;pressed=24'h180800;end
   default:begin base=24'h010101;pressed=24'h101010;end
  endcase
  for(i=0;i<25;i=i+1) frame[i*24+:24]=mapped[i*24+:24]!=0 ? pressed : base;
 end
endmodule
