// R3 identity association and palm-thickness centre. Region heuristic, not a
// semantic hand/face model. Color thresholds, policy, model and GS2 unchanged.
module p20_autoxy_tracker #(
 parameter CLK_HZ=74250000,HOLD_MS=450,ACQUIRE_MS=1200,MIN_AREA=6,MAX_AREA=640,
 parameter LOCK_TARGET=1,PALM_CENTER=1,REQUIRE_MOTION=1
)(input wire clk,rst,enable,have_frame,configured,input wire [3:0] error,
 input wire [31:0] frame_id,input wire [8:0] roi_x,input wire [7:0] roi_y,
 input wire port_available,output wire hold_frame,port_owned,output wire [9:0] read_address,
 input wire [15:0] read_data,
 output reg initialized,valid,held,output reg [8:0] hand_x,output reg [7:0] hand_y,
 output reg [2:0] direction,output reg [31:0] measured_frame,output reg done,
 input wire [9:0] debug_address,output reg debug_data,
 output reg [10:0] skin_pixels,best_pixels,motion_pixels,
 output reg [3:0] reject_reason,output reg [31:0] analyzed_frame);
 localparam HOLD_CYCLES=(CLK_HZ/1000)*HOLD_MS,ACQUIRE_CYCLES=(CLK_HZ/1000)*ACQUIRE_MS;
 localparam MAX_CYCLES=HOLD_CYCLES>ACQUIRE_CYCLES ? HOLD_CYCLES:ACQUIRE_CYCLES;
 localparam AW=$clog2(MAX_CYCLES+1);
 localparam IDLE=0,COPY=1,SCAN_ADDR=2,SCAN_WAIT=3,SCAN_GET=4,SCAN_NEXT=5,
 POP_ADDR=6,POP_WAIT=7,POP_GET=8,N_ADDR=9,N_WAIT=10,N_GET=11,N_NEXT=12,
 SCORE=13,CHOOSE=14,PUBLISH=15,FILTER=16,RANK=17,DT_ADDR=18,DT_WAIT=19,
 DT_GET=20,COLOR_WAIT=21,COLOR_GET=22,DIVIDE=23,DIV_DONE=24,FEATURES=25,
 TAG_ADDR=26,TAG_WAIT=27,TAG_GET=28,ASSOC_PREP=29;
 reg [4:0] state;
 reg was_enabled,seen,previous_valid,pending,job_tracking,pending_jump,shape_found;
 reg [31:0] seen_frame,job_frame;
 reg [8:0] job_x;reg [7:0] job_y;reg [AW-1:0] age;
 reg [10:0] issued,received,sp,area,moving,overlap,other_pixels;
 reg [4:0] pipe_valid;
 reg [9:0] scan_index,node,neighbor,region_id,next_region,best_region;
 reg [1:0] neighbor_index;reg neighbor_inside,overflow;
 reg [4:0] min_x,min_y,max_x,max_y,best_x,best_y,last_x,last_y,pending_x,pending_y;
 reg [5:0] best_sum_x,best_sum_y;
 reg [10:0] best_area,last_owner_area,best_overlap,owner_count;
 reg [12:0] best_score,second_score,rank_score;reg rank_eligible;
 reg [3:0] best_radius,last_radius;
 reg signed [6:0] best_rg,best_bg,last_rg,last_bg;
 reg signed [5:0] velocity_x,velocity_y;
 reg [8:0] raw_x,filtered_x;reg [7:0] raw_y;reg [8:0] filtered_y;
 reg signed [17:0] cr_q,cb_q;
 reg rgb_ok_q,motion_q,skin_q,moving_q,changed_q,owner0,owner1,other0,other1;
 reg [15:0] rgb_q0,rgb_q1,old0,old1,old2;
 reg [10:0] job_skin_pixels,job_motion_pixels,job_changed_pixels;
 // All these private memories fit 1024x18 or smaller. The mask stores the
 // original skin bit, motion, previous owner/background, distance and label.
 (* syn_ramstyle="block_ram" *) reg [17:0] mask[0:1023];
 (* syn_ramstyle="block_ram" *) reg [15:0] previous[0:1023];
 (* syn_ramstyle="block_ram" *) reg [16:0] stack[0:1023];
 (* syn_ramstyle="block_ram" *) reg debug_mask[0:2047];
 reg [17:0] mask_q,tag0,tag1;reg [16:0] stack_q;
 reg debug_bank,debug_published,debug_read;
 wire [9:0] mask_address=state==COPY ? issued[9:0]:
    (state==N_ADDR||state==N_WAIT||state==N_GET) ? neighbor:scan_index;
 wire [9:0] previous_address=(state==COLOR_WAIT||state==COLOR_GET) ? node:issued[9:0];
 wire [9:0] stack_address=sp[9:0]-10'd1;
 wire allowed=enable&&have_frame&&configured&&error==0;
 wire [31:0] frame_delta=frame_id-seen_frame;
 wire new_frame=!seen||(frame_delta!=0&&!frame_delta[31]);reg frame_ready;
 always @(posedge clk)if(rst||!allowed)frame_ready<=0;else frame_ready<=new_frame;
 wire start_requested=allowed&&was_enabled&&state==IDLE&&port_available&&frame_ready;
 assign hold_frame=start_requested||port_owned;
 assign port_owned=allowed&&state==COPY;assign read_address=issued[9:0];
 wire [7:0] r={read_data[15:11],read_data[15:13]},g={read_data[10:5],read_data[10:9]},b={read_data[4:0],read_data[4:2]};
 wire [7:0] rgb_max=r>g ? (r>b ? r:b):(g>b ? g:b),rgb_min=r<g ? (r<b ? r:b):(g<b ? g:b);
 wire signed [17:0] cr=$signed({1'b0,r})*18'sd128-$signed({1'b0,g})*18'sd107-$signed({1'b0,b})*18'sd21;
 wire signed [17:0] cb=-$signed({1'b0,r})*18'sd43-$signed({1'b0,g})*18'sd85+$signed({1'b0,b})*18'sd128;
 wire chroma_skin=rgb_ok_q&&cr_q>=768&&cr_q<=17408&&cb_q>=-14336&&cb_q<=4096;
 wire [7:0] old_r={old2[15:11],old2[15:13]},old_g={old2[10:5],old2[10:9]},old_b={old2[4:0],old2[4:2]};
 wire [8:0] dr=r>=old_r ? {1'b0,r}-{1'b0,old_r}:{1'b0,old_r}-{1'b0,r};
 wire [8:0] dg=g>=old_g ? {1'b0,g}-{1'b0,old_g}:{1'b0,old_g}-{1'b0,g};
 wire [8:0] db=b>=old_b ? {1'b0,b}-{1'b0,old_b}:{1'b0,old_b}-{1'b0,b};
 wire [10:0] pixel_change={2'b0,dr}+{2'b0,dg}+{2'b0,db};
 wire unvisited=mask_q[0]&&mask_q[17:8]==10'h3ff;
 wire pop_scan=state==SCAN_GET&&unvisited,pop_neighbor=state==N_GET&&unvisited;
 wire stack_write=allowed&&(pop_scan||(pop_neighbor&&sp<1024));
 wire [9:0] stack_write_address=pop_scan ? 10'd0:sp[9:0];
 wire [16:0] stack_write_data={mask_q[7:4],mask_q[3:1],(pop_scan ? scan_index:neighbor)};

 // Two-pass saturating Manhattan distance; a 32-entry register line buffer.
 (* syn_ramstyle="registers" *) reg [3:0] distance_line[0:31];
 reg reverse_pass;reg [3:0] line_q,edge_distance;
 wire [3:0] across=(reverse_pass ? scan_index[4:0]==31:scan_index[4:0]==0) ? 4'd0:edge_distance;
 wire [3:0] above=(reverse_pass ? scan_index[9:5]==31:scan_index[9:5]==0) ? 4'd0:line_q;
 wire [3:0] neighbor_min=across<above ? across:above;
 wire [3:0] next_distance=neighbor_min==15 ? 4'd15:neighbor_min+1'b1;
 wire [3:0] distance_value=!mask_q[0] ? 4'd0:
    reverse_pass&&mask_q[7:4]<next_distance ? mask_q[7:4]:next_distance;
 wire [5:0] tag_dx=scan_index[4:0]>=best_x ? {1'b0,scan_index[4:0]}-{1'b0,best_x}:{1'b0,best_x}-{1'b0,scan_index[4:0]};
 wire [5:0] tag_dy=scan_index[9:5]>=best_y ? {1'b0,scan_index[9:5]}-{1'b0,best_y}:{1'b0,best_y}-{1'b0,scan_index[9:5]};
 wire [4:0] core_radius={1'b0,best_radius}+5'd2;
 wire [3:0] core_threshold=best_radius<2 ? 4'd1:({1'b0,best_radius}+5'd1)>>1;
 wire tag_owned=mask_q[0]&&mask_q[17:8]==best_region&&mask_q[7:4]>=core_threshold&&tag_dx<=core_radius&&tag_dy<=core_radius;
 wire mask_write=allowed&&((state==COPY&&pipe_valid[4])||pop_scan||pop_neighbor||state==DT_GET||state==TAG_GET);
 wire [9:0] mask_write_address=state==COPY ? received[9:0]:pop_neighbor ? neighbor:scan_index;
 wire [17:0] mask_write_data=state==COPY ? {10'h3ff,4'd0,other1,owner1,moving_q,skin_q}:
    (pop_scan||pop_neighbor) ? {(pop_scan ? next_region:region_id),mask_q[7:0]}:
    state==DT_GET ? {mask_q[17:8],distance_value,mask_q[3:0]}:{mask_q[17:3],tag_owned,mask_q[1:0]};
 always @(posedge clk)begin
  mask_q<=mask[mask_address];tag0<=mask_q;tag1<=tag0;stack_q<=stack[stack_address];
  if(mask_write)mask[mask_write_address]<=mask_write_data;
  if(stack_write)stack[stack_write_address]<=stack_write_data;
  old0<=previous[previous_address];old1<=old0;old2<=old1;
  debug_read<=debug_mask[{debug_published,debug_address}];debug_data<=debug_read;
  if(state==DT_ADDR)line_q<=distance_line[scan_index[4:0]];
  if(allowed&&state==DT_GET)distance_line[scan_index[4:0]]<=distance_value;
  if(rst)begin
   cr_q<=0;cb_q<=0;rgb_ok_q<=0;motion_q<=0;skin_q<=0;moving_q<=0;changed_q<=0;
   rgb_q0<=0;rgb_q1<=0;owner0<=0;owner1<=0;other0<=0;other1<=0;
  end else begin
   cr_q<=cr;cb_q<=cb;rgb_q0<=read_data;rgb_q1<=rgb_q0;
   rgb_ok_q<=r>=24&&g>=16&&b>=8&&{1'b0,r}+9'd16>={1'b0,g}&&{1'b0,r}+9'd24>={1'b0,b}&&rgb_max-rgb_min>=12;
   motion_q<=previous_valid&&pixel_change>=32;skin_q<=chroma_skin;moving_q<=chroma_skin&&motion_q;changed_q<=motion_q;
   owner0<=previous_valid&&initialized&&tag1[2];owner1<=owner0;
   other0<=previous_valid&&tag1[0]&&!(initialized&&tag1[2]);other1<=other0;
  end
  if(allowed&&state==COPY&&pipe_valid[4])begin
   previous[received[9:0]]<=rgb_q1;debug_mask[{debug_bank,received[9:0]}]<=skin_q;
  end
 end
 always @*begin
  neighbor_inside=1;
  case(neighbor_index)
   0:begin neighbor=node-10'd1;neighbor_inside=node[4:0]!=0;end
   1:begin neighbor=node+10'd1;neighbor_inside=node[4:0]!=31;end
   2:begin neighbor=node-10'd32;neighbor_inside=node[9:5]!=0;end
   default:begin neighbor=node+10'd32;neighbor_inside=node[9:5]!=31;end
  endcase
 end

 reg [3:0] node_distance,global_radius,local_radius;reg node_owner;
 reg [7:0] local_score,node_score_q;reg local_node_q;
 reg [10:0] global_count,local_count;
 reg [14:0] gx,gy,gr,gg,gb,lx,ly,lr,lg,lb;
 wire [5:0] node_dx=node[4:0]>=last_x ? {1'b0,node[4:0]}-{1'b0,last_x}:{1'b0,last_x}-{1'b0,node[4:0]};
 wire [5:0] node_dy=node[9:5]>=last_y ? {1'b0,node[9:5]}-{1'b0,last_y}:{1'b0,last_y}-{1'b0,node[9:5]};
 wire [4:0] cap_distance={1'b0,node_distance}>{1'b0,last_radius}+5'd1 ? {1'b0,last_radius}+5'd1:{1'b0,node_distance};
 wire [5:0] local_gap_x=node_dx>3 ? node_dx-6'd3:6'd0,local_gap_y=node_dy>3 ? node_dy-6'd3:6'd0;
 wire [7:0] node_score=8'd64+({2'd0,cap_distance}<<2)+(node_owner ? 8'd8:8'd0)-({1'b0,local_gap_x}+{1'b0,local_gap_y});
 wire local_node=node_dx<=8&&node_dy<=8;
 wire use_local=job_tracking&&local_count!=0;
 wire [10:0] peak_count=use_local ? local_count:global_count;
 wire [14:0] peak_x=use_local ? lx:gx,peak_y=use_local ? ly:gy;
 wire [14:0] peak_r=use_local ? lr:gr,peak_g=use_local ? lg:gg,peak_b=use_local ? lb:gb;
 reg [10:0] divisor;
 reg [15:0] qx,qy,qr,qg,qb,qm;
 reg [11:0] rx,ry,rr,rg,rb,rm;
 reg [4:0] divide_bit;
 function [27:0] divide_step;
  input [11:0] remainder;input [15:0] quotient;input [10:0] den;
  reg [12:0] t;reg [15:0] q;
  begin
   t={remainder,quotient[15]};q={quotient[14:0],1'b0};
   if(t>={2'b0,den})begin t=t-{2'b0,den};q[0]=1;end
   divide_step={t[11:0],q};
  end
 endfunction
 wire [27:0] step_x=divide_step(rx,qx,divisor),step_y=divide_step(ry,qy,divisor);
 wire [27:0] step_r=divide_step(rr,qr,divisor),step_g=divide_step(rg,qg,divisor),step_b=divide_step(rb,qb,divisor);
 wire [27:0] step_m=divide_step(rm,qm,area);
 reg [5:0] feature_sum_x,feature_sum_y;reg [3:0] feature_radius;
 reg signed [6:0] feature_rg,feature_bg;
 reg [6:0] motion_fraction;
 reg [12:0] score_base_q,score_color_q,score_radius_q,score_overlap_q,cold_score_q;
 reg eligible_q;
 wire [4:0] component_x=feature_sum_x[5:1],component_y=feature_sum_y[5:1];
 wire [5:0] width={1'b0,max_x}-{1'b0,min_x}+6'd1,height={1'b0,max_y}-{1'b0,min_y}+6'd1;
 wire shape_ok=area>=MIN_AREA&&area<=MAX_AREA&&width>=2&&height>=2&&{2'b0,width}<=({2'b0,height}<<2)&&{2'b0,height}<=({2'b0,width}<<2);
 wire [5:0] dx=component_x>=last_x ? {1'b0,component_x}-{1'b0,last_x}:{1'b0,last_x}-{1'b0,component_x};
 wire [5:0] dy=component_y>=last_y ? {1'b0,component_y}-{1'b0,last_y}:{1'b0,last_y}-{1'b0,component_y};
 wire signed [6:0] predicted_x=$signed({2'd0,last_x})+$signed({velocity_x[5],velocity_x});
 wire signed [6:0] predicted_y=$signed({2'd0,last_y})+$signed({velocity_y[5],velocity_y});
 wire [4:0] px=predicted_x<0 ? 5'd0:predicted_x>31 ? 5'd31:predicted_x[4:0];
 wire [4:0] py=predicted_y<0 ? 5'd0:predicted_y>31 ? 5'd31:predicted_y[4:0];
 wire [5:0] pdx=component_x>=px ? {1'b0,component_x}-{1'b0,px}:{1'b0,px}-{1'b0,component_x};
 wire [5:0] pdy=component_y>=py ? {1'b0,component_y}-{1'b0,py}:{1'b0,py}-{1'b0,component_y};
 wire signed [7:0] rg_difference=$signed({feature_rg[6],feature_rg})-$signed({last_rg[6],last_rg});
 wire signed [7:0] bg_difference=$signed({feature_bg[6],feature_bg})-$signed({last_bg[6],last_bg});
 wire [7:0] color_difference=(rg_difference<0 ? -rg_difference:rg_difference)+(bg_difference<0 ? -bg_difference:bg_difference);
 wire [4:0] radius_difference=feature_radius>=last_radius ? {1'b0,feature_radius}-{1'b0,last_radius}:{1'b0,last_radius}-{1'b0,feature_radius};
 wire [10:0] overlap_reference=last_owner_area<area ? last_owner_area:area;
 wire enough_overlap=overlap!=0&&({3'b0,overlap}<<3)>={3'b0,overlap_reference};
 wire [5:0] feature_pending_dx=component_x>=pending_x ? {1'b0,component_x}-{1'b0,pending_x}:{1'b0,pending_x}-{1'b0,component_x};
 wire [5:0] feature_pending_dy=component_y>=pending_y ? {1'b0,component_y}-{1'b0,pending_y}:{1'b0,pending_y}-{1'b0,component_y};
 wire pending_match=pending&&age<ACQUIRE_CYCLES&&feature_pending_dx<=4&&feature_pending_dy<=4;
 wire novelty=({2'b0,other_pixels}<<2)<({2'b0,area}*13'd3);
 wire clear_motion=moving>=3&&motion_fraction>=16&&job_changed_pixels<640;
 wire consistent=color_difference<=12&&{2'b0,feature_radius}<={1'b0,last_radius,1'b0}+6'd2&&
     {1'b0,last_radius}<={feature_radius,1'b0}+6'd2;
 wire linked=dx<=8&&dy<=8&&consistent&&
     (enough_overlap||(novelty&&clear_motion&&pdx<=8&&pdy<=8)||(pending_jump&&pending_match));
 wire cold_ok=!REQUIRE_MOTION||(clear_motion&&(!initialized||novelty))||pending_match||(initialized&&enough_overlap);
 wire eligible=shape_ok&&(!LOCK_TARGET ? (!job_tracking||(dx<=8&&dy<=8)):(job_tracking ? linked:cold_ok));
 wire [5:0] clipped_overlap=overlap>63 ? 6'd63:overlap[5:0];
 wire [12:0] candidate_score=REQUIRE_MOTION ? 
    ({6'd0,motion_fraction}<<6)+(area>255 ? 13'd255:{2'd0,area}):{2'd0,area}+({2'd0,moving}<<3);
 wire confident=best_area!=0&&!overflow&&(second_score==0||(job_tracking ? best_score>=second_score+13'd64:
    best_score>=second_score+13'd16&&{2'd0,second_score}*15'd4<={2'd0,best_score}*15'd3));
 wire [5:0] pending_dx=best_x>=pending_x ? {1'b0,best_x}-{1'b0,pending_x}:{1'b0,pending_x}-{1'b0,best_x};
 wire [5:0] pending_dy=best_y>=pending_y ? {1'b0,best_y}-{1'b0,pending_y}:{1'b0,pending_y}-{1'b0,best_y};
 wire [10:0] best_reference=last_owner_area<best_area ? last_owner_area:best_area;
 wire best_link=best_overlap!=0&&({3'd0,best_overlap}<<3)>={3'd0,best_reference};
 wire confirmed=(job_tracking&&(!LOCK_TARGET||best_link))||
    (pending&&age<ACQUIRE_CYCLES&&pending_dx<=6&&pending_dy<=6);
 wire [9:0] mapped_x={1'b0,job_x}+(({4'd0,best_sum_x}*10'd15)>>2);
 wire [9:0] mapped_y={2'd0,job_y}+(({4'd0,best_sum_y}*10'd15)>>2);
 function [8:0] smooth;
  input [8:0] old_value,new_value;reg [8:0] distance;reg [10:0] total;
  begin distance=old_value>new_value ? old_value-new_value:new_value-old_value;
   if(distance<=2)smooth=old_value;
   else if(distance>=24)begin total={2'd0,old_value}+{2'd0,new_value}*11'd3+11'd2;smooth=total[10:2];end
   else begin total={2'd0,old_value}+{2'd0,new_value}+11'd1;smooth=total[9:1];end
  end
 endfunction
 function signed [5:0] velocity;
  input [4:0] a,b;reg signed [6:0] d;
  begin d=$signed({2'd0,a})-$signed({2'd0,b});velocity=d>4 ? 6'sd4:d< -4 ? -6'sd4:d[5:0];end
 endfunction
 wire [8:0] next_x=valid ? smooth(hand_x,raw_x):raw_x,next_y=valid ? smooth({1'b0,hand_y},{1'b0,raw_y}):{1'b0,raw_y};
 wire [8:0] output_dx=filtered_x>=hand_x ? filtered_x-hand_x:hand_x-filtered_x;
 wire [8:0] output_dy=filtered_y>={1'b0,hand_y} ? filtered_y-{1'b0,hand_y}:{1'b0,hand_y}-filtered_y;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;was_enabled<=0;seen<=0;previous_valid<=0;pending<=0;pending_jump<=0;job_tracking<=0;shape_found<=0;
   seen_frame<=0;job_frame<=0;job_x<=0;job_y<=0;age<=MAX_CYCLES;
   issued<=0;received<=0;pipe_valid<=0;sp<=0;area<=0;moving<=0;overlap<=0;other_pixels<=0;
   scan_index<=0;node<=0;neighbor_index<=0;region_id<=0;next_region<=0;best_region<=0;
   overflow<=0;min_x<=31;min_y<=31;max_x<=0;max_y<=0;
   best_x<=0;best_y<=0;last_x<=0;last_y<=0;pending_x<=0;pending_y<=0;
   best_sum_x<=0;best_sum_y<=0;best_area<=0;last_owner_area<=0;best_overlap<=0;owner_count<=0;
   best_score<=0;second_score<=0;rank_score<=0;rank_eligible<=0;best_radius<=0;last_radius<=0;
   best_rg<=0;best_bg<=0;last_rg<=0;last_bg<=0;velocity_x<=0;velocity_y<=0;
   raw_x<=0;raw_y<=0;filtered_x<=0;filtered_y<=0;initialized<=0;valid<=0;held<=0;
   hand_x<=0;hand_y<=0;direction<=0;measured_frame<=0;done<=0;
   debug_bank<=1;debug_published<=0;skin_pixels<=0;best_pixels<=0;motion_pixels<=0;
   reject_reason<=0;analyzed_frame<=0;job_skin_pixels<=0;job_motion_pixels<=0;job_changed_pixels<=0;
   reverse_pass<=0;edge_distance<=0;node_distance<=0;node_owner<=0;global_radius<=0;local_radius<=0;local_score<=0;node_score_q<=0;local_node_q<=0;
   global_count<=0;local_count<=0;gx<=0;gy<=0;gr<=0;gg<=0;gb<=0;lx<=0;ly<=0;lr<=0;lg<=0;lb<=0;
   divisor<=1;qx<=0;qy<=0;qr<=0;qg<=0;qb<=0;qm<=0;rx<=0;ry<=0;rr<=0;rg<=0;rb<=0;rm<=0;divide_bit<=0;
   feature_sum_x<=0;feature_sum_y<=0;feature_radius<=0;feature_rg<=0;feature_bg<=0;motion_fraction<=0;
   score_base_q<=0;score_color_q<=0;score_radius_q<=0;score_overlap_q<=0;cold_score_q<=0;eligible_q<=0;
  end else begin
   done<=0;was_enabled<=enable;
   if(age<MAX_CYCLES)age<=age+1'b1;
   if(age>=HOLD_CYCLES)begin valid<=0;held<=0;direction<=0;end
   if(age>=ACQUIRE_CYCLES)begin pending<=0;pending_jump<=0;end
   if(!allowed||!was_enabled||(seen&&(roi_x!=job_x||roi_y!=job_y)))begin
    state<=IDLE;seen<=0;previous_valid<=0;pending<=0;pending_jump<=0;initialized<=0;valid<=0;held<=0;
    direction<=0;pipe_valid<=0;age<=MAX_CYCLES;job_x<=roi_x;job_y<=roi_y;reject_reason<=0;
    velocity_x<=0;velocity_y<=0;last_owner_area<=0;
   end else case(state)
    IDLE:if(start_requested)begin
     seen<=1;seen_frame<=frame_id;job_frame<=frame_id;job_x<=roi_x;job_y<=roi_y;
     job_tracking<=valid&&age<HOLD_CYCLES;issued<=0;received<=0;pipe_valid<=0;
     best_score<=0;second_score<=0;best_area<=0;best_overlap<=0;overflow<=0;shape_found<=0;state<=COPY;
     job_skin_pixels<=0;job_motion_pixels<=0;job_changed_pixels<=0;debug_bank<=!debug_published;
    end
    COPY:begin
     pipe_valid<={pipe_valid[3:0],issued<1024};if(issued<1024)issued<=issued+1'b1;
     if(pipe_valid[4])begin
      if(skin_q)job_skin_pixels<=job_skin_pixels+1'b1;if(moving_q)job_motion_pixels<=job_motion_pixels+1'b1;
      if(changed_q)job_changed_pixels<=job_changed_pixels+1'b1;
      received<=received+1'b1;
      if(received==1023)begin previous_valid<=1;pipe_valid<=0;scan_index<=0;reverse_pass<=0;edge_distance<=0;state<=DT_ADDR;end
     end
    end
    DT_ADDR:state<=DT_WAIT;
    DT_WAIT:state<=DT_GET;
    DT_GET:begin
     edge_distance<=distance_value;
     if(!reverse_pass&&scan_index==1023)begin reverse_pass<=1;edge_distance<=0;state<=DT_ADDR;end
     else if(reverse_pass&&scan_index==0)begin next_region<=0;state<=SCAN_ADDR;end
     else begin scan_index<=reverse_pass ? scan_index-1'b1:scan_index+1'b1;state<=DT_ADDR;end
    end
    SCAN_ADDR:state<=SCAN_WAIT;
    SCAN_WAIT:state<=SCAN_GET;
    SCAN_GET:if(unvisited)begin
     sp<=1;area<=0;moving<=0;overlap<=0;other_pixels<=0;min_x<=31;min_y<=31;max_x<=0;max_y<=0;
     region_id<=next_region;next_region<=next_region+1'b1;
     global_radius<=0;local_radius<=0;local_score<=0;global_count<=0;local_count<=0;
     gx<=0;gy<=0;gr<=0;gg<=0;gb<=0;lx<=0;ly<=0;lr<=0;lg<=0;lb<=0;state<=POP_ADDR;
    end else state<=SCAN_NEXT;
    POP_ADDR:if(sp==0)state<=SCORE;else state<=POP_WAIT;
    POP_WAIT:state<=POP_GET;
    POP_GET:begin
     node<=stack_q[9:0];node_distance<=stack_q[16:13];node_owner<=stack_q[11];sp<=sp-1'b1;area<=area+1'b1;
     if(stack_q[10])moving<=moving+1'b1;if(stack_q[11])overlap<=overlap+1'b1;if(stack_q[12])other_pixels<=other_pixels+1'b1;
     if(stack_q[4:0]<min_x)min_x<=stack_q[4:0];if(stack_q[4:0]>max_x)max_x<=stack_q[4:0];
     if(stack_q[9:5]<min_y)min_y<=stack_q[9:5];if(stack_q[9:5]>max_y)max_y<=stack_q[9:5];state<=COLOR_WAIT;
    end
    COLOR_WAIT:begin node_score_q<=node_score;local_node_q<=local_node;state<=COLOR_GET;end
    COLOR_GET:begin
     if(node_distance>global_radius)begin
      global_radius<=node_distance;global_count<=1;gx<=node[4:0];gy<=node[9:5];gr<=old0[15:11];gg<=old0[10:6];gb<=old0[4:0];
     end else if(node_distance==global_radius)begin
      global_count<=global_count+1'b1;gx<=gx+node[4:0];gy<=gy+node[9:5];gr<=gr+old0[15:11];gg<=gg+old0[10:6];gb<=gb+old0[4:0];
     end
     if(local_node_q)begin
      if(local_count==0||node_score_q>local_score)begin
       local_score<=node_score_q;local_radius<=node_distance;local_count<=1;
       lx<=node[4:0];ly<=node[9:5];lr<=old0[15:11];lg<=old0[10:6];lb<=old0[4:0];
      end else if(node_score_q==local_score)begin
       local_count<=local_count+1'b1;if(node_distance>local_radius)local_radius<=node_distance;
       lx<=lx+node[4:0];ly<=ly+node[9:5];lr<=lr+old0[15:11];lg<=lg+old0[10:6];lb<=lb+old0[4:0];
      end
     end
     neighbor_index<=0;state<=N_ADDR;
    end
    N_ADDR:state<=neighbor_inside ? N_WAIT:N_NEXT;
    N_WAIT:state<=N_GET;
    N_GET:begin if(unvisited)begin if(sp<1024)sp<=sp+1'b1;else overflow<=1;end state<=N_NEXT;end
    N_NEXT:if(neighbor_index==3)state<=POP_ADDR;else begin neighbor_index<=neighbor_index+1'b1;state<=N_ADDR;end
    SCORE:if(!shape_ok||peak_count==0)state<=SCAN_NEXT;else begin
     shape_found<=1;
     divisor<=peak_count;qx<={peak_x,1'b0}+{5'd0,peak_count};qy<={peak_y,1'b0}+{5'd0,peak_count};
     qr<={1'b0,peak_r};qg<={1'b0,peak_g};qb<={1'b0,peak_b};qm<={moving[9:0],6'd0};
     rx<=0;ry<=0;rr<=0;rg<=0;rb<=0;rm<=0;divide_bit<=0;state<=DIVIDE;
    end
    DIVIDE:begin
     {rx,qx}<=step_x;{ry,qy}<=step_y;{rr,qr}<=step_r;{rg,qg}<=step_g;{rb,qb}<=step_b;{rm,qm}<=step_m;
     if(divide_bit==15)state<=DIV_DONE;else divide_bit<=divide_bit+1'b1;
    end
    DIV_DONE:begin
     feature_sum_x<=PALM_CENTER ? qx[5:0]:{1'b0,min_x}+{1'b0,max_x}+6'd1;
     feature_sum_y<=PALM_CENTER ? qy[5:0]:{1'b0,min_y}+{1'b0,max_y}+6'd1;
     feature_radius<=use_local ? local_radius:global_radius;
     feature_rg<=$signed({2'd0,qr[4:0]})-$signed({2'd0,qg[4:0]});
     feature_bg<=$signed({2'd0,qb[4:0]})-$signed({2'd0,qg[4:0]});motion_fraction<=qm[6:0];state<=ASSOC_PREP;
    end
    ASSOC_PREP:begin
     score_base_q<=13'd6144-(({7'd0,pdx}+{7'd0,pdy})<<6);
     score_color_q<=({5'd0,color_difference}<<4);score_radius_q<=({8'd0,radius_difference}<<5);
     score_overlap_q<=({7'd0,clipped_overlap}<<2);cold_score_q<=candidate_score;eligible_q<=eligible;state<=FEATURES;
    end
    FEATURES:begin
     rank_score<=job_tracking ? (score_base_q-score_color_q)+(score_overlap_q-score_radius_q):cold_score_q;
     rank_eligible<=eligible_q;state<=RANK;
    end
    RANK:begin
     if(rank_eligible)begin
      if(rank_score>best_score)begin
       second_score<=best_score;best_score<=rank_score;best_area<=area;best_overlap<=overlap;best_region<=region_id;
       best_x<=component_x;best_y<=component_y;best_sum_x<=feature_sum_x;best_sum_y<=feature_sum_y;
       best_radius<=feature_radius;best_rg<=feature_rg;best_bg<=feature_bg;
      end else if(rank_score>second_score)second_score<=rank_score;
     end
     state<=SCAN_NEXT;
    end
    SCAN_NEXT:if(scan_index==1023)state<=CHOOSE;else begin scan_index<=scan_index+1'b1;state<=SCAN_ADDR;end
    CHOOSE:begin
     debug_published<=debug_bank;skin_pixels<=job_skin_pixels;best_pixels<=best_area;motion_pixels<=job_motion_pixels;analyzed_frame<=job_frame;
     if(confident)begin
      if(confirmed)begin raw_x<=mapped_x[8:0];raw_y<=mapped_y[7:0];reject_reason<=0;state<=FILTER;end
      else begin
       pending<=1;pending_jump<=job_tracking;pending_x<=best_x;pending_y<=best_y;
       if(!job_tracking)age<=0;held<=valid&&age<HOLD_CYCLES;reject_reason<=4;done<=1;state<=IDLE;
      end
     end else begin
      pending<=0;pending_jump<=0;held<=valid&&age<HOLD_CYCLES;direction<=0;done<=1;state<=IDLE;
      reject_reason<=overflow ? 5:job_skin_pixels<MIN_AREA ? 1:job_changed_pixels>=640 ? 7:
        best_area==0 ? (REQUIRE_MOTION&&!job_tracking&&shape_found ? 6:2):3;
     end
    end
    FILTER:begin filtered_x<=next_x;filtered_y<=next_y;state<=PUBLISH;end
    PUBLISH:begin
     initialized<=1;valid<=1;held<=0;age<=0;pending<=0;pending_jump<=0;hand_x<=filtered_x;hand_y<=filtered_y[7:0];
     velocity_x<=job_tracking ? velocity(best_x,last_x):6'd0;velocity_y<=job_tracking ? velocity(best_y,last_y):6'd0;
     last_x<=best_x;last_y<=best_y;last_radius<=best_radius;last_rg<=best_rg;last_bg<=best_bg;measured_frame<=job_frame;
     owner_count<=0;scan_index<=0;state<=TAG_ADDR;
     if(!valid||(output_dx<4&&output_dy<4))direction<=0;
     else if(output_dx>=output_dy)direction<=filtered_x<hand_x ? 1:2;
     else direction<=filtered_y<{1'b0,hand_y} ? 3:4;
    end
    TAG_ADDR:state<=TAG_WAIT;
    TAG_WAIT:state<=TAG_GET;
    TAG_GET:begin
     if(tag_owned)owner_count<=owner_count+1'b1;
     if(scan_index==1023)begin last_owner_area<=owner_count+tag_owned;done<=1;state<=IDLE;end
     else begin scan_index<=scan_index+1'b1;state<=TAG_ADDR;end
    end
    default:begin state<=IDLE;valid<=0;held<=0;pending<=0;end
   endcase
  end
 end
endmodule
