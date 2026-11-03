// New-library private preview bundle; loaded/Game title unchanged.
// Private optional simplification: no hardcoded three-song aliases.
// Private fallback: generic ASCII names show first24 characters plus ellipsis.
// All40 bytes still participate in alias and non-ASCII classification.
// V13 workbench: real backend decoding reused, explicit destination->widget map.
module ui_page_writer #(parameter WITH_LIBRARY=0,WITH_GESTURE=0,WITH_V18=0,WITH_LOOP_EXPORT=0,WITH_NEW_FX=0,WITH_SYNTH_PREVIEW=1)(input wire clk,rst,ready,snapshot_valid,
 input wire[191:0]library_status,input wire[319:0]library_title,
 input wire[15:0]gesture_status,input wire[31:0]gesture_expression_status,
 input wire[63:0]dd_status,v18_status,
 input wire [127:0] score_status,input wire [95:0] guide_status,
 input wire [639:0] snapshot,input wire [255:0] controller,
 input wire [159:0] audio_status,input wire [47:0] harmonics,input wire [95:0] adc_raw,
 input wire [119:0] envelope_status,
 input wire [63:0] navigation,input wire [63:0] layer_timbres,input wire [63:0] synth_status,
 input wire [255:0] storage_status,input wire[511:0]practice_status,input wire[127:0]record_status,input wire[383:0]song_title,
 output reg wr_en,output reg [10:0] wr_addr,output wire [31:0] wr_data,output wire publish);
 reg[31:0]ges;reg[15:0]gs;reg[63:0]dds,vc;reg[511:0]ps;reg[127:0]rs;reg[191:0]title;reg[63:0]selection_title;reg title_truncated,selection_truncated;reg[191:0]lib;reg title_fallback,selection_fallback;reg title_alias,selection_alias;
 reg busy;reg [10:0] address;reg [639:0] s;reg [255:0] c,st;
 reg [63:0] w,lt,n;reg [127:0] score;reg [95:0] guide,adc;
 reg[119:0]env;reg[15:0]env_item_value;
 reg[15:0]feedback_sequence;reg[25:0]feedback_clocks;
 reg envelope_feedback;
 always @(posedge clk)begin
  if(rst)begin feedback_sequence<=0;feedback_clocks<=0;end
  else begin
   feedback_sequence<=envelope_status[115:100];
   if(feedback_sequence!=envelope_status[115:100])feedback_clocks<=26'd50000000;
   else if(feedback_clocks!=0)feedback_clocks<=feedback_clocks-1'b1;
  end
 end
 reg [159:0] a;reg [47:0] h;
 wire [2:0] tab=n[2:0];wire [1:0] sub=n[4:3];wire [3:0] focus=n[8:5];
 wire browse=n[9],editing=n[10],armed=n[11],confirmation=n[12];
 wire [3:0] page=tab==5 ? (sub>=2 ? 15 : 14) : tab==0 ? (sub!=0 ? 3 : 0) : tab==1 ? (sub==2 ? 15 : sub==0 ? 1 : 2) : tab==2 ? (sub==0 ? 11 : sub==1 ? 4 : 8) : tab==3 ? (sub==0 ? 5 : sub==1 ? 9 : 10) : sub==0 ? 6 : sub==1 ? 7 : sub==2 ? 12 : 13;
 wire [4:0] real_row=address[10:6];wire [5:0] real_col=address[5:0];
 // One title read mux shared by Library loaded line and Game heading.
 reg[5:0]title_index;reg title_scan;
 wire[5:0]title_display_index=real_col-((WITH_LIBRARY&&sub==1) ? 6'd12:6'd21);
 wire[5:0]title_read_index=title_display_index;
 wire[5:0]selection_read_index=real_col-6'd21;
 wire[7:0]title_display_byte=title_read_index<24 ? title[title_read_index*8+:8] : title_truncated&&title_read_index<27 ? 8'd46 : 8'd32;
 wire[7:0]selection_display_byte=selection_read_index<8 ? selection_title[selection_read_index*8+:8] : selection_truncated&&selection_read_index<11 ? 8'd46 : 8'd32;
 reg [4:0] row,mapped_row,mapped_row_q;reg [5:0] col,mapped_col,mapped_col_q;reg[2:0]r;reg[3:0]f;reg[5:0]dx;reg[1:0]dy;
 always @* begin
  mapped_row=real_row;mapped_col=real_col;r=0;f=0;dx=0;dy=0;
  if(real_col>=12&&real_col<60)begin
   if(page==1)begin mapped_row=real_row+2;if(real_col<24)mapped_col=real_col-10;else if(real_col>=25&&real_col<37)mapped_col=real_col-5;if(real_row==15&&real_col>=18&&real_col<36)mapped_col=real_col-16;end
   else if(page==0&&real_row>=4&&real_row<=17)begin
    r=(real_row-4)>>2;dy=(real_row-4)&3;f=1+r*2+(real_col>=38);dx=real_col-(real_col>=38 ? 38 : 12);
    if(f==8)begin mapped_row=18;mapped_col=2+dx;end
    else begin mapped_row=6+({2'd0,f[3:1]}+{1'd0,f[3:1],1'b0})+dy;mapped_col=2+(f&1)*30+dx;end
   end else if(page==2&&real_row>=4&&real_row<=19)begin
    r=(real_row-4)>>2;mapped_row=6+({2'd0,r}+{1'd0,r,1'b0})+((real_row-4)&3);mapped_col=real_col>=38 ? real_col-6 : real_col-10;
   end else if((page==3||page==4||page==8||page==6||page==7||page==12||page==13)&&real_row>=4&&real_row<=15)begin
    r=(real_row-4)>>2;mapped_row=6+({2'd0,r}+{1'd0,r,1'b0})+((real_row-4)&3);mapped_col=real_col>=38 ? real_col-6 : real_col-10;
    if((page==4||page==8)&&real_row>=12)begin mapped_row=real_row;end
    if(page==12&&real_row>=13)mapped_row=real_row-1;
   end else begin
    mapped_col=real_col>=38 ? real_col-6 : real_col-10;
    if(page==11)mapped_row=real_row+2;
    if(page==6)begin
     if(real_row==17)begin mapped_row=16;mapped_col=real_col-10;end
     if(real_row==19)begin mapped_row=17;mapped_col=real_col-10;end
     if(real_row==21)begin mapped_row=17;mapped_col=real_col+20;end
    end
    if(page==12&&real_row>=13)mapped_row=real_row-1;
    if(page==13&&real_row==17)mapped_row=15;
    if(page==7&&real_row==21)mapped_row=19;
    if(page==7&&real_row==23)mapped_row=18;
   end
  end
 end

 reg[5:0]progress_col;reg [17:0] progress_threshold;
 always @(posedge clk)progress_threshold<=s[123:112]*progress_col;
 wire [3:0] timbre=ps[1] ? ps[291:288] : s[10:8]==1 ? 4'd10 : s[10:8]==7 ? 4'd7+{2'd0,a[147:146]} : {1'b0,s[10:8]};
 wire envelope_capable=timbre==0||timbre==4||timbre==5;
 wire ensemble_capable=timbre==7||timbre==8||timbre==9||timbre==10;
 wire lead_capable=timbre==4||ensemble_capable;
 wire display_hold=ps[1] ? ensemble_capable : a[148];
 wire [1:0] feedback=timbre==6 ? 3 : timbre==9 ? 2 : timbre==7||timbre==8 ? 1 : 0;
 wire [1:0] analysis=tab==3 ? sub+2'd1 : 0;
 wire [1:0] synth=WITH_SYNTH_PREVIEW ? (page==8 ? 2 : page==4 ? 1 : 0) : 0;
 wire [15:0] scene={browse,focus,sub,tab,feedback,synth,analysis};
 wire [4:0] library_base=st[13:9]>7 ? st[13:9]-5'd7 : 5'd0;
 wire storage_available=st[255:240]==16'd1;
 wire [4:0] library_index=library_base+((real_row-6'd4)>>1);
 reg[9:0]label_bank;reg[5:0]label_literal,label_origin,label_basis;reg label_relative;wire[5:0]label_column=label_relative ? label_basis-label_origin:label_literal;wire[15:0]label_address={label_bank,label_column};reg [9:0]label_bank_pipe;reg[5:0]label_literal_pipe,label_origin_pipe,label_basis_pipe;reg label_relative_pipe;wire[5:0]label_column_pipe=label_relative_pipe ? label_basis_pipe-label_origin_pipe:label_literal_pipe;reg [15:0]label_address_q;wire [8:0] label;ui_labels labels(clk,label_address_q,label);
 reg [8:0] ch;reg [3:0] color;reg [12:0] record;reg metadata,numeric,literal,percentage,sustain_round;
 reg [16:0] number;reg[7:0]value_id,value_id_q;reg [5:0] start;reg [3:0] length,number_position,recorded_timbre,widget;reg multiple_timbres,applicable;
 // One serial constant divider shared by elapsed/duration once per scene.
 // No wide combinational divider is placed on the pixel or audio path.
 reg [31:0] time_value;reg [19:0] time_remainder;reg [5:0] time_count;
 reg[1:0] time_second;reg[15:0]library_seconds;reg [15:0] elapsed_seconds,duration_seconds;
 wire [20:0] time_shift={time_remainder,time_value[31]};
 wire time_take=time_shift>=21'd1000000;
 wire [31:0] time_next={time_value[30:0],time_take};
 function [4:0] envelope_grade;input[15:0]raw;begin
  if(raw>=2048)envelope_grade=1;else if(raw>=1024)envelope_grade=2;else if(raw>=512)envelope_grade=3;else if(raw>=256)envelope_grade=4;
  else if(raw>=128)envelope_grade=5;else if(raw>=96)envelope_grade=6;else if(raw>=68)envelope_grade=7;else if(raw>=48)envelope_grade=8;
  else if(raw>=24)envelope_grade=9;else if(raw>=16)envelope_grade=10;else if(raw>=12)envelope_grade=11;else if(raw>=6)envelope_grade=12;
  else if(raw>=4)envelope_grade=13;else if(raw>=3)envelope_grade=14;else if(raw>=2)envelope_grade=15;else envelope_grade=16;
 end endfunction
 integer i,j,bcol,brow;reg[3:0]pad;
 wire[9:0]capture_error_label=rs[98:96]==3 ? 10'd750 : (rs[98:96]==4||rs[98:96]==5) ? 10'd637 : 10'd638;
 task capture_error_text;input[5:0]x,len;begin if(col>=x&&col<x+len)relative_label(capture_error_label,x);end endtask
 // Select track before summarizing its layers; one shared text-cell unit.
 reg[3:0]summary_valid_q;reg[15:0]summary_tones_q;
 wire[1:0]summary_track=page==2 ? ((real_row-5'd5)>>2):{(mapped_row>=12),(mapped_col>=20)};
function[4:0] summarize_layers;input[3:0]valid;input[15:0]tones;integer k;reg[3:0]first;reg mixed;begin
 first=15;mixed=0;
 for(k=0;k<4;k=k+1)if(valid[k])begin
  if(first==15)first=tones[k*4+:4];else if(first!=tones[k*4+:4])mixed=1;
 end
 summarize_layers={mixed,first};
end endfunction
 wire[4:0]shared_layer_summary=summarize_layers(summary_valid_q,summary_tones_q);
 always @(posedge clk)begin
  if(rst)begin summary_valid_q<=0;summary_tones_q<=0;end
  else if(busy&&phase==0)begin
   summary_valid_q<=s[96+{summary_track,2'b00}+:4];
   summary_tones_q<=lt[{summary_track,4'b0000}+:16];
  end
 end
 wire[11:0] minimum_length_ms=ps[1] ? 12'd500 : a[150:149]==0 ? 12'd500 : a[150:149]==1 ? 12'd1000 : a[150:149]==2 ? 12'd1500 : 12'd2000;
 wire[24:0] key_bits=c[60:36];wire[15:0]drum_bits=s[415:400];
 wire[3:0]mute_bits=s[25:22];wire[31:0]library_flags=st[187:156];
 task field;input [7:0] value;input [5:0] x;input [3:0] len;
 begin if(col>=x&&col<x+len) begin
 // synthesis translate_off
 if(numeric)$fatal(1,"numeric field overlap page%0d row%0d col%0d",page,row,col);
 // synthesis translate_on
 value_id=value_id|value;start=x;length=len;number_position=len-1-(col-x);numeric=1;end end endtask
 task percent_field;input [7:0] value;input [5:0] x;
 begin if(col>=x&&col<x+3)begin field(value,x,3);percentage=1;sustain_round=0;end end endtask
 // Sustain uses a 0..65535 raw scale; display the nearest integer percent.
 // Other percentages retain their original 0..65536 Q16 floor semantics.
 task sustain_field;input [7:0] value;input [5:0] x;
 begin if(col>=x&&col<x+3)begin percent_field(value,x);sustain_round=1;end end endtask
 task set_label;input[9:0]bank;input[5:0]column;
 begin label_bank=bank;label_literal=column;label_origin=0;label_basis=0;label_relative=0;end endtask
 task relative_label;input[9:0]bank;input[5:0]origin;
 begin label_bank=bank;label_literal=0;label_origin=origin;label_basis=col;label_relative=1;end endtask
 task text;input [6:0] index;input [5:0] x;input [5:0] len;
 begin if(col>=x&&col<x+len)relative_label(10'd512+index,x);end endtask
 task sound_name;input [3:0] id;input [5:0] x;input [5:0] len;
 begin if(col>=x&&col<x+len)relative_label(10'd640+id,x-(len<16 ? 6'd32 : 6'd0));end endtask
 task vtext;input[5:0]id;input[5:0]x,len;
 begin if(col>=x&&col<x+len)relative_label(10'd900+id,x);end endtask
 task ltext;input[5:0]id;input[5:0]x,len;begin if(col>=x&&col<x+len)relative_label(10'd976+{4'd0,id},x);end endtask
 task gtext;input[3:0]id;input[5:0]x,len;
 begin if(col>=x&&col<x+len)relative_label(10'd960+id,x);end endtask
 task practice_text;input[5:0]id;input[5:0]x,len;
 begin if(col>=x&&col<x+len)relative_label(10'd736+id,x);end endtask
 task name;input [5:0] x;input [5:0] len;begin sound_name(timbre,x,len);end endtask
 task character;input [8:0] value;input [5:0] x;
 begin if(col==x)begin literal=1;ch=value;end end endtask
 task highlight;input [3:0] index;input [5:0] x,y,w,ht;
 begin if(browse&&focus==index&&(real_col<36||(real_col>=38&&real_col<59))&&col>=x&&col<x+w&&row>=y&&row<y+ht)color=editing ? 7 : 3;end endtask
 function [3:0] drum_pad;input integer key;begin case(key)
 5:drum_pad=9;6:drum_pad=5;7:drum_pad=6;8:drum_pad=7;9:drum_pad=8;default:drum_pad=key&15;endcase end endfunction
 // Footer priority is selected independently of the current text column.
 // A single range/column formatter serves all normal footer messages.
 reg[9:0]footer_label;reg[7:0]footer_index;reg[5:0]footer_length;
 reg[2:0]footer_special;reg[3:0]footer_color;
 always @*begin
  footer_label=0;footer_index=0;footer_length=47;footer_special=0;footer_color=0;
   if((tab==5||ps[1])&&ps[11])begin begin footer_index=8;footer_label=10'd736+{4'd0,footer_index[5:0]};end footer_color=5;end
   else if(tab==5&&lib[4])begin begin footer_index=14;footer_label=10'd976+{4'd0,footer_index[5:0]};end footer_color=5;end
   else if(tab==5&&lib[15:8]!=0)begin
    begin footer_index=lib[15:8]==3 ? (lib[7] ? 9:10):lib[15:8]==6 ? 12:lib[15:8]==4 ? 13:lib[15:8]==9 ? 11:27;footer_label=10'd976+{4'd0,footer_index[5:0]};end footer_color=5;
   end
   else if((tab==5&&sub==2||rs[92]||rs[93])&&rs[95])begin footer_label=capture_error_label;footer_color=5;end
   else if(st[31:24]!=0)begin footer_label=10'd672+{2'd0,st[31:24]};footer_color=5;end
   else if(((tab==0&&sub==2)||envelope_feedback)&&env[99:92]==4)begin begin footer_index=94;footer_label=10'd512+{3'd0,footer_index[6:0]};end footer_color=5;end
   else if(((tab==0&&sub==2)||envelope_feedback)&&env[99:92]==5)begin begin footer_index=95;footer_label=10'd512+{3'd0,footer_index[6:0]};end footer_color=5;end
   else if(confirmation)begin
    if(tab==0&&sub==2)begin footer_index=86;footer_label=10'd512+{3'd0,footer_index[6:0]};end
    else if(tab==5&&sub==3)begin footer_index=18;footer_label=10'd736+{4'd0,footer_index[5:0]};end
    else begin footer_index=28;footer_label=10'd512+{3'd0,footer_index[6:0]};end footer_color=5;
   end
   else if((tab==5||ps[1])&&ps[307:300]!=0)begin footer_label=10'd743;footer_special=1;footer_color=5;end
   else if(tab==5&&sub==2&&rs[106:99]!=0)begin footer_label=10'd773;footer_special=2;footer_color=5;end
   else if(c[103:96]!=0)begin footer_label=10'd656+{2'd0,c[103:96]};footer_color=5;end
   else if(tab==5&&lib[2])begin footer_index=7;footer_label=10'd976+{4'd0,footer_index[5:0]};end
   else if((tab==5||ps[1])&&ps[8])begin footer_index=3;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if(tab==5&&sub==2&&rs[94])begin footer_index=15;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if(rs[92]||rs[93])begin
    if(rs[92])begin footer_index=10;footer_label=10'd512+{3'd0,footer_index[6:0]};end else begin footer_index=37;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   end
   else if((tab==5||ps[1])&&ps[489])begin begin footer_index=18;footer_label=10'd736+{4'd0,footer_index[5:0]};end footer_color=5;end
   else if((tab==5||ps[1])&&ps[12])begin begin footer_index=7;footer_label=10'd736+{4'd0,footer_index[5:0]};end footer_color=5;end
   else if((tab==5||ps[1])&&ps[7])begin footer_index=10;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if((tab==5||ps[1])&&ps[4])begin footer_index=11;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if(s[12])begin footer_index=12;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   else if(s[14])begin footer_index=10;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   else if(((tab==0&&sub==2)||envelope_feedback)&&ps[1])begin footer_index=42;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if(((tab==0&&sub==2)||envelope_feedback)&&score[0])begin footer_index=92;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   else if(editing)begin footer_index=103;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   else if((tab==0&&sub==2)||envelope_feedback)footer_special=3;
   else if(tab==5&&sub==2)begin footer_index=29;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if(tab==5&&ps[5])footer_special=4;
   else if(ps[1]&&(tab<3||(tab==4&&sub==3)))begin footer_index=42;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if(tab==5&&sub==0)begin
    if(lib[7])begin footer_index=9;footer_label=10'd976+{4'd0,footer_index[5:0]};end else if(lib[6])begin footer_index=25;footer_label=10'd976+{4'd0,footer_index[5:0]};end
    else begin footer_index=lib[5] ? 8:lib[1] ? 28:lib[3] ? 15:11;footer_label=10'd976+{4'd0,footer_index[5:0]};end
   end
   else if(tab==5)begin footer_index=ps[3] ? 11:ps[2] ? 22:ps[0] ? 28:6;footer_label=10'd736+{4'd0,footer_index[5:0]};end
   else if(!armed)begin footer_index=26;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   else if(WITH_GESTURE&&gs[0]&&ges[0]&&ges[4]&&ges[5]&&(tab==0||tab==4&&sub==1))begin footer_index=115;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   else if(WITH_GESTURE&&gs[0]&&ges[3]&&ges[31]&&(tab==0||tab==4&&sub==1))footer_special=5;
   else if(WITH_GESTURE&&gs[0]&&(tab==0||tab==4&&sub==1))begin
    begin footer_index=!gs[2] ? 5:gs[7] ? 7:gs[6] ? 6:!gs[5] ? 8:gs[8] ? 9:gs[1] ? 4:3;footer_label=10'd960+{6'd0,footer_index[3:0]};footer_length=24;end
   end
   else if(focus==15&&browse)begin footer_index=39;footer_label=10'd512+{3'd0,footer_index[6:0]};end
   else begin footer_index=browse ? 27:5;footer_label=10'd512+{3'd0,footer_index[6:0]};end
 end
 always @* begin
  row=mapped_row_q;col=mapped_col_q;number_position=0;
  set_label({1'b0,page,address[10:6]},address[5:0]);ch=32;color=0;record=0;metadata=0;numeric=0;value_id=0;literal=0;percentage=0;sustain_round=0;
  env_item_value=0;recorded_timbre=15;multiple_timbres=0;value_id=0;start=0;length=0;widget=0;applicable=1;bcol=0;brow=0;pad=0;
  if(real_col>=12&&real_row<27&&(page!=0||(real_row>=4&&real_row<=17)))begin
  case(page)
   0:begin
    for(i=0;i<8;i=i+1) begin
     bcol=2+(i%2)*30;brow=6+(i/2)*3;
     applicable=i==1&&timbre==6 ? 0 : (i==4||i==5) ? lead_capable : i==6 ? timbre==4 : 1;
     if(row>=brow&&row<brow+2&&col>=bcol&&col<bcol+26) begin
      if(!applicable) color=6;else highlight(i,bcol,brow,26,2);
      if(row==brow+1) begin
       if(!applicable) text(2,bcol,24);
       else case(i)
        0:name(bcol,24);1:if(envelope_capable)begin
         text(79+env[89:88],bcol,10);
         if(env[89:88]==2)begin sustain_field(7'd1,bcol+11);character("%",bcol+14);end
         else field(7'd2,bcol+11,2);
        end else field(7'd3,bcol,1);
        2:text(!ps[1]&&s[372] ? 1 : 0,bcol,8);3:text(!ps[1]&&s[373] ? 1 : 0,bcol,8);
        4:begin field(7'd4,bcol,3);character("/",bcol+5);field(7'd5,bcol+7,3);end
        5:field(7'd6,bcol,1);6:field(7'd7,bcol,1);7:text(s[374] ? 1 : 0,bcol,8);
        default:begin end
       endcase
      end
     end
    end
    highlight(8,2,18,26,1);
    if(row==19) begin
     character("C",9);field(7'd8,10,1);
     character("C",39);field(7'd9,40,1);
    end
   end
   1:begin
    if(real_row>=4&&real_row<=14&&((real_col>=12&&real_col<24)||(real_col>=25&&real_col<37)))begin
    for(i=0;i<4;i=i+1) begin
     bcol=2+(i%2)*18;brow=6+(i/2)*6;
     recorded_timbre=shared_layer_summary[3:0];multiple_timbres=shared_layer_summary[4];
     if(row==brow+1) begin
      if(recorded_timbre==15) text(17,bcol,15);
      else if(multiple_timbres) text(34,bcol,15);
      else sound_name(recorded_timbre,bcol,12);
     end
     if(row==brow&&col>=bcol&&col<bcol+15) color=s[7:6]==i ? 2 : 6;
     if(row==brow+2) begin percent_field(7'd10+i,bcol+4);character("%",bcol+7);end
     if(row==brow+3) for(j=0;j<4;j=j+1) if(col==bcol+5+j) begin
      literal=1;ch=s[96+i*4+j] ? "+" : ".";color=s[96+i*4+j] ? 4 : 6;
     end
     if(row==brow+4) text(s[14]&&s[28:27]==i ? 10 : s[22+i] ? 15 : s[96+i*4+:4]!=0 ? 18 : 17,bcol,11);
    end
    end
    for(i=0;i<9;i=i+1) highlight(i,40,5+i*2,19,1);
    if(row==5) field(7'd14,52,1);
    if(row==7) text(mute_bits[s[7:6]] ? 1 : 0,52,7);
    if(row==17&&real_col>=18&&real_col<36) begin
     literal=1;ch=(({5'd0,s[75:64]}<<4)+({5'd0,s[75:64]}<<1))>=progress_threshold ? "=" : ".";color=4;
    end
    if(row==21) field(7'd15,55,1);
    if(confirmation&&row==17) begin text(36,40,19);color=5;end
   end
   2:begin
    for(i=0;i<4;i=i+1) begin
     brow=6+i*3;
     recorded_timbre=shared_layer_summary[3:0];multiple_timbres=shared_layer_summary[4];
     if(row==brow+1) begin
      if(recorded_timbre==15) text(17,42,17);
      else if(multiple_timbres) text(34,42,17);
      else sound_name(recorded_timbre,42,11);
     end
     highlight(i*2,2,brow,26,2);highlight(i*2+1,32,brow,26,2);
     if(row==brow+1) begin percent_field(7'd10+i,2);character("%",5);
      text(c[90+i] ? 20 : 19,10,15);text(s[22+i] ? 1 : 0,32,8);end
    end
    if(row==18) name(14,15);
    highlight(8,2,19,26,1);
   end
   3:begin
    for(i=0;i<4;i=i+1) begin
     bcol=2+(i%2)*30;brow=6+(i/2)*3;
     applicable=i==0 ? timbre==5 : ensemble_capable;
     if(row>=brow&&row<brow+2&&col>=bcol&&col<bcol+26) begin
      if(!applicable)color=6;else highlight(i,bcol,brow,26,2);
      if(row==brow+1)begin
       if(!applicable)text(2,bcol,24);
       else case(i)
        0:text(c[186] ? 1 : 0,bcol,8);
        1:text(display_hold ? 4 : 3,bcol,20);
        2:begin field(7'd16,bcol,4);character("m",bcol+5);character("s",bcol+6);end
        3:begin field(7'd17,bcol,2);character("s",bcol+3);end
       endcase
      end
     end
    end
   end
   11:begin highlight(0,2,6,26,4);highlight(1,32,6,26,4);end
   4:begin
    highlight(4,2,12,26,1);
    for(i=0;i<4;i=i+1) begin
     bcol=2+(i%2)*30;brow=6+(i/2)*3;highlight(i,bcol,brow,26,2);
     if(row==brow+1) begin
      field(7'd18+i,bcol,3);character("/",bcol+5);
      case(i) 0:field(7'd22,bcol+7,3);1:field(7'd23,bcol+7,3);2:field(7'd24,bcol+7,3);3:field(7'd25,bcol+7,3);endcase
      text(c[90+i] ? 20 : 19,bcol+12,13);
     end
    end
   end
   8:begin
    highlight(0,2,6,26,2);highlight(1,32,6,26,2);highlight(2,2,9,26,2);highlight(3,32,9,26,2);
    if(row==7) begin
     if(col>=2&&col<26) relative_label(10'd704+{8'd0,w[1:0]},6'd2);
     if(col>=32&&col<58) relative_label(10'd704+{8'd0,w[3:2]},6'd32);
    end
    if(row==10) begin percent_field(7'd26,2);character("%",5);character("/",7);
     percent_field(7'd27,9);character("%",12);text(c[90] ? 20 : 19,16,12);end
   end
   5:begin end
   6:begin
    for(i=0;i<6;i=i+1) begin
     bcol=2+(i%2)*30;brow=6+(i/2)*3;highlight(i,bcol,brow,26,2);
     if(row==brow+1) case(i)
      0:begin field(7'd28,bcol,3);character("/",bcol+4);field(7'd29,bcol+6,3);end
      1:begin field(7'd30,bcol,1);character("/",bcol+1);character("4",bcol+2);end
      2:field(7'd15,bcol,1);3:text(33-{4'd0,s[55:54]},bcol,14);
      4:begin percent_field(7'd31,bcol);character("%",bcol+3);end
      5:text(s[16] ? 1 : 0,bcol,8);default:begin end
     endcase
    end
    highlight(6,2,16,26,1);
    highlight(7,2,17,26,1);highlight(8,32,17,26,1);
   end
   7:begin end
   12:begin
    highlight(0,2,6,26,2);highlight(1,32,6,26,2);
    highlight(2,2,9,26,2);highlight(3,32,9,26,2);
    if(row==7)begin text(score[0] ? 1 : 0,2,8);field(7'd32,32,4);end
    if(row==10)begin text(7'd96+{5'd0,score[10:9]},2,18);text(score[11] ? 1 : 0,32,8);end
   end
   13:begin
    for(i=0;i<4;i=i+1)highlight(i,2+(i%2)*30,6+(i/2)*3,26,2);
    highlight(4,2,12,26,2);
    if(row==7)begin text(guide[0] ? 1 : 0,2,8);text(guide[1] ? 1 : 0,32,8);end
    if(row==10)begin text(guide[0]||guide[1] ? 1 : 0,2,8);text(guide[2] ? 1 : 0,32,8);end
    if(row==13)begin character(guide[22] ? "-" : "+",2);field(7'd34,4,2);end
   end
  endcase

  end
  // Global fields use destination coordinates, independent of widget reflow.
  col=real_col;
  if(real_col<10)begin
   color=6;
   if(real_row>=2&&real_row<=19)begin
    case((real_row-2)/3)
     0:if(tab==0)color=focus==15&&browse ? 3 : 2;
     1:if(tab==1)color=focus==15&&browse ? 3 : 2;
     2:if(tab==2)color=focus==15&&browse ? 3 : 2;
     3:if(tab==5)color=focus==15&&browse ? 3 : 2;
     4:if(tab==3)color=focus==15&&browse ? 3 : 2;
     5:if(tab==4)color=focus==15&&browse ? 3 : 2;
    endcase
   end
   if(real_row==21)begin if(col>=1&&col<10)relative_label(10'd640+{6'd0,timbre},6'd1-6'd32); color=2;end
   if(real_row==23)begin percent_field(7'd35,5);character("%",8);end
   if(real_row==25)text(s[16] ? 1 : 0,6,3);
   if(real_row==26)begin
    if(ps[1])practice_text(33,1,8);
    else begin field(7'd29,1,3);character("B",5);character("P",6);character("M",7);end
   end
   if(real_row==28)begin field(7'd36,5,2);character("/",7);field(7'd37,8,2);end
  end
  if(page==0&&real_row==0&&real_col>=12)begin
   if(real_col<34)begin name(12,21);if(browse&&focus==0)color=editing ? 7 : 3;end
   else begin text(ensemble_capable&&display_hold ? 4 : 3,38,20);if(!ensemble_capable)color=6;end
  end
  if(page==0&&real_row==19)begin
   character("C",23);field(7'd38,24,1);character("C",50);field(7'd39,51,1);
  end
  if(page==1&&real_col>=40&&real_row==21&&browse&&focus==9)color=3;
  if(page==0&&real_row>=16&&real_row<18&&real_col>=38&&timbre!=5&&!ensemble_capable)color=6;
  if(tab==3&&real_row==2)for(i=0;i<3;i=i+1)if(real_col>=12+i*13&&real_col<24+i*13)color=browse&&focus==i ? 3 : sub==i ? 4 : 6;
  // Display only actual loop position and fixed total capacity. Old row448
  // is the loop counter, not the used-event count; never label it as usage.
  if(page==1&&real_col>=12&&real_col<37)begin
   if(real_row==16)begin
    literal=1;ch=32;numeric=0;value_id=0;percentage=0;color=0;
    field(7'd40,18,4);character("/",22);field(7'd41,24,4);
   end
   if(real_row==17)field(7'd42,26,4);
   if(real_row==18)name(20,16);
  end
  // Status sections are formatted in destination cells, not old card coordinates.
  if(real_col>=12&&real_col<60)begin
   col=real_col;
   if(page==7)begin
    for(i=0;i<8;i=i+1)if(real_row==5+(i/2)*4)field(7'd43+i,12+(i%2)*26,4);
    if(real_row==21)begin text(c[89] ? 22 : 21,17,15);text(c[209:208]==1 ? 23 : c[209:208]==2 ? 25 : 24,44,16);end
    if(real_row==23)begin text(s[17]||c[95] ? 1 : 0,19,12);field(7'd51,50,3);end
   end
   if(page==12)begin
    if(real_row==13)begin field(7'd52,23,4);field(7'd53,52,4);end
    if(real_row==15)begin field(7'd54,23,4);field(7'd55,52,4);end
    if(real_row==17)begin field(7'd56,23,5);text(score[3]||score[4] ? 1 : 0,52,6);end
    if(real_row==19)text(score[5] ? 25 : score[1] ? 8 : score[2] ? 8 : 21,23,16);
   end
   if(page==13)begin
    if(real_row==17)begin field(7'd57,23,3);field(7'd58,50,2);end
    if(real_row==19)text(guide[3] ? 25 : 21,23,18);
   end
  end
  if(tab==5&&real_col>=12&&real_col<60&&real_row<27&&(!WITH_LIBRARY||sub!=0))begin
   col=real_col;row=real_row;numeric=0;value_id=0;percentage=0;literal=0;color=0;
   set_label({1'b0,page,address[10:6]},address[5:0]);
   if(sub<2)begin
    if(sub==1&&real_row>=12)begin literal=1;ch=32;end
    if(sub==1&&real_row==0)begin
     set_label(10'd0,6'd0);
     practice_text(ps[6] ? 1 : 0,12,8);
     practice_text(34,25,4);field(7'd59,30,4);
     practice_text(35,37,6);field(7'd60,44,4);
     practice_text(36,49,5);field(7'd61,55,4);
    end
    if(sub==1&&real_row==4)begin practice_text(24,12,20);practice_text(25,38,20);end
    if(sub==1&&real_row==8)begin practice_text(26,12,20);practice_text(23,38,20);end
    for(i=0;i<(sub==0 ? 6 : 4);i=i+1)if(browse&&focus==i&&real_row>=4+(i/2)*4&&real_row<=6+(i/2)*4&&real_col>=12+(i%2)*26&&real_col<36+(i%2)*26)color=3;
    if(real_row==5)begin
     if(sub==0)practice_text(ps[1] ? 28 : 6,12,24);
     else text(ps[4] ? 37 : ps[3] ? 47 : ps[2] ? 46 : 14,12,24);
     if(sub==0)practice_text(ps[6] ? 1 : 0,38,18);
    end
    if(real_row==9)begin
     if(sub==0)begin
      if(ps[4])practice_text(11,12,23);else if(ps[7])practice_text(10,12,23);else text(ps[2] ? (ps[3] ? 47 : 46) : 14,12,24);
     end else practice_text(ps[6] ? 1 : 0,12,20);
    end
    if(sub==0&&real_row==17&&col>=21)begin
     literal=1;ch=32;
     if(!ps[0])begin literal=0;practice_text(2,21,28);end
     else if(title[7])begin literal=0;practice_text(41,21,19);field(7'd62,44,5);end
     else if(col>=21&&col<60)ch=title_display_byte>=32&&title_display_byte<127 ? title_display_byte : 32;
    end
    if(sub==0&&real_row==19)begin field(7'd63,17,4);character("/",21);field(7'd64,22,4);character("s",27);field(7'd65,46,4);end
    if(sub==0&&real_row==21)begin field(7'd59,17,5);field(7'd60,33,5);field(7'd61,49,5);end
    if(sub==0&&real_row==24)begin practice_text(ps[9] ? 5 : 4,15,9);practice_text(ps[8] ? 3 : ps[0] ? 28 : 2,30,10);field(7'd66,47,5);end
   end else if(sub==2)begin
    for(i=0;i<3;i=i+1)if(browse&&focus==i&&real_row>=4+(i/2)*4&&real_row<=6+(i/2)*4&&real_col>=12+(i%2)*26&&real_col<36+(i%2)*26)color=3;
    if(real_row==5)begin if(rs[95])capture_error_text(12,24);else if(rs[94])practice_text(15,12,22);else text(rs[92] ? 10 : rs[93] ? 37 : 14,12,22);end
    if(real_row==13)begin field(7'd67,21,5);character("m",27);character("s",28);end
    if(real_row==15)begin field(7'd68,24,3);character("/",28);field(7'd69,30,3);end
    if(real_row==17)begin field(7'd70,24,4);text(127,30,4);field(7'd71,35,3);end
    if(real_row==19)begin if(rs[95])capture_error_text(22,34);else if(rs[94])practice_text(15,22,34);else if(rs[92]||rs[93])text(rs[92] ? 10:37,22,34);else practice_text(28,22,34);end
   end else begin
    literal=1;ch=32;
    if(real_row==0)begin literal=0;practice_text(27,12,24);end
    if(real_row==2)begin literal=0;practice_text(16,12,24);practice_text(17,38,20);if(browse&&focus==0&&col<36)color=3;if(browse&&focus==1&&col>=38)color=3;end
    if(real_row==25)begin literal=0;practice_text(19,12,36);end
    for(i=0;i<25;i=i+1)if(real_row==5+(i/5)*3&&col>=12+(i%5)*9&&col<20+(i%5)*9)begin
     field(7'd72+i,12+(i%5)*9,2);character(">",14+(i%5)*9);field(7'd97+i,16+(i%5)*9,2);
    end
   end
  end
  if(tab==1&&sub==2&&real_col>=12&&real_col<60&&real_row<27)begin
   col=real_col;numeric=0;value_id=0;percentage=0;literal=1;ch=32;color=6;
   if(real_row==0)begin literal=0;practice_text(30,12,40);end
   if(real_row==6)begin literal=0;practice_text(31,12,40);end
   if(real_row==14)begin literal=0;practice_text(32,12,40);color=focus==3&&browse ? 3 : 2;end
  end
  if(real_row==29&&real_col>=12)begin
   set_label(10'd0,6'd0);literal=1;ch=32;
   if(col<60)begin
    literal=0;
    if(st[31:24]!=0)begin relative_label(10'd672+{2'd0,st[31:24]},6'd12);color=5;end
    else if(confirmation)begin text(28,12,36);color=5;end
    else if(st[3:0]==10)text(51,12,36);
    else if(st[7])text(st[3:0]==7 ? 48 : st[3:0]==8 ? 49 : 50,12,36);
    else if(st[6])text(47,12,36);
    else if(st[5])text(46,12,36);
    else if(st[3:0]==2)text(43,12,36);
    else if(st[3:0]==4)text(45,12,36);
    else if(!armed)text(26,12,36);
    else if(c[103:96]!=0)begin relative_label(10'd656+{2'd0,c[103:96]},6'd12);color=5;end
    else if(editing)begin text(8,12,18);text(27,32,24);end
    else if(focus==15&&browse)text(39,12,36);
    else if(s[12])text(12,12,36);
    else if(s[14])text(10,12,36);
    else if(c[226])text(37,12,36);
    else if(c[207])text(38,12,36);
    else text(browse ? 27 : 5,12,36);
    if(!storage_available&&(page==14||(page==15&&!WITH_V18)))begin
     literal=1;numeric=0;value_id=0;percentage=0;ch=32;color=6;
     literal=0;practice_text(6,12,47);
    end
   end
  end
  // Practice keeps its own fixed patch. Ordinary controls are read-only.
  if(ps[1]&&real_col>=12&&real_col<60&&real_row>=4&&real_row<27&&
    (tab<3||(tab==4&&(sub==3||(sub==0&&real_row<16)))))color=6;
  if(real_row==29&&real_col>=12&&real_col<60&&(tab==5||ps[1]||ps[11]||ps[12]))begin
   col=real_col;numeric=0;value_id=0;percentage=0;literal=0;color=0;set_label(10'd0,6'd0);
   if(ps[11])begin practice_text(8,12,47);color=5;end
   else if(ps[489])begin practice_text(18,12,47);color=5;end
   else if(ps[12])begin practice_text(7,12,47);color=5;end
   else if(ps[307:300]!=0)begin practice_text(7,12,40);field(7'd122,54,2);color=5;end
   else if(ps[8])practice_text(3,12,47);
   else if(tab==5&&sub==2&&rs[106:99]!=0)begin practice_text(37,12,38);field(7'd123,54,2);color=5;end
   else if(rs[95])begin practice_text(14,12,47);color=5;end
   else if(rs[92]||rs[93])practice_text(13,12,47);
   else if(ps[7])practice_text(10,12,47);
   else if(ps[4])practice_text(11,12,47);
   else if(ps[5])practice_text(12,12,47);
   else if(tab==5&&sub==2)practice_text(29,12,47);
   else if(ps[1]&&(tab<3||(tab==4&&sub==3)))practice_text(42,12,47);
   else if(ps[2])practice_text(22,12,47);
   else practice_text(ps[0] ? 28 : 6,12,47);
  end
  if(!WITH_V18&&tab==1&&sub==2&&real_row==29&&real_col>=12&&real_col<60)begin
   col=real_col;numeric=0;value_id=0;percentage=0;literal=0;color=6;set_label(10'd0,6'd0);practice_text(31,12,47);
  end
  // V15 dedicated subpages use the same cards, text bank and atomic frame.
  // No additional image buffer or envelope renderer is instantiated.
  if(tab==0&&sub>=2&&real_col>=12&&real_col<60&&real_row<27)begin
   col=real_col;row=real_row;literal=1;numeric=0;value_id=0;percentage=0;ch=32;color=0;set_label(10'd0,6'd0);
   if(row==0)begin literal=0;text(sub==2 ? 78 : 89,12,22);name(38,22);end
   if(sub==2)begin
    widget={1'b0,(row>=8), (col>=38)};bcol=col>=38 ? 38 : 12;brow=row>=8 ? 8 : 4;
    if(row>=4&&row<=9)begin
     highlight(widget,bcol,brow,24,2);env_item_value=env[widget*16+:16];
     if(row==brow)begin literal=0;text(79+widget,bcol,20);end
     if(row==brow+1)begin
      if(widget==2)begin sustain_field(7'd124,bcol);character("%",bcol+3);end
      else begin field(7'd125,bcol,2);character("/",bcol+3);field(7'd126,bcol+4,2);end
      if(col>=bcol+9&&col<bcol+21)begin literal=0;text(env[64+widget] ? 84 : 83,bcol+9,12);end
     end
    end
    if(row==12)begin literal=0;text(confirmation ? 86 : 85,12,24);highlight(4,12,12,24,1);end
    if(row==16)begin literal=0;text(88,12,24);text(87,38,22);end
    if(!envelope_capable||ps[1]||score[0]||s[14]||s[12])color=6;
   end else begin
    if(row==4)begin literal=0;text(90,12,24);text(100,38,21);end
    if(row==5)begin literal=0;text(s[374] ? 1 : 0,12,24);percent_field(7'd127,38);character("%",41);end
    highlight(0,12,4,24,2);highlight(1,38,4,22,2);
   end
  end
  if(page==0&&real_row==4&&real_col>=12&&real_col<36&&envelope_capable)begin
   col=real_col;literal=0;numeric=0;value_id=0;set_label(10'd0,6'd0);text(78,12,24);
  end
  if(((tab==0&&sub==2)||envelope_feedback)&&real_row==29&&real_col>=12&&real_col<60)begin
   col=real_col;literal=0;numeric=0;value_id=0;percentage=0;set_label(10'd0,6'd0);color=0;
   if(ps[1])practice_text(42,12,47);
   else if(score[0])text(92,12,47);
   else if(s[14]||s[12])text(93,12,47);
   else if(env[99:92]==4)begin text(94,12,47);color=5;end
   else if(env[99:92]==5)begin text(95,12,47);color=5;end
   else if(confirmation)begin text(86,12,47);color=5;end
   else begin
    name(12,16);text(79+env[89:88],29,8);
    if(env[89:88]==2)begin sustain_field(7'd1,38);character("%",41);end
    else begin field(7'd2,38,2);character("/",40);field(7'd126,41,2);end
    text(87,46,13);
   end
  end
  if(WITH_V18&&real_col>=12&&real_col<60)begin
   col=real_col;
   if(WITH_NEW_FX&&tab==0&&sub==0&&real_row>=16&&real_row<=17&&real_col<36)begin
    literal=0;numeric=0;value_id=0;percentage=0;color=browse&&focus==7 ? 3 : 0;set_label(0,0);
    vtext(real_row==16 ? 0 : 6+vc[1:0],12,24);
   end
   if(WITH_NEW_FX&&tab==0&&sub==3&&real_row<21)begin
    literal=0;numeric=0;value_id=0;percentage=0;color=0;set_label(0,0);
    for(i=0;i<6;i=i+1)begin
     bcol=12+(i%2)*26;brow=4+(i/2)*4;
     if(row==brow)begin end
     if(real_row==brow)begin vtext(i,bcol,24);end
     applicable=i==1 ? vc[1:0]!=0 : i==3 ? vc[3:2]!=0 : i>=4 ? vc[1:0]==2 : 1;
     if(real_row>=brow&&real_row<=brow+1&&col>=bcol&&col<bcol+24)begin
      if(!applicable)color=6;else if(browse&&focus==i)color=editing ? 7 : 3;
      if(real_row==brow+1)case(i)
       0:vtext(6+vc[1:0],bcol,24);
       1:begin percent_field(7'd127,bcol);character("%",bcol+3);end
       2:vtext(vc[3:2]==0 ? 6 : 8+vc[3:2],bcol,24);
       3:field(8'd130,bcol,5);
       4:vtext(11+vc[10:8],bcol,24);
       5:begin field(8'd131,bcol,1);character("/",bcol+2);character("7",bcol+4);end
      endcase
     end
    end
   end
   if(tab==0&&sub==0&&real_row==2)begin
    literal=0;numeric=0;value_id=0;percentage=0;color=dds[22] ? 4 : 6;set_label(0,0);
    vtext(36,12,3);sound_name(dds[28:25],16,21);character("C",40);field(8'd128,41,1);vtext(37,45,3);field(8'd129,49,3);vtext(dds[23] ? (dds[22] ? 38 : 39) : 40,53,7);
   end
   // This card now selects the recording keyboard; no fake Save caption.
   if(!WITH_LOOP_EXPORT&&tab==1&&sub==0&&real_row==21&&real_col>=40)begin
    literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);vtext(19,40,20);
   end
   if(tab==1&&sub==2&&real_row<29)begin
    literal=0;numeric=0;value_id=0;percentage=0;color=0;set_label(0,0);
    if(real_row==0)vtext(WITH_LOOP_EXPORT ? 25 : 19,12,40);
    if(WITH_LOOP_EXPORT&&real_row==2)vtext(26,12,47);
    if(WITH_LOOP_EXPORT&&real_row==3)vtext(27,12,47);
    for(i=0;i<4;i=i+1)if(WITH_LOOP_EXPORT||i==0||i==3)begin
     bcol=12+(i%2)*26;brow=6+(WITH_LOOP_EXPORT ? (i/2)*4 : 0);
     if(real_row>=brow&&real_row<=brow+1&&col>=bcol&&col<bcol+24&&browse&&focus==i)color=3;
     if(real_row==brow)case(i)0:vtext(19,bcol,24);1:vtext(22,bcol,24);2:vtext(23,bcol,24);3:vtext(24,bcol,24);endcase
     if(real_row==brow+1&&i==0)vtext(vc[14] ? 21 : 20,bcol,24);
    end
    if(WITH_LOOP_EXPORT&&real_row==16)vtext(vc[17] ? 28 : vc[19] ? 30 : vc[18] ? 29 : vc[16] ? 31 : 26,12,47);
    if(WITH_LOOP_EXPORT&&real_row==18&&vc[17])begin field(8'd132,12,4);end
   end
   if(tab==4&&sub==1&&real_row>=2&&real_row<4)begin
    literal=0;numeric=0;value_id=0;percentage=0;color=0;set_label(0,0);
    if(real_row==2)begin vtext(32,12,24);vtext(33,38,21);end
    if(real_row==3)begin vtext(44,12,24);vtext(vc[15] ? 35 : 34,38,21);end
    if(real_row<4&&browse&&focus==(col>=38 ? 1 : 0))color=3;
   end
   if(WITH_LOOP_EXPORT&&real_row==29&&(vc[17]||vc[18]||vc[19]))begin
    literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=vc[19] ? 5 : 4;vtext(vc[17] ? 28 : vc[19] ? 30 : 29,12,47);
   end
   else if(real_row==29&&vc[39:24]!=0&&(vc[23:20]==8||vc[23:20]==3))begin
    literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=vc[23:20]==8 ? 5 : 4;vtext(vc[23:20]==8 ? 42 : 43,12,47);
   end
  end
  // GAME_ONLY: mode is readable, never a misleading editable card.
  if(tab==5&&((sub==0&&real_row>=4&&real_row<=6&&real_col>=38&&real_col<60)||
              (sub==1&&real_row>=8&&real_row<=10&&real_col>=12&&real_col<36)))color=6;
  if(address>=1920&&address<1945)begin
   metadata=1;record=0;record[11]=1;
   record[6:0]=address[4:0]<12 ? c[81:75]+address[4:0] : c[88:82]+(address[4:0]-5'd12);
   record[7]=key_bits[address[4:0]];
  end
  if(address>=1952&&address<1968)begin
   metadata=1;record=0;record[11]=1;pad=address[3:0];
   for(j=0;j<10;j=j+1)if(drum_pad(j)==pad&&c[36+j])record[7]=1;
   record[8]=drum_bits[pad];
  end
  if(address>=1984)begin
   literal=0;numeric=0;value_id=0;metadata=0;color=0;
   set_label(10'd708+{6'd0,address[5:2]},{4'd0,address[1:0]});
  end
  if(WITH_GESTURE&&real_col>=12&&real_col<60)begin
   if(tab==4&&sub==1&&(real_row==24||real_row==25||real_row==26||real_row==27))begin
    col=real_col;row=mapped_row_q;literal=0;numeric=0;value_id=0;percentage=0;color=0;set_label(0,0);
    if(real_row==24)begin gtext(0,12,24);highlight(2,12,24,24,2);end
    if(real_row==25)begin gtext(gs[0] ? 2:1,12,10);highlight(2,12,24,24,2);end
    if(real_row==26)begin
     gtext(!gs[0] ? 3:!gs[2] ? 5:!gs[5] ? 8:gs[6] ? 6:gs[7] ? 7:gs[1] ? 4:3,12,24);
     gtext(gs[11:10]==2 ? 11:gs[11:10]==1 ? 10:8,38,10);if(gs[8])gtext(9,49,10);
    end
    if(real_row==27)begin text(111,12,8);gtext(gs[3] ? 2:1,21,4);gtext(3,38,8);gtext(a[81] ? 2:1,48,4);end
   end
   if(tab==0&&sub==0&&real_row==5&&real_col>=38)begin
    col=real_col;literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);
    gtext(gs[3] ? 2:1,38,5);gtext(gs[1] ? 4:3,45,12);
   end
   if(real_row==29&&gs[0]&&(tab==0||(tab==4&&sub==1)))begin
    col=real_col;literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=gs[6]||!gs[2] ? 5:4;
    gtext(!gs[2] ? 5:gs[7] ? 7:gs[6] ? 6:!gs[5] ? 8:gs[8] ? 9:gs[1] ? 4:3,12,24);
   end
  end

  if(WITH_LIBRARY&&tab==5&&real_col>=12&&real_col<60)begin
   col=real_col;
   if(sub==0&&real_row<27)begin
    row=real_row;numeric=0;value_id=0;percentage=0;literal=1;ch=32;color=0;set_label(0,0);
    if(row==0)begin literal=0;ltext(0,12,24);field(8'd133,49,2);character("/",51);field(8'd134,53,2);end
    if(row==2)begin
     if(!lib[1])begin literal=0;ltext(lib[21:16]==0&&lib[3] ? 15:25,12,47);end
     else if(selection_fallback)begin literal=0;ltext(26,21,6);field(8'd135,28,5);end
     else if(selection_alias)begin literal=0;ltext(alias_label(lib[47:32]),21,30);end
     else if(col>=21&&col<51)ch=selection_display_byte>=32&&selection_display_byte<127 ? selection_display_byte:32;
     if(lib[1])begin literal=0;ltext(4,12,8);if(col>=21)literal=!(selection_fallback||selection_alias);end
    end
    for(i=0;i<8;i=i+1)begin
     if(row==4+(i/2)*4)begin
      literal=0;
      case(i)
       0:ltext(29,12,24);1:ltext(1,38,22);
       2:practice_text(24,12,24);3:practice_text(25,38,22);
       4:ltext(30,12,24);5:ltext(31,38,22);
       6:ltext(2,12,24);7:ltext(3,38,22);
      endcase
     end
     highlight(i,12+(i%2)*26,4+(i/2)*4,24,2);
    end
    if(row==5)begin literal=0;ltext(ps[0] ? 41:38,12,24);ltext(editing&&focus==1 ? 16:28,38,22);end
    if(row==9)begin literal=0;text(ps[3] ? 47:ps[2] ? 46:14,12,24);end
    if(row==17)begin literal=0;ltext(lib[4] ? 14:lib[2] ? 7:lib[5] ? 8:28,12,24);end
    if(row==20)begin literal=0;ltext(5,12,8);
     if(!ps[0])ltext(6,21,38);
     else if(title_fallback)begin ltext(26,21,6);field(7'd62,28,5);end
     else if(title_alias)begin literal=0;ltext(alias_label(ps[31:16]),21,39);end
     else if(col>=21)begin literal=1;ch=title_display_byte>=32&&title_display_byte<127 ? title_display_byte:32;end
    end
    if(row==22)begin literal=0;ltext(17,12,11);field(8'd135,25,5);ltext(18,38,8);field(8'd136,47,5);end
    // Optional Library metadata row removed; total is already in the heading.
    if(row==26&&lib[176:160]!=0)begin literal=0;ltext(20,12,7);field(8'd138,20,5);character("/",25);field(8'd139,26,5);end
    if(lib[2]&&row>=4&&row<19&&!(row>=16&&col>=38))color=6;
    if(!lib[1]&&row>=16&&row<=17&&col<36)color=6;
   end
   if(sub==1&&real_row==2)begin
    literal=1;numeric=0;value_id=0;percentage=0;ch=32;color=0;
    if(!ps[0])begin literal=0;ltext(6,12,30);end
    else if(title_fallback)begin literal=0;ltext(26,12,6);field(7'd62,19,5);end
    else if(title_alias)begin literal=0;ltext(alias_label(ps[31:16]),12,39);end
    else if(col<51)ch=title_display_byte>=32&&title_display_byte<127 ? title_display_byte:32;
   end
   if(sub==1&&real_row==0)begin
    literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=0;
    if(ps[5])ltext(21,12,10);else ltext(36,12,10);
    ltext(32,23,3);field(7'd59,27,5);ltext(33,33,4);field(7'd60,38,5);ltext(34,44,5);field(7'd61,50,5);
   end
   if(sub==1&&(real_row==8||real_row==9)&&col<36)begin
    literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=6;ltext(real_row==8 ? 35:36,12,24);
   end
   if(sub==1&&real_row==10)begin literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=0;ltext(22,12,8);field(7'd65,21,5);end
   if(real_row==29)begin
    literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=0;
    if(lib[4])begin ltext(14,12,47);color=5;end
    else if(lib[2])ltext(7,12,47);
    else if(lib[15:8]!=0)begin ltext(lib[15:8]==3 ? (lib[7] ? 9:10):lib[15:8]==6 ? 12:lib[15:8]==4 ? 13:lib[15:8]==9 ? 11:27,12,47);color=5;end
    else if(lib[7])ltext(9,12,47);
    else if(lib[6])ltext(25,12,47);
    else if(sub==0)ltext(lib[5] ? 8:lib[1] ? 28:lib[3] ? 15:11,12,47);
    else if(ps[5])begin ltext(21,12,8);ltext(22,23,8);field(7'd65,32,5);end
    else practice_text(ps[3] ? 11:ps[2] ? 22:ps[0] ? 28:6,12,47);
   end
  end

  // Footer format stage: common label path plus five compound messages.
  if(real_row==29&&real_col>=12&&real_col<59)begin
   col=real_col;row=real_row;literal=0;numeric=0;value_id=0;percentage=0;sustain_round=0;
   ch=32;color=footer_color;number_position=0;set_label(0,0);
   if(footer_special==0)begin
    if(col<12+footer_length)relative_label(footer_label,6'd12);
   end else case(footer_special)
    1:begin practice_text(7,12,40);field(8'd122,54,2);end
    2:begin practice_text(37,12,38);field(8'd123,54,2);end
    3:begin
     name(12,15);text(79+env[89:88],28,8);
     if(env[89:88]==2)begin sustain_field(8'd1,37);character("%",40);end
     else begin field(8'd2,37,2);character("/",39);field(8'd126,40,2);end
     text(87,44,14);
    end
    4:begin ltext(21,12,8);ltext(22,23,8);field(8'd65,32,5);end
    5:begin text(110,12,8);text(ges[2] ? 109:ges[7:6]==1 ? 107:ges[7:6]==2 ? 108:118,21,12);end
    default:begin end
   endcase
  end
  // This optional build deliberately retains GS2 sustain only.
  // Never display unavailable XY controls or their numeric values as active.
  if(WITH_GESTURE&&tab==4&&sub==1&&real_col>=38&&real_col<59&&(real_row==24||real_row==25))begin
   col=real_col;literal=0;numeric=0;value_id=0;percentage=0;set_label(0,0);color=6;
   if(real_row==24)begin text(110,38,8);text(2,47,12);end
  end
  // ADC rows leave one complete text-row gap below DD actions.
  if(tab==4&&sub==1&&real_row>=4&&real_row<=19&&real_col>=12&&real_col<59)begin
   col=real_col;literal=1;numeric=0;value_id=0;percentage=0;ch=32;color=0;set_label(0,0);
   for(i=0;i<8;i=i+1)begin
    bcol=12+(i%2)*26;
    if(real_row==5+(i/2)*4&&col>=bcol&&col<bcol+21)begin
     literal=0;relative_label(10'd228+(i/2)*4,6'd0);
    end
    if(real_row==6+(i/2)*4)field(8'd43+i,bcol,4);
   end
  end
  // Legal content excludes the half-visible cell at x1904..1935.
  if(real_col==59&&real_row<30)begin literal=1;numeric=0;value_id=0;ch=32;color=0;end
  if(tab==4&&sub==1&&real_row==0&&real_col>=12&&real_col<59)begin
   col=real_col;literal=0;numeric=0;value_id=0;color=0;set_label(0,0);text(75,12,30);
  end
  if(ps[1]&&tab==0&&sub==3&&real_col>=12&&real_col<59&&real_row>=4&&real_row<=5)color=6;

 end
 wire[7:0]vision_bend_magnitude=ges[22] ? -ges[22:15]:ges[22:15];
 wire[12:0]vision_cents_product={1'b0,vision_bend_magnitude,4'd0}+{2'b0,vision_bend_magnitude,3'd0}+{5'd0,vision_bend_magnitude};
 always @*begin
  case(value_id_q)
   8'd145:number={ges[29:23],10'd0};
   8'd146:number={8'd0,vision_cents_product[12:4]};
   7'd0:number=0;
   7'd1:number={1'b0,env[47:32]};
   7'd2:number=envelope_grade(env[env[89:88]*16+:16]);
   7'd3:number=ps[1] ? 3'd3 : s[363:361];
   7'd4:number=ps[1] ? 7'd0 : c[182:176];
   7'd5:number=ps[1] ? 7'd0 : s[381:375];
   7'd6:number=ps[1] ? 3'd0 : c[185:183];
   7'd7:number=ps[1] ? 3'd0 : s[366:364];
   7'd8:number=c[81:75]<36 ? 1 : c[81:75]<48 ? 2 : c[81:75]<60 ? 3 : c[81:75]<72 ? 4 : 5;
   7'd9:number=c[88:82]<36 ? 1 : c[88:82]<48 ? 2 : c[88:82]<60 ? 3 : c[88:82]<72 ? 4 : 5;
   7'd10:number=s[192+0*32+:17];
   7'd11:number=s[192+1*32+:17];
   7'd12:number=s[192+2*32+:17];
   7'd13:number=s[192+3*32+:17];
   7'd14:number={30'd0,s[7:6]}+1;
   7'd15:number=s[53:51];
   7'd16:number=minimum_length_ms;
   7'd17:number=ps[1] ? 17'd8 : (a[152:151]+17'd1)*4;
   7'd18:number=h[0*12+:12]==4095 ? 256 : {20'd0,h[0*12+:12]}>>4;
   7'd19:number=h[1*12+:12]==4095 ? 256 : {20'd0,h[1*12+:12]}>>4;
   7'd20:number=h[2*12+:12]==4095 ? 256 : {20'd0,h[2*12+:12]}>>4;
   7'd21:number=h[3*12+:12]==4095 ? 256 : {20'd0,h[3*12+:12]}>>4;
   7'd22:number=s[328:320];
   7'd23:number=s[337:329];
   7'd24:number=s[346:338];
   7'd25:number=s[360:352];
   7'd26:number=w[15:4]==4095 ? 17'd65536 : {1'd0,w[15:4],4'd0};
   7'd27:number=w[32:16];
   7'd28:number=s[39:32];
   7'd29:number=s[47:40];
   7'd30:number=s[50:48];
   7'd31:number={s[623:615],8'd0};
   7'd32:number=score[31:16];
   7'd33:number=score[10:9];
   7'd34:number=guide[22] ? -$signed(guide[22:17]) : guide[22:17];
   7'd35:number=s[176:160];
   7'd36:number=s[159:152];
   7'd37:number=ps[1] ? 8'd16 : s[639:632];
   7'd38:number=c[81:75]/12-1;
   7'd39:number=c[88:82]/12-1;
   7'd40:number=s[75:64];
   7'd41:number=s[123:112];
   7'd42:number=2048;
   7'd43:number=adc[0*12+:12];
   7'd44:number=adc[1*12+:12];
   7'd45:number=adc[2*12+:12];
   7'd46:number=adc[3*12+:12];
   7'd47:number=adc[4*12+:12];
   7'd48:number=adc[5*12+:12];
   7'd49:number=adc[6*12+:12];
   7'd50:number=adc[7*12+:12];
   7'd51:number=s[631:624];
   7'd52:number=score[47:32];
   7'd53:number=score[79:64];
   7'd54:number=score[63:48];
   7'd55:number=score[95:80];
   7'd56:number=score[111:96];
   7'd57:number=guide[16:9];
   7'd58:number={12'd0,guide[8:4]}+1;
   7'd59:number=ps[223:208];
   7'd60:number=ps[239:224];
   7'd61:number=ps[255:240];
   7'd62:number=ps[31:16];
   8'd133:number=lib[21:16]==0 ? 0:{12'd0,lib[28:24]}+1'b1;
   8'd134:number=lib[21:16];8'd135:number=lib[47:32];8'd136:number=lib[63:48];
   8'd137:number=0;8'd138:number=lib[144:128];8'd139:number=lib[176:160];
   7'd63:number=WITH_LIBRARY ? 17'd0:elapsed_seconds;
   7'd64:number=WITH_LIBRARY ? 17'd0:duration_seconds;
   7'd65:number=ps[207:192];
   7'd66:number=ps[287:256];
   7'd67:number=rs[51:36];
   7'd68:number=rs[83:68];
   7'd69:number=512;
   7'd70:number=rs[67:52];
   7'd71:number=rs[91:84];
   7'd72:number=0+1;
   7'd73:number=1+1;
   7'd74:number=2+1;
   7'd75:number=3+1;
   7'd76:number=4+1;
   7'd77:number=5+1;
   7'd78:number=6+1;
   7'd79:number=7+1;
   7'd80:number=8+1;
   7'd81:number=9+1;
   7'd82:number=10+1;
   7'd83:number=11+1;
   7'd84:number=12+1;
   7'd85:number=13+1;
   7'd86:number=14+1;
   7'd87:number=15+1;
   7'd88:number=16+1;
   7'd89:number=17+1;
   7'd90:number=18+1;
   7'd91:number=19+1;
   7'd92:number=20+1;
   7'd93:number=21+1;
   7'd94:number=22+1;
   7'd95:number=23+1;
   7'd96:number=24+1;
   8'd97,8'd98,8'd99,8'd100,8'd101,8'd102,8'd103,8'd104,8'd105,8'd106,8'd107,8'd108,8'd109,8'd110,8'd111,8'd112,8'd113,8'd114,8'd115,8'd116,8'd117,8'd118,8'd119,8'd120,8'd121:number={12'd0,map_operand_q}+17'd1;
   7'd122:number=ps[307:300];
   7'd123:number=rs[106:99];
   7'd124:number={1'b0,env_item_value};
   7'd125:number=envelope_grade(env_item_value);
   7'd126:number=16;
   8'd128:number=dds[35:29]==24 ? 1 : dds[35:29]==36 ? 2 : dds[35:29]==48 ? 3 : dds[35:29]==60 ? 4 : 5;
   8'd129:number=dds[43:36];
   8'd130:begin case(vc[7:4])
    4'd0:number=80;
    4'd1:number=120;
    4'd2:number=180;
    4'd3:number=260;
    4'd4:number=380;
    4'd5:number=550;
    4'd6:number=800;
    4'd7:number=1100;
    4'd8:number=1600;
    4'd9:number=2300;
    4'd10:number=3300;
    4'd11:number=4700;
    4'd12:number=6800;
    4'd13:number=9600;
    4'd14:number=13000;
    4'd15:number=16000;
    endcase end
   8'd131:number=vc[13:11];
   8'd132:number=vc[51:40];
   7'd127:number={env[87:80],9'd0};
   default:number=0;
  endcase
 end

 reg[4:0]map_operand_q;
 function[4:0]select_map_operand;input[7:0]id;begin case(id)
 8'd97:select_map_operand=ps[364+:5];
 8'd98:select_map_operand=ps[369+:5];
 8'd99:select_map_operand=ps[374+:5];
 8'd100:select_map_operand=ps[379+:5];
 8'd101:select_map_operand=ps[384+:5];
 8'd102:select_map_operand=ps[389+:5];
 8'd103:select_map_operand=ps[394+:5];
 8'd104:select_map_operand=ps[399+:5];
 8'd105:select_map_operand=ps[404+:5];
 8'd106:select_map_operand=ps[409+:5];
 8'd107:select_map_operand=ps[414+:5];
 8'd108:select_map_operand=ps[419+:5];
 8'd109:select_map_operand=ps[424+:5];
 8'd110:select_map_operand=ps[429+:5];
 8'd111:select_map_operand=ps[434+:5];
 8'd112:select_map_operand=ps[439+:5];
 8'd113:select_map_operand=ps[444+:5];
 8'd114:select_map_operand=ps[449+:5];
 8'd115:select_map_operand=ps[454+:5];
 8'd116:select_map_operand=ps[459+:5];
 8'd117:select_map_operand=ps[464+:5];
 8'd118:select_map_operand=ps[469+:5];
 8'd119:select_map_operand=ps[474+:5];
 8'd120:select_map_operand=ps[479+:5];
 8'd121:select_map_operand=ps[484+:5];
 default:select_map_operand=0;
 endcase end endfunction
 reg [16:0] number_q;reg percentage_q,sustain_round_q;
 wire [23:0] percent_product=({7'd0,number_q}<<6)+({7'd0,number_q}<<5)+({7'd0,number_q}<<2);
 wire[7:0] percent_display=percent_product[23:16]+{7'd0,(sustain_round_q&&percent_product[15])};
 reg [31:0] output_word;reg [4:0] phase;reg [16:0] binary_value;reg [23:0] bcd,bcd_adjusted;
 reg [3:0] digit_position;reg field_q,metadata_q,literal_q;
 reg [8:0] ch_q;reg [3:0] color_q;reg [12:0] record_q;integer digit;
 wire [23:0] selected_bcd=bcd>>(digit_position*4);
 wire [8:0] decimal_character=(digit_position!=0&&selected_bcd==0) ? 9'd32 : 9'd48+{5'd0,selected_bcd[3:0]};
 always @* begin bcd_adjusted=bcd;for(digit=0;digit<6;digit=digit+1)if(bcd[digit*4+:4]>=5)bcd_adjusted[digit*4+:4]=bcd[digit*4+:4]+3;end
 assign wr_data=output_word;assign publish=wr_en&&(&wr_addr);
 function alias_known;input[15:0]id;begin alias_known=id==16'd1||id==16'd3||id==16'd4;end endfunction
function[7:0]alias_byte;input[15:0]id;input[5:0]idx;reg[319:0]raw;begin case(id)
16'd1:raw=320'h0000000000000000000000000000000096bce7b994e6ae94e9353220b7c22082a2e990b9e4a2ace6;
16'd3:raw=320'h0000000000000000000096bce7b994e6ae94e9353220b7c220bfaee6abaee58b8ee794ade9b1b1e5;
16'd4:raw=320'h0000000000000000000000000000000096bce7b994e6ae94e9353220b7c22090ade596a2e8bfbbe7;
default:raw=0;endcase alias_byte=raw[idx*8+:8];end endfunction
function[5:0]alias_label;input[15:0]id;begin case(id)
16'd1:alias_label=42;16'd3:alias_label=43;16'd4:alias_label=44;
default:alias_label=26;endcase end endfunction
function alias_tail_equal;input[15:0]id;input[127:0]tail;begin case(id)
16'd1:alias_tail_equal=tail==128'h00000000000000000000000000000000;
16'd3:alias_tail_equal=tail==128'h0000000000000000000096bce7b994e6;
16'd4:alias_tail_equal=tail==128'h00000000000000000000000000000000;
default:alias_tail_equal=0;endcase end endfunction
 reg title_match,title_ascii,selection_match,selection_ascii;
 wire[7:0]title_char=title_display_byte,selection_char=selection_display_byte;
 wire title_equal=title_char==alias_byte(ps[31:16],title_index);
 wire selection_equal=selection_char==alias_byte(lib[47:32],title_index);
 always @(posedge clk)if(!busy)begin
  ges<=gesture_expression_status;gs<=gesture_status;dds<=dd_status;vc<=v18_status;envelope_feedback<=feedback_clocks!=0;env<=envelope_status;ps<=practice_status;rs<=record_status;title<=song_title[191:0];selection_title<=library_title[63:0];title_truncated<=|song_title[319:192];selection_truncated<=library_title[318];lib<=library_status;s<=snapshot;w<=synth_status;lt<=layer_timbres;c<=controller;a<=audio_status;h<=harmonics;adc<=adc_raw;n<=navigation;score<=score_status;guide<=guide_status;st<=storage_status;
  title_alias<=0;selection_alias<=0;title_fallback<=(song_title[7]|song_title[15]|song_title[23]|song_title[31]|song_title[39]|song_title[47]|song_title[55]|song_title[63]|song_title[71]|song_title[79]|song_title[87]|song_title[95]|song_title[103]|song_title[111]|song_title[119]|song_title[127]|song_title[135]|song_title[143]|song_title[151]|song_title[159]|song_title[167]|song_title[175]|song_title[183]|song_title[191]|song_title[199]|song_title[207]|song_title[215]|song_title[223]|song_title[231]|song_title[239]|song_title[247]|song_title[255]|song_title[263]|song_title[271]|song_title[279]|song_title[287]|song_title[295]|song_title[303]|song_title[311]|song_title[319]);selection_fallback<=library_title[319];
 end

 always @(posedge clk)begin
  if(rst)begin busy<=0;address<=0;wr_en<=0;wr_addr<=0;phase<=0;binary_value<=0;bcd<=0;digit_position<=0;field_q<=0;metadata_q<=0;literal_q<=0;ch_q<=32;color_q<=0;record_q<=0;output_word<=0;
   map_operand_q<=0;value_id_q<=0;number_q<=0;percentage_q<=0;sustain_round_q<=0;mapped_row_q<=0;mapped_col_q<=0;progress_col<=6'd62;label_bank_pipe<=0;label_literal_pipe<=0;label_origin_pipe<=0;label_basis_pipe<=0;label_relative_pipe<=0;label_address_q<=0;time_value<=0;time_remainder<=0;time_count<=0;time_second<=0;library_seconds<=0;elapsed_seconds<=0;duration_seconds<=0;end
  else begin
   wr_en<=0;
   if(!busy)begin if(snapshot_valid&&ready&&!wr_en)begin busy<=1;address<=0;phase<=24;
    time_value<=WITH_LIBRARY ? 32'd0:practice_status[159:128];time_remainder<=0;time_count<=31;time_second<=0;end end
   else if(phase==24)begin
    time_value<=time_next;time_remainder<=time_take ? time_shift-21'd1000000 : time_shift;
    if(time_count!=0)time_count<=time_count-1'b1;
    else if(time_second==0)begin elapsed_seconds<=time_next[15:0];time_value<=WITH_LIBRARY ? 32'd0:ps[191:160];time_remainder<=0;time_count<=31;time_second<=1;end
    else if(time_second==1)begin duration_seconds<=time_next[15:0];
     if(WITH_LIBRARY)begin time_value<=lib[95:64];time_remainder<=0;time_count<=31;time_second<=2;end else phase<=0;
    end else begin library_seconds<=time_next[15:0];phase<=0;end
   end
   else if(phase==0)begin mapped_row_q<=mapped_row;mapped_col_q<=mapped_col;progress_col<=mapped_col-6'd2;phase<=25;end
   else if(phase==25)begin
    label_bank_pipe<=label_bank;label_literal_pipe<=label_literal;label_origin_pipe<=label_origin;label_basis_pipe<=label_basis;label_relative_pipe<=label_relative;value_id_q<=value_id;percentage_q<=percentage;sustain_round_q<=sustain_round;bcd<=0;digit_position<=number_position;
    field_q<=numeric;metadata_q<=metadata;literal_q<=literal;color_q<=color;record_q<=record;phase<=27;
   end else if(phase==27)begin label_address_q<={label_bank_pipe,label_column_pipe};map_operand_q<=select_map_operand(value_id_q);ch_q<=ch;phase<=28;
   end else if(phase==28)begin number_q<=number;phase<=26;
   end else if(phase==26)begin
    binary_value<=percentage_q ? {9'd0,percent_display} : number_q;phase<=1;
   end else if(phase<=17)begin bcd<={bcd_adjusted[22:0],binary_value[16]};binary_value<={binary_value[15:0],1'b0};phase<=phase+1'b1;end
   else begin
    wr_addr<=address;wr_en<=1;output_word<={scene,3'd0,metadata_q ? record_q : {color_q,field_q ? decimal_character : literal_q ? ch_q : label}};
    phase<=0;if(&address)busy<=0;else address<=address+1'b1;
   end
  end
 end
endmodule
