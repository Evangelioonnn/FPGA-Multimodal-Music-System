// Grayscale framing only. Outline and enlarged view use the committed native ROI.
// Registered address + three memory cycles + output, all overlays equally delayed.
module p20_crop_live_render(input wire clk,rst,input wire [10:0] x,y,input wire de,hs,vs,
    input wire have_frame,configured,frozen,input wire [3:0] error,input wire [31:0] frame_id,
    input wire [8:0] roi_x,input wire [7:0] roi_y,input wire [8:0] roi_side,
    input wire [511:0] result_payload,
    input wire track_enable,track_initialized,track_valid,input wire [8:0] track_x,input wire [7:0] track_y,
    input wire [2:0] track_direction,input wire [31:0] track_frame,input wire track_held,input wire sustain_valid,sustain_request,sustain_unstable,sustain_fault,
    output reg [14:0] read_address,output reg [11:0] model_address,input wire [7:0] preview_data,model_data,
    output reg [23:0] rgb,output reg out_de,out_hs,out_vs,
    output reg [9:0] debug_address,input wire debug_data,
    input wire [10:0] skin_pixels,best_pixels,input wire [3:0] reject_reason,
    input wire effect_owned,effect_returning,input wire [1:0] effect_axis,
    input wire [7:0] effect_gain,input wire signed [7:0] effect_bend);
    wire left=x>=32 && x<672 && y>=128 && y<608;
    wire right=x>=832 && x<1088 && y>=160 && y<416;
    wire mask_view=track_enable && have_frame && x>=1104 && x<1232 && y>=160 && y<288;
    wire [10:0] debug_x=x-11'd1104,debug_y=y-11'd160;
    reg [3:0] mask_pipe;reg debug_delay;
    reg [10:0] skin,best,skin0,best0;reg [3:0] why,why0;
    wire [10:0] bx=11'd32+{roi_x,1'b0},by=11'd128+{roi_y,1'b0};
    wire [10:0] ex=bx+{roi_side,1'b0},ey=by+{roi_side,1'b0};
    wire inside_roi=x>=bx && x<ex && y>=by && y<ey;
    wire border=left && inside_roi && (x<bx+2 || x>=ex-2 || y<by+2 || y>=ey-2);
    wire [10:0] lx=x-11'd32,ly=y-11'd128,rx=x-11'd832,ry=y-11'd160;
    wire [5:0] mx=rx[7:2],my=ry[7:2];wire [7:0] sx=lx[9:2];wire [6:0] sy=ly[8:2];
    wire [14:0] row_base={sy,7'b0}+{2'b0,sy,5'b0};
    reg [4:0] view_pipe[0:3];reg [3:0] de_pipe,hs_pipe,vs_pipe,text_pipe;
    reg [5:0] label0;reg [2:0] row0,col0,row1,col1,col2;reg [4:0] char0,font_pixels;
    reg [31:0] frame0;reg [11:0] rx0,ry0,side0;reg [7:0] ascii1;wire [4:0] font_row;reg dot3;
    p20_crop_live_font font(ascii1,row1,col1,,font_row);
    localparam [255:0] TEXT0=256'h4753322b474533202f2058592045464645435453202f2052334c202020202020;
    localparam [255:0] TEXT1=256'h46554c4c2056494557202f20424c5545204d414e55414c20524f492020202020;
    localparam [255:0] TEXT2=256'h535553543A4F4646204F574E3A3020553A3020463A30205458204F4E4C592020;
    localparam [255:0] TEXT3=256'h475241593634202f2053414d45204e415449564520524f492020202020202020;
    localparam [255:0] TEXT4=256'h4652414d453a2020202020202020202020202020202020202020202020202020;
    localparam [255:0] TEXT5=256'h53302053495A45202F205332204D4F5645202020202020202020202020202020;
    localparam [255:0] TEXT6=256'h524553554c543a20574149542020202020202020202020202020202020202020;
    localparam [255:0] TEXT7=256'h524553554c543a204f50454e2020202020202020202020202020202020202020;
    localparam [255:0] TEXT8=256'h524553554c543a20464953542020202020202020202020202020202020202020;
    localparam [255:0] TEXT9=256'h524553554c543a2052454a454354202020202020202020202020202020202020;
    localparam [255:0] TEXT10=256'h524553554c543a205354414c4520202020202020202020202020202020202020;
    localparam [255:0] TEXT11=256'h524553554c543a204552524f5220202020202020202020202020202020202020;
    localparam [255:0] TEXT12=256'h504f53453a204f50454e20202020202020202020202020202020202020202020;
    localparam [255:0] TEXT13=256'h504f53453a204649535420202020202020202020202020202020202020202020;
    localparam [255:0] TEXT14=256'h504f53453a205741495420202020202020202020202020202020202020202020;
    localparam [255:0] TEXT15=256'h504f5345204741503a2030303020513420202020202020202020202020202020;
    localparam [255:0] TEXT16=256'h414343455054204741503a202b30303020513420202020202020202020202020;
    localparam [255:0] TEXT17=256'h524541534f4e3a204e4f4e452020202020202020202020202020202020202020;
    localparam [255:0] TEXT18=256'h524541534f4e3a20504f53452047415020202020202020202020202020202020;
    localparam [255:0] TEXT19=256'h524541534f4e3a20414343455054204741502020202020202020202020202020;
    localparam [255:0] TEXT20=256'h524541534f4e3a20504f5345202b204143434550542020202020202020202020;
    localparam [255:0] TEXT21=256'h524541534f4e3a2043414d455241205345545550202020202020202020202020;
    localparam [255:0] TEXT22=256'h524541534f4e3a20434f5245204641554c542020202020202020202020202020;
    localparam [255:0] TEXT23=256'h524541534f4e3a205354414c4520202020202020202020202020202020202020;
    localparam [255:0] TEXT24=256'h524541534f4e3a2057414954204652414d452020202020202020202020202020;
    localparam [255:0] TEXT25=256'h4650533a20303030202f204652414d4520524553554c54532020202020202020;
    localparam [255:0] TEXT26=256'h4D4F44454C3A204F4E4348495020524F4D205247423332202020202020202020;
    localparam [255:0] TEXT27=256'h4d41534b3a30303020415245413a303030205748593a30202020202020202020;
    localparam [255:0] TEXT_FIXED=256'h524f493a204d414e55414c202f204649584544205245434f474e4954494f4e20;
    reg sv,sr,su,sf,sv0,sr0,su0,sf0;
    always @(posedge clk)if(rst)begin sv<=0;sr<=0;su<=0;sf<=1;end
      else if(y>=720)begin sv<=sustain_valid;sr<=sustain_request;su<=sustain_unstable;sf<=sustain_fault;end
    reg te,ti,tv,ts;reg [8:0] hx;reg [7:0] hy;reg [2:0] direction;reg [31:0] mf;
    reg [3:0] cross_pipe;reg [8:0] hx0;reg [7:0] hy0;reg [2:0] direction0;reg [31:0] mf0;
    reg [1:0] track_status0;
    wire [10:0] cross_x=11'd32+{hx,1'b0},cross_y=11'd128+{hy,1'b0};
    wire crosshair=te && tv && left &&
      ((x==cross_x && y+11'd10>=cross_y && y<=cross_y+11'd10) ||
       (y==cross_y && x+11'd10>=cross_x && x<=cross_x+11'd10));
    always @(posedge clk)if(rst)begin te<=0;ti<=0;tv<=0;ts<=0;hx<=0;hy<=0;direction<=0;mf<=0;end
      else if(y>=720)begin te<=track_enable;ti<=track_initialized;tv<=track_valid;ts<=track_held;
        hx<=track_x;hy<=track_y;direction<=track_direction;mf<=track_frame;end
    always @(posedge clk)if(rst)begin skin<=0;best<=0;why<=0;end
      else if(y>=720)begin skin<=skin_pixels;best<=best_pixels;why<=reject_reason;end
    localparam [255:0] TEXT28=256'h48414e4420583a2030303020593a203030302020202020202020202020202020;
    localparam [255:0] TEXT29=256'h4d4f56453a205354494c4c202020202020202020202020202020202020202020;
    localparam [255:0] TEXT30=256'h545241434b3a2057414954202020202020202020202020202020202020202020;
    localparam [255:0] TEXT31=256'h4d45415355524544204652414d453a2030303030303030302020202020202020;
    reg [511:0] display_payload;
    always @(posedge clk)if(rst)display_payload<=0;else if(y>=720)display_payload<=result_payload;
    wire [7:0] rs=display_payload[503:496],cl=display_payload[495:488],reason=display_payload[487:480];
    wire signed [7:0] log_o=display_payload[447:440],log_f=display_payload[439:432];
    wire [15:0] pg={display_payload[407:400],display_payload[415:408]};
    wire signed [15:0] ag={display_payload[391:384],display_payload[399:392]};
    wire [15:0] fps={display_payload[87:80],display_payload[95:88]};
    wire [15:0] abs_ag=ag<0 ? -ag:ag;
    reg [9:0] number0;reg sign0;reg [5:0] label;reg text_enable;
    reg [10:0] tx,ty;
    (* syn_romstyle="block_rom" *) reg [7:0] labels[0:2047];
    localparam [255:0] TEXT32=256'h58593a3020415849533a5741495420564f4c3a31303020423a2b303030432020;
    wire [14:0] gain_times100={1'b0,effect_gain,6'd0}+{2'd0,effect_gain,5'd0}+{5'd0,effect_gain,2'd0};
    wire [14:0] gain_rounded=gain_times100+15'd128;
    wire [6:0] gain_percent=effect_gain==255 ? 7'd100 : gain_rounded[14:8];
    wire [7:0] bend_abs=effect_bend<0 ? -effect_bend : effect_bend;
    wire [11:0] bend_times25={bend_abs,4'd0}+{1'd0,bend_abs,3'd0}+{4'd0,bend_abs};
    wire [11:0] cents_rounded=bend_times25+12'd8;
    reg fx_own,fx_return,fx_negative,fx_own0,fx_return0,fx_negative0;
    reg [1:0] fx_axis,fx_axis0;reg [6:0] fx_gain,fx_cents,fx_gain0,fx_cents0;
    always @(posedge clk)if(rst)begin
      fx_own<=0;fx_return<=0;fx_negative<=0;fx_axis<=0;fx_gain<=100;fx_cents<=0;
    end else if(y>=720)begin
      fx_own<=effect_owned;fx_return<=effect_returning;fx_negative<=effect_bend<0;
      fx_axis<=effect_axis;fx_gain<=gain_percent;fx_cents<=cents_rounded[10:4];
    end
    integer c;
    initial begin
        for(c=0;c<1024;c=c+1)labels[c]=8'd32;
        for(c=0;c<1024;c=c+1)labels[1024+c]=8'd32;
        for(c=0;c<32;c=c+1)labels[0+c]=TEXT0[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[32+c]=TEXT1[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[64+c]=TEXT2[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[96+c]=TEXT3[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[128+c]=TEXT4[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[160+c]=TEXT5[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[192+c]=TEXT6[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[224+c]=TEXT7[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[256+c]=TEXT8[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[288+c]=TEXT9[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[320+c]=TEXT10[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[352+c]=TEXT11[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[384+c]=TEXT12[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[416+c]=TEXT13[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[448+c]=TEXT14[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[480+c]=TEXT15[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[512+c]=TEXT16[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[544+c]=TEXT17[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[576+c]=TEXT18[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[608+c]=TEXT19[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[640+c]=TEXT20[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[672+c]=TEXT21[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[704+c]=TEXT22[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[736+c]=TEXT23[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[768+c]=TEXT24[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[800+c]=TEXT25[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[832+c]=TEXT26[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[864+c]=TEXT27[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[896+c]=TEXT28[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[928+c]=TEXT29[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[960+c]=TEXT30[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[992+c]=TEXT31[255-c*8-:8];
        for(c=0;c<32;c=c+1)labels[1024+c]=TEXT32[255-c*8-:8];
    end
    always @* begin
        label=0;tx=x-11'd32;ty=0;text_enable=x>=32 && x<544;
        if(y>=32 && y<48)begin label=0;ty=y-11'd32;end
        else if(y>=104 && y<120)begin label=32;ty=y-11'd104;end
        else if(y>=80 && y<96)begin label=1;ty=y-11'd80;end
        else if(y>=632 && y<648 && x<800)begin label=2;ty=y-11'd632;end
        else if(y>=664 && y<680 && x<800)begin label=5;ty=y-11'd664;end
        else begin
            tx=x-11'd800;text_enable=x>=800 && x<1280;
            if(y>=112 && y<128)begin label=3;ty=y-11'd112;end
            else if(y>=432 && y<448)begin label=rs==0 ? 6:rs==2 ? 10:rs==3 ? 11:cl==1 ? 7:cl==2 ? 8:9;ty=y-11'd432;end
            else if(y>=464 && y<480)begin label=4;ty=y-11'd464;end
            else if(y>=496 && y<512)begin label=rs!=1 ? 14:log_o>=log_f ? 12:13;ty=y-11'd496;end
            else if(y>=528 && y<544)begin label=te ? 28:15;ty=y-11'd528;end
            else if(y>=560 && y<576)begin label=te ? 29:16;ty=y-11'd560;end
            else if(y>=592 && y<608)begin
                label=te ? 30:rs==0 ? 24:rs==2 ? 23:reason[2] ? 21:reason[3] ? 22:
                    reason[1:0]==3 ? 20:reason[1] ? 19:reason[0] ? 18:17;ty=y-11'd592;
            end
            else if(y>=624 && y<640)begin label=25;ty=y-11'd624;end
            else if(y>=656 && y<672)begin label=te ? 31:26;ty=y-11'd656;end
            else if(y>=688 && y<704)begin label=27;ty=y-11'd688;end
            else text_enable=0;
        end
    end
    function [7:0] hexchar;input [3:0] n;begin hexchar=n<10 ? 8'd48+n:8'd55+n;end endfunction
    function [7:0] decimal_digit;input [9:0] v;input [1:0] place;reg [9:0] digit;
        begin digit=place==2 ? v/100:place==1 ? (v/10)%10:v%10;
            decimal_digit=8'd48+{4'd0,digit[3:0]};end
    endfunction
    function [7:0] move_char;input [2:0] d;input [4:0] p;reg [39:0] word;begin
      case(d)1:word="LEFT ";2:word="RIGHT";3:word="UP   ";4:word="DOWN ";default:word="STILL";endcase
      move_char=word[(10-p)*8+:8];end endfunction
    function [7:0] status_char;input [1:0] st;input [4:0] p;reg [255:0] word;begin
      case(st)0:word=256'h545241434b3a20534541524348202f204d4f56452048414e4420202020202020;1:word=256'h545241434b3a20484f4c44202f204e4f204e4557205859202020202020202020;2:word=256'h545241434b3a204c495645202f204155544f2058592020202020202020202020;3:word=256'h545241434b3a204c4f5354202f204155544f2053454152434820202020202020;endcase
      status_char=word[255-p*8-:8];end endfunction
    function [7:0] axis_char;input [1:0] a;input own,ret;input [4:0] p;reg [31:0] word;begin
      if(!own)word=ret ? "BACK" : "MAN ";
      else case(a)1:word="BEND";2:word="VOL ";default:word="WAIT";endcase
      axis_char=word[(13-p)*8+:8];end endfunction
    wire [7:0] gray=view_pipe[3][1] ? model_data:preview_data;
    integer i;
    always @(posedge clk)begin
        if(label0==32 && char0==3)ascii1<=fx_own0 ? 8'd49 : fx_return0 ? 8'd82 : 8'd48;
        else if(label0==32 && char0>=10 && char0<=13)ascii1<=axis_char(fx_axis0,fx_own0,fx_return0,char0);
        else if(label0==32 && char0>=19 && char0<=21)ascii1<=decimal_digit({3'd0,fx_gain0},char0==19 ? 2 : char0==20 ? 1 : 0);
        else if(label0==32 && char0==25)ascii1<=fx_negative0 ? 8'd45 : 8'd43;
        else if(label0==32 && char0>=26 && char0<=28)ascii1<=decimal_digit({3'd0,fx_cents0},char0==26 ? 2 : char0==27 ? 1 : 0);
        else if(label0==2 && char0>=5 && char0<=7)begin
          if(sr0)ascii1<=char0==5 ? 8'd79:char0==6 ? 8'd78:8'd32;
          else ascii1<=char0==5 ? 8'd79:8'd70;
        end else if(label0==2 && char0==13)ascii1<=sv0 ? 8'd49:8'd48;
        else if(label0==2 && char0==17)ascii1<=su0 ? 8'd49:8'd48;
        else if(label0==2 && char0==21)ascii1<=sf0 ? 8'd49:8'd48;
        else if(label0==28 && ((char0>=8 && char0<=10) || (char0>=15 && char0<=17)))begin
          if(!tv)ascii1<=8'd45;
          else ascii1<=decimal_digit(char0<11 ? {1'b0,hx0}:{2'b0,hy0},char0==8 || char0==15 ? 2:char0==9 || char0==16 ? 1:0);
        end else if(label0==29 && char0>=6 && char0<=10)ascii1<=tv ? move_char(direction0,char0):8'd45;
        else if(label0==30)ascii1<=status_char(track_status0,char0);
        else if(label0==27 && te && char0>=5 && char0<=7)ascii1<=hexchar(({1'b0,skin0}>>((7-char0)*4))&15);
        else if(label0==27 && te && char0>=14 && char0<=16)ascii1<=hexchar(({1'b0,best0}>>((16-char0)*4))&15);
        else if(label0==27 && te && char0==22)ascii1<=hexchar(why0);
        else if(label0==31 && char0>=16 && char0<24)ascii1<=hexchar(mf0[(23-char0)*4+:4]);
        else if(label0==4 && char0>=7 && char0<15)ascii1<=hexchar(frame0[(14-char0)*4+:4]);
        else if((label0==15 && char0>=10 && char0<13) || (label0==16 && char0>=13 && char0<16) || (label0==25 && char0>=5 && char0<8))begin
            if(label0!=25 && rs!=1)ascii1<=8'd45;
            else if(char0==(label0==15 ? 10:label0==16 ? 13:5))ascii1<=decimal_digit(number0,2);
            else if(char0==(label0==15 ? 11:label0==16 ? 14:6))ascii1<=decimal_digit(number0,1);
            else ascii1<=decimal_digit(number0,0);
        end else if(label0==16 && char0==12)ascii1<=sign0 ? 8'd45:8'd43;
        else if(label0==27 && !te)ascii1<=TEXT_FIXED[255-char0*8-:8];
        else ascii1<=labels[{label0,char0}];
        if(rst)begin
            read_address<=0;model_address<=0;rgb<=0;out_de<=0;out_hs<=0;out_vs<=0;
            de_pipe<=0;hs_pipe<=0;vs_pipe<=0;text_pipe<=0;
            debug_address<=0;debug_delay<=0;mask_pipe<=0;skin0<=0;best0<=0;why0<=0;
            for(i=0;i<4;i=i+1)view_pipe[i]<=0;
            fx_own0<=0;fx_return0<=0;fx_negative0<=0;fx_axis0<=0;fx_gain0<=100;fx_cents0<=0;
            sv0<=0;sr0<=0;su0<=0;sf0<=1;cross_pipe<=0;hx0<=0;hy0<=0;direction0<=0;mf0<=0;track_status0<=0;number0<=0;sign0<=0;label0<=0;char0<=0;frame0<=0;rx0<=0;ry0<=0;side0<=0;row0<=0;col0<=0;row1<=0;col1<=0;col2<=0;font_pixels<=0;dot3<=0;
        end else begin
            read_address<=left ? row_base+{7'b0,sx}:15'd0;model_address<=right ? {my,mx}:12'd0;
            debug_address<={debug_y[6:2],debug_x[6:2]};debug_delay<=debug_data;mask_pipe<={mask_pipe[2:0],mask_view};
            skin0<=skin;best0<=best;why0<=why;
            fx_own0<=fx_own;fx_return0<=fx_return;fx_negative0<=fx_negative;fx_axis0<=fx_axis;fx_gain0<=fx_gain;fx_cents0<=fx_cents;
            sv0<=sv;sr0<=sr;su0<=su;sf0<=sf;cross_pipe<={cross_pipe[2:0],crosshair};hx0<=hx;hy0<=hy;direction0<=direction;mf0<=mf;
            track_status0<=!ti ? 0:tv ? (ts ? 1:2):3;
            view_pipe[0]<={have_frame,inside_roi,border,right,left};
            for(i=1;i<4;i=i+1)view_pipe[i]<=view_pipe[i-1];
            de_pipe<={de_pipe[2:0],de};hs_pipe<={hs_pipe[2:0],hs};vs_pipe<={vs_pipe[2:0],vs};text_pipe<={text_pipe[2:0],text_enable};
            number0<=label==15 ? pg[9:0]:label==16 ? abs_ag[9:0]:fps>999 ? 10'd999:fps[9:0];sign0<=ag<0;label0<=label;char0<=tx[8:4];frame0<=frame_id;rx0<={3'b0,roi_x};ry0<={4'b0,roi_y};side0<={3'b0,roi_side};row0<=ty[3:1];col0<=tx[3:1];
            row1<=row0;col1<=col0;font_pixels<=font_row;col2<=col1;dot3<=col2<5 ? font_pixels[4-col2]:1'b0;
            out_de<=de_pipe[3];out_hs<=hs_pipe[3];out_vs<=vs_pipe[3];rgb<=24'h101820;
            if(view_pipe[3][0] || view_pipe[3][1])begin
                rgb<=24'h182030;
                if(view_pipe[3][4])begin
                    if(view_pipe[3][1] || view_pipe[3][3])rgb<={gray,gray,gray};
                    else rgb<={2'b0,gray[7:2],2'b0,gray[7:2],2'b0,gray[7:2]};
                end
            end
            if(view_pipe[3][2])rgb<=frozen ? 24'h40ff80:24'h20d8ff;
            if(cross_pipe[3])rgb<=ts ? 24'hffb840:24'h40ff80;
            if(mask_pipe[3])rgb<=debug_delay ? 24'hf0e080:24'h080808;
            if(text_pipe[3] && dot3)rgb<=24'he8eef8;
            if(!de_pipe[3])rgb<=0;
        end
    end
endmodule
