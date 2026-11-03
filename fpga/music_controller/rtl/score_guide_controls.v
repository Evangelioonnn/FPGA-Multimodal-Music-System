// Only the new settings subpages consume these actions. Existing shortcuts stay.
module score_guide_controls(input wire clk,rst,input wire [63:0] navigation,
 input wire activate,step_valid,input wire signed [1:0] step,input wire score_active,
 output reg score_toggle,output reg [2:0] score_size,output reg [1:0] score_group,output reg score_probe,
 output reg guide_start,guide_pause,guide_stop,output reg guide_loop,output reg signed [5:0] guide_transpose);
 wire [2:0] tab=navigation[2:0];wire [1:0] sub=navigation[4:3];
 wire [3:0] focus=navigation[8:5];wire edit=navigation[10]&&navigation[9];
 always @(posedge clk)begin
  if(rst)begin score_toggle<=0;score_size<=0;score_group<=0;score_probe<=0;
   guide_start<=0;guide_pause<=0;guide_stop<=0;guide_loop<=0;guide_transpose<=0;end
  else begin
   score_toggle<=0;guide_start<=0;guide_pause<=0;guide_stop<=0;
   if(tab==4&&sub==2)begin
    if(activate&&focus==0)score_toggle<=1;
    if(activate&&focus==3)score_probe<=!score_probe;
    if(step_valid&&edit)case(focus)
     1:if(!score_active)begin
      if(step>0&&score_size<4)score_size<=score_size+1'b1;
      else if(step<0&&score_size>0)score_size<=score_size-1'b1;end
     2:if(step>0)score_group<=score_group+1'b1;else if(step<0)score_group<=score_group-1'b1;
     default:begin end
    endcase
   end
   if(tab==4&&sub==3)begin
    if(activate)case(focus)
     0:guide_start<=1;1:guide_pause<=1;2:guide_stop<=1;3:guide_loop<=!guide_loop;
     default:begin end
    endcase
    if(step_valid&&edit&&focus==4)begin
     if(step>0&&guide_transpose<24)guide_transpose<=guide_transpose+1'b1;
     else if(step<0&&guide_transpose> -24)guide_transpose<=guide_transpose-1'b1;
    end
   end
  end
 end
endmodule
