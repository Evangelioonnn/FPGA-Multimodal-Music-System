// Timestamped dual-contact front end. No audio oscillator or duplicate voice bank.
module dd_keyboard(input wire clk,rst,rx,enabled,swap_ab,patch_locked,reload,
 input wire [135:0] profile_patch,input wire profile_ready,output wire profile_request,
 output reg [3:0] preset,output reg [6:0] base_note,output reg [135:0] patch,
 output wire valid,input wire ready,output wire off,output wire [31:0] token,
 output wire [6:0] note,output wire [2:0] timbre,output wire [7:0] velocity,
 output wire source_fault,output wire idle,output wire [63:0] status);
 wire byte_valid,uart_error;wire[7:0]data;
 dcl_uart_rx uart(clk,rst,rx,byte_valid,data,uart_error);
 wire rv,rr,initial_sample,rebase,stream_fault,synced,core_fault;
 wire[1:0]row;wire[7:0]contacts;wire[31:0]capture_us;
 wire[31:0]crc_errors,frame_errors,sequence_errors,duplicates,link_errors;
 reg previous_enabled,previous_swap;reg [2:0]previous_buttons,pending_buttons;reg needs_profile;
 wire[2:0]buttons;wire[31:0]bitmap;wire[12:0]active;
 wire ev,er;wire[108:0]event_data;
 wire[31:0]on_count,off_count,order_errors,same_sample,cancel_count,timeout_count,time_errors;
 wire gate_changed=enabled!=previous_enabled||swap_ab!=previous_swap;
 dcl_receiver receiver(clk,rst,byte_valid,data,uart_error,core_fault||gate_changed,
  rv,rr,row,contacts,capture_us,initial_sample,rebase,stream_fault,synced,
  crc_errors,frame_errors,sequence_errors,duplicates,link_errors);
 dcl_velocity detector(clk,rst,rebase||stream_fault||gate_changed,swap_ab,
  rv,rr,row,contacts,capture_us,initial_sample,ev,er,event_data,
  core_fault,bitmap,buttons,active,on_count,off_count,order_errors,same_sample,cancel_count,timeout_count,time_errors);
 reg[9:0]strike_info[0:12];
 reg last_off;reg[7:0]last_velocity;reg[19:0]last_delta;
 wire[3:0]key=event_data[107:104];
 function[3:0]next_preset;input[3:0]p;begin case(p)
  0:next_preset=3;3:next_preset=4;4:next_preset=5;5:next_preset=6;
  6:next_preset=7;7:next_preset=8;8:next_preset=9;9:next_preset=10;default:next_preset=0;
 endcase end endfunction
 function[3:0]drum_pad;input[3:0]k;begin case(k)
  5:drum_pad=9;6:drum_pad=5;7:drum_pad=6;8:drum_pad=7;9:drum_pad=8;default:drum_pad=k;
 endcase end endfunction
 wire legal_key=key<13;
 wire[6:0]on_note=preset==6 ? {3'd0,drum_pad(key)} : base_note+{3'd0,key};
 wire[2:0]on_timbre=preset==10 ? 3'd1 : preset>=7 ? 3'd7 : preset[2:0];
 assign valid=ev&&enabled&&!needs_profile&&legal_key&&(preset!=6||key<10||event_data[108]);
 assign er=!enabled||!legal_key||(preset==6&&key>=10&&!event_data[108]) ? 1'b1 : ready&&!needs_profile;
 assign off=event_data[108];assign token=event_data[95:64];assign velocity=event_data[103:96];
 assign note=off ? strike_info[key][9:3] : on_note;
 assign timbre=off ? strike_info[key][2:0] : on_timbre;
 assign source_fault=rebase||stream_fault||core_fault||gate_changed;
 assign profile_request=needs_profile;
 assign idle=active==0&&!ev;
 assign status={last_delta,last_velocity,base_note,preset,needs_profile,enabled,synced,active,buttons,core_fault||stream_fault,4'd0,(|bitmap)};
 always @(posedge clk)begin
  if(rst)begin preset<=0;base_note<=60;patch<=0;needs_profile<=1;previous_enabled<=0;previous_swap<=0;previous_buttons<=0;pending_buttons<=0;last_velocity<=0;last_delta<=0;last_off<=0;end
  else begin
   previous_enabled<=enabled;previous_swap<=swap_ab;previous_buttons<=buttons;
   if(!enabled||gate_changed||stream_fault)pending_buttons<=0;
   else pending_buttons<=pending_buttons|(buttons&~previous_buttons);
   if(profile_ready&&needs_profile)begin patch<=profile_patch;needs_profile<=0;end
   if(reload&&!patch_locked)needs_profile<=1;
   if(enabled&&!ev)begin
    pending_buttons<=0;
    if((pending_buttons[0]||(buttons[0]&&!previous_buttons[0]))&&preset!=6&&base_note>(preset==9 ? 24 : 36))base_note<=base_note-12;
    if((pending_buttons[1]||(buttons[1]&&!previous_buttons[1]))&&preset!=6&&base_note<72)base_note<=base_note+12;
    if((pending_buttons[2]||(buttons[2]&&!previous_buttons[2]))&&!patch_locked)begin
     preset<=next_preset(preset);needs_profile<=1;
     if(base_note<36&&next_preset(preset)!=9)base_note<=36;
    end
   end
   if(ev&&er&&legal_key)begin
    if(!off)begin strike_info[key]<={on_note,on_timbre};last_velocity<=velocity;last_delta<=event_data[19:0];end
    last_off<=off;
   end
  end
 end
endmodule
