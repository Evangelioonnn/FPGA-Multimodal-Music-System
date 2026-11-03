// Small extension registers; audio voices and the legacy parameter bridge stay shared.
module v18_controls #(parameter WITH_NEW_FX=1,WITH_LOOP_EXPORT=0)(input wire clk,rst,enabled,locked,record_locked,
 input wire[63:0]navigation,dd_status,input wire activate,edit_step,input wire[1:0]direction,
 input wire export_lock,export_finished,export_failed,input wire[11:0]export_progress,
 output reg[1:0]space_type,filter_type,output reg[3:0]cutoff,
 output reg[2:0]chorus_rate,chorus_depth,output reg record_source,dd_swap,dd_reload,
 output reg export_armed,export_cancel,output wire[63:0]status);
 wire[2:0]tab=navigation[2:0];wire[1:0]sub=navigation[4:3];wire[3:0]focus=navigation[8:5];
 wire browsing=navigation[9],editing=navigation[10];wire up=direction==1;
 reg[15:0]seq;reg[3:0]last;reg done,failed;
 assign status={12'd0,export_progress,seq,last,failed,done,export_lock,export_armed,dd_swap,record_source,chorus_depth,chorus_rate,cutoff,filter_type,space_type};
 always @(posedge clk)begin
  if(rst)begin space_type<=0;filter_type<=0;cutoff<=10;chorus_rate<=3;chorus_depth<=3;record_source<=0;dd_swap<=0;dd_reload<=0;export_armed<=0;export_cancel<=0;seq<=0;last<=0;done<=0;failed<=0;end
  else begin
   dd_reload<=0;export_cancel<=0;
   if(WITH_LOOP_EXPORT&&(export_finished||export_failed))begin export_armed<=0;done<=export_finished;failed<=export_failed;end
   if(enabled&&browsing)begin
    if(WITH_LOOP_EXPORT&&activate&&tab==1&&sub==2&&focus==2)begin export_cancel<=1;export_armed<=0;last<=9;seq<=seq+1'b1;end
    else if(!locked)begin
     if(activate&&((tab==4&&sub==1&&focus==1&&dd_status[21:9]!=0)||(tab==1&&sub==2&&focus<2&&record_locked)))begin last<=8;seq<=seq+1'b1;end
     if(activate)begin
      if(WITH_NEW_FX&&tab==0&&sub==3&&focus==0)begin space_type<=space_type==2 ? 0 : space_type+1'b1;last<=1;seq<=seq+1'b1;end
      if(WITH_NEW_FX&&tab==0&&sub==3&&focus==2)begin filter_type<=filter_type==2 ? 0 : filter_type+1'b1;last<=2;seq<=seq+1'b1;end
      if(tab==4&&sub==1&&focus==0)begin dd_reload<=1;last<=3;seq<=seq+1'b1;end
      if(tab==4&&sub==1&&focus==1&&dd_status[21:9]==0)begin dd_swap<=!dd_swap;last<=4;seq<=seq+1'b1;end
      if(tab==1&&sub==2&&focus==0&&!record_locked)begin record_source<=!record_source;last<=5;seq<=seq+1'b1;end
      if(WITH_LOOP_EXPORT&&tab==1&&sub==2&&focus==1&&!record_locked)begin export_armed<=1;done<=0;failed<=0;last<=6;seq<=seq+1'b1;end
     end
     if(WITH_NEW_FX&&edit_step&&editing&&tab==0&&sub==3)begin
      if(focus==3)cutoff<=up ? (cutoff==15 ? 15 : cutoff+1'b1) : (cutoff==0 ? 0 : cutoff-1'b1);
      if(focus==4)chorus_rate<=up ? (chorus_rate==7 ? 7 : chorus_rate+1'b1) : (chorus_rate==0 ? 0 : chorus_rate-1'b1);
      if(focus==5)chorus_depth<=up ? (chorus_depth==7 ? 7 : chorus_depth+1'b1) : (chorus_depth==0 ? 0 : chorus_depth-1'b1);
      if(focus>=3&&focus<=5)begin last<=7;seq<=seq+1'b1;end
     end
    end else if(activate||edit_step)begin last<=8;seq<=seq+1'b1;end
   end
  end
 end
endmodule
