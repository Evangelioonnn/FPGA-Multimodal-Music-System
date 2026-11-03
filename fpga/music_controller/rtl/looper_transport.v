module looper_transport #(
    parameter PPQN = 96,
    parameter MAX_BARS = 4
)(
    input wire clk,
    input wire rst,
    input wire tick_pulse,
    input wire beat_pulse,
    input wire bar_pulse,
    input wire [6:0] tick_in_beat,
    input wire [2:0] beat_in_bar,
    input wire start_req,
    input wire stop_req,
    input wire record_req,
    input wire [2:0] beats_per_bar,
    input wire [2:0] loop_bars,
    input wire metronome_enable,
    output reg transport_run,
    output reg count_in,
    output reg playing,
    output reg recording,
    output reg record_armed,
    output reg record_start_pulse,
    output reg record_done_pulse,
    output reg loop_wrap_pulse,
    output reg stop_pulse,
    output reg metronome_click,
    output reg metronome_accent,
    output reg [11:0] loop_tick,
    output reg [31:0] loop_number
);
    localparam [11:0] MAX_LOOP_TICKS = PPQN * 7 * MAX_BARS;
    reg pending_first_record;
    reg first_pass_record;
    reg [2:0] active_beats_per_bar;
    reg [2:0] active_loop_bars;
    reg [12:0] active_last_tick;
    function [12:0] last_tick;input [2:0] beats,bars;begin case({beats,bars})
        6'd0:last_tick=PPQN*4*1-1;
        6'd1:last_tick=PPQN*4*1-1;
        6'd2:last_tick=PPQN*4*2-1;
        6'd3:last_tick=PPQN*4*3-1;
        6'd4:last_tick=PPQN*4*4-1;
        6'd5:last_tick=PPQN*4*5-1;
        6'd6:last_tick=PPQN*4*6-1;
        6'd7:last_tick=PPQN*4*7-1;
        6'd8:last_tick=PPQN*1*1-1;
        6'd9:last_tick=PPQN*1*1-1;
        6'd10:last_tick=PPQN*1*2-1;
        6'd11:last_tick=PPQN*1*3-1;
        6'd12:last_tick=PPQN*1*4-1;
        6'd13:last_tick=PPQN*1*5-1;
        6'd14:last_tick=PPQN*1*6-1;
        6'd15:last_tick=PPQN*1*7-1;
        6'd16:last_tick=PPQN*2*1-1;
        6'd17:last_tick=PPQN*2*1-1;
        6'd18:last_tick=PPQN*2*2-1;
        6'd19:last_tick=PPQN*2*3-1;
        6'd20:last_tick=PPQN*2*4-1;
        6'd21:last_tick=PPQN*2*5-1;
        6'd22:last_tick=PPQN*2*6-1;
        6'd23:last_tick=PPQN*2*7-1;
        6'd24:last_tick=PPQN*3*1-1;
        6'd25:last_tick=PPQN*3*1-1;
        6'd26:last_tick=PPQN*3*2-1;
        6'd27:last_tick=PPQN*3*3-1;
        6'd28:last_tick=PPQN*3*4-1;
        6'd29:last_tick=PPQN*3*5-1;
        6'd30:last_tick=PPQN*3*6-1;
        6'd31:last_tick=PPQN*3*7-1;
        6'd32:last_tick=PPQN*4*1-1;
        6'd33:last_tick=PPQN*4*1-1;
        6'd34:last_tick=PPQN*4*2-1;
        6'd35:last_tick=PPQN*4*3-1;
        6'd36:last_tick=PPQN*4*4-1;
        6'd37:last_tick=PPQN*4*5-1;
        6'd38:last_tick=PPQN*4*6-1;
        6'd39:last_tick=PPQN*4*7-1;
        6'd40:last_tick=PPQN*5*1-1;
        6'd41:last_tick=PPQN*5*1-1;
        6'd42:last_tick=PPQN*5*2-1;
        6'd43:last_tick=PPQN*5*3-1;
        6'd44:last_tick=PPQN*5*4-1;
        6'd45:last_tick=PPQN*5*5-1;
        6'd46:last_tick=PPQN*5*6-1;
        6'd47:last_tick=PPQN*5*7-1;
        6'd48:last_tick=PPQN*6*1-1;
        6'd49:last_tick=PPQN*6*1-1;
        6'd50:last_tick=PPQN*6*2-1;
        6'd51:last_tick=PPQN*6*3-1;
        6'd52:last_tick=PPQN*6*4-1;
        6'd53:last_tick=PPQN*6*5-1;
        6'd54:last_tick=PPQN*6*6-1;
        6'd55:last_tick=PPQN*6*7-1;
        6'd56:last_tick=PPQN*7*1-1;
        6'd57:last_tick=PPQN*7*1-1;
        6'd58:last_tick=PPQN*7*2-1;
        6'd59:last_tick=PPQN*7*3-1;
        6'd60:last_tick=PPQN*7*4-1;
        6'd61:last_tick=PPQN*7*5-1;
        6'd62:last_tick=PPQN*7*6-1;
        6'd63:last_tick=PPQN*7*7-1;
        default:last_tick=PPQN*4-1;
    endcase end endfunction

    always @(posedge clk) begin
        if (rst) begin
            transport_run <= 0;
            count_in <= 0;
            playing <= 0;
            recording <= 0;
            record_armed <= 0;
            record_start_pulse <= 0;
            record_done_pulse <= 0;
            loop_wrap_pulse <= 0;
            stop_pulse <= 0;
            metronome_click <= 0;
            metronome_accent <= 0;
            loop_tick <= 0;
            loop_number <= 0;
            pending_first_record <= 0;
            first_pass_record <= 0;
            active_beats_per_bar <= 4;
            active_loop_bars <= 1;active_last_tick<=PPQN*4-1;
        end else begin
            record_start_pulse <= 0;
            record_done_pulse <= 0;
            loop_wrap_pulse <= 0;
            stop_pulse <= 0;
            metronome_click <= 0;
            metronome_accent <= 0;

            if (stop_req && transport_run) begin
                transport_run <= 0;
                count_in <= 0;
                playing <= 0;
                recording <= 0;
                record_armed <= 0;
                pending_first_record <= 0;
                first_pass_record <= 0;
                loop_tick <= 0;
                stop_pulse <= 1;
            end else begin
                if (start_req && !transport_run) begin
                    transport_run <= 1;
                    count_in <= 1;
                    playing <= 0;
                    recording <= 0;
                    record_armed <= 0;
                    pending_first_record <= record_req;
                    first_pass_record <= record_req;
                    loop_tick <= 0;
                    loop_number <= 0;
                    active_beats_per_bar <= beats_per_bar == 0 ? 3'd4 : beats_per_bar;
                    active_loop_bars <= loop_bars == 0 ? 3'd1 : loop_bars;
                    active_last_tick<=last_tick(beats_per_bar,loop_bars);
                end

                if (transport_run && metronome_enable && beat_pulse) begin
                    metronome_click <= 1;
                    metronome_accent <= beat_in_bar == 0;
                end

                if (transport_run && count_in && bar_pulse) begin
                    count_in <= 0;
                    playing <= 1;
                    loop_tick <= 0;
                    if (pending_first_record) begin
                        recording <= 1;
                        record_start_pulse <= 1;
                        pending_first_record <= 0;
                    end
                end else if (transport_run && playing && tick_pulse) begin
                    if ({1'b0,loop_tick}>=active_last_tick) begin
                        loop_tick <= 0;
                        loop_wrap_pulse <= 1;
                        loop_number <= loop_number + 1'b1;
                        if (record_armed) begin
                            recording <= 1;
                            record_armed <= 0;
                            record_start_pulse <= 1;
                            first_pass_record <= 0;
                        end else if (recording) begin
                            recording <= 0;
                            record_done_pulse <= 1;
                            first_pass_record <= 0;
                        end
                    end else begin
                        loop_tick <= loop_tick + 1'b1;
                    end
                end

                if (transport_run && playing && record_req && !recording && !record_armed)
                    record_armed <= 1;
            end
        end
    end
endmodule
