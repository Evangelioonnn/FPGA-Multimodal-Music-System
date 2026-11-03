// Screen-only MCU library client. CRC/parser byte RAM and UART TX are shared.
// No song cache, filesystem, audio, or second wide packet bus is instantiated.
module library_client #(
 parameter TIMEOUT_CYCLES=500000000,POLL_CYCLES=5000000,STALL_POLLS=300,MAX_POLLS=2047
)(input wire clk,rst,enter,leave,next_song,previous_song,confirm,refresh,
 input wire safe_stopped,phone_connected,panic,
 input wire ram_valid,input wire[15:0]ram_id,input wire[31:0]ram_generation,
 input wire upload_busy,flushing,
 output reg request_valid,input wire request_ready,
 output wire[7:0]request_command,output wire[6:0]request_length,
 output reg[31:0]request_session,output reg[15:0]request_sequence,
 input wire[5:0]request_address,output reg[7:0]request_byte,
 input wire response_valid,output wire response_ready,
 input wire[7:0]response_command,input wire[31:0]response_session,
 input wire[15:0]response_sequence,input wire[6:0]response_length,
 output wire[5:0]response_address,input wire[7:0]response_byte,
 output reg active,entry_ready,loading,linked,unknown,
 output wire load_admit,
 output reg[7:0]error,output reg[5:0]count,output reg[4:0]index,
 output reg[15:0]selected_id,selected_notes,output wire[319:0]selected_title,
 output reg[31:0]selected_duration,output reg[16:0]selected_size,received,total,
 output wire selected_loaded,output wire transaction_busy
);
 // Internal display bundle, NOT a changed UART title field.
 reg[63:0]selected_prefix;reg preview_nonascii,preview_truncated;
 assign selected_title={preview_nonascii,preview_truncated,254'd0,selected_prefix};
 localparam CAPS=0,ENTRY=1,LOAD=2,STATUS=3;
 localparam RX_IDLE=0,RX_WAIT=1,RX_READ=2,RX_DONE=3;
 reg[1:0]phase,rx_state;reg waiting,poll_pending,aborted;
 // Countdown registers load only the truncated 32-bit parameter and count
 // down while nonzero; upper unreachable bits need no flip-flops.
 function integer counter_width;
  input [31:0] maximum;integer bit_index;
  begin counter_width=1;for(bit_index=1;bit_index<32;bit_index=bit_index+1)
   if((maximum>>bit_index)!=0)counter_width=bit_index+1;end
 endfunction
 localparam TIMEOUT_WIDTH=counter_width(TIMEOUT_CYCLES);
 localparam POLL_WIDTH=counter_width(POLL_CYCLES);
 reg[1:0]retries;
 reg[TIMEOUT_WIDTH-1:0]timer;reg[POLL_WIDTH-1:0]poll_timer;
 reg[31:0]revision,job,free_counter;
 reg[79:0]request_data;reg[191:0]header;
 reg[5:0]rx_address;reg[6:0]rx_length;reg rx_match;
 reg[10:0]poll_count;reg[8:0]stall_count;reg[16:0]last_progress;
 reg[15:0]verified_id;reg[31:0]verified_generation;
 assign load_admit=!transaction_busy&&!loading&&active&&entry_ready&&confirm&&safe_stopped&&!phone_connected&&!panic;
 wire match=response_session==request_session&&response_sequence==request_sequence&&response_command==(request_command|8'h80);
 assign request_command=8'h40+{6'd0,phase};
 assign request_length=phase==CAPS ? 7'd7 : phase==ENTRY ? 7'd5 : phase==LOAD ? 7'd10 : 7'd0;
 always @*case(request_address)
  0:request_byte=request_data[7:0];1:request_byte=request_data[15:8];
  2:request_byte=request_data[23:16];3:request_byte=request_data[31:24];
  4:request_byte=request_data[39:32];5:request_byte=request_data[47:40];
  6:request_byte=request_data[55:48];7:request_byte=request_data[63:56];
  8:request_byte=request_data[71:64];9:request_byte=request_data[79:72];default:request_byte=0;
 endcase
 assign response_address=rx_address;
 assign response_ready=rx_state==RX_DONE;
 assign transaction_busy=request_valid||waiting||poll_pending||rx_state!=RX_IDLE;
 assign selected_loaded=entry_ready&&!unknown&&ram_valid&&!upload_busy&&!flushing&&
  selected_id==ram_id&&verified_id==ram_id&&verified_generation==ram_generation;
 task launch;input[1:0]p;input[79:0]bytes;begin
  phase<=p;timer<=TIMEOUT_CYCLES;request_data<=bytes;request_valid<=1;waiting<=0;retries<=0;poll_pending<=0;
 end endtask
 task fail;input[7:0]reason;begin
  error<=reason;unknown<=loading||unknown;entry_ready<=phase==ENTRY ? 1'b0 : entry_ready;waiting<=0;request_valid<=0;poll_pending<=0;
 end endtask
 task open_catalog;begin
  active<=1;entry_ready<=0;linked<=0;error<=0;count<=0;index<=0;
  request_session<=free_counter|32'd1;request_sequence<=0;
  launch(CAPS,{24'd0,ram_generation,ram_id,7'd0,ram_valid});
 end endtask
 always @(posedge clk)begin
  if(rst)begin
   active<=0;entry_ready<=0;loading<=0;linked<=0;unknown<=0;aborted<=0;
   error<=0;count<=0;index<=0;selected_id<=0;selected_notes<=0;selected_prefix<=0;preview_nonascii<=0;preview_truncated<=0;
   selected_duration<=0;selected_size<=0;received<=0;total<=0;
   request_valid<=0;request_session<=0;request_sequence<=0;request_data<=0;
   phase<=CAPS;waiting<=0;poll_pending<=0;retries<=0;timer<=0;poll_timer<=0;
   revision<=0;job<=0;free_counter<=1;header<=0;rx_state<=RX_IDLE;rx_address<=0;rx_length<=0;rx_match<=0;
   poll_count<=0;stall_count<=0;last_progress<=0;verified_id<=0;verified_generation<=0;
  end else begin
   free_counter<=free_counter+1'b1;
   if(panic&&loading)aborted<=1;
   // Drain every library reply, including stale/unsolicited frames. Only the
   // current immutable transaction may update fields or renew its deadline.
   case(rx_state)
    RX_IDLE:if(response_valid)begin
     rx_address<=0;rx_length<=response_length;rx_match<=waiting&&match;
     if(waiting&&match)begin header<=0;if(phase==ENTRY)begin preview_nonascii<=0;preview_truncated<=0;end end
     rx_state<=response_length==0||response_length>64 ? RX_DONE:RX_WAIT;
    end
    RX_WAIT:rx_state<=RX_READ;
    RX_READ:begin
     if(rx_match)begin
      if(phase==ENTRY)begin
       if(rx_address<18)header[rx_address*8+:8]<=response_byte;
       else if(rx_address<58)begin
        if(rx_address<26)selected_prefix[(rx_address-18)*8+:8]<=response_byte;
        preview_nonascii<=preview_nonascii||response_byte[7];
        if(rx_address>=26)preview_truncated<=preview_truncated||(|response_byte);
       end
       else if(rx_address==58)header[151:144]<=response_byte;
       else if(rx_address==59)header[159:152]<=response_byte;
      end else if(rx_address<24)header[rx_address*8+:8]<=response_byte;
     end
     if({1'b0,rx_address}+7'd1>=rx_length)rx_state<=RX_DONE;
     else begin rx_address<=rx_address+1'b1;rx_state<=RX_WAIT;end
    end
    RX_DONE:rx_state<=RX_IDLE;
   endcase
   if(request_valid&&request_ready)begin request_valid<=0;waiting<=1;timer<=TIMEOUT_CYCLES;end
   if((waiting||request_valid)&&timer!=0)timer<=timer-1'b1;
   // Process after the last registered byte. A matching reply wins timeout.
   if(rx_state==RX_DONE&&rx_match&&waiting)begin
    waiting<=0;request_sequence<=request_sequence+1'b1;
    if(rx_length==0||rx_length>64)fail(2);
    else if(header[7:0]!=0)begin
     fail(header[7:0]);
     // An explicit LOAD rejection is a known non-acceptance, unlike silence.
     if(phase==LOAD)begin loading<=0;unknown<=0;end
    end
    else case(phase)
     CAPS:if(rx_length!=10||header[15:8]!=1||header[23:16]>32||header[71:64]!=48||header[79:72]!=72)fail(2);
      else if(!header[24])begin linked<=1;fail(6);end
      else begin
       linked<=1;count<=header[21:16];revision<=header[63:32];
       if(header[23:16]!=0)launch(ENTRY,{40'd0,8'd0,header[63:32]});
       else begin entry_ready<=0;selected_id<=0;selected_prefix<=0;preview_nonascii<=0;preview_truncated<=0;end
      end
     ENTRY:if(rx_length!=60||header[39:8]!=revision||header[47:40]!={3'd0,index}||header[63:48]==0||
        header[95:64]<512||header[95:64]>66048||header[72:64]!=0||header[151:144]!={2'd0,count})fail(4);
      else begin
       selected_id<=header[63:48];selected_size<=header[80:64];selected_duration<=header[127:96];selected_notes<=header[143:128];entry_ready<=1;
       verified_id<=0; // Each ENTRY must renew proof, including same-ID content replacement.
       if(header[152]&&!unknown&&ram_valid&&header[63:48]==ram_id)begin verified_id<=ram_id;verified_generation<=ram_generation;end
      end
     LOAD:if(rx_length!=5||header[39:8]!=job)fail(4);
      else begin phase<=STATUS;poll_pending<=1;poll_timer<=POLL_CYCLES;end
     STATUS:if(rx_length!=24||header[127:96]>66048||header[95:64]>header[127:96])fail(4);
      else if(header[63:32]!=job)begin
       // Reboot/another completed job: release only on a terminal, unowned,
       // non-writing MCU observation and a locally idle transfer engine.
       fail(9);
       if((header[15:8]==0||header[15:8]>=9)&&header[31:24]==0&&header[183:176]==0&&!upload_busy&&!flushing)begin loading<=0;unknown<=1;end
      end
      else begin
       received<=header[80:64];total<=header[112:96];
       if(header[15:8]==9)begin
        if(header[143:128]!=selected_id||!ram_valid||ram_id!=selected_id||ram_generation!=header[175:144]||upload_busy||flushing||header[31:24]!=0||header[183:176]!=0)fail(9);
        else begin loading<=0;unknown<=0;error<=aborted?8'd10:8'd0;verified_id<=ram_id;verified_generation<=ram_generation;end
       end else if(header[15:8]==10||header[15:8]==11)begin
        fail(header[23:16]!=0?header[23:16]:8'd9);
        if(!upload_busy&&!flushing&&header[31:24]==0&&header[183:176]==0)loading<=0;
       end
       else if(poll_count>=MAX_POLLS||stall_count>=STALL_POLLS)fail(9);
       else begin
        poll_count<=poll_count+1'b1;
        if(header[80:64]!=last_progress)stall_count<=0;else stall_count<=stall_count+1'b1;
        last_progress<=header[80:64];poll_pending<=1;poll_timer<=POLL_CYCLES;
       end
      end
    endcase
   end else if((waiting||request_valid)&&timer==0&&rx_state==RX_IDLE)begin
    if(retries==2)begin linked<=0;fail(9);end
    else begin retries<=retries+1'b1;request_valid<=1;waiting<=0;timer<=TIMEOUT_CYCLES;end
   end else if(poll_pending)begin
    if(poll_timer!=0)poll_timer<=poll_timer-1'b1;
    else launch(STATUS,80'd0);
   end else if(!transaction_busy&&loading&&unknown&&refresh)begin
    // Explicit retry reconciles an ambiguous outcome; never silently unlock.
    request_sequence<=request_sequence+1'b1;launch(STATUS,80'd0);
   end else if(!transaction_busy&&!loading)begin
    if((enter||refresh)&&!upload_busy&&!flushing&&!phone_connected)open_catalog;
    else if(enter||refresh)begin active<=1;error<=3;end
    else if(leave)active<=0;
    else if(active&&entry_ready)begin
     if(next_song||previous_song)begin
      entry_ready<=0;error<=0;
      if(next_song)begin
       index<=({1'b0,index}+6'd1<count)?index+1'b1:5'd0;
       launch(ENTRY,{40'd0,({1'b0,index}+6'd1<count)?({3'd0,index}+8'd1):8'd0,revision});
      end else begin
       index<=index!=0?index-1'b1:count[4:0]-1'b1;
       launch(ENTRY,{40'd0,index!=0?({3'd0,index}-8'd1):({2'd0,count}-8'd1),revision});
      end
     end else if(confirm)begin
      if(!safe_stopped||phone_connected||panic)error<=3;
      else begin
       error<=0;unknown<=0;aborted<=0;loading<=1;received<=0;total<=selected_size;
       job<=free_counter|32'd1;poll_count<=0;stall_count<=0;last_progress<=0;verified_id<=0;
       launch(LOAD,{revision,selected_id,free_counter|32'd1});
      end
     end
    end
   end
  end
 end
endmodule
