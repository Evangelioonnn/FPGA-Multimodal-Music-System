// GW2A-specific input alignment. D11 PCLK uses a fabric-to-clock route on this Dock.
// Ten identical I/O delay elements fix the provisional minimum-delay budget;
// one common register stage keeps byte data, HREF and VSYNC aligned.
module p20_camera_input(input wire pclk,rst,vsync,href,input wire [7:0] data,
    output wire out_vsync,out_href,output wire [7:0] out_data);
    wire [9:0] pins={vsync,href,data};
    wire [9:0] aligned;
    genvar i;
    generate for(i=0;i<10;i=i+1)begin: input_alignment
        IODELAY #(.C_STATIC_DLY(127)) delay_pin(.DI(pins[i]),.DO(aligned[i]),.DF(),
            .SDTAP(1'b0),.VALUE(1'b0),.SETN(1'b1));
    end endgenerate
    reg [9:0] sampled;
    always @(posedge pclk)if(rst)sampled<=0;else sampled<=aligned;
    assign {out_vsync,out_href,out_data}=sampled;
endmodule
