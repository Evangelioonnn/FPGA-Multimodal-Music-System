// Same 720p60 clock/raster as board-qualified C01, with blank-start for bank commit.
module p20_preview_timing(input wire clk,rst,output reg [10:0] x,y,
    output reg de,hs,vs,blank_start);
    reg [10:0] h;
    reg [9:0] v;
    always @(posedge clk)begin
        if(rst)begin h<=0;v<=0;x<=0;y<=0;de<=0;hs<=0;vs<=0;blank_start<=0;end
        else begin
            if(h==1649)begin h<=0;if(v==749)v<=0;else v<=v+1'b1;end else h<=h+1'b1;
            x<=h;y<={1'b0,v};de<=h<1280 && v<720;
            hs<=h>=1390 && h<1430;vs<=v>=725 && v<730;blank_start<=h==0 && v==720;
        end
    end
endmodule
