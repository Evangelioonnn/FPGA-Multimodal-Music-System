// GW2A-18C 27MHz -> 371.25MHz rPLL -> dedicated /5 -> 74.25MHz.
module p20_video_clocks(input wire clk27,reset,
    output wire pixel_clk,serial_clk,locked,output reg serializer_reset=1);
    wire unused_div,pll_serial;
    TMDS_rPLL pll(pll_serial,locked,unused_div,reset,clk27);
    reg [5:0] guard=0;
    reg enable_clocks=0;
    // Release OSER reset while BOTH serializer clocks are stationary.
    // At27MHz, guards are593ns before reset release and another593ns
    // before clock enable, much longer than routing/gate latency.
    always @(posedge clk27 or negedge locked)begin
        if(!locked)begin guard<=0;enable_clocks<=0;serializer_reset<=1;end
        else if(reset)begin guard<=0;enable_clocks<=0;serializer_reset<=1;end
        else if(!enable_clocks)begin
            guard<=guard+1'b1;
            if(guard==15)serializer_reset<=0;
            if(guard==31)enable_clocks<=1;
        end
    end
    // GW2A DHCEN uses active-low CE. Its built-in enable pipeline is used.
    DHCEN serial_gate(.CLKOUT(serial_clk),.CLKIN(pll_serial),.CE(!enable_clocks));
    CLKDIV #(.DIV_MODE("5")) pixel_div(
        .CLKOUT(pixel_clk),.HCLKIN(serial_clk),.RESETN(locked && enable_clocks),.CALIB(1'b0));
endmodule
