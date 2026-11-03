// Original ROM exercise. Pure LED guidance, never feeds audio note events.
// sample_ce must describe CLK_HZ / SAMPLE_CYCLES; no approximate 48 kHz timebase.
module offline_song_guide #(
    parameter CLK_HZ = 50000000,
    parameter SAMPLE_CYCLES = 1040
)(
    input wire clk, rst, sample_ce,
    input wire start_pulse, pause_pulse, stop_pulse, loop_enable,
    input wire [7:0] bpm,
    input wire signed [5:0] transpose_semitones,
    output reg running, paused,
    output reg [4:0] step_index,
    output wire [24:0] current_keys, next_keys,
    output reg step_pulse, beat_pulse, done_pulse,
    output wire out_of_range,
    output reg [7:0] bpm_effective
);
    localparam [31:0] DENOMINATOR = CLK_HZ * 60;
    localparam [31:0] STEP_SCALE = SAMPLE_CYCLES * 4;
    reg [31:0] tempo_phase;
    reg [31:0] tempo_step;
    reg [3:0] ticks_in_step;
    reg [1:0] tick_in_beat;
    wire [7:0] safe_bpm = bpm < 40 ? 8'd40 : bpm > 240 ? 8'd240 : bpm;
    wire [32:0] phase_sum = {1'b0,tempo_phase} + {1'b0,tempo_step};
    wire visible = running || paused;
    wire [4:0] next_index = step_index == 23 ? 5'd0 : step_index + 1'b1;
    wire next_visible = visible && (step_index != 23 || loop_enable);

    function [24:0] song_keys;
        input [4:0] index;
        begin
            case(index)
                0: song_keys=25'h0000001; // C
                1: song_keys=25'h0000010; // E
                2: song_keys=25'h0000080; // G
                3: song_keys=25'h0001000; // C+
                4: song_keys=25'h0000080;
                5: song_keys=25'h0000010;
                6: song_keys=25'h0000004; // D
                7: song_keys=25'h0000020; // F
                8: song_keys=25'h0000200; // A
                9: song_keys=25'h0004000; // D+
               10: song_keys=25'h0000200;
               11: song_keys=25'h0000020;
               12: song_keys=25'h0000091; // C/E/G
               13: song_keys=25'h0000000; // rest
               14: song_keys=25'h0001220; // F/A/C+
               15: song_keys=25'h0000000;
               16: song_keys=25'h0004880; // G/B/D+
               17: song_keys=25'h0000000;
               18: song_keys=25'h0011080; // G/C+/E+
               19: song_keys=25'h0000000;
               20: song_keys=25'h0001000;
               21: song_keys=25'h0010000;
               22: song_keys=25'h0080000;
               23: song_keys=25'h1001001; // C/C+/C++
               default: song_keys=0;
            endcase
        end
    endfunction
    function [3:0] song_ticks;
        input [4:0] index;
        begin
            case(index)
                12,14,16,18,23: song_ticks=8;
                default: song_ticks=4;
            endcase
        end
    endfunction
    function [24:0] transpose;
        input [24:0] keys;
        input signed [5:0] semitones;
        reg [5:0] magnitude;
        begin
            magnitude=semitones[5] ? (~semitones+1'b1) : semitones;
            transpose=semitones[5] ? keys >> magnitude : keys << magnitude;
        end
    endfunction
    function range_lost;
        input [24:0] keys;
        input signed [5:0] semitones;
        reg [5:0] magnitude;
        reg [49:0] shifted;
        begin
            magnitude=semitones[5] ? (~semitones+1'b1) : semitones;
            shifted=0;
            if(magnitude>=25) range_lost=|keys;
            else if(semitones[5]) begin
                shifted={keys,25'd0} >> magnitude;
                range_lost=|shifted[24:0];
            end else begin
                shifted={25'd0,keys} << magnitude;
                range_lost=|shifted[49:25];
            end
        end
    endfunction
    wire [24:0] raw_current=song_keys(step_index),raw_next=song_keys(next_index);
    assign current_keys=visible ? transpose(raw_current,transpose_semitones) : 25'd0;
    assign next_keys=next_visible ? transpose(raw_next,transpose_semitones) : 25'd0;
    assign out_of_range=(visible && range_lost(raw_current,transpose_semitones)) ||
        (next_visible && range_lost(raw_next,transpose_semitones));

    always @(posedge clk) begin
        if(rst) begin
            running<=0;paused<=0;step_index<=0;tempo_phase<=0;tempo_step<=120*STEP_SCALE;
            ticks_in_step<=0;tick_in_beat<=0;bpm_effective<=120;
            step_pulse<=0;beat_pulse<=0;done_pulse<=0;
        end else begin
            step_pulse<=0;beat_pulse<=0;done_pulse<=0;
            if(stop_pulse) begin
                running<=0;paused<=0;step_index<=0;tempo_phase<=0;
                ticks_in_step<=0;tick_in_beat<=0;
            end else if(pause_pulse && running) begin
                running<=0;paused<=1;
            end else if(start_pulse && !running) begin
                running<=1;paused<=0;bpm_effective<=safe_bpm;tempo_step<=safe_bpm*STEP_SCALE;
                if(!paused) begin
                    step_index<=0;tempo_phase<=0;ticks_in_step<=0;tick_in_beat<=0;
                    step_pulse<=1;beat_pulse<=1;
                end
            end else if(sample_ce && running) begin
                if(phase_sum >= DENOMINATOR) begin
                    tempo_phase<=phase_sum-DENOMINATOR;
                    tick_in_beat<=tick_in_beat+1'b1;
                    if(tick_in_beat==3) begin
                        beat_pulse<=1;bpm_effective<=safe_bpm;tempo_step<=safe_bpm*STEP_SCALE;
                    end
                    if(ticks_in_step+1'b1 >= song_ticks(step_index)) begin
                        ticks_in_step<=0;step_pulse<=1;
                        if(step_index==23) begin
                            if(loop_enable) step_index<=0;
                            else begin running<=0;paused<=0;done_pulse<=1;end
                        end else step_index<=step_index+1'b1;
                    end else ticks_in_step<=ticks_in_step+1'b1;
                end else tempo_phase<=phase_sum[31:0];
            end
        end
    end
endmodule
