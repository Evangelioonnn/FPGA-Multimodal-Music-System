// Serial shared first-order LP/HP. Q4 state retains weak signals. No sample RAM.
module bus_filter #(parameter W=18)(input wire clk,rst,in_valid,force_dry,
 input wire signed[W-1:0]in_sample,input wire[1:0]kind,input wire[3:0]cutoff,
 output reg out_valid,output reg signed[W-1:0]out_sample,output reg overrun);
 reg[3:0]state;reg[1:0]applied_kind;reg[8:0]fade,frame_fade;
 reg[16:0]alpha;reg signed[W+3:0]history,next_history;
 reg signed[W-1:0]dry;reg frame_dry;reg signed[W+4:0]difference;
 reg signed[W+21:0]product;reg signed[W:0]filtered,diff_out;
 reg signed[W+10:0]blend;
 function[16:0]coefficient;input[3:0]i;begin case(i)
 4'd0:coefficient=17'd682;
 4'd1:coefficient=17'd1020;
 4'd2:coefficient=17'd1524;
 4'd3:coefficient=17'd2189;
 4'd4:coefficient=17'd3175;
 4'd5:coefficient=17'd4544;
 4'd6:coefficient=17'd6500;
 4'd7:coefficient=17'd8762;
 4'd8:coefficient=17'd12326;
 4'd9:coefficient=17'd16906;
 4'd10:coefficient=17'd22680;
 4'd11:coefficient=17'd29417;
 4'd12:coefficient=17'd37109;
 4'd13:coefficient=17'd44051;
 4'd14:coefficient=17'd49177;
 4'd15:coefficient=17'd51840;
 endcase end endfunction
 function signed[W-1:0]sat;input signed[W+2:0]v;begin
 if(v>((32'sd1<<(W-1))-1))sat=(32'sd1<<(W-1))-1;
 else if(v<-(32'sd1<<(W-1)))sat=-(32'sd1<<(W-1));else sat=v[W-1:0];end endfunction
 always @(posedge clk)begin
  if(rst)begin state<=0;history<=0;alpha<=1024;applied_kind<=0;fade<=0;out_valid<=0;out_sample<=0;overrun<=0;dry<=0;frame_dry<=0;frame_fade<=0;end
  else begin
   out_valid<=0;if(in_valid&&state!=0)overrun<=1;
   case(state)
    0:if(in_valid)begin
      dry<=in_sample;frame_dry<=force_dry;frame_fade<=fade;
      if(alpha<coefficient(cutoff))alpha<=alpha+((coefficient(cutoff)-alpha)>32 ? (coefficient(cutoff)-alpha)>>5 : 1);
      else if(alpha>coefficient(cutoff))alpha<=alpha-((alpha-coefficient(cutoff))>32 ? (alpha-coefficient(cutoff))>>5 : 1);
      if(force_dry)begin applied_kind<=0;fade<=0;end
      else if(kind!=applied_kind)begin if(fade!=0)fade<=fade>8 ? fade-8 : 0;else applied_kind<=kind;end
      else if(kind!=0&&fade<256)fade<=fade+8;
      else if(kind==0)fade<=0;
      state<=1;
    end
    1:begin difference<=($signed({{5{dry[W-1]}},dry})<<<4)-$signed({history[W+3],history});state<=2;end
    2:begin product<=difference*$signed({1'b0,alpha});state<=3;end
    3:begin next_history<=history+(product>>>16);state<=4;end
    4:begin history<=next_history;filtered<=applied_kind==2 ? $signed({dry[W-1],dry})-(next_history>>>4) : next_history>>>4;state<=5;end
    5:begin diff_out<=filtered-$signed({dry[W-1],dry});state<=6;end
    6:begin blend<=diff_out*$signed({1'b0,frame_fade});state<=7;end
    7:begin out_sample<=frame_dry||frame_fade==0 ? dry : sat($signed({{3{dry[W-1]}},dry})+(blend>>>8));out_valid<=1;state<=0;end
    default:state<=0;
   endcase
  end
 end
endmodule
