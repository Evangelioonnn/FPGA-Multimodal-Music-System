// Sample-domain triangle LFO, pitch ratio in unsigned Q16.
module vibrato_factor(
    input wire clk, rst, sample_ce,
    input wire enable,
    input wire [7:0] depth,
    input wire [2:0] speed_index,
    output reg [16:0] factor_q16,
    output reg [6:0] depth_applied
);
    reg [23:0] phase;
    reg [11:0] phase_increment;
    wire [6:0] depth_target = !enable ? 7'd0 : (depth > 64 ? 7'd64 : depth[6:0]);
    wire signed [9:0] triangle = phase[23] ?
        10'sd383 - $signed({1'b0,phase[23:15]}) :
        $signed({1'b0,phase[23:15]}) - 10'sd128;
    wire signed [17:0] modulation_product = triangle * $signed({1'b0,depth_applied});
    wire[23:0]phase_next=phase+phase_increment;
    wire[6:0]depth_next=depth_applied<depth_target ? depth_applied+1'b1 :
     depth_applied>depth_target ? depth_applied-1'b1 : depth_applied;
    wire signed[9:0]triangle_next=phase_next[23] ?
     10'sd383-$signed({1'b0,phase_next[23:15]}) :
     $signed({1'b0,phase_next[23:15]})-10'sd128;
    wire signed[17:0]product_next=triangle_next*$signed({1'b0,depth_next});
    reg signed[17:0]product_q;
    // product_q tracks the CURRENT phase/depth without waiting an extra
    // sample; prepare it on the edge that updates those same registers.
    always @(posedge clk)if(rst)product_q<=0;else if(sample_ce)product_q<=product_next;
    wire signed [18:0] target_factor = 19'sd65536 + (product_q >>> 2);
    wire signed [18:0] factor_current = $signed({2'b00,factor_q16});
    always @* begin
        case(speed_index)
            0: phase_increment = 12'd698;
            1: phase_increment = 12'd1047;
            2: phase_increment = 12'd1396;
            3: phase_increment = 12'd1745;
            4: phase_increment = 12'd2094;
            5: phase_increment = 12'd2443;
            6: phase_increment = 12'd2792;
            default: phase_increment = 12'd3141;
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin
            phase <= 0;
            depth_applied <= 0;
            factor_q16 <= 17'd65536;
        end else if(sample_ce) begin
            phase <= phase_next;
            depth_applied <= depth_next;
            if(target_factor > factor_current + 19'sd16) factor_q16 <= factor_q16 + 17'd16;
            else if(target_factor < factor_current - 19'sd16) factor_q16 <= factor_q16 - 17'd16;
            else factor_q16 <= target_factor[16:0];
        end
    end
endmodule
