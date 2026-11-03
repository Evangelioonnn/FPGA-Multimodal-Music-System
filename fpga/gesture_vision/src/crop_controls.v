// Local video-domain button synchronizers. Release must debounce before arming.
// Busy presses are consumed, not queued. S0 size; S2 position. S1 capture is separate.
module p20_crop_button #(parameter DEBOUNCE=742500)(
    input wire clk,rst,button_n,locked,output reg pulse);
    (* ASYNC_REG="TRUE" *) reg q1,q2;
    reg stable,armed;reg [31:0] count;
    always @(posedge clk)begin
        if(rst)begin q1<=1;q2<=1;stable<=1;armed<=0;count<=0;pulse<=0;end
        else begin
            q1<=button_n;q2<=q1;pulse<=0;
            if(q2!=stable)begin
                if(count==DEBOUNCE-1)begin
                    stable<=q2;count<=0;
                    if(q2)armed<=1;
                    else begin if(armed && !locked)pulse<=1;armed<=0;end
                end else count<=count+1'b1;
            end else if(stable && !armed)begin
                if(count==DEBOUNCE-1)begin armed<=1;count<=0;end else count<=count+1'b1;
            end else count<=0;
        end
    end
endmodule

module p20_crop_controls #(parameter DEBOUNCE=742500)(
    input wire clk,rst,size_n,position_n,locked,
    output reg [8:0] roi_x,output reg [7:0] roi_y,output reg [8:0] roi_side);
    wire resize,reposition;
    p20_crop_button #(.DEBOUNCE(DEBOUNCE)) size_key(clk,rst,size_n,locked,resize);
    p20_crop_button #(.DEBOUNCE(DEBOUNCE)) position_key(clk,rst,position_n,locked,reposition);
    reg [2:0] size_index,position_index;
    wire [3:0] next_size={1'b0,size_index}+4'd1,next_position={1'b0,position_index}+4'd1;
    integer xx,yy,side;
    always @(posedge clk)begin
        if(rst)begin size_index<=2;position_index<=0;end
        else if(!locked)begin
            if(resize)size_index<=size_index==3'd4 ? 3'd0:next_size[2:0];
            if(reposition)position_index<=position_index==3'd4 ? 3'd0:next_position[2:0];
        end
    end
    always @* begin
        case(size_index)0:side=96;1:side=128;2:side=160;3:side=192;default:side=240;endcase
        xx=(320-side)/2;yy=(240-side)/2;
        case(position_index)1:xx=xx-32;2:xx=xx+32;3:yy=yy-32;4:yy=yy+32;default:begin end endcase
        if(xx<0)xx=0;if(xx>320-side)xx=320-side;
        if(yy<0)yy=0;if(yy>240-side)yy=240-side;
        roi_x=xx[8:0];roi_y=yy[7:0];roi_side=side[8:0];
    end
endmodule
