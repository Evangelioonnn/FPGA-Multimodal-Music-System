// 16-bit Philips I2S,32 BCK/frame. All state remains in the existing50MHz
// domain. ODDR emits65 half-clock ticks/BCK: constant650ns period,330ns low,
// 320ns high. No fractional cycle modulation,PLL,new internal clock or FIFO.
module i2s_pcm5102_tx(
 input wire clk,rst,frame_ce,
 input wire signed[15:0]sample_left,sample_right,
 output wire i2s_bck,i2s_lrck,i2s_din
);
 reg active=0;reg[6:0]phase=0;reg[4:0]slot=0;
 reg[15:0]left_hold=0,right_hold=0;reg previous_right_lsb=0;
 // The existing phase/slot state returns here every1040 clocks. External
 // frame_ce is used only for initial alignment; both transports share rst.
 wire capture=(!active&&frame_ce)||(active&&phase==63&&slot==31);
 always @(posedge clk)begin
  if(rst)begin active<=0;phase<=0;slot<=0;left_hold<=0;right_hold<=0;previous_right_lsb<=0;end
  else begin
   if(capture)begin
    active<=1;left_hold<=sample_left;right_hold<=sample_right;
    previous_right_lsb<=right_hold[0];
   end
   if(active)begin
    if(phase>=63)begin phase<=phase-7'd63;slot<=slot+1'b1;end
    else phase<=phase+7'd2;
   end
  end
 end
 wire[6:0]phase1=phase==64 ? 7'd0 : phase+1'b1;
 wire[4:0]slot1=phase==64 ? slot+1'b1 : slot;
 function serial_bit;
  input[4:0]position;input[15:0]l,r;input last_r;
  begin
   if(position==0)serial_bit=last_r;
   else if(position<=16)serial_bit=l[16-position];
   else serial_bit=r[32-position];
  end
 endfunction
 // LRCK changes with the previous channel's LSB. Its new MSB follows one
 // complete BCK later. All three outputs traverse the same ODDR pipeline.
 ODDR bck_ddr(.Q0(i2s_bck),.Q1(),.D0(active&&phase>=33),.D1(active&&phase1>=33),.TX(1'b0),.CLK(clk));
 ODDR lrck_ddr(.Q0(i2s_lrck),.Q1(),.D0(active&&slot>=16),.D1(active&&slot1>=16),.TX(1'b0),.CLK(clk));
 ODDR data_ddr(.Q0(i2s_din),.Q1(),.D0(active&&serial_bit(slot,left_hold,right_hold,previous_right_lsb)),.D1(active&&serial_bit(slot1,left_hold,right_hold,previous_right_lsb)),.TX(1'b0),.CLK(clk));
endmodule
