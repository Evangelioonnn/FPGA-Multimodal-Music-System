// Three same-frame planes, sampled directly from native RGB565 camera pixels.
// Producer writes only the inactive bank. Bundled frame/ROI metadata is held
// until video blank commits its bank and the acknowledgement returns to PCLK.
module p20_crop_frames #(
    parameter WIDTH=320,HEIGHT=240,MODEL=64,COLOR=32,ADDR_BITS=15,MODEL_AW=12,COLOR_AW=10
)(input wire sys_clk,video_clk,rst,pclk,vsync,href,input wire [7:0] data,
    input wire video_blank,hold_frame,input wire [8:0] cfg_x,input wire [7:0] cfg_y,input wire [8:0] cfg_side,
    input wire [ADDR_BITS-1:0] preview_address,output reg [7:0] preview_data,
    input wire [MODEL_AW-1:0] model_address,output reg [7:0] model_data,
    input wire [COLOR_AW-1:0] color_address,output reg [15:0] color_data,
    output reg have_frame,output reg [31:0] displayed_frame,
    output reg [8:0] displayed_x,output reg [7:0] displayed_y,output reg [8:0] displayed_side,
    output reg pclk_seen,output wire stats_valid,output wire [31:0] good_frames,bad_frames,
    output wire [15:0] line_min,line_max,line_count,output wire stats_overrun);
    localparam FULL=WIDTH*HEIGHT,COUNT=(WIDTH/2)*(HEIGHT/2),MN=MODEL*MODEL,CN=COLOR*COLOR;
    localparam SMALL=(WIDTH<HEIGHT ? WIDTH:HEIGHT),SIDE=(SMALL<160 ? SMALL:160);
    localparam LEFT=(WIDTH-SIDE)/2,TOP=(HEIGHT-SIDE)/2;
    localparam PAGE_BITS=(ADDR_BITS<11 ? ADDR_BITS:11),DEPTH=1<<PAGE_BITS;
    localparam PAGES=(COUNT+DEPTH-1)/DEPTH,GROUPS=(2*PAGES+3)/4;
    (* ASYNC_REG="TRUE" *) reg [1:0] p_reset=3,v_reset=3;
    always @(posedge pclk or posedge rst)if(rst)p_reset<=3;else p_reset<={p_reset[0],1'b0};
    always @(posedge video_clk or posedge rst)if(rst)v_reset<=3;else v_reset<={v_reset[0],1'b0};
    wire prst=p_reset[1],vrst=v_reset[1];

    // Send configuration as one atomic tuple; a changed tuple waits for ready.
    wire cfg_ready,cfg_received;wire [25:0] cfg_received_data;
    reg cfg_sent;reg [25:0] last_cfg;
    wire [25:0] current_cfg={cfg_x,cfg_y,cfg_side};
    wire cfg_send=cfg_ready && (!cfg_sent || current_cfg!=last_cfg);
    wire unused_cfg_overrun;
    snapshot_cdc #(.WIDTH(26)) configuration(video_clk,vrst,cfg_send,current_cfg,cfg_ready,unused_cfg_overrun,
        pclk,prst,cfg_received,cfg_received_data);
    always @(posedge video_clk or posedge vrst)begin
        if(vrst)begin cfg_sent<=0;last_cfg<=0;end
        else if(cfg_send)begin cfg_sent<=1;last_cfg<=current_cfg;end
    end
    reg [8:0] pending_x,pending_side,frame_x,frame_side,held_x,held_side;
    reg [7:0] pending_y,frame_y,held_y;
    wire pending_valid=pending_side>=MODEL && pending_side>=COLOR &&
        ({1'b0,pending_x}+{1'b0,pending_side})<=WIDTH &&
        ({2'b0,pending_y}+{1'b0,pending_side})<=HEIGHT;

    reg request,ack;
    (* ASYNC_REG="TRUE" *) reg ack1,ack2,request1,request2;
    reg active,half,prev_vs,prev_href,bad;
    reg [7:0] high_byte;
    reg [17:0] pixels;reg [ADDR_BITS:0] sampled;
    reg [MODEL_AW:0] model_count;reg [COLOR_AW:0] color_count;
    reg [15:0] bytes_line,lines,min_bytes,max_bytes,mx,my,cx,cy;
    reg [31:0] frame_counter,good_counter,bad_counter,held_frame;
    reg [15:0] held_min,held_max,held_lines;
    reg report_event;reg [7:0] heartbeat;
    wire full_pixel=!prst && active && href && !vsync && half;
    wire valid_frame=!bad && !half && !href && pixels==FULL && sampled==COUNT &&
        model_count==MN && color_count==CN && lines==HEIGHT && min_bytes==WIDTH*2 && max_bytes==WIDTH*2;
    wire [15:0] rgb={high_byte,data};
    wire [7:0] red={rgb[15:11],rgb[15:13]},green={rgb[10:5],rgb[10:9]},blue={rgb[4:0],rgb[4:2]};
    wire [15:0] weighted=red*16'd77+green*16'd150+blue*16'd29;
    // Sample indices are below MODEL/COLOR while their sample count is active.
    // Bound the multipliers explicitly; after the final row the count guard
    // disables sampling, so the wrapped low index bits are never consumed.
    localparam MIW=MODEL>1 ? $clog2(MODEL):1,CIW=COLOR>1 ? $clog2(COLOR):1;
    wire [MIW+8:0] mx_product=mx[MIW-1:0]*frame_side,my_product=my[MIW-1:0]*frame_side;
    wire [CIW+8:0] cx_product=cx[CIW-1:0]*frame_side,cy_product=cy[CIW-1:0]*frame_side;
    wire [15:0] model_x={7'd0,frame_x}+(mx_product/MODEL),model_y={8'd0,frame_y}+(my_product/MODEL);
    wire [15:0] color_x={7'd0,frame_x}+(cx_product/COLOR),color_y={8'd0,frame_y}+(cy_product/COLOR);
    wire selected_model=full_pixel && !bad && (bytes_line>>1)==model_x && lines==model_y && model_count<MN;
    wire selected_color=full_pixel && !bad && (bytes_line>>1)==color_x && lines==color_y && color_count<CN;
    reg [7:0] gray_value;reg [15:0] color_value;
    reg gray_write,model_write,color_write,gray_bank;
    reg [ADDR_BITS-1:0] gray_address;
    reg [MODEL_AW-1:0] gray_model_address;reg [COLOR_AW-1:0] rgb_color_address;
    always @(posedge pclk or posedge prst)begin
        if(prst)begin
            gray_value<=0;color_value<=0;gray_write<=0;model_write<=0;color_write<=0;gray_bank<=0;
            gray_address<=0;gray_model_address<=0;rgb_color_address<=0;
        end else begin
            gray_value<=weighted[15:8];color_value<=rgb;gray_bank<=!request;
            gray_address<=sampled[ADDR_BITS-1:0];gray_model_address<=model_count[MODEL_AW-1:0];
            rgb_color_address<=color_count[COLOR_AW-1:0];
            gray_write<=full_pixel && !bad && !bytes_line[1] && !lines[0] && sampled<COUNT;
            model_write<=selected_model;color_write<=selected_color;
        end
    end
    // Preserve the 2K-byte page layout and three-clock display read pipeline.
    wire [7:0] page_data[0:2*PAGES-1];genvar page;
    generate for(page=0;page<2*PAGES;page=page+1)begin: pages
        (* syn_ramstyle="block_ram" *) reg [7:0] memory[0:DEPTH-1];
        reg [7:0] result;assign page_data[page]=result;
        always @(posedge pclk)
            if(!prst && gray_write && (gray_address>>PAGE_BITS)==page%PAGES && gray_bank==page/PAGES)
                memory[gray_address[PAGE_BITS-1:0]]<=gray_value;
        always @(posedge video_clk)result<=memory[preview_address[PAGE_BITS-1:0]];
    end endgenerate
    (* syn_ramstyle="block_ram" *) reg [7:0] model[0:(1<<(MODEL_AW+1))-1];
    (* syn_ramstyle="block_ram" *) reg [15:0] color[0:(1<<(COLOR_AW+1))-1];
    always @(posedge pclk)begin
        if(!prst && model_write)model[{gray_bank,gray_model_address}]<=gray_value;
        if(!prst && color_write)color[{gray_bank,rgb_color_address}]<=color_value;
    end
    reg [7:0] model_read,model_read2;reg [15:0] color_read,color_read2;
    reg read_bank;reg [ADDR_BITS-1:0] read_page;
    wire [ADDR_BITS:0] read_index=read_page+(read_bank ? PAGES:0);
    reg [ADDR_BITS:0] group_index;reg [7:0] selected[0:GROUPS-1];genvar groupn;
    generate for(groupn=0;groupn<GROUPS;groupn=groupn+1)begin: select_group
        wire [7:0] a=page_data[groupn*4];
        wire [7:0] b,c,d;
        if(groupn*4+1<2*PAGES)begin: has_b assign b=page_data[groupn*4+1];end
        else begin: no_b assign b=8'b0;end
        if(groupn*4+2<2*PAGES)begin: has_c assign c=page_data[groupn*4+2];end
        else begin: no_c assign c=8'b0;end
        if(groupn*4+3<2*PAGES)begin: has_d assign d=page_data[groupn*4+3];end
        else begin: no_d assign d=8'b0;end
        always @(posedge video_clk)case(read_index[1:0])
            0:selected[groupn]<=a;1:selected[groupn]<=b;2:selected[groupn]<=c;3:selected[groupn]<=d;
        endcase
    end endgenerate
    always @(posedge video_clk)begin
        read_page<=preview_address>>PAGE_BITS;read_bank<=ack;
        group_index<=read_index>>2;preview_data<=selected[group_index];
        model_read<=model[{ack,model_address}];model_read2<=model_read;model_data<=model_read2;
        color_read<=color[{ack,color_address}];color_read2<=color_read;color_data<=color_read2;
    end
    always @(posedge pclk or posedge prst)begin
        if(prst)begin
            pending_x<=LEFT;pending_y<=TOP;pending_side<=SIDE;
            frame_x<=LEFT;frame_y<=TOP;frame_side<=SIDE;held_x<=0;held_y<=0;held_side<=0;
            request<=0;ack1<=0;ack2<=0;active<=0;half<=0;prev_vs<=0;prev_href<=0;bad<=0;
            high_byte<=0;pixels<=0;sampled<=0;model_count<=0;color_count<=0;mx<=0;my<=0;cx<=0;cy<=0;
            bytes_line<=0;lines<=0;min_bytes<=16'hffff;max_bytes<=0;
            frame_counter<=0;good_counter<=0;bad_counter<=0;held_frame<=0;
            held_min<=0;held_max<=0;held_lines<=0;report_event<=0;heartbeat<=0;
        end else begin
            ack1<=ack;ack2<=ack1;prev_vs<=vsync;prev_href<=href;report_event<=0;heartbeat<=heartbeat+1'b1;
            if(cfg_received)begin
                pending_x<=cfg_received_data[25:17];pending_y<=cfg_received_data[16:9];pending_side<=cfg_received_data[8:0];
            end
            if(vsync && !prev_vs)begin
                frame_counter<=frame_counter+1'b1;
                if(active)begin
                    active<=0;report_event<=1;held_min<=min_bytes;held_max<=max_bytes;held_lines<=lines;
                    if(valid_frame)begin
                        held_frame<=frame_counter;held_x<=frame_x;held_y<=frame_y;held_side<=frame_side;
                        good_counter<=good_counter+1'b1;request<=!request;
                    end else bad_counter<=bad_counter+1'b1;
                end else if(request==ack2)begin
                    active<=1;half<=0;bad<=!pending_valid;pixels<=0;sampled<=0;model_count<=0;color_count<=0;
                    mx<=0;my<=0;cx<=0;cy<=0;frame_x<=pending_x;frame_y<=pending_y;frame_side<=pending_side;
                    bytes_line<=0;lines<=0;min_bytes<=16'hffff;max_bytes<=0;
                end
            end else if(active)begin
                if(href && !vsync)begin
                    if(bytes_line<16'hffff)bytes_line<=bytes_line+1'b1;else bad<=1;
                    if(!half)begin high_byte<=data;half<=1;end
                    else begin
                        half<=0;if(pixels<FULL+1)pixels<=pixels+1'b1;if(pixels>=FULL)bad<=1;
                        if(!bytes_line[1] && !lines[0])begin
                            if(sampled<COUNT+1)sampled<=sampled+1'b1;if(sampled>=COUNT)bad<=1;
                        end
                        if(selected_model)begin
                            model_count<=model_count+1'b1;
                            if(mx==MODEL-1)begin mx<=0;my<=my+1'b1;end else mx<=mx+1'b1;
                        end
                        if(selected_color)begin
                            color_count<=color_count+1'b1;
                            if(cx==COLOR-1)begin cx<=0;cy<=cy+1'b1;end else cx<=cx+1'b1;
                        end
                    end
                end else if(!href && prev_href)begin
                    if(half || bytes_line!=WIDTH*2)bad<=1;
                    if(bytes_line<min_bytes)min_bytes<=bytes_line;if(bytes_line>max_bytes)max_bytes<=bytes_line;
                    if(lines<16'hffff)lines<=lines+1'b1;else bad<=1;
                    bytes_line<=0;half<=0;
                end
            end
        end
    end
    always @(posedge video_clk or posedge vrst)begin
        if(vrst)begin
            request1<=0;request2<=0;ack<=0;have_frame<=0;displayed_frame<=0;
            displayed_x<=0;displayed_y<=0;displayed_side<=0;
        end else begin
            request1<=request;request2<=request1;
            if(video_blank && !hold_frame && request2!=ack)begin
                ack<=request2;have_frame<=1;displayed_frame<=held_frame;
                displayed_x<=held_x;displayed_y<=held_y;displayed_side<=held_side;
            end
        end
    end
    wire unused_ready;
    snapshot_cdc #(.WIDTH(112)) statistics(pclk,prst,report_event,
        {good_counter,bad_counter,held_min,held_max,held_lines},unused_ready,stats_overrun,
        sys_clk,rst,stats_valid,{good_frames,bad_frames,line_min,line_max,line_count});
    (* ASYNC_REG="TRUE" *) reg hb1,hb2;reg old_hb;
    always @(posedge sys_clk)begin
        if(rst)begin hb1<=0;hb2<=0;old_hb<=0;pclk_seen<=0;end
        else begin hb1<=heartbeat[7];hb2<=hb1;old_hb<=hb2;if(hb2!=old_hb)pclk_seen<=1;end
    end
endmodule
