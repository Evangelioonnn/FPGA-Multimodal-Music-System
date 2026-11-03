// Bounded input intents, not stale absolute SETs. Two encoder steps in one
// cycle are retained in RELEASE, EDIT order. No audible state lives here.
module envelope_controls(
 input wire clk,rst,input wire [2:0] preset,input wire [7:0] epoch,
 input wire locked,timbre_pending,input wire tim_step,
 input wire release_short,release_long,release_step,input wire signed[1:0]release_direction,
 input wire edit_step,input wire signed[1:0]edit_direction,
 input wire [63:0] navigation,input wire activate,
 output reg [1:0] selected,output wire valid,input wire ready,output wire[31:0]value,
 output reg overflow,output reg[7:0]feedback,output reg[15:0]sequence
);
 wire supported=preset==0||preset==4||preset==5;
 wire envelope_page=navigation[2:0]==0&&navigation[4:3]==2;
 wire [3:0]focus=navigation[8:5];
 wire confirm_item=envelope_page&&activate&&focus<4;
 wire reset_all=envelope_page&&activate&&focus==4;
 wire step_edit=envelope_page&&navigation[9]&&(navigation[10]||confirm_item)&&edit_step;
 wire [1:0]next_selected=confirm_item ? focus[1:0] : release_short&&!release_long ? selected+2'd1 : selected;
 reg [31:0]queue[0:7];reg [2:0]read_pointer,write_pointer;reg [3:0]count;
 reg [7:0]previous_epoch;reg [2:0]previous_preset;
 // Simultaneous TIM and RELEASE means the new timbre's default R. Preserve
 // the physical increments until the TIM transaction has completed.
 reg signed [7:0]deferred_release;
 reg [1:0]requested_count;wire[1:0]add_count=dispatch ? requested_count : 2'd0;reg [31:0]first,second,third;
 wire context_change=epoch!=previous_epoch;
 wire switching=timbre_pending||tim_step;
 wire dispatch=!locked&&!switching&&!context_change&&supported;
 assign valid=count!=0&&dispatch;
 assign value=queue[read_pointer];
 wire pop=valid&&ready;
 wire[3:0]add_limit=4'd8-{2'd0,requested_count};
 wire room_for_add=count<=add_limit||(pop&&count==add_limit+4'd1);
 function [31:0]intent;input[7:0]ep;input[2:0]pre;input[1:0]item,op;input[15:0]raw;
 begin intent={ep,1'b0,pre,item,op,raw};end endfunction
 always @*begin
  requested_count=0;first=0;second=0;third=0;
  begin
   if(reset_all)begin first=intent(epoch,preset,0,2,0);requested_count=1;end
   else if(release_long)begin first=intent(epoch,preset,next_selected,1,0);requested_count=1;end
   else begin
    if(deferred_release!=0)begin first=intent(epoch,preset,3,3,deferred_release>0 ? 16'd1 : 16'hffff);requested_count=1;end
    if(release_step)begin
     if(requested_count==0)first=intent(epoch,preset,next_selected,3,release_direction>0 ? 16'd1 : 16'hffff);
     else second=intent(epoch,preset,next_selected,3,release_direction>0 ? 16'd1 : 16'hffff);
     requested_count=requested_count+1'b1;
    end
    if(step_edit)begin
     if(requested_count==0)first=intent(epoch,preset,next_selected,3,edit_direction>0 ? 16'd1 : 16'hffff);
     else if(requested_count==1)second=intent(epoch,preset,next_selected,3,edit_direction>0 ? 16'd1 : 16'hffff);
     else third=intent(epoch,preset,next_selected,3,edit_direction>0 ? 16'd1 : 16'hffff);
     requested_count=requested_count+1'b1;
    end
   end
  end
 end
 always @(posedge clk)begin
  if(rst)begin selected<=3;read_pointer<=0;write_pointer<=0;count<=0;
   previous_epoch<=0;previous_preset<=0;deferred_release<=0;overflow<=0;feedback<=0;sequence<=0;end
  else begin
   previous_epoch<=epoch;previous_preset<=preset;
   if(preset!=previous_preset)selected<=3;
   else if(supported&&!locked&&!switching)selected<=next_selected;
   if(locked||!supported)begin
    count<=0;read_pointer<=write_pointer;deferred_release<=0;
    if(release_step||release_short||release_long||step_edit||activate&&envelope_page)begin feedback<=locked ? 8'd2 : 8'd3;sequence<=sequence+1'b1;end
   end else begin
    if(switching&&release_step)begin
     if((release_direction>0&&deferred_release==127)||(release_direction<0&&deferred_release==-127))begin overflow<=1;feedback<=4;end
     else deferred_release<=deferred_release+$signed(release_direction);
    end
    if(context_change)begin count<=0;read_pointer<=write_pointer;if(count!=0)begin feedback<=5;sequence<=sequence+1'b1;end end
    else begin
     if(pop)read_pointer<=read_pointer+1'b1;
     if(add_count!=0&&room_for_add)begin
      queue[write_pointer]<=first;
      if(add_count>=2)queue[write_pointer+3'd1]<=second;
      if(add_count==3)queue[write_pointer+3'd2]<=third;
      write_pointer<=write_pointer+add_count;count<=count+add_count-(pop ? 1'b1 : 1'b0);
      if(deferred_release!=0&&!reset_all&&!release_long)deferred_release<=deferred_release+(deferred_release>0 ? -1 : 1);
      feedback<=1;sequence<=sequence+1'b1;
     end else begin
      if(pop)count<=count-1'b1;
      if(add_count!=0)begin overflow<=1;feedback<=4;sequence<=sequence+1'b1;end
     end
    end
    if(release_short||confirm_item)begin sequence<=sequence+1'b1;feedback<=1;end
   end
  end
 end
endmodule
