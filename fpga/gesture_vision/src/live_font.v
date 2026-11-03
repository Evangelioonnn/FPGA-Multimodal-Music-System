// Preserve the baseline glyphs; add the signed-positive diagnostic glyph.
module p20_crop_live_font(input wire [7:0] ascii,input wire [2:0] row,col,
    output wire dot,output wire [4:0] row_bits);
    wire [4:0] original;
    camera_preview_font base(ascii,row,col,,original);
    assign row_bits=ascii==8'h2b ? (row==3 ? 5'b11111:(row==2 || row==4) ? 5'b00100:5'd0):original;
    assign dot=col<5 ? row_bits[4-col]:1'b0;
endmodule
