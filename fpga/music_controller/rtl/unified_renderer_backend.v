// V9: one physical sine read port, one signed 27x18 multiplier and one
// 48-bit accumulator for ALL melodic tone families and independent scoring.
// Separate state frontends do not own oscillators/multipliers/accumulators.
// Music microsequence: legacy8, bell9, ensemble9, A/B11 clocks. Scoring II1 unchanged.
module unified_renderer_backend #(parameter TAG_W=22)(
 input wire clk,rst,frame_clear,score_frame,
 input wire start,input wire [31:0] phase,input wire [15:0] envelope,brightness,accent,
 input wire [2:0] timbre,input wire [8:0] coeff0,coeff1,coeff2,coeff3,
 input wire [1:0] style,wave_a,wave_b,input wire [16:0] mix,input wire [6:0] note,
 input wire [TAG_W-1:0] tag,output wire ready,output reg valid,
 output reg signed [19:0] sample,output reg [TAG_W-1:0] result_tag,
 input wire [31:0] score_phase,input wire [15:0] score_envelope,
 output wire signed [15:0] score_sine,
 input wire score_accumulate,input wire music_accumulate,
 input wire signed [31:0] music_term,
 output wire signed [47:0] accumulator_value,accumulator_next,
 output wire signed [32:0] score_product
);
 reg [3:0] state;
 reg [31:0] p,bell_phase;reg [2:0] kind;
 reg [15:0] env,bright,accent_q;reg [8:0] c0,c1,c2,c3;
 reg [1:0] table_style,ka,kb,band;reg [8:0] pos;reg [7:0] frac;
 reg [16:0] blend;reg [TAG_W-1:0] locked_tag;
 wire [31:0] p2=p<<1,p3=p+(p<<1),p4=p<<2;
 wire [11:0] music_address=start ? phase[31:20] : state==1 ? p2[31:20] :
   state==2 ? p3[31:20] : state==3 ? p4[31:20] : bell_phase[31:20];
 wire signed [15:0] sine_q;
 refinement_sine shared_sine(clk,score_frame ? score_phase[31:20] : music_address,sine_q);
 assign score_sine=sine_q;
 wire [1:0] band_in=timbre==7 ? (note<=59 ? 0 : note<=71 ? 1 : note<=83 ? 2 : 3) :
   (note<=47 ? 0 : note<=59 ? 1 : note<=71 ? 2 : 3);
 wire [8:0] nextpos=pos+9'd1;
 wire [13:0] ensemble_address=start ? {style,1'b0,band_in,phase[31:23]} :
   state==1 ? {table_style,1'b0,band,nextpos} : state==2 ? {table_style,1'b1,band,pos} : {table_style,1'b1,band,nextpos};
 wire [12:0] ab_address=start ? {wave_a,band_in,phase[31:23]} :
   state==1 ? {ka,band,nextpos} : state==2 ? {kb,band,pos} : {kb,band,nextpos};
 wire signed [15:0] ensemble_data,ab_data;
 selected_ensemble_rom ensemble_tables(clk,ensemble_address,ensemble_data);
 wavetable_rom ab_tables(clk,ab_address,ab_data);
 // ROM reflection/bank selection ends here; interpolation subtraction and DSP
 // selection start on the next clock. No added oscillators or audio samples.
 reg signed [15:0] table_data;
 always @(posedge clk) table_data<=kind==7 ? ensemble_data : ab_data;
 reg signed [26:0] operand_x;reg signed [17:0] operand_y;
 // sole registered multiplier: legacy, bell modulation/brightness/envelope,
 // table interpolation/blend/envelope and scoring amplitude all visit here.
 reg signed [44:0] product;
 wire signed [26:0] selected_x=score_frame ? {{11{sine_q[15]}},sine_q} : operand_x;
 wire signed [17:0] selected_y=score_frame ? {2'b0,score_envelope} : operand_y;
 assign score_product=product[32:0];
 reg signed [47:0] accumulator;
 wire signed [47:0] term=score_frame ? {{15{product[32]}},product[32:0]} : {{16{music_term[31]}},music_term};
 assign accumulator_value=accumulator;
 assign accumulator_next=accumulator+term;
 always @(posedge clk)begin
  if(rst)begin product<=0;accumulator<=0;end
  else begin
   product<=selected_x*selected_y;
   if(frame_clear)accumulator<=0;
   else if(score_frame ? score_accumulate : music_accumulate)accumulator<=accumulator_next;
  end
 end
 reg signed [25:0] fundamental,upper,shape,bell_upper,bell_shape_q;
 reg signed [26:0] custom_sum;reg signed [15:0] bell_b;
 reg signed [42:0] bell_bright;
 wire signed [25:0] coeff_product=product[25:0];
 wire signed [26:0] coeff_extended={coeff_product[25],coeff_product};
 wire signed [27:0] custom_final=$signed({custom_sum[26],custom_sum})+$signed({{2{coeff_product[25]}},coeff_product});
 wire signed [25:0] sine_wide={{10{sine_q[15]}},sine_q};
 wire signed [26:0] drive_in=$signed({shape[25],shape})<<<1;
 wire signed [26:0] drive_shape=drive_in>27'sd3000000 ? 27'sd3000000+((drive_in-27'sd3000000)>>>2) :
  drive_in< -27'sd3000000 ? -27'sd3000000+((drive_in+27'sd3000000)>>>2) : drive_in;
 wire signed [25:0] bell_fundamental=(sine_wide<<<6)+(sine_wide<<<5);
 wire signed [25:0] bell_shape=bell_fundamental+(bell_bright>>>16);
 wire signed [42:0] legacy_product=product[42:0];
 wire signed [42:0] legacy_round=legacy_product<0 ? -(((-legacy_product)+43'sd4194304)>>>23) : (legacy_product+43'sd4194304)>>>23;
 reg signed [15:0] a0,b0,interp_a,interp_b,interpolated;
 reg signed [35:0] first;
 wire signed [35:0] table_product=product[35:0];
 wire signed [17:0] interpolation=$signed({{2{a0[15]}},a0})+$signed((table_product+128)>>>8);
 wire signed [35:0] q16round=table_product<0 ? -(((-table_product)+32768)>>>16) : (table_product+32768)>>>16;
 wire signed [17:0] blended=$signed({{2{interp_a[15]}},interp_a})+$signed(q16round);
 wire signed [36:0] ensemble_total=$signed({first[35],first})+$signed({table_product[35],table_product});
 wire signed [36:0] ensemble_round=ensemble_total<0 ? -(((-ensemble_total)+16384)>>>15) : (ensemble_total+16384)>>>15;
 always @*begin
  operand_x=0;operand_y=0;
  if(kind==1||kind==7)case(state)
   3,5:begin operand_x=$signed({table_data[15],table_data})-$signed({a0[15],a0});operand_y={10'd0,frac};end
   6:if(kind==7)begin operand_x=interp_a;operand_y={2'd0,env};end
   7:if(kind==7)begin operand_x=interp_b;operand_y={2'd0,accent_q};end
     else begin operand_x=$signed({interp_b[15],interp_b})-$signed({interp_a[15],interp_a});operand_y={1'b0,blend};end
   9:begin operand_x=interpolated;operand_y={2'd0,env};end
   default:begin end
  endcase
  else case(state)
   1:begin operand_x=sine_q;operand_y={9'd0,c0};end
   2:begin operand_x=sine_q;operand_y={9'd0,c1};end
   3:begin operand_x=sine_q;operand_y=kind==3 ? {2'd0,bright} : {9'd0,c2};end
   4:begin operand_x=kind==3 ? $signed({bell_upper[25],bell_upper}) : $signed(sine_q);operand_y=kind==3 ? {2'd0,bright} : {9'd0,c3};end
   6:if(kind!=3)begin operand_x=kind==4 ? drive_shape : $signed({shape[25],shape});operand_y={2'd0,env};end
   7:if(kind==3)begin operand_x=$signed({bell_shape_q[25],bell_shape_q});operand_y={2'd0,env};end
   default:begin end
  endcase
 end
 assign ready=state==0&&!score_frame;
 always @(posedge clk)begin
  if(rst)begin
   state<=0;p<=0;bell_phase<=0;kind<=0;env<=0;bright<=0;accent_q<=0;c0<=0;c1<=0;c2<=0;c3<=0;
   table_style<=0;ka<=0;kb<=0;band<=0;pos<=0;frac<=0;blend<=0;locked_tag<=0;
   fundamental<=0;upper<=0;shape<=0;bell_upper<=0;bell_shape_q<=0;custom_sum<=0;bell_b<=0;bell_bright<=0;
   a0<=0;b0<=0;interp_a<=0;interp_b<=0;interpolated<=0;first<=0;valid<=0;sample<=0;result_tag<=0;
  end else begin
   valid<=0;
   if(start&&ready)begin
    p<=phase;kind<=timbre;env<=envelope;bright<=brightness;accent_q<=accent;
    c0<=coeff0;c1<=coeff1;c2<=coeff2;c3<=coeff3;locked_tag<=tag;
    table_style<=style;ka<=wave_a;kb<=wave_b;band<=band_in;pos<=phase[31:23];frac<=phase[22:15];
    blend<=mix>65536 ? 17'd65536 : mix;state<=1;
   end else if(state!=0)begin
    state<=state+1'b1;
    if(kind==1||kind==7)case(state)
     2:a0<=table_data;
     4:begin interp_a<=interpolation[15:0];a0<=table_data;end
     6:interp_b<=interpolation[15:0];
     7:if(kind==7)first<=table_product;
     8:if(kind==7)begin sample<=ensemble_round[19:0];valid<=1;result_tag<=locked_tag;state<=0;end
       else interpolated<=blended[15:0];
     10:begin sample<=q16round[19:0];valid<=1;result_tag<=locked_tag;state<=0;end
     default:begin end
    endcase else case(state)
     1:fundamental<=sine_wide<<<7;
     2:begin upper<=kind==4 ? sine_wide<<<4 : sine_wide<<<5;custom_sum<=coeff_extended;bell_b<=sine_q;end
     3:begin upper<=upper+(kind==4 ? sine_wide<<<6 : sine_wide<<<4);custom_sum<=custom_sum+coeff_extended;
       bell_upper<=($signed({{10{bell_b[15]}},bell_b})<<<4)+(sine_wide<<<4);end
     4:begin upper<=upper+(kind==4 ? sine_wide<<<4 : sine_wide<<<3);custom_sum<=custom_sum+coeff_extended;
       bell_phase<=p+$signed(product>>>1);end
     5:begin shape<=kind==5 ? custom_final>>>1 : fundamental+upper;bell_bright<=legacy_product;end
     6:if(kind==3)bell_shape_q<=bell_shape;
     7:if(kind!=3)begin sample<=legacy_round[19:0];valid<=1;result_tag<=locked_tag;state<=0;end
     8:if(kind==3)begin sample<=legacy_round[19:0];valid<=1;result_tag<=locked_tag;state<=0;end
     default:begin end
    endcase
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&start&&!ready)$fatal(1,"Unified backend launch while busy");
 // synthesis translate_on
endmodule
