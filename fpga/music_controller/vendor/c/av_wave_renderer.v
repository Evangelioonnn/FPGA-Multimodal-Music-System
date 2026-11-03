// Five stages: RAM -> amplitude register -> min/max -> segment/glyph -> RGB.
// A 512-pair PCM bank is displayed as two 1024x256 graphs using its upper bytes.
module av_wave_renderer(input wire clk,rst,input wire [10:0] x,y,
    input wire de,hs,vs,have_frame,frame_changed,frame_start,
    output wire [8:0] sample_address,input wire [39:0] sample_data,
    output reg [23:0] rgb,output reg out_de,out_hs,out_vs);
    wire in_x=x>=512 && x<1536;
    wire left_graph=in_x && y>=192 && y<448;
    wire right_graph=in_x && y>=544 && y<800;
    wire graph=left_graph || right_graph;
    wire [9:0] sample_offset=x[10:1]-10'd256;
    assign sample_address=graph ? sample_offset[8:0] : 9'd0;
    wire [7:0] ordinate=left_graph ? y[7:0]+8'd64 : y[7:0]-8'd32;
    wire border=graph && (x==512 || x==1535 || y==192 || y==447 || y==544 || y==799);
    wire grid=graph && (x[6:0]==0 || (left_graph&&y[5:0]==0) || (right_graph&&y[5:0]==32));
    wire zero=graph && (y==319 || y==671);
    wire [10:0] label_address={y[9:5],x[10:5]};
    wire [7:0] character=32;
    reg d1,d2,d3,d4,h1,h2,h3,h4,v1,v2,v3,v4;
    reg graph1,left1,odd1,first1,valid1;
    reg [7:0] y1,previous_left=127,previous_right=127;
    reg [3:0] row1,row2,col1,col2,col3;
    reg [5:0] cell_x1;reg [4:0] cell_y1;
    reg [7:0] character2;reg label3;
    function [7:0] hexchar;input [3:0] n;begin hexchar=n<10 ? 8'd48+{4'd0,n} : 8'd55+{4'd0,n};end endfunction
    reg [7:0] next_character;
    always @* begin
        next_character=character;
        if(cell_y1==8 && cell_x1>=51 && cell_x1<=54)begin
            case(cell_x1)
                51:next_character=hexchar(sample_data[23:20]);
                52:next_character=hexchar(sample_data[19:16]);
                53:next_character=hexchar(sample_data[7:4]);
                54:next_character=hexchar(sample_data[3:0]);
            endcase
            if(!valid1 || sample_data[39:36]!=4'hA)next_character=8'd45;
        end
        if(cell_y1==21 && cell_x1==53)begin
            next_character=hexchar(sample_data[35:32]);
            if(!valid1 || sample_data[39:36]!=4'hA)next_character=8'd45;
        end
    end
    reg [5:0] background1;
    // Palette data is hidden by the reset valid/de pipeline. It needs no
    // runtime reset mux, which otherwise extends the high-fanout reset path
    // through a three-level palette priority chain at 150 MHz.
    reg [23:0] base2=0,base3=0,base4=0;
    reg valid2,valid3,hit4,glyph3,glyph4,label1,label2;
    reg [7:0] current2,previous2,low3,high3,y2,y3;
    reg left2,left3,left4,badge1,badge2,badge3,badge4,stale1,stale2,stale3,stale4;
    reg [7:0] age=255;
    wire [7:0] current_left=8'd127-sample_data[15:8];
    wire [7:0] current_right=8'd127-sample_data[31:24];
    wire [7:0] current=left1 ? current_left : current_right;
    wire [7:0] previous=first1 ? current : left1 ? previous_left : previous_right;
    wire [7:0] low=current2<previous2 ? current2 : previous2;
    wire [7:0] high=current2>previous2 ? current2 : previous2;
    wire [15:0] font_bits=0;
    always @(posedge clk)begin
        if(rst)begin
            d1<=0;d2<=0;d3<=0;d4<=0;out_de<=0;h1<=0;h2<=0;h3<=0;h4<=0;out_hs<=0;v1<=0;v2<=0;v3<=0;v4<=0;out_vs<=0;
            graph1<=0;left1<=0;odd1<=0;first1<=0;valid1<=0;y1<=0;row1<=0;col1<=0;col2<=0;
            row2<=0;col3<=0;cell_x1<=0;cell_y1<=0;character2<=32;label3<=0;
            background1<=0;valid2<=0;valid3<=0;hit4<=0;glyph3<=0;glyph4<=0;label1<=0;label2<=0;left2<=0;left3<=0;left4<=0;
            current2<=0;previous2<=0;low3<=0;high3<=0;y2<=0;y3<=0;
            badge1<=0;badge2<=0;badge3<=0;badge4<=0;stale1<=1;stale2<=1;stale3<=1;stale4<=1;age<=255;
            previous_left<=127;previous_right<=127;
        end else begin
            if(frame_changed)age<=0;else if(frame_start && age!=255)age<=age+1'b1;
            d1<=de;d2<=d1;d3<=d2;d4<=d3;out_de<=d4;h1<=hs;h2<=h1;h3<=h2;h4<=h3;out_hs<=h4;v1<=vs;v2<=v1;v3<=v2;v4<=v3;out_vs<=v4;
            graph1<=graph;left1<=left_graph;odd1<=x[0];first1<=sample_offset==0;valid1<=have_frame;y1<=ordinate;
            row1<=y[4:1];col1<=x[4:1];col2<=col1;
            label1<=y<1024;label2<=label1;label3<=label2;
            cell_x1<=x[10:5];cell_y1<=y[9:5];
            character2<=next_character;row2<=row1;col3<=col2;
            // Decode geometry first; choose the palette one cycle later.
            background1<={x>=1376 && x<1856 && y>=160 && y<832,
                border,zero,grid,graph,y<80 || y>=1032};
            badge1<=x>=1792 && x<1856 && y>=112 && y<144;badge2<=badge1;badge3<=badge2;badge4<=badge3;
            stale1<=!have_frame || age>=120;stale2<=stale1;stale3<=stale2;stale4<=stale3;
            if(graph1 && odd1)begin previous_left<=current_left;previous_right<=current_right;end
            // BSRAM clock-to-output + offset/mux ends at this register.
            current2<=current;previous2<=previous;y2<=y1;valid2<=graph1 && valid1;
            // Compute segment bounds, then ordinate membership, separately.
            low3<=low;high3<=high;y3<=y2;valid3<=valid2;
            left2<=left1;left3<=left2;left4<=left3;
            hit4<=valid3 && y3>=low3 && y3<=high3;
            glyph4<=label3 && font_bits[15-col3];
        end
    end
    // Color is irrelevant while out_de=0. Keep the DE/sync reset, but avoid
    // routing the global150MHz reset into the final color-priority chain.
    always @(posedge clk) begin
            if(!d4)rgb<=0;
            else if(badge4)rgb<=stale4 ? 24'hEF8086 : 24'h78BEA1;
            else if(glyph4)rgb<=24'hE8E9E2;
            else if(hit4)rgb<=left4 ? 24'hD7BA7C : 24'h78BEA1;
            else rgb<=base4;
    end
    always @(posedge clk)begin
        base2<=24'h151719;
        if(background1[0])base2<=24'h242729;
        if(background1[1])base2<=24'h1C2225;
        if(background1[2])base2<=24'h333D42;
        if(background1[3])base2<=24'h566369;
        if(background1[4])base2<=24'h78858A;
        if(background1[5])base2<=24'h242729;
        base3<=base2;base4<=base3;
    end
endmodule
