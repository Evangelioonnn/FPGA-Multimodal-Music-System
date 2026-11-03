// Generated from KEY_MAP.json. Frame bytes are GRB, max component16/255.
module board_rgb_map(input wire [24:0] keys,input wire [4:0] chase,input wire chase_mode,output wire [599:0] frame);
assign frame[0+:24]=(chase_mode ? chase==0 : keys[24]) ? 24'h100000 : 24'h000000; // LED12 / KEY36
assign frame[24+:24]=(chase_mode ? chase==1 : keys[18]) ? 24'h100000 : 24'h000000; // LED11 / KEY30
assign frame[48+:24]=(chase_mode ? chase==2 : keys[12]) ? 24'h100000 : 24'h000000; // LED10 / KEY24
assign frame[72+:24]=(chase_mode ? chase==3 : keys[6]) ? 24'h100000 : 24'h000000; // LED9 / KEY18
assign frame[96+:24]=(chase_mode ? chase==4 : keys[0]) ? 24'h100000 : 24'h000000; // LED8 / KEY12
assign frame[120+:24]=(chase_mode ? chase==5 : keys[1]) ? 24'h100000 : 24'h000000; // LED7 / KEY13
assign frame[144+:24]=(chase_mode ? chase==6 : keys[2]) ? 24'h100000 : 24'h000000; // LED18 / KEY14
assign frame[168+:24]=(chase_mode ? chase==7 : keys[3]) ? 24'h100000 : 24'h000000; // LED17 / KEY15
assign frame[192+:24]=(chase_mode ? chase==8 : keys[4]) ? 24'h100000 : 24'h000000; // LED16 / KEY16
assign frame[216+:24]=(chase_mode ? chase==9 : keys[5]) ? 24'h100000 : 24'h000000; // LED15 / KEY17
assign frame[240+:24]=(chase_mode ? chase==10 : keys[11]) ? 24'h100000 : 24'h000000; // LED14 / KEY23
assign frame[264+:24]=(chase_mode ? chase==11 : keys[10]) ? 24'h100000 : 24'h000000; // LED13 / KEY22
assign frame[288+:24]=(chase_mode ? chase==12 : keys[9]) ? 24'h100000 : 24'h000000; // LED24 / KEY21
assign frame[312+:24]=(chase_mode ? chase==13 : keys[8]) ? 24'h100000 : 24'h000000; // LED23 / KEY20
assign frame[336+:24]=(chase_mode ? chase==14 : keys[7]) ? 24'h100000 : 24'h000000; // LED22 / KEY19
assign frame[360+:24]=(chase_mode ? chase==15 : keys[17]) ? 24'h100000 : 24'h000000; // LED21 / KEY29
assign frame[384+:24]=(chase_mode ? chase==16 : keys[16]) ? 24'h100000 : 24'h000000; // LED20 / KEY28
assign frame[408+:24]=(chase_mode ? chase==17 : keys[15]) ? 24'h100000 : 24'h000000; // LED19 / KEY27
assign frame[432+:24]=(chase_mode ? chase==18 : keys[14]) ? 24'h100000 : 24'h000000; // LED30 / KEY26
assign frame[456+:24]=(chase_mode ? chase==19 : keys[13]) ? 24'h100000 : 24'h000000; // LED29 / KEY25
assign frame[480+:24]=(chase_mode ? chase==20 : keys[23]) ? 24'h100000 : 24'h000000; // LED28 / KEY35
assign frame[504+:24]=(chase_mode ? chase==21 : keys[22]) ? 24'h100000 : 24'h000000; // LED27 / KEY34
assign frame[528+:24]=(chase_mode ? chase==22 : keys[21]) ? 24'h100000 : 24'h000000; // LED26 / KEY33
assign frame[552+:24]=(chase_mode ? chase==23 : keys[20]) ? 24'h100000 : 24'h000000; // LED25 / KEY32
assign frame[576+:24]=(chase_mode ? chase==24 : keys[19]) ? 24'h100000 : 24'h000000; // LED31 / KEY31
endmodule
