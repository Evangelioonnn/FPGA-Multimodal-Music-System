// C-local PHY wrapper. Original colorbar source remains unchanged.
module av_dvi_tx(input wire sys_clk, startup_reset, pixel_clock, ddr_bit_clock, rstn,
 input wire den,hsync,vsync,input wire [23:0] pixel_data,
 output wire [1:0] tmds_clk,tmds_d0,tmds_d1,tmds_d2);
 wire enable_clocks,enable_pixel_clocks,serializer_reset,phy_pixel_clock,phy_serial_clock;
 av_serializer_start startup(sys_clk,startup_reset,enable_clocks,serializer_reset,enable_pixel_clocks);
 DCE pixel_gate(.CLKIN(pixel_clock),.CE(enable_pixel_clocks),.CLKOUT(phy_pixel_clock));
 DHCE serial_gate(.CLKIN(ddr_bit_clock),.CEN(!enable_clocks),.CLKOUT(phy_serial_clock));
 wire [5:0] ctrl={4'b0,vsync,hsync};
 wire [29:0] codes;
 wire [2:0] serial_bits;
 wire [1:0] lanes[0:2];
 genvar i;
 generate for(i=0;i<3;i=i+1) begin: lanes_gen
  // Encoder and OSER10 share the gated PCLK branch. Startup blanking fills
  // the encoder pipeline; steady-state words and serializer format are kept.
  dvi_tx_tmds_enc encoder(phy_pixel_clock,rstn,den,pixel_data[8*i+:8],ctrl[2*i+:2],codes[10*i+:10]);
  // One complete encoded pixel, all lanes together. Control symbols are
  // delayed with data; external video geometry and clocks are unchanged.
  (* syn_preserve=1 *)reg[9:0]code_pipe;
  always @(posedge phy_pixel_clock or negedge rstn)
   if(!rstn)code_pipe<=0;else code_pipe<=codes[10*i+:10];
  OSER10 serializer(.Q(serial_bits[i]),
   .D0(code_pipe[0]),.D1(code_pipe[1]),.D2(code_pipe[2]),.D3(code_pipe[3]),.D4(code_pipe[4]),
   .D5(code_pipe[5]),.D6(code_pipe[6]),.D7(code_pipe[7]),.D8(code_pipe[8]),.D9(code_pipe[9]),
   .PCLK(phy_pixel_clock),.FCLK(phy_serial_clock),.RESET(serializer_reset));
  ELVDS_OBUF data_buffer(.I(serial_bits[i]),.O(lanes[i][1]),.OB(lanes[i][0]));
 end endgenerate
 assign tmds_d0=lanes[0];assign tmds_d1=lanes[1];assign tmds_d2=lanes[2];
 ELVDS_OBUF clock_buffer(.I(phy_pixel_clock),.O(tmds_clk[1]),.OB(tmds_clk[0]));
endmodule
