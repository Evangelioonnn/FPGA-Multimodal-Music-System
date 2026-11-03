// Inference owns RGB32 reads during loading; capture reads only after completion.
module p20_crop_live_cache #(
    parameter PN=19200,MN=4096,ADDR_BITS=15
)(input wire clk,rst,enabled,slot,loading,
    input wire [14:0] render_address,input wire [11:0] render_model_address,
    input wire [9:0] inference_address,input wire [ADDR_BITS-1:0] uart_address,
    output wire [14:0] preview_address,output wire [11:0] model_address,
    output wire [9:0] color_address,input wire [7:0] preview_data,model_data,
    input wire [15:0] color_data,output reg [7:0] uart_data,output wire uart_valid);
    reg [2:0] state;reg [ADDR_BITS-1:0] held,cached_address;reg cached;
    wire [31:0] mo=held-PN,co=held-PN-MN;
    assign preview_address=state!=0 && held<PN ? held:render_address;
    assign model_address=state!=0 && held>=PN && held<PN+MN ? mo[11:0]:render_model_address;
    assign color_address=loading ? inference_address:co[10:1];
    assign uart_valid=enabled && !loading && cached && cached_address==uart_address;
    always @(posedge clk)begin
        if(rst || !enabled || loading)begin state<=0;cached<=0;held<=0;cached_address<=0;uart_data<=0;end
        else case(state)
            0:if(slot && !uart_valid)begin held<=uart_address;state<=1;end
            1:state<=2;2:state<=3;3:state<=4;
            4:begin
                uart_data<=held<PN ? preview_data:held<PN+MN ? model_data:held[0] ? color_data[7:0]:color_data[15:8];
                cached_address<=held;cached<=1;state<=0;
            end
            default:state<=0;
        endcase
    end
endmodule
