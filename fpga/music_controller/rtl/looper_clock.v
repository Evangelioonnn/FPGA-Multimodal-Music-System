module looper_clock #(
    parameter CLK_HZ = 50000000,
    parameter FRAME_CLOCKS = 1040,
    parameter PPQN = 96
)(
    input wire clk,
    input wire rst,
    input wire sample_ce,
    input wire run,
    input wire restart,
    input wire [7:0] bpm,
    input wire [2:0] beats_per_bar,
    output reg tick_pulse,
    output reg beat_pulse,
    output reg bar_pulse,
    output reg [6:0] tick_in_beat,
    output reg [2:0] beat_in_bar,
    output wire [7:0] applied_bpm,output wire [2:0] applied_meter,
    output reg [31:0] frame_index
);
    localparam [63:0] DENOMINATOR = CLK_HZ * 60;
    localparam [63:0] STEP_SCALE = PPQN * FRAME_CLOCKS;
    reg [31:0] phase;
    wire [7:0] safe_bpm = bpm < 40 ? 8'd40 : bpm > 240 ? 8'd240 : bpm;
    wire [2:0] safe_beats = beats_per_bar>=2 && beats_per_bar<=4 ? beats_per_bar : 3'd4;
    reg run_prev;
    reg [7:0] active_bpm;reg [2:0] active_meter;
    assign applied_bpm=active_bpm;assign applied_meter=active_meter;
    reg [24:0] step_value;
    wire [32:0] phase_sum = {1'b0, phase} + {8'd0,step_value};

    always @(posedge clk) begin
        if (rst) begin
            phase <= 0;
            tick_pulse <= 0;
            beat_pulse <= 0;
            bar_pulse <= 0;
            tick_in_beat <= 0;
            beat_in_bar <= 0;
            frame_index <= 0;
            run_prev <= 0; active_meter<=4;active_bpm <= 120; step_value <= 120*STEP_SCALE;
        end else begin
            tick_pulse <= 0;
            beat_pulse <= 0;
            bar_pulse <= 0;
            run_prev <= run;
            step_value <= active_bpm * STEP_SCALE;
            if (!run || restart === 1'b1 || (run && !run_prev)) active_bpm <= safe_bpm;
            else if (beat_pulse) active_bpm <= safe_bpm;
            if(!run || restart === 1'b1 || (run && !run_prev) || bar_pulse) active_meter<=safe_beats;
            if (run && (!run_prev || restart === 1'b1)) begin
                phase <= 0;tick_in_beat<=0;beat_in_bar<=0;step_value<=safe_bpm*STEP_SCALE;
                beat_pulse<=1;
            end
            if (sample_ce) begin
                frame_index <= frame_index + 1'b1;
                if (run && run_prev && !(restart === 1'b1)) begin
                    if (phase_sum >= DENOMINATOR) begin
                        phase <= phase_sum - DENOMINATOR;
                        tick_pulse <= 1;
                        if (tick_in_beat == PPQN - 1) begin
                            tick_in_beat <= 0;
                            beat_pulse <= 1;
                            if (beat_in_bar + 1'b1 >= active_meter) begin
                                beat_in_bar <= 0;
                                bar_pulse <= 1;
                            end else begin
                                beat_in_bar <= beat_in_bar + 1'b1;
                            end
                        end else begin
                            tick_in_beat <= tick_in_beat + 1'b1;
                        end
                    end else begin
                        phase <= phase_sum[31:0];
                    end
                end
            end
        end
    end
endmodule
