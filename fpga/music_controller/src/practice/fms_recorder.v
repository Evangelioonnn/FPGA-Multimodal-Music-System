// Manual-key event capture only. No PCM, playback clock, or audio backpressure.
module fms_recorder #(
 parameter CLK_HZ=50000000,DEPTH=128,MAX_MS=60000,MAX_NOTES=512,
 parameter AW=$clog2(DEPTH),DW=(CLK_HZ/1000>1 ? $clog2(CLK_HZ/1000) : 1)
)(input wire clk,rst,input wire [24:0] keys,input wire [3:0] preset,
 input wire cancel,input wire [2:0] cancel_reason,
 input wire start,stop,input wire [31:0] requested_id,
 output reg control_done,output reg [7:0] control_error,
 input wire pop,output wire [63:0] front,
 output reg [31:0] record_id,output reg [3:0] recorded_preset,
 output reg active,closing,complete,failed,output reg [2:0] reason,
 output reg [15:0] elapsed_ms,total_events,note_ons,
 output wire [AW:0] level,output wire front_valid);
 localparam MS_DIV=(CLK_HZ>=1000 ? CLK_HZ/1000 : 1);
 wire fifo_ready,fifo_busy;
 reg [DW-1:0] divider;
 reg [24:0] owned;
 reg [4:0] scan;
 reg stop_wait;
 wire valid_preset=preset==0 || preset==3 || preset==7 || preset==8 || preset==9;
 wire do_pop=pop && level!=0 && front_valid;
 wire changed=keys[scan]!=owned[scan];
 wire limit_note=active && changed && keys[scan] && note_ons==MAX_NOTES;
 wire valid_stop=stop && record_id!=0 && requested_id==record_id;
 wire ending=valid_stop || elapsed_ms==MAX_MS || limit_note;
 wire capture=(active && !ending && changed) || (closing && owned[scan]);
 wire room=level<DEPTH || do_pop;
 // !start implies !new_record, so the FIFO flush term is redundant here.
 wire write_event=capture && room && !fifo_busy && !rst && !cancel && !start;
 wire [7:0] pitch=8'd48+{3'd0,scan};
 wire is_on=active && keys[scan];
 // The index is part of every record, so the phone detects a lost batch.
 wire [63:0] event_word={total_events,7'd0,is_on,pitch,16'd0,elapsed_ms};
 wire new_record=start && !active && !closing && !cancel && requested_id!=0 && keys==0 && valid_preset;
 fms_record_fifo #(.DEPTH(DEPTH)) fifo(clk,rst,new_record,write_event,event_word,fifo_ready,pop,front,front_valid,level,fifo_busy);
 genvar oi;generate for(oi=0;oi<25;oi=oi+1)begin:owned_bits
  always @(posedge clk)if(rst||new_record)owned[oi]<=0;
   else if(write_event&&scan==oi)owned[oi]<=is_on;
 end endgenerate
 always @(posedge clk)begin
  if(rst)begin
   divider<=0;scan<=0;stop_wait<=0;
   record_id<=0;recorded_preset<=0;active<=0;closing<=0;complete<=0;failed<=0;reason<=0;
   elapsed_ms<=0;total_events<=0;note_ons<=0;control_done<=0;control_error<=0;
  end else begin
   control_done<=0;
   if(write_event)begin
    total_events<=total_events+1'b1;

    if(is_on)note_ons<=note_ons+1'b1;
   end
   if(active)begin
    if(divider==MS_DIV-1)begin divider<=0;if(elapsed_ms<MAX_MS)elapsed_ms<=elapsed_ms+1'b1;end
    else divider<=divider+1'b1;
   end
   if(start)begin
    control_done<=1;control_error<=0;
    if(active || closing || cancel)control_error<=3;
    else if(requested_id==0 || keys!=0 || !valid_preset)control_error<=2;
    else begin
     scan<=0;divider<=0;stop_wait<=0;
     record_id<=requested_id;recorded_preset<=preset;active<=1;closing<=0;complete<=0;failed<=0;reason<=0;
     elapsed_ms<=0;total_events<=0;note_ons<=0;
    end
   end else if(cancel && (active || closing))begin
    active<=0;closing<=0;complete<=0;failed<=1;reason<=cancel_reason;
    if(stop_wait || stop)begin control_done<=1;control_error<=0;end
    stop_wait<=0;
   end else begin
    if(stop)begin
     control_error<=0;
     if(requested_id!=record_id || record_id==0)begin control_done<=1;control_error<=4;end
     else if(!active && !closing)control_done<=1;
     else stop_wait<=1;
    end
    if(active)begin
     if(ending)begin
      active<=0;closing<=1;scan<=0;
      reason<=valid_stop ? 0 : elapsed_ms==MAX_MS ? 1 : 2;
     end else if(capture && !room)begin
      active<=0;complete<=0;failed<=1;reason<=3;
     end else if(!capture||write_event)scan<=scan==24 ? 0 : scan+1'b1;
    end else if(closing)begin
     if(capture && !room)begin
      closing<=0;complete<=0;failed<=1;reason<=3;
      if(stop_wait || stop)begin control_done<=1;control_error<=0;end
      stop_wait<=0;
     end else if(scan==24)begin
      if(!capture&&!fifo_busy)begin
      closing<=0;complete<=1;scan<=0;
      if(stop_wait || stop)begin control_done<=1;control_error<=0;end
      stop_wait<=0;end
     end else if(!capture||write_event)scan<=scan+1'b1;
    end
   end
  end
 end
endmodule
