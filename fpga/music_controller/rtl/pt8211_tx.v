// Extracted from the verified audio_probe transport. PT8211 is LSBJ, not I2S.
module pt8211_tx (
    input wire clk, rst,
    input wire signed [15:0] sample_left, sample_right,
    output wire sample_ce,
    output reg hp_bck = 0,
    output reg hp_ws = 0,
    output reg hp_din = 0
);
    reg [4:0] bck_div = 0;
    reg [5:0] bit_count = 0;
    reg [15:0] left_hold = 0, right_hold = 0;
    // Predecode the next counter value. CE occurs on the original edge;
    // reset and the counter decode no longer feed the whole render/record chain.
    reg sample_ce_q=0;
    assign sample_ce=sample_ce_q;
    always @(posedge clk)begin
        if(rst)sample_ce_q<=0;
        else sample_ce_q<=bck_div==11 && hp_bck && bit_count==39;
    end
    always @(posedge clk) begin
        if (rst) begin
            bck_div <= 0;
            bit_count <= 0;
            hp_bck <= 0;
            hp_ws <= 0;
            hp_din <= 0;
            left_hold <= 0;
            right_hold <= 0;
        end else if (bck_div == 12) begin
            bck_div <= 0;
            hp_bck <= ~hp_bck;
            if (hp_bck) begin
                if (bit_count == 19) begin
                    hp_ws <= 1;
                    bit_count <= 20;
                    hp_din <= 0;
                end else if (bit_count == 39) begin
                    hp_ws <= 0;
                    bit_count <= 0;
                    hp_din <= 0;
                    left_hold <= sample_left;
                    right_hold <= sample_right;
                end else if (bit_count >= 3 && bit_count <= 18) begin
                    bit_count <= bit_count + 1'b1;
                    hp_din <= right_hold[18 - bit_count];
                end else if (bit_count >= 23 && bit_count <= 38) begin
                    bit_count <= bit_count + 1'b1;
                    hp_din <= left_hold[38 - bit_count];
                end else begin
                    bit_count <= bit_count + 1'b1;
                    hp_din <= 0;
                end
            end
        end else bck_div <= bck_div + 1'b1;
    end
endmodule
