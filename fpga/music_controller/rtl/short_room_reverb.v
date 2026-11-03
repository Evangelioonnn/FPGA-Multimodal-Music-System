// Four bounded feedback combs share a single synchronous delay RAM.
module short_room_reverb #(parameter DATA_W=16, DAMPING=1, WET_SHIFT=6)(
    input wire clk, rst,
    input wire flush_tail,force_dry,
    input wire in_valid,
    input wire signed [DATA_W-1:0] in_sample,
    input wire fx_enable,
    input wire [8:0] wet_q8,
    output reg out_valid,
    output reg signed [DATA_W-1:0] out_left, out_right,
    output reg clip,
    output reg ready,
    output wire busy,
    output reg overrun,
    output reg [8:0] wet_applied
);
    // Four narrow2048-word banks fit the device's X9 modes without padding
    // an18-bit4096-word object to five4-bit physical banks. No bit is dropped.
    localparam LO_W=DATA_W/2,HI_W=DATA_W-LO_W;
    (* syn_ramstyle="block_ram" *)reg[LO_W-1:0]lo0[0:2047],lo1[0:2047];
    (* syn_ramstyle="block_ram" *)reg[HI_W-1:0]hi0[0:2047],hi1[0:2047];
    reg[LO_W-1:0]lq0,lq1;reg[HI_W-1:0]hq0,hq1;reg bank_q;
    reg [11:0] clear_address, ram_address;
    wire signed [DATA_W-1:0]ram_read=bank_q ? {hq1,lq1} : {hq0,lq0};
    reg signed [DATA_W-1:0] ram_write_data;
    reg ram_write;
    reg [5:0] state;
    reg [1:0] comb_index;
    reg [10:0] position [0:3];
    reg signed [DATA_W-1:0] delayed [0:3];
    reg signed [DATA_W-1:0] dry;
    reg signed [DATA_W-1:0] damped_history[0:3];
    reg frame_force_dry;
    reg [8:0] frame_wet;
    reg frame_bypass;
    reg signed [DATA_W+3:0] stereo_sum_left, stereo_sum_right;
    reg signed [DATA_W-1:0] wet_left, wet_right;
    reg signed [DATA_W+1:0] multiplier_a;
    reg signed [9:0] multiplier_b;
    reg signed [DATA_W+11:0] multiplier_result;
    reg signed [DATA_W+3:0] mix_left, mix_right;
    integer i;

    assign busy = state != 0;
    wire [8:0] wet_target = !fx_enable ? 9'd0 :
        (wet_q8 > 9'd128 ? 9'd128 : wet_q8);
    wire [8:0] wet_next = wet_applied < wet_target ? wet_applied + 1'b1 :
        (wet_applied > wet_target ? wet_applied - 1'b1 : wet_applied);

    function [11:0] comb_address;
        input [1:0] index;
        input [10:0] offset;
        begin
            case(index)
                0: comb_address = offset;
                1: comb_address = 12'd768 + offset;
                2: comb_address = 12'd1536 + offset;
                default: comb_address = 12'd2560 + offset;
            endcase
        end
    endfunction
    function [10:0] comb_last;
        input [1:0] index;
        begin
            case(index)
                0: comb_last = 11'd600;
                1: comb_last = 11'd732;
                2: comb_last = 11'd886;
                default: comb_last = 11'd1090;
            endcase
        end
    endfunction
    function signed [DATA_W+3:0] trunc_shift;
        input signed [DATA_W+11:0] value;
        input [3:0] amount;
        begin
            trunc_shift = value < 0 ? -((-value) >>> amount) : value >>> amount;
        end
    endfunction
    function signed [DATA_W-1:0] saturate;
        input signed [DATA_W+3:0] value;
        begin
            if (value > ((32'sd1<<(DATA_W-1))-1)) saturate = (32'sd1<<(DATA_W-1))-1;
            else if (value < -(32'sd1<<(DATA_W-1))) saturate = -(32'sd1<<(DATA_W-1));
            else saturate = value[DATA_W-1:0];
        end
    endfunction
    wire signed [DATA_W+3:0] input_quarter = frame_force_dry ? 0 : trunc_shift({{12{dry[DATA_W-1]}},dry},2);
    wire signed [DATA_W+3:0] damped = DAMPING ? trunc_shift(
      $signed({{12{ram_read[DATA_W-1]}},ram_read})+
      $signed({{12{damped_history[comb_index][DATA_W-1]}},damped_history[comb_index]}),1) : ram_read;
    wire signed [DATA_W+3:0] feedback = trunc_shift(
        $signed({{8{damped[DATA_W+3]}},damped}) +
        ($signed({{8{damped[DATA_W+3]}},damped}) <<< 1),2);
    wire signed [DATA_W+3:0] comb_new = input_quarter + feedback;

    // Clearing is an addressed write sweep, so memory remains block-RAM eligible.
    wire[11:0]write_address=!ready ? clear_address : ram_address;
    wire[DATA_W-1:0]write_value=!ready ? {DATA_W{1'b0}} : ram_write_data;
    always @(posedge clk) begin
        bank_q<=ram_address[11];
        lq0<=lo0[ram_address[10:0]];lq1<=lo1[ram_address[10:0]];
        hq0<=hi0[ram_address[10:0]];hq1<=hi1[ram_address[10:0]];
        if(!rst&&(!ready||ram_write))begin
          if(!write_address[11])begin lo0[write_address[10:0]]<=write_value[LO_W-1:0];hi0[write_address[10:0]]<=write_value[DATA_W-1:LO_W];end
          else begin lo1[write_address[10:0]]<=write_value[LO_W-1:0];hi1[write_address[10:0]]<=write_value[DATA_W-1:LO_W];end
        end
        multiplier_result <= multiplier_a * multiplier_b;
    end

    always @(posedge clk) begin
        if (rst) begin
            clear_address <= 0;
            ram_address <= 0;
            ram_write_data <= 0;
            ram_write <= 0;
            ready <= 0;
            state <= 0;
            comb_index <= 0;
            dry <= 0;
            frame_wet <= 0;
            frame_bypass <= 1;frame_force_dry<=0;
            stereo_sum_left <= 0;
            stereo_sum_right <= 0;
            wet_left <= 0;
            wet_right <= 0;
            multiplier_a <= 0;
            multiplier_b <= 0;
            mix_left <= 0;
            mix_right <= 0;
            wet_applied <= 0;
            out_valid <= 0;
            out_left <= 0;
            out_right <= 0;
            clip <= 0;
            overrun <= 0;
            for(i=0;i<4;i=i+1) begin
                position[i] <= 0;
                delayed[i] <= 0;damped_history[i]<=0;
            end
        end else begin
            out_valid <= 0;
            clip <= 0;
            ram_write <= 0;
            if (!ready) begin
                if (clear_address == 12'd4095) ready <= 1;
                else clear_address <= clear_address + 1'b1;
            end
            if (in_valid && busy) overrun <= 1;
            case(state)
                0: if (in_valid) begin
                    dry <= in_sample;
                    frame_bypass <= !ready;
                    frame_wet <= ready && !(force_dry===1'b1) ? wet_next : 9'd0;
                    frame_force_dry<=force_dry===1'b1;
                    wet_applied <= ready && !(force_dry===1'b1) ? wet_next : 9'd0;
                    comb_index <= 0;
                    state <= 1;
                end
                1: begin
                    ram_address <= comb_address(comb_index,position[comb_index]);
                    state <= 2;
                end
                2: state <= 3;
                3: begin
                    delayed[comb_index] <= frame_bypass ? 16'sd0 : ram_read;
                    ram_write_data <= comb_new[DATA_W-1:0];
                    if(!frame_bypass) damped_history[comb_index]<=damped[DATA_W-1:0];
                    ram_write <= !frame_bypass;
                    state <= 4;
                end
                4: begin
                    if (!frame_bypass) begin
                        if (position[comb_index] == comb_last(comb_index)) position[comb_index] <= 0;
                        else position[comb_index] <= position[comb_index] + 1'b1;
                    end
                    if (comb_index == 3) state <= 20;
                    else begin comb_index <= comb_index + 1'b1; state <= 1; end
                end
                20: begin
                    stereo_sum_left <=
                        $signed({{4{delayed[0][DATA_W-1]}},delayed[0]}) +
                        ($signed({{4{delayed[0][DATA_W-1]}},delayed[0]}) <<< 1) +
                        ($signed({{4{delayed[1][DATA_W-1]}},delayed[1]}) <<< 1) +
                        $signed({{4{delayed[2][DATA_W-1]}},delayed[2]}) +
                        ($signed({{4{delayed[3][DATA_W-1]}},delayed[3]}) <<< 1);
                    stereo_sum_right <=
                        $signed({{4{delayed[0][DATA_W-1]}},delayed[0]}) +
                        ($signed({{4{delayed[1][DATA_W-1]}},delayed[1]}) <<< 1) +
                        $signed({{4{delayed[2][DATA_W-1]}},delayed[2]}) +
                        ($signed({{4{delayed[2][DATA_W-1]}},delayed[2]}) <<< 1) +
                        ($signed({{4{delayed[3][DATA_W-1]}},delayed[3]}) <<< 1);
                    state <= 21;
                end
                21: begin
                    wet_left <= trunc_shift({{8{stereo_sum_left[DATA_W+3]}},stereo_sum_left},3);
                    wet_right <= trunc_shift({{8{stereo_sum_right[DATA_W+3]}},stereo_sum_right},3);
                    state <= 22;
                end
                22: begin
                    // Add reflections at fixed dry gain. Wet no longer attenuates
                    // the original note; shared multiplier and delay banks remain.
                    multiplier_a <= $signed({{2{wet_left[DATA_W-1]}},wet_left});
                    multiplier_b <= $signed({1'b0,frame_wet});
                    state <= 23;
                end
                23: state <= 24;
                24: begin
                    mix_left <= $signed({{4{dry[DATA_W-1]}},dry}) + trunc_shift(multiplier_result,WET_SHIFT);
                    multiplier_a <= $signed({{2{wet_right[DATA_W-1]}},wet_right});
                    state <= 25;
                end
                25: state <= 26;
                26: begin
                    mix_right <= $signed({{4{dry[DATA_W-1]}},dry}) + trunc_shift(multiplier_result,WET_SHIFT);
                    state <= 27;
                end
                27: begin
                    out_left <= frame_bypass || flush_tail===1'b1 ? dry : saturate(mix_left);
                    out_right <= frame_bypass || flush_tail===1'b1 ? dry : saturate(mix_right);
                    clip <= !(frame_bypass || flush_tail===1'b1) && (mix_left > ((32'sd1<<(DATA_W-1))-1) || mix_left < -(32'sd1<<(DATA_W-1)) ||
                        mix_right > ((32'sd1<<(DATA_W-1))-1) || mix_right < -(32'sd1<<(DATA_W-1)));
                    out_valid <= 1;
                    state <= 0;
                end
                default: state <= 0;
            endcase
            // Tail flush does not discard an accepted dry sample or reset the
            // output pipeline. New frames bypass until RAM clear completes.
            if(flush_tail===1'b1)begin
              ready<=0;clear_address<=0;ram_write<=0;wet_applied<=0;
              frame_bypass<=1;frame_wet<=0;
              for(i=0;i<4;i=i+1)begin position[i]<=0;damped_history[i]<=0;end
            end
        end
    end
endmodule
