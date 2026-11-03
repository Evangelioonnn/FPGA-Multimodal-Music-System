// V18 R02: exact timestamp semantics, serial RAM state access.
module dcl_velocity #(parameter DEBOUNCE_US=500,HALF_TIMEOUT_US=800000,
 CONFIRM_GRACE_US=4000,LEVELS=64)(
 input wire clk,rst,reset_stream,swap_ab,
 input wire row_valid,output wire row_ready,input wire[1:0]row,input wire[7:0]closed,
 input wire[31:0]capture_us,input wire initial_sample,
 output reg event_valid,input wire event_ready,output reg[108:0]event_data,
 output reg fault,output reg[31:0]raw_bitmap,output wire[2:0]function_keys,
 output reg[12:0]active,output reg[31:0]on_count,off_count,
 output reg[31:0]invalid_order,same_sample,half_cancel,half_timeout,time_errors);
 localparam WAIT_RELEASE=0,READY=1,HALF=2,ACTIVE=3,INVALID=4;
 reg[31:0]raw,stable;reg[31:0]row_time[0:3];

 reg[3:0]seen;reg[2:0]key_state[0:12];reg[31:0]next_token;
 reg busy,checking,work_initial;reg[1:0]work_row,pair;reg[7:0]work_bits;reg[31:0]work_time;
 integer j;integer a,b,k;reg ra,rb,sa,sb;reg[31:0]ta,tb,dt;
 reg mapping,map_start;reg[19:0]map_delta;wire map_busy,map_done;wire[7:0]map_velocity;
 dcl_curve #(.LEVELS(LEVELS)) curve(clk,rst||reset_stream,map_start,map_delta,map_busy,map_done,map_velocity);
 // Four words/contact-pair: A edge,B edge,first edge,ON token. Validity is
 // guarded by raw/stable and key_state; no reset sweep of block RAM.
 (* syn_ramstyle="block_ram" *)reg[31:0]timing_mem[0:63];
 reg[31:0]timing_q,edge_a,edge_b,first_cache,token_cache;reg[3:0]mem_phase;
 wire[1:0]write_slot=mem_phase[1:0]-2'd2;
 wire[5:0]timing_address={work_row,pair,mem_phase>=6 ? write_slot : mem_phase[1:0]};
 reg[31:0]timing_write;
 always @*case(write_slot)0:timing_write=edge_a;1:timing_write=edge_b;2:timing_write=first_cache;default:timing_write=token_cache;endcase
 always @(posedge clk)begin
  if(!rst&&!reset_stream&&busy&&!mapping&&!event_valid&&mem_phase>=6&&mem_phase<=9)timing_mem[timing_address]<=timing_write;
  else timing_q<=timing_mem[timing_address];
 end
 assign row_ready=!busy&&!checking&&!mapping&&!event_valid&&!reset_stream&&!rst;
 assign function_keys={stable[31],stable[29],stable[27]};
 task emit_event;input is_off;input[3:0]key;input[7:0]velocity;input[31:0]token,at,delta;
 begin
  event_data<={is_off,key,velocity,token,at,delta};
  if(is_off)event_valid<=1;
  else begin mapping<=1;map_start<=1;map_delta<=delta[19:0];end
 end endtask
 always @(posedge clk)begin
  if(rst)begin
   busy<=0;checking<=0;mapping<=0;map_start<=0;map_delta<=0;work_initial<=0;event_valid<=0;event_data<=0;fault<=0;raw_bitmap<=0;raw<=0;stable<=0;seen<=0;active<=0;
   work_row<=0;pair<=0;work_bits<=0;work_time<=0;next_token<=1;
   on_count<=0;off_count<=0;invalid_order<=0;same_sample<=0;half_cancel<=0;half_timeout<=0;time_errors<=0;
   mem_phase<=0;edge_a<=0;edge_b<=0;first_cache<=0;token_cache<=0;
   for(j=0;j<4;j=j+1)row_time[j]<=0;
   for(j=0;j<13;j=j+1)key_state[j]<=WAIT_RELEASE;
  end else begin
   fault<=0;map_start<=0;if(event_valid&&event_ready)event_valid<=0;
   if(reset_stream)begin
    busy<=0;checking<=0;mapping<=0;map_start<=0;event_valid<=0;raw_bitmap<=0;raw<=0;stable<=0;seen<=0;active<=0;
    for(j=0;j<13;j=j+1)key_state[j]<=WAIT_RELEASE;
   end else if(mapping)begin
    if(map_done)begin mapping<=0;event_valid<=1;event_data[103:96]<=map_velocity;end
   end else if(row_valid&&row_ready)begin
    // Register the complete transaction before validation. This cuts the
    // packet RAM -> time subtract/compare -> global state-enable path.
    work_row<=row;work_bits<=closed;work_time<=capture_us;work_initial<=initial_sample;checking<=1;
   end else if(checking)begin
    checking<=0;
    if(seen[work_row]&&((work_time-row_time[work_row])>32'h7fffffff || work_time-row_time[work_row]>1000000))begin
     fault<=1;time_errors<=time_errors+1'b1;active<=0;seen<=0;event_valid<=0;raw<=0;stable<=0;raw_bitmap<=0;
     for(j=0;j<13;j=j+1)key_state[j]<=WAIT_RELEASE;
    end else begin
     row_time[work_row]<=work_time;seen[work_row]<=1;raw_bitmap[work_row*8+:8]<=work_bits;
     pair<=0;mem_phase<=0;busy<=1;
    end
   end else if(busy&&!event_valid)begin
    case(mem_phase)
     0:mem_phase<=1;
     1:begin edge_a<=timing_q;mem_phase<=2;end
     2:begin edge_b<=timing_q;mem_phase<=3;end
     3:begin first_cache<=timing_q;mem_phase<=4;end
     4:begin token_cache<=timing_q;mem_phase<=5;end
     5:begin
    a=work_row*8+pair*2;b=a+1;k=work_row*4+pair;
    ra=work_bits[pair*2];rb=work_bits[pair*2+1];
    if(swap_ab&&k<13)begin ra=work_bits[pair*2+1];rb=work_bits[pair*2];end
    sa=stable[a];sb=stable[b];ta=edge_a;tb=edge_b;
    if(work_initial)begin
     raw[a]<=ra;raw[b]<=rb;stable[a]<=ra;stable[b]<=rb;ta=work_time;tb=work_time;
    end else begin
    if(raw[a]!=ra)begin raw[a]<=ra;ta=work_time;end
    else if(work_time-ta>=DEBOUNCE_US)begin sa=ra;stable[a]<=ra;end
    if(raw[b]!=rb)begin raw[b]<=rb;tb=work_time;end
    else if(work_time-tb>=DEBOUNCE_US)begin sb=rb;stable[b]<=rb;end
    if(k<13)begin
     case(key_state[k])
      WAIT_RELEASE,INVALID:if(!sa&&!sb&&!ra&&!rb)key_state[k]<=READY;
      READY:begin
       if(sb&&!sa)begin key_state[k]<=INVALID;invalid_order<=invalid_order+1'b1;end
       else if(sa)begin
        first_cache<=ta;
        if(!sb)key_state[k]<=HALF;
        else begin
         dt=tb-ta;
         if(dt>HALF_TIMEOUT_US||work_time-ta>HALF_TIMEOUT_US+CONFIRM_GRACE_US||next_token==0)begin key_state[k]<=INVALID;invalid_order<=invalid_order+1'b1;end
         else begin
          if(dt==0)same_sample<=same_sample+1'b1;
          emit_event(0,k[3:0],0,next_token,tb,dt);
          token_cache<=next_token;next_token<=next_token+1'b1;key_state[k]<=ACTIVE;active[k]<=1;on_count<=on_count+1'b1;
         end
        end
       end
      end
      HALF:begin
       dt=tb-first_cache;
       if(!sa)begin key_state[k]<=(!sb&&!ra&&!rb)?READY:WAIT_RELEASE;half_cancel<=half_cancel+1'b1;end
       else if(sb)begin
        if(dt>HALF_TIMEOUT_US||work_time-first_cache>HALF_TIMEOUT_US+CONFIRM_GRACE_US||next_token==0)begin key_state[k]<=INVALID;invalid_order<=invalid_order+1'b1;end
        else begin
         if(dt==0)same_sample<=same_sample+1'b1;
         emit_event(0,k[3:0],0,next_token,tb,dt);
         token_cache<=next_token;next_token<=next_token+1'b1;key_state[k]<=ACTIVE;active[k]<=1;on_count<=on_count+1'b1;
        end
       end else if(work_time-first_cache>HALF_TIMEOUT_US)begin
        // Only an already observed, in-range B edge can finish debounce late.
        // Capture progress bounds this grace; UART delivery time never enters it.
        if(!(rb && dt<=HALF_TIMEOUT_US && work_time-first_cache<=HALF_TIMEOUT_US+CONFIRM_GRACE_US))begin
         key_state[k]<=INVALID;half_timeout<=half_timeout+1'b1;
        end
       end
      end
      ACTIVE:if(!sb)begin emit_event(1,k[3:0],0,token_cache,tb,0);active[k]<=0;
       key_state[k]<=(!sa&&!ra&&!rb)?READY:WAIT_RELEASE;off_count<=off_count+1'b1;end
      default:key_state[k]<=WAIT_RELEASE;
     endcase
    end
    end
    edge_a<=ta;edge_b<=tb;mem_phase<=6;
     end
     6,7,8:mem_phase<=mem_phase+1'b1;
     9:begin mem_phase<=0;if(pair==3)busy<=0;else pair<=pair+1'b1;end
     default:mem_phase<=0;
    endcase
   end
  end
 end
endmodule
