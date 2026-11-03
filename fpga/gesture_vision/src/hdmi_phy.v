// GW2A PHY adaptation of C's readable encoder path: native TLVDS, OSER10.
// C's av_dvi_tx/clock gates are left unchanged in their original snapshot.
module p20_hdmi_phy(input wire pixel_clk,serial_clk,rst,serializer_reset,
    input wire de,hs,vs,input wire [23:0] rgb,
    output wire tmds_clk_p,tmds_clk_n,
    output wire [2:0] tmds_d_p,tmds_d_n);
    wire [29:0] codes;
    wire [3:0] serial;
    genvar lane;
    generate for(lane=0;lane<3;lane=lane+1)begin: channels
        wire [1:0] control=(lane==0)?{vs,hs}:2'b00;
        dvi_tx_tmds_enc encoder(pixel_clk,~rst,de,rgb[lane*8+:8],control,codes[lane*10+:10]);
        OSER10 #(.GSREN("false"),.LSREN("true")) ser(
            .Q(serial[lane]),.PCLK(pixel_clk),.FCLK(serial_clk),.RESET(serializer_reset),
            .D0(codes[lane*10]),.D1(codes[lane*10+1]),.D2(codes[lane*10+2]),
            .D3(codes[lane*10+3]),.D4(codes[lane*10+4]),.D5(codes[lane*10+5]),
            .D6(codes[lane*10+6]),.D7(codes[lane*10+7]),.D8(codes[lane*10+8]),.D9(codes[lane*10+9]));
        TLVDS_OBUF buffer(.I(serial[lane]),.O(tmds_d_p[lane]),.OB(tmds_d_n[lane]));
    end endgenerate
    OSER10 #(.GSREN("false"),.LSREN("true")) clock_ser(
        .Q(serial[3]),.PCLK(pixel_clk),.FCLK(serial_clk),.RESET(serializer_reset),
        .D0(1'b0),.D1(1'b0),.D2(1'b0),.D3(1'b0),.D4(1'b0),
        .D5(1'b1),.D6(1'b1),.D7(1'b1),.D8(1'b1),.D9(1'b1));
    TLVDS_OBUF clock_buffer(.I(serial[3]),.O(tmds_clk_p),.OB(tmds_clk_n));
endmodule
