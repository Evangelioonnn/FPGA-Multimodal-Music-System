// Pitch -> identity -> actual LED chain. Reuses exactly the verified chain map.
module control_guide_rgb(input wire [24:0] pressed_identity,current_pitch,next_pitch,
 input wire [599:0] normal_frame,output reg [599:0] frame);
 reg [24:0] current_identity,next_identity;
 wire [599:0] current_mapped,next_mapped,pressed_mapped;integer i;
 function integer identity;input integer pitch;begin case(pitch)
  0:identity=19;1:identity=24;2:identity=20;3:identity=18;4:identity=21;
  5:identity=22;6:identity=12;7:identity=23;8:identity=6;9:identity=13;
  10:identity=0;11:identity=14;12:identity=15;13:identity=1;14:identity=16;
  15:identity=2;16:identity=17;17:identity=7;18:identity=3;19:identity=8;
  20:identity=4;21:identity=9;22:identity=5;23:identity=10;default:identity=11;
 endcase end endfunction
 always @*begin
  current_identity=0;next_identity=0;
  for(i=0;i<25;i=i+1)begin current_identity[identity(i)]=current_pitch[i];next_identity[identity(i)]=next_pitch[i];end
 end
 board_rgb_map cur(current_identity,5'd0,1'b0,current_mapped);
 board_rgb_map nxt(next_identity,5'd0,1'b0,next_mapped);
 board_rgb_map pressed(pressed_identity,5'd0,1'b0,pressed_mapped);
 always @*begin
  frame=normal_frame;
  for(i=0;i<25;i=i+1)begin
   if(pressed_mapped[i*24+:24]!=0) frame[i*24+:24]=24'h001818;
   else if(current_mapped[i*24+:24]!=0)frame[i*24+:24]=24'h180000;
   else if(next_mapped[i*24+:24]!=0)frame[i*24+:24]=24'h000008;
  end
 end
endmodule
