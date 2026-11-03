// Both render paths stay active; frame-committed selection never gates audio.
module av_display(input wire clk,rst,page,input wire [10:0] x,y,
    input wire de,hs,vs,text_valid,scope_valid,text_changed,scope_changed,frame_start,
    output wire [10:0] text_address,input wire [12:0] text_data,input wire [15:0] scene,
    output wire [8:0] scope_address,input wire [39:0] scope_data,
    output wire [23:0] rgb,output wire out_de,out_hs,out_vs);
    wire [23:0] home_rgb,wave_rgb;
    wire hd,hh,hv,wd,wh,wv;
    wire [8:0] unused_address;
    // Isolate the raster counters from the two renderers' coordinate fanout.
    // RAM addresses and each renderer's first stage use these same coordinates.
    (* syn_preserve=1 *) reg [10:0] x1=0,y1=0;
    reg de1=0,hs1=0,vs1=0,text_valid1=0,scope_valid1=0;
    reg text_changed1=0,scope_changed1=0,frame_start1=0;
    reg [11:0] page_pipe=0,plot_pipe=0;
    reg [23:0] wave_delay1=0,wave_delay2=0,wave_delay3=0,wave_delay4=0,wave_delay5=0,wave_delay6=0;
    always @(posedge clk)begin
        if(rst)begin
            x1<=0;y1<=0;de1<=0;hs1<=0;vs1<=0;text_valid1<=0;scope_valid1<=0;
            text_changed1<=0;scope_changed1<=0;frame_start1<=0;page_pipe<=0;plot_pipe<=0;
            wave_delay1<=0;wave_delay2<=0;wave_delay3<=0;wave_delay4<=0;wave_delay5<=0;wave_delay6<=0;
        end else begin
            x1<=x;y1<=y;de1<=de;hs1<=hs;vs1<=vs;
            text_valid1<=text_valid;scope_valid1<=scope_valid;
            text_changed1<=text_changed;scope_changed1<=scope_changed;frame_start1<=frame_start;
            page_pipe<={page_pipe[10:0],page};
            plot_pipe<={plot_pipe[10:0],x>=512&&x<1536&&((y>=192&&y<448)||(y>=544&&y<800))};
            wave_delay1<=wave_rgb;wave_delay2<=wave_delay1;wave_delay3<=wave_delay2;
            wave_delay4<=wave_delay3;wave_delay5<=wave_delay4;wave_delay6<=wave_delay5;
        end
    end
    av_renderer home(clk,rst,x1,y1,de1,hs1,vs1,text_valid1,1'b0,text_changed1,frame_start1,
        text_address,text_data,scene,unused_address,18'd0,home_rgb,hd,hh,hv);
    av_wave_renderer wave(clk,rst,x1,y1,de1,hs1,vs1,scope_valid1,scope_changed1,frame_start1,
        scope_address,scope_data,wave_rgb,wd,wh,wv);
    // Home takes eight clocks; pad the five-clock wave path to match it.
    assign rgb=(page_pipe[11]&&plot_pipe[11]) ? wave_delay6 : home_rgb;
    assign out_de=hd;assign out_hs=hh;assign out_vs=hv;
endmodule
