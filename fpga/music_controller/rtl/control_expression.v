// Live expression supports preset4 and family7. UI browse masks the joystick only.
// EDIT depth is retained separately, so a centered/stale joystick cannot erase it.
module control_expression(input wire [2:0] preset,input wire stale,
 input wire signed [4:0] joystick_bend,input wire [6:0] joystick_vibrato,base_depth,
 output wire signed [4:0] bend,output wire [6:0] depth);
 assign bend=(preset==4||preset==7||preset==1)&&!stale ? joystick_bend : 5'sd0;
 assign depth=(preset!=4&&preset!=7&&preset!=1) ? 7'd0 : !stale&&joystick_vibrato>base_depth ? joystick_vibrato : base_depth;
endmodule
