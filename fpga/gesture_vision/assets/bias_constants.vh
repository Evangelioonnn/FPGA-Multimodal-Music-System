function signed [31:0] p20_bias;
input [4:0] index;
begin case(index)
5'd0:p20_bias=32'hfffff72a;
5'd1:p20_bias=32'h00000848;
5'd2:p20_bias=32'hfffffd55;
5'd3:p20_bias=32'hfffff79f;
5'd4:p20_bias=32'hfffffe9c;
5'd5:p20_bias=32'h000001c3;
5'd6:p20_bias=32'hfffffdc2;
5'd7:p20_bias=32'hfffffa75;
5'd8:p20_bias=32'h00000001;
5'd9:p20_bias=32'hfffffe66;
5'd10:p20_bias=32'h000013cf;
5'd11:p20_bias=32'h00000463;
5'd12:p20_bias=32'h00001465;
5'd13:p20_bias=32'hfffffaea;
5'd14:p20_bias=32'h00000fa9;
5'd15:p20_bias=32'hfffff548;
5'd16:p20_bias=32'h00000060;
5'd17:p20_bias=32'hffffffa0;
5'd18:p20_bias=32'h000000ab;
5'd19:p20_bias=32'hffffff55;
default:p20_bias=32'd0;
endcase end
endfunction
