// Coherent five-channel fader snapshot service.
// CH0 is post-mix volume; CH1..CH4 are Q8 harmonic amplitudes.
module custom_harmonic_params (
    input wire clk,
    input wire rst,
    input wire sample_ce,
    input wire adc_valid,
    input wire [11:0] adc_ch0,
    input wire [11:0] adc_ch1,
    input wire [11:0] adc_ch2,
    input wire [11:0] adc_ch3,
    input wire [11:0] adc_ch4,
    output reg [15:0] volume_gain,
    output reg [8:0] coeff0,
    output reg [8:0] coeff1,
    output reg [8:0] coeff2,
    output reg [8:0] coeff3,
    output reg [15:0] volume_target,
    output reg [8:0] coeff0_target,
    output reg [8:0] coeff1_target,
    output reg [8:0] coeff2_target,
    output reg [8:0] coeff3_target,
    output reg params_updated,
    output reg params_busy,
    output reg adc_overrun
);
    localparam [10:0] COEFF_SUM_LIMIT = 11'd368;
    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] LOAD_DIVIDEND = 2'd1;
    localparam [1:0] DIVIDE = 2'd2;

    reg [1:0] state;
    reg [8:0] pending0, pending1, pending2, pending3;
    reg [8:0] normalized0, normalized1, normalized2;
    reg [10:0] denominator;
    reg [16:0] dividend, quotient;
    reg [11:0] remainder;
    reg [4:0] bit_count;
    reg [1:0] channel_index;
    reg [15:0] pending_volume;

    wire [8:0] scan0 = {1'b0, adc_ch1[11:4]} + adc_ch1[3];
    wire [8:0] scan1 = {1'b0, adc_ch2[11:4]} + adc_ch2[3];
    wire [8:0] scan2 = {1'b0, adc_ch3[11:4]} + adc_ch3[3];
    wire [8:0] scan3 = {1'b0, adc_ch4[11:4]} + adc_ch4[3];
    wire [10:0] scan_sum = {2'b0, scan0} + {2'b0, scan1} +
                           {2'b0, scan2} + {2'b0, scan3};
    wire [15:0] scan_volume = {adc_ch0, 4'b0000} +
                              {12'b0, adc_ch0[11:8]};

    wire [11:0] trial_remainder = {remainder[10:0], dividend[16]};
    wire divide_subtract = trial_remainder >= {1'b0, denominator};
    wire [11:0] next_remainder = divide_subtract ?
        trial_remainder - {1'b0, denominator} : trial_remainder;
    wire [16:0] next_quotient = {quotient[15:0], divide_subtract};

    reg [2:0] slew_state;
    reg [8:0] base0,base1,base2,base3;
    reg [8:0] target0,target1,target2,target3;
    reg [3:0] remaining;
    reg [8:0] next_coeff0,next_coeff1,next_coeff2,next_coeff3;
    reg next_coeff_valid;
    wire [8:0] down0_snap = target0 < base0 ?
        ((base0-target0)>9'd2 ? base0-9'd2 : target0) : base0;
    wire [8:0] down1_snap = target1 < base1 ?
        ((base1-target1)>9'd2 ? base1-9'd2 : target1) : base1;
    wire [8:0] down2_snap = target2 < base2 ?
        ((base2-target2)>9'd2 ? base2-9'd2 : target2) : base2;
    wire [8:0] down3_snap = target3 < base3 ?
        ((base3-target3)>9'd2 ? base3-9'd2 : target3) : base3;
    wire [1:0] req0_snap = target0 > base0 ?
        ((target0-base0)>9'd2 ? 2'd2 : target0-base0) : 2'd0;
    wire [1:0] req1_snap = target1 > base1 ?
        ((target1-base1)>9'd2 ? 2'd2 : target1-base1) : 2'd0;
    wire [1:0] req2_snap = target2 > base2 ?
        ((target2-base2)>9'd2 ? 2'd2 : target2-base2) : 2'd0;
    wire [1:0] req3_snap = target3 > base3 ?
        ((target3-base3)>9'd2 ? 2'd2 : target3-base3) : 2'd0;
    wire [10:0] down_sum_snap = {2'b0,down0_snap}+{2'b0,down1_snap}+
                                {2'b0,down2_snap}+{2'b0,down3_snap};
    wire [3:0] initial_room = down_sum_snap >= COEFF_SUM_LIMIT ? 4'd0 :
                              (COEFF_SUM_LIMIT-down_sum_snap >= 11'd8 ?
                               4'd8 : (COEFF_SUM_LIMIT-down_sum_snap));
    wire [1:0] grant0_seq = remaining < req0_snap ? remaining[1:0] : req0_snap;
    wire [1:0] grant1_seq = remaining < req1_snap ? remaining[1:0] : req1_snap;
    wire [1:0] grant2_seq = remaining < req2_snap ? remaining[1:0] : req2_snap;
    wire [1:0] grant3_seq = remaining < req3_snap ? remaining[1:0] : req3_snap;

    function [16:0] scale_by_limit;
        input [8:0] value;
        begin
            // 368 = 256 + 64 + 32 + 16; one shared constant-multiply path.
            scale_by_limit = {value, 8'b0} + {value, 6'b0} +
                             {value, 5'b0} + {value, 4'b0};
        end
    endfunction

    function [8:0] selected_pending;
        input [1:0] index;
        begin
            case (index)
                2'd0: selected_pending = pending0;
                2'd1: selected_pending = pending1;
                2'd2: selected_pending = pending2;
                default: selected_pending = pending3;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            volume_gain <= 16'hffff;
            coeff0 <= 9'd256;
            coeff1 <= 9'd64;
            coeff2 <= 9'd32;
            coeff3 <= 9'd16;
            volume_target <= 16'hffff;
            coeff0_target <= 9'd256;
            coeff1_target <= 9'd64;
            coeff2_target <= 9'd32;
            coeff3_target <= 9'd16;
            params_updated <= 1'b0;
            params_busy <= 1'b0;
            adc_overrun <= 1'b0;
            state <= IDLE;
            pending0 <= 0;
            pending1 <= 0;
            pending2 <= 0;
            pending3 <= 0;
            normalized0 <= 0;
            normalized1 <= 0;
            normalized2 <= 0;
            denominator <= 0;
            dividend <= 0;
            quotient <= 0;
            remainder <= 0;
            bit_count <= 0;
            channel_index <= 0;
            pending_volume <= 0;
            slew_state <= 0;
            base0 <= 9'd256; base1 <= 9'd64; base2 <= 9'd32; base3 <= 9'd16;
            target0 <= 9'd256; target1 <= 9'd64; target2 <= 9'd32; target3 <= 9'd16;
            remaining <= 0;
            next_coeff0 <= 9'd256; next_coeff1 <= 9'd64;
            next_coeff2 <= 9'd32; next_coeff3 <= 9'd16;
            next_coeff_valid <= 0;
        end else begin
            params_updated <= 1'b0;

            if (sample_ce) begin
                if (next_coeff_valid) begin
                    coeff0 <= next_coeff0;
                    coeff1 <= next_coeff1;
                    coeff2 <= next_coeff2;
                    coeff3 <= next_coeff3;
                    next_coeff_valid <= 1'b0;
                end
                if (slew_state==0) begin
                    base0 <= next_coeff_valid ? next_coeff0 : coeff0;
                    base1 <= next_coeff_valid ? next_coeff1 : coeff1;
                    base2 <= next_coeff_valid ? next_coeff2 : coeff2;
                    base3 <= next_coeff_valid ? next_coeff3 : coeff3;
                    target0 <= coeff0_target;
                    target1 <= coeff1_target;
                    target2 <= coeff2_target;
                    target3 <= coeff3_target;
                    slew_state <= 1;
                end
            end

            case (slew_state)
                3'd1: begin
                    remaining <= initial_room;
                    next_coeff0 <= down0_snap;
                    next_coeff1 <= down1_snap;
                    next_coeff2 <= down2_snap;
                    next_coeff3 <= down3_snap;
                    slew_state <= 2;
                end
                3'd2: begin
                    next_coeff0 <= down0_snap + {7'b0,grant0_seq};
                    remaining <= remaining - {2'b0,grant0_seq};
                    slew_state <= 3;
                end
                3'd3: begin
                    next_coeff1 <= down1_snap + {7'b0,grant1_seq};
                    remaining <= remaining - {2'b0,grant1_seq};
                    slew_state <= 4;
                end
                3'd4: begin
                    next_coeff2 <= down2_snap + {7'b0,grant2_seq};
                    remaining <= remaining - {2'b0,grant2_seq};
                    slew_state <= 5;
                end
                3'd5: begin
                    next_coeff3 <= down3_snap + {7'b0,grant3_seq};
                    next_coeff_valid <= 1'b1;
                    slew_state <= 0;
                end
                default: begin end
            endcase

            if (sample_ce) begin
                if (volume_gain < volume_target) begin
                    if ((volume_target - volume_gain) > 16'd1024)
                        volume_gain <= volume_gain + 16'd1024;
                    else
                        volume_gain <= volume_target;
                end else if (volume_gain > volume_target) begin
                    if ((volume_gain - volume_target) > 16'd1024)
                        volume_gain <= volume_gain - 16'd1024;
                    else
                        volume_gain <= volume_target;
                end

            end

            if (adc_valid && params_busy)
                adc_overrun <= 1'b1;

            if (adc_valid && !params_busy) begin
                pending_volume <= scan_volume;
                if (scan_sum <= COEFF_SUM_LIMIT) begin
                    volume_target <= scan_volume;
                    coeff0_target <= scan0;
                    coeff1_target <= scan1;
                    coeff2_target <= scan2;
                    coeff3_target <= scan3;
                    params_updated <= 1'b1;
                end else begin
                    pending0 <= scan0;
                    pending1 <= scan1;
                    pending2 <= scan2;
                    pending3 <= scan3;
                    denominator <= scan_sum;
                    channel_index <= 2'd0;
                    params_busy <= 1'b1;
                    state <= LOAD_DIVIDEND;
                end
            end

            if (params_busy) begin
                case (state)
                    LOAD_DIVIDEND: begin
                        dividend <= scale_by_limit(selected_pending(channel_index));
                        quotient <= 0;
                        remainder <= 0;
                        bit_count <= 5'd17;
                        state <= DIVIDE;
                    end
                    DIVIDE: begin
                        dividend <= {dividend[15:0], 1'b0};
                        remainder <= next_remainder;
                        quotient <= next_quotient;
                        if (bit_count == 1) begin
                            case (channel_index)
                                2'd0: normalized0 <= next_quotient[8:0];
                                2'd1: normalized1 <= next_quotient[8:0];
                                2'd2: normalized2 <= next_quotient[8:0];
                                default: begin
                                    volume_target <= pending_volume;
                                    coeff0_target <= normalized0;
                                    coeff1_target <= normalized1;
                                    coeff2_target <= normalized2;
                                    coeff3_target <= next_quotient[8:0];
                                    params_updated <= 1'b1;
                                    params_busy <= 1'b0;
                                    state <= IDLE;
                                end
                            endcase
                            if (channel_index != 2'd3) begin
                                channel_index <= channel_index + 1'b1;
                                state <= LOAD_DIVIDEND;
                            end
                        end else begin
                            bit_count <= bit_count - 1'b1;
                        end
                    end
                    default: begin
                        state <= LOAD_DIVIDEND;
                    end
                endcase
            end
        end
    end
endmodule
