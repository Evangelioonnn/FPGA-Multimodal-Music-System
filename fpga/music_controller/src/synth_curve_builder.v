// Fixed-scale ideal periodic preview, excludes envelope, master and effects.
// One read port, one shared multiplier, small preview ROM; never drives audio.
module synth_curve_builder(input wire clk,rst,start,input wire ab,
 input wire [63:0] synth_status,input wire [35:0] coefficients,
 output reg wr_en,output reg [7:0] wr_addr,output reg [23:0] wr_data,output reg done);
 reg [4:0] state;reg [7:0] point;reg [1:0] partial,a,b;
 reg mode;reg [16:0] mix;reg [35:0] coeffs;
 reg [9:0] address;wire signed [15:0] data;
 preview_wave_rom rom(clk,address,data);
 reg signed [15:0] table_a,table_b;
 reg signed [17:0] operand,factor;wire signed [35:0] product=operand*factor;
 reg signed [35:0] sum;wire [7:0] next_phase=point*(partial+8'd2);
 wire signed [35:0] rounded=product<0 ? -(((-product)+32768)>>>16) : (product+32768)>>>16;
 wire signed [36:0] mixed=$signed({{21{table_a[15]}},table_a})+$signed({rounded[35],rounded});
 wire signed [35:0] total=sum+product;
 always @(posedge clk) begin
  if(rst) begin state<=0;point<=0;partial<=0;a<=0;b<=0;mode<=0;mix<=0;coeffs<=0;
   address<=0;table_a<=0;table_b<=0;operand<=0;factor<=0;sum<=0;wr_en<=0;wr_addr<=0;wr_data<=0;done<=0;end
  else begin wr_en<=0;done<=0;
   case(state)
    0:if(start) begin point<=0;a<=synth_status[1:0];b<=synth_status[3:2];mix<=synth_status[32:16];
     coeffs<=coefficients;mode<=ab;state<=1;end
    1:begin partial<=0;sum<=0;address<=mode ? {a,point} : {2'd0,point};state<=2;end
    2:state<=3;
    3:if(mode) begin table_a<=data;address<={b,point};state<=4;end
      else begin operand<=data;factor<=$signed({1'b0,coeffs[partial*9+:9]});state<=7;end
    4:state<=5;
    5:begin table_b<=data;operand<=$signed({data[15],data})-$signed({table_a[15],table_a});factor<=$signed({1'b0,mix});state<=6;end
    6:begin wr_en<=1;wr_addr<=point;wr_data<={mixed[15:8],table_b[15:8],table_a[15:8]};state<=8;end
    7:begin sum<=total;
     if(partial==3) begin wr_en<=1;wr_addr<=point;wr_data<={total[25:18],12'd0,point<coeffs[35:27],point<coeffs[26:18],point<coeffs[17:9],point<coeffs[8:0]};state<=8;end
     else begin partial<=partial+1'b1;address<={2'd0,next_phase};state<=2;end
    end
    8:if(point==255) begin done<=1;state<=0;end else begin point<=point+1'b1;state<=1;end
    default:state<=0;
   endcase
  end
 end
endmodule
