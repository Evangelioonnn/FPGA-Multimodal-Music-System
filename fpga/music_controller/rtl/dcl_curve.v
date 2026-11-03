module dcl_curve #(parameter LEVELS=64)(input wire clk,rst,start,input wire[19:0]delta_us,output reg busy,done,output reg[7:0]velocity);
(* syn_ramstyle="block_ram" *)reg[13:0]table_words[0:127];
reg[13:0]lo,rom_q;wire[27:0]word_q={rom_q,lo};reg[19:0]delta_q;reg[5:0]rank,probe,step;reg[1:0]phase;
wire[6:0]rom_address={probe,phase==1};
always @(posedge clk)rom_q<=table_words[rom_address];
initial begin
 if(LEVELS==64)begin
 table_words[0]=14'd8;table_words[1]=14'd12500;
 table_words[2]=14'd1548;table_words[3]=14'd11789;
 table_words[4]=14'd4368;table_words[5]=14'd10486;
 table_words[6]=14'd7188;table_words[7]=14'd9327;
 table_words[8]=14'd10776;table_words[9]=14'd8296;
 table_words[10]=14'd12828;table_words[11]=14'd7379;
 table_words[12]=14'd4128;table_words[13]=14'd6564;
 table_words[14]=14'd13603;table_words[15]=14'd5838;
 table_words[16]=14'd9511;table_words[17]=14'd5193;
 table_words[18]=14'd10283;table_words[19]=14'd4619;
 table_words[20]=14'd1839;table_words[21]=14'd4109;
 table_words[22]=14'd307;table_words[23]=14'd3655;
 table_words[24]=14'd1591;table_words[25]=14'd3251;
 table_words[26]=14'd13371;table_words[27]=14'd2891;
 table_words[28]=14'd3903;table_words[29]=14'd2572;
 table_words[30]=14'd16195;table_words[31]=14'd2287;
 table_words[32]=14'd2375;table_words[33]=14'd2035;
 table_words[34]=14'd3915;table_words[35]=14'd1810;
 table_words[36]=14'd3151;table_words[37]=14'd1610;
 table_words[38]=14'd3922;table_words[39]=14'd1432;
 table_words[40]=14'd15702;table_words[41]=14'd1273;
 table_words[42]=14'd2906;table_words[43]=14'd1133;
 table_words[44]=14'd15710;table_words[45]=14'd1007;
 table_words[46]=14'd9314;table_words[47]=14'd896;
 table_words[48]=14'd8038;table_words[49]=14'd797;
 table_words[50]=14'd5738;table_words[51]=14'd709;
 table_words[52]=14'd15726;table_words[53]=14'd630;
 table_words[54]=14'd3954;table_words[55]=14'd561;
 table_words[56]=14'd3446;table_words[57]=14'd499;
 table_words[58]=14'd634;table_words[59]=14'd444;
 table_words[60]=14'd15998;table_words[61]=14'd394;
 table_words[62]=14'd5250;table_words[63]=14'd351;
 table_words[64]=14'd8325;table_words[65]=14'd312;
 table_words[66]=14'd15753;table_words[67]=14'd277;
 table_words[68]=14'd3981;table_words[69]=14'd247;
 table_words[70]=14'd15249;table_words[71]=14'd219;
 table_words[72]=14'd10133;table_words[73]=14'd195;
 table_words[74]=14'd153;table_words[75]=14'd174;
 table_words[76]=14'd12701;table_words[77]=14'd154;
 table_words[78]=14'd10913;table_words[79]=14'd137;
 table_words[80]=14'd7589;table_words[81]=14'd122;
 table_words[82]=14'd15273;table_words[83]=14'd108;
 table_words[84]=14'd14509;table_words[85]=14'd96;
 table_words[86]=14'd2993;table_words[87]=14'd86;
 table_words[88]=14'd10677;table_words[89]=14'd76;
 table_words[90]=14'd3000;table_words[91]=14'd68;
 table_words[92]=14'd10684;table_words[93]=14'd60;
 table_words[94]=14'd15552;table_words[95]=14'd53;
 table_words[96]=14'd16324;table_words[97]=14'd47;
 table_words[98]=14'd11208;table_words[99]=14'd42;
 table_words[100]=14'd15820;table_words[101]=14'd37;
 table_words[102]=14'd12752;table_words[103]=14'd33;
 table_words[104]=14'd724;table_words[105]=14'd30;
 table_words[106]=14'd11736;table_words[107]=14'd26;
 table_words[108]=14'd12764;table_words[109]=14'd23;
 table_words[110]=14'd2272;table_words[111]=14'd21;
 table_words[112]=14'd13284;table_words[113]=14'd18;
 table_words[114]=14'd12007;table_words[115]=14'd16;
 table_words[116]=14'd14571;table_words[117]=14'd14;
 table_words[118]=14'd3823;table_words[119]=14'd13;
 table_words[120]=14'd12787;table_words[121]=14'd11;
 table_words[122]=14'd7927;table_words[123]=14'd10;
 table_words[124]=14'd5371;table_words[125]=14'd9;
 table_words[126]=14'd4863;table_words[127]=14'd8;
 end
 else if(LEVELS==32)begin
 table_words[0]=14'd8;table_words[1]=14'd12500;
 table_words[2]=14'd10512;table_words[3]=14'd11097;
 table_words[4]=14'd4120;table_words[5]=14'd8747;
 table_words[6]=14'd10784;table_words[7]=14'd6894;
 table_words[8]=14'd6952;table_words[9]=14'd5434;
 table_words[10]=14'd7728;table_words[11]=14'd4283;
 table_words[12]=14'd4408;table_words[13]=14'd3376;
 table_words[14]=14'd3392;table_words[15]=14'd2661;
 table_words[16]=14'd9544;table_words[17]=14'd2097;
 table_words[18]=14'd5456;table_words[19]=14'd1653;
 table_words[20]=14'd2904;table_words[21]=14'd1303;
 table_words[22]=14'd2912;table_words[23]=14'd1027;
 table_words[24]=14'd10344;table_words[25]=14'd809;
 table_words[26]=14'd2416;table_words[27]=14'd638;
 table_words[28]=14'd16248;table_words[29]=14'd502;
 table_words[30]=14'd7552;table_words[31]=14'd396;
 table_words[32]=14'd8327;table_words[33]=14'd312;
 table_words[34]=14'd5263;table_words[35]=14'd246;
 table_words[36]=14'd2455;table_words[37]=14'd194;
 table_words[38]=14'd415;table_words[39]=14'd153;
 table_words[40]=14'd10151;table_words[41]=14'd120;
 table_words[42]=14'd1199;table_words[43]=14'd95;
 table_words[44]=14'd15287;table_words[45]=14'd74;
 table_words[46]=14'd1215;table_words[47]=14'd59;
 table_words[48]=14'd9159;table_words[49]=14'd46;
 table_words[50]=14'd11471;table_words[51]=14'd36;
 table_words[52]=14'd15319;table_words[53]=14'd28;
 table_words[54]=14'd13279;table_words[55]=14'd22;
 table_words[56]=14'd16103;table_words[57]=14'd17;
 table_words[58]=14'd2799;table_words[59]=14'd14;
 table_words[60]=14'd2807;table_words[61]=14'd11;
 table_words[62]=14'd13311;table_words[63]=14'd8;
 end
end
always @(posedge clk)begin
 if(rst)begin busy<=0;done<=0;velocity<=8;delta_q<=0;rank<=0;probe<=0;step<=0;lo<=0;phase<=0;end
 else begin done<=0;
  if(start&&!busy)begin busy<=1;delta_q<=delta_us;rank<=0;probe<=LEVELS/2;step<=LEVELS/2;velocity<=8;phase<=0;end
  else if(busy)case(phase)
   0:phase<=1;
   1:begin lo<=rom_q;phase<=2;end
   default:begin
    if(delta_q<=word_q[27:8])begin rank<=probe;velocity<=word_q[7:0];end
    if(step==1)begin busy<=0;done<=1;end
    else begin probe<=(delta_q<=word_q[27:8]?probe:rank)|(step>>1);step<=step>>1;phase<=0;end
   end
  endcase
 end
end
endmodule
