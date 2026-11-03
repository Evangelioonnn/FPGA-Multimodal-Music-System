// Fixed board-validated 150 MHz / 2200 / 1125 = 60.606 Hz.
// Coordinates are don't-care outside DE; removing blanking-coordinate muxes
// avoids a long timing-counter -> subtract -> enable -> renderer path.
module av_timing(input wire clk,rst,
    output reg [10:0] x,y,output reg de,hs,vs,frame_start);
    reg [11:0] h=0;
    reg [10:0] v=0;
    always @(posedge clk) begin
        if(rst) begin h<=0;v<=0;x<=0;y<=0;de<=0;hs<=0;vs<=0;frame_start<=0;end
        else begin
            if(h==2199) begin h<=0;if(v==1124)v<=0;else v<=v+1'b1;end
            else h<=h+1'b1;
            x<=h-12'd192;y<=v-11'd41;
            hs<=h<44;vs<=v<5;
            de<=h>=192 && h<2112 && v>=41 && v<1121;
            frame_start<=h==0 && v==0;
        end
    end
endmodule
