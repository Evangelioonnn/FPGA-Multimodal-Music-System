// R3 identity -> proposed chromatic order. Verify on physical board.
module control_key_map(input wire [24:0] identity,output wire [24:0] pitch);
assign pitch[0]=identity[19]; // KEY31
assign pitch[1]=identity[24]; // KEY36
assign pitch[2]=identity[20]; // KEY32
assign pitch[3]=identity[18]; // KEY30
assign pitch[4]=identity[21]; // KEY33
assign pitch[5]=identity[22]; // KEY34
assign pitch[6]=identity[12]; // KEY24
assign pitch[7]=identity[23]; // KEY35
assign pitch[8]=identity[6]; // KEY18
assign pitch[9]=identity[13]; // KEY25
assign pitch[10]=identity[0]; // KEY12
assign pitch[11]=identity[14]; // KEY26
assign pitch[12]=identity[15]; // KEY27
assign pitch[13]=identity[1]; // KEY13
assign pitch[14]=identity[16]; // KEY28
assign pitch[15]=identity[2]; // KEY14
assign pitch[16]=identity[17]; // KEY29
assign pitch[17]=identity[7]; // KEY19
assign pitch[18]=identity[3]; // KEY15
assign pitch[19]=identity[8]; // KEY20
assign pitch[20]=identity[4]; // KEY16
assign pitch[21]=identity[9]; // KEY21
assign pitch[22]=identity[5]; // KEY17
assign pitch[23]=identity[10]; // KEY22
assign pitch[24]=identity[11]; // KEY23
endmodule
