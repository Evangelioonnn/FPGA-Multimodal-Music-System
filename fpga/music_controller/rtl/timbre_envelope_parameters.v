// V15: three local envelope banks, separate from live harmonic/expression state.
// Values are amplitude steps per sample (A/D/R) and unsigned level (S).
// commit is already gated to the authoritative audio sample boundary.
module timbre_envelope_parameters(
 input wire clk,rst,reset_all,
 input wire [2:0] selected_preset,query_preset,
 input wire custom_hold,input wire [1:0] lead_attack_index,
 input wire [2:0] release_index,
 input wire commit,input wire [1:0] item,operation,input wire [15:0] value,
 output wire supported,output wire [3:0] edited,
 output wire [63:0] selected_adsr,query_adsr,
 output wire operation_legal
);
 reg [63:0] piano_values,lead_values,custom_values;
 reg [3:0] piano_mask,lead_mask,custom_mask;
 assign supported=selected_preset==0||selected_preset==4||selected_preset==5;
 assign edited=selected_preset==0 ? piano_mask : selected_preset==4 ? lead_mask : selected_preset==5 ? custom_mask : 4'd0;
 function [15:0] release_rate;input [2:0] index;
 begin case(index)0:release_rate=96;1:release_rate=48;2:release_rate=24;3:release_rate=12;
  4:release_rate=6;5:release_rate=3;6:release_rate=2;default:release_rate=1;endcase end endfunction
 function [15:0] rate;input [3:0] grade;
 begin case(grade)
  0:rate=2048;1:rate=1024;2:rate=512;3:rate=256;4:rate=128;5:rate=96;6:rate=68;7:rate=48;
  8:rate=24;9:rate=16;10:rate=12;11:rate=6;12:rate=4;13:rate=3;14:rate=2;default:rate=1;
 endcase end endfunction
 function [3:0] grade;input [15:0] raw;
 begin
  if(raw>=2048)grade=0;else if(raw>=1024)grade=1;else if(raw>=512)grade=2;else if(raw>=256)grade=3;
  else if(raw>=128)grade=4;else if(raw>=96)grade=5;else if(raw>=68)grade=6;else if(raw>=48)grade=7;
  else if(raw>=24)grade=8;else if(raw>=16)grade=9;else if(raw>=12)grade=10;else if(raw>=6)grade=11;
  else if(raw>=4)grade=12;else if(raw>=3)grade=13;else if(raw>=2)grade=14;else grade=15;
 end endfunction
 // No divider or multiplier in the audio path. Percent display rounds to the
 // nearest integer; a first user increment deliberately enters the 1% grid.
 function [6:0] percent;input [15:0] raw;reg [22:0] scaled;
 begin scaled=({7'd0,raw}<<6)+({7'd0,raw}<<5)+({7'd0,raw}<<2)+23'd32768;
  percent=scaled[22:16];end endfunction
 function [15:0] percent_raw;input[6:0]p;
 begin case(p)
  7'd0:percent_raw=16'd0;
  7'd1:percent_raw=16'd655;
  7'd2:percent_raw=16'd1311;
  7'd3:percent_raw=16'd1966;
  7'd4:percent_raw=16'd2621;
  7'd5:percent_raw=16'd3277;
  7'd6:percent_raw=16'd3932;
  7'd7:percent_raw=16'd4587;
  7'd8:percent_raw=16'd5243;
  7'd9:percent_raw=16'd5898;
  7'd10:percent_raw=16'd6554;
  7'd11:percent_raw=16'd7209;
  7'd12:percent_raw=16'd7864;
  7'd13:percent_raw=16'd8520;
  7'd14:percent_raw=16'd9175;
  7'd15:percent_raw=16'd9830;
  7'd16:percent_raw=16'd10486;
  7'd17:percent_raw=16'd11141;
  7'd18:percent_raw=16'd11796;
  7'd19:percent_raw=16'd12452;
  7'd20:percent_raw=16'd13107;
  7'd21:percent_raw=16'd13762;
  7'd22:percent_raw=16'd14418;
  7'd23:percent_raw=16'd15073;
  7'd24:percent_raw=16'd15728;
  7'd25:percent_raw=16'd16384;
  7'd26:percent_raw=16'd17039;
  7'd27:percent_raw=16'd17694;
  7'd28:percent_raw=16'd18350;
  7'd29:percent_raw=16'd19005;
  7'd30:percent_raw=16'd19661;
  7'd31:percent_raw=16'd20316;
  7'd32:percent_raw=16'd20971;
  7'd33:percent_raw=16'd21627;
  7'd34:percent_raw=16'd22282;
  7'd35:percent_raw=16'd22937;
  7'd36:percent_raw=16'd23593;
  7'd37:percent_raw=16'd24248;
  7'd38:percent_raw=16'd24903;
  7'd39:percent_raw=16'd25559;
  7'd40:percent_raw=16'd26214;
  7'd41:percent_raw=16'd26869;
  7'd42:percent_raw=16'd27525;
  7'd43:percent_raw=16'd28180;
  7'd44:percent_raw=16'd28835;
  7'd45:percent_raw=16'd29491;
  7'd46:percent_raw=16'd30146;
  7'd47:percent_raw=16'd30801;
  7'd48:percent_raw=16'd31457;
  7'd49:percent_raw=16'd32112;
  7'd50:percent_raw=16'd32768;
  7'd51:percent_raw=16'd33423;
  7'd52:percent_raw=16'd34078;
  7'd53:percent_raw=16'd34734;
  7'd54:percent_raw=16'd35389;
  7'd55:percent_raw=16'd36044;
  7'd56:percent_raw=16'd36700;
  7'd57:percent_raw=16'd37355;
  7'd58:percent_raw=16'd38010;
  7'd59:percent_raw=16'd38666;
  7'd60:percent_raw=16'd39321;
  7'd61:percent_raw=16'd39976;
  7'd62:percent_raw=16'd40632;
  7'd63:percent_raw=16'd41287;
  7'd64:percent_raw=16'd41942;
  7'd65:percent_raw=16'd42598;
  7'd66:percent_raw=16'd43253;
  7'd67:percent_raw=16'd43908;
  7'd68:percent_raw=16'd44564;
  7'd69:percent_raw=16'd45219;
  7'd70:percent_raw=16'd45875;
  7'd71:percent_raw=16'd46530;
  7'd72:percent_raw=16'd47185;
  7'd73:percent_raw=16'd47841;
  7'd74:percent_raw=16'd48496;
  7'd75:percent_raw=16'd49151;
  7'd76:percent_raw=16'd49807;
  7'd77:percent_raw=16'd50462;
  7'd78:percent_raw=16'd51117;
  7'd79:percent_raw=16'd51773;
  7'd80:percent_raw=16'd52428;
  7'd81:percent_raw=16'd53083;
  7'd82:percent_raw=16'd53739;
  7'd83:percent_raw=16'd54394;
  7'd84:percent_raw=16'd55049;
  7'd85:percent_raw=16'd55705;
  7'd86:percent_raw=16'd56360;
  7'd87:percent_raw=16'd57015;
  7'd88:percent_raw=16'd57671;
  7'd89:percent_raw=16'd58326;
  7'd90:percent_raw=16'd58982;
  7'd91:percent_raw=16'd59637;
  7'd92:percent_raw=16'd60292;
  7'd93:percent_raw=16'd60948;
  7'd94:percent_raw=16'd61603;
  7'd95:percent_raw=16'd62258;
  7'd96:percent_raw=16'd62914;
  7'd97:percent_raw=16'd63569;
  7'd98:percent_raw=16'd64224;
  7'd99:percent_raw=16'd64880;
  7'd100:percent_raw=16'd65535;
  default:percent_raw=16'd65535;
 endcase end endfunction
 function [63:0] resolve;input [2:0] preset;input hold_mode;
 input [63:0] values;input [3:0] mask;
 reg held_shape;reg [63:0] defaults;integer k;
 begin
  held_shape=preset==4||(preset==5&&hold_mode);
  defaults[15:0]=held_shape ? 16'd512 : 16'd68;
  defaults[31:16]=held_shape ? 16'd2 : 16'd6;
  defaults[47:32]=held_shape ? 16'd56000 : 16'd32768;
  defaults[63:48]=preset==4 ? 16'd24 : 16'd3;
  for(k=0;k<4;k=k+1)resolve[k*16+:16]=mask[k] ? values[k*16+:16] : defaults[k*16+:16];
 end endfunction
 assign selected_adsr=resolve(selected_preset,custom_hold,
  selected_preset==0 ? piano_values : selected_preset==4 ? lead_values : custom_values,edited);
 assign query_adsr=resolve(query_preset,custom_hold,
  query_preset==0 ? piano_values : query_preset==4 ? lead_values : custom_values,
  query_preset==0 ? piano_mask : query_preset==4 ? lead_mask : query_preset==5 ? custom_mask : 4'd0);
 wire [15:0] current=selected_adsr[item*16+:16];
 wire [3:0] current_grade=grade(current);
 wire [6:0] current_percent=percent(current);
 wire up=!value[15];
 wire [3:0] next_grade=up ? (current_grade==15 ? 4'd15 : current_grade+4'd1) :
  (current_grade==0 ? 4'd0 : current_grade-4'd1);
 wire [6:0] next_percent=up ? (current_percent>=100 ? 7'd100 : current_percent+7'd1) :
  (current_percent==0 ? 7'd0 : current_percent-7'd1);
 wire [15:0] write_value=operation==3 ? (item==2 ? percent_raw(next_percent) : rate(next_grade)) : value;
 assign operation_legal=supported && (operation==0 ? (item==2||value!=0) :
  operation==3 ? (value==16'd1||value==16'hffff) : value==0);
 always @(posedge clk)begin
  if(rst||reset_all)begin piano_values<=0;lead_values<=0;custom_values<=0;piano_mask<=0;lead_mask<=0;custom_mask<=0;end
  else if(commit&&operation_legal)begin
   case(selected_preset)
    0:if(operation==2)piano_mask<=0;else begin piano_mask[item]<=operation!=1;if(operation!=1)piano_values[item*16+:16]<=write_value;end
    4:if(operation==2)lead_mask<=0;else begin lead_mask[item]<=operation!=1;if(operation!=1)lead_values[item*16+:16]<=write_value;end
    5:if(operation==2)custom_mask<=0;else begin custom_mask[item]<=operation!=1;if(operation!=1)custom_values[item*16+:16]<=write_value;end
    default:begin end
   endcase
  end
 end
endmodule
