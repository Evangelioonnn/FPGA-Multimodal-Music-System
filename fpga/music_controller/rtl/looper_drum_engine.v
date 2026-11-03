module looper_drum_engine #(
    parameter VOICES = 8,WITH_TF=0,WITH_PRACTICE=0,
    parameter SW = (VOICES > 1 ? $clog2(VOICES) : 1)
)(
    input wire clk,
    input wire rst,
    input wire sample_ce,input wire pause_loops,output wire sequencer_busy,
    input wire strike_valid,
    output wire strike_ready,
    output wire strike_accepted,
    input wire [3:0] strike_pad,
    input wire [1:0] strike_layer,
    input wire [2:0] strike_track,
    input wire [67:0] track_gains,
    input wire flush_all,flush_valid,
    input wire [1:0] flush_track,flush_layer,input wire flush_whole_track,
    input wire [7:0] strike_velocity,
    output reg sample_valid,
    output reg signed [19:0] sample,
    output reg [VOICES-1:0] active,
    output wire [VOICES*4-1:0] active_pads,
    output reg [31:0] late_strikes,
    output reg [31:0] rejected_strikes,input wire practice_mode,input wire practice_clear_auto
);
    localparam IDLE = 0;
    localparam SCAN = 1;
    localparam MIX = 2;
    reg [2:0] state;
    reg [SW-1:0] index;
    reg [1:0] layers[0:VOICES-1];reg [2:0] tracks[0:VOICES-1];reg [VOICES-1:0] forced_release;
    wire[VOICES-1:0]sequencer_mask;genvar sq;
    generate for(sq=0;sq<VOICES;sq=sq+1)begin: sequencer_usage assign sequencer_mask[sq]=active[sq]&&tracks[sq]<4;end endgenerate
    assign sequencer_busy=|sequencer_mask;
    reg [16:0] rise_q,loss_q;reg [15:0] level_q,target_q;
    reg signed [31:0] wave_product_q;
    reg signed [37:0] track_product_q;
    wire [16:0] gain_raw=tracks[index]<4 ? track_gains[tracks[index]*17+:17] : 17'd65536;
    wire [16:0] selected_gain=gain_raw>65536 ? 17'd65536 : gain_raw;
    reg free_found, choke_found;
    reg [SW-1:0] free_index, choke_index;
    reg [3:0] pad [0:VOICES-1];





    reg [VOICES-1:0] attack_done;

    // History has exactly three reachable values: reset0, +32767, -32768.
    // Encode it as two bits instead of an indexed16-bit read/modify/write bank.
    reg [VOICES-1:0] history_valid,history_positive;
    wire signed [15:0] previous_noise [0:VOICES-1];
    genvar history_i;
    generate for(history_i=0;history_i<VOICES;history_i=history_i+1)begin: history_decode
        assign previous_noise[history_i]=!history_valid[history_i] ? 16'sd0 :
            history_positive[history_i] ? 16'sd32767 : -16'sd32768;
    end endgenerate
    reg signed [17:0] cymbal_wide;
    wire signed [31:0] raw_voice_q=active[index] ? $signed(wave_product_q>>>16) : 32'sd0;
    wire signed [31:0] shaped_voice_q=(is_tom(pad[index]) || pad[index]==0) ? raw_voice_q+(raw_voice_q>>>1) :
        (pad[index]==5 || pad[index]==6) ? raw_voice_q>>>1 : raw_voice_q;


    reg [23:0] accumulator;
    reg [9:0] rom_address;
    wire signed [15:0] sine_sample;
    reg signed [15:0] wave_sample;
    reg signed [31:0] scaled_product;
    reg signed [23:0] voice_sample;
    reg [15:0] next_noise;
    reg [31:0] next_step;
    reg [31:0] next_phase;
    reg [15:0] next_noise_q;reg [31:0] next_step_q,next_phase_q;
    reg [3:0] wave_pad_q;reg wave_noise_q;
    reg signed [15:0] wave_history_q;reg [31:0] wave_phase_q;reg [15:0] wave_level_q;
    reg strike_pending;reg [SW-1:0] pending_slot;
    reg [31:0] pending_step,pending_floor;reg [15:0] pending_target,pending_noise;
    reg [3:0] pending_attack;reg [4:0] pending_decay;
    reg [16:0] env_loss;
    reg [16:0] env_rise;
    reg signed [23:0] next_sum;
    integer i;
    integer reset_i;


    wire[152:0] numeric_record;wire record_valid,record_writing;
    wire[31:0]phase_w=numeric_record[31:0],step_w=numeric_record[63:32],step_floor_w=numeric_record[95:64];
    wire[15:0]level_w=numeric_record[111:96],target_level_w=numeric_record[127:112],noise_w=numeric_record[143:128];
    wire[3:0]attack_shift_w=numeric_record[147:144];wire[4:0]decay_shift_w=numeric_record[152:148];
    reg[152:0] numeric_write;wire numeric_mix=!sample_ce&&state==MIX&&active[index];
    wire numeric_we=strike_pending||numeric_mix;
    always @*begin
      numeric_write=numeric_record;
      if(strike_pending)numeric_write={pending_decay,pending_attack,pending_noise,pending_target,16'd0,pending_floor,pending_step,32'd0};
      if(numeric_mix)begin
        numeric_write[31:0]=next_phase_q;numeric_write[63:32]=next_step_q;
        numeric_write[143:128]=next_noise_q==0?16'h1:next_noise_q;
        if(WITH_TF&&pause_loops&&tracks[index]<4)begin end
        else if(forced_release[index])numeric_write[111:96]=level_w>128?level_w-16'd128:0;
        else if(!attack_done[index]&&level_q<target_q)
          numeric_write[111:96]=({1'b0,level_q}+rise_q>={1'b0,target_q})?target_q:level_q+rise_q[15:0];
        else numeric_write[111:96]=level_w<=loss_q?16'd0:level_q-loss_q[15:0];
      end
    end
    drum_numeric_ram #(.N(VOICES),.AW(SW)) records(.clk(clk),.rst(rst),
      .read_enable(!sample_ce&&state==SCAN),.read_index(index),.read_valid(record_valid),.read_data(numeric_record),
      .write_enable(numeric_we),.write_index(numeric_mix?index:pending_slot),.write_data(numeric_write),.writing(record_writing));

    sine_rom shared_drum_sine(clk, rom_address, sine_sample);

    genvar g;
    generate for (g = 0; g < VOICES; g = g + 1) begin: pad_outputs
        assign active_pads[g*4 +: 4] = pad[g];
    end endgenerate

    // V2 stable pad map. Disabled pads are consumed/rejected, never allocate.
    function pad_enabled;
        input [3:0] drum_pad;
        begin pad_enabled=(drum_pad<=9 || drum_pad==12 || drum_pad==13);end
    endfunction
    function is_tom;
        input [3:0] drum_pad;
        begin is_tom=(drum_pad==2 || drum_pad==3 || drum_pad==4 || drum_pad==9);end
    endfunction
    function [3:0] noise_profile;
        input [3:0] drum_pad;
        begin case(drum_pad)
            0:noise_profile=2;5:noise_profile=6;6:noise_profile=8;
            default:noise_profile=drum_pad;
        endcase end
    endfunction
    function [31:0] start_step;
        input [3:0] drum_pad;
        begin case(drum_pad)
            0:start_step=8900000; // exact former low tom body and pitch fall
            1:start_step=16500000;
            2:start_step=13117318;
            3:start_step=17509518;
            4:start_step=22060612;
            9:start_step=26234636;
            5:start_step=37700000; // former open hat, now closed
            6:start_step=127000000; // former crash2, now open hat
            7:start_step=160000000;
            8:start_step=174000000;
            12:start_step=18800000;
            13:start_step=28400000;
            default:start_step=0;
        endcase end
    endfunction
    function [3:0] attack_rate;
        input [3:0] drum_pad;
        begin case(drum_pad)
            0,1,2,3,4,9:attack_rate=7;
            6,7,8:attack_rate=6;
            default:attack_rate=4;
        endcase end
    endfunction
    function [4:0] decay_rate;
        input [3:0] drum_pad;
        begin case(drum_pad)
            0,2,3,4,9,12,13:decay_rate=10;
            1,5:decay_rate=9;
            6:decay_rate=11;
            7:decay_rate=13;
            8:decay_rate=14;
            default:decay_rate=10;
        endcase end
    endfunction

    always @* begin
        free_found = 0;
        free_index = 0;
        choke_found = 0;
        choke_index = 0;
        for (i = 0; i < VOICES; i = i + 1) begin
            if (!active[i] && !free_found && (!WITH_PRACTICE || !practice_mode || i<4)) begin
                free_found = 1;
                free_index = i[SW-1:0];
            end
            if ((strike_pad == 5) && active[i] &&
                (pad[i] == 6) && !choke_found && (!WITH_PRACTICE || !practice_mode || i<4)) begin
                choke_found = 1;
                choke_index = i[SW-1:0];
            end
        end
    end

    wire [SW-1:0] strike_slot=free_found ? free_index : choke_index;
    assign strike_ready = state == IDLE && !sample_ce && !strike_pending && !record_writing;
    assign strike_accepted = strike_ready && pad_enabled(strike_pad) && (free_found || choke_found);

    always @* begin
        cymbal_wide=0;
        rom_address = phase_w[31:22];
        wave_sample = sine_sample;
        next_noise = {noise_w[14:0], noise_w[15] ^ noise_w[13] ^
                      noise_w[12] ^ noise_w[10]};
        if (wave_pad_q != 0 && !is_tom(wave_pad_q)) begin
            if (wave_pad_q == 7 || wave_pad_q == 8) begin
                // Brighter cymbal: bounded white/high-pass noise and denser metallic partials.
                cymbal_wide=$signed(wave_noise_q ? 16'sd32767 : -16'sd32768);
                cymbal_wide=(cymbal_wide>>>2)+((cymbal_wide-$signed(wave_history_q))>>>2)+
                    ((wave_phase_q[31]^wave_phase_q[28]^wave_phase_q[25]^wave_phase_q[22]) ? 18'sd8191 : -18'sd8192);
                wave_sample=cymbal_wide>32767 ? 16'sd32767 : cymbal_wide< -32768 ? -16'sd32768 : cymbal_wide[15:0];
            end else begin
                wave_sample = wave_noise_q ? 16'sd32767 : -16'sd32768;
                if (wave_pad_q == 1)
                    wave_sample = (sine_sample >>> 1) + (wave_sample >>> 1);
                else if (wave_pad_q >= 5)
                    wave_sample = (wave_sample >>> 1) +
                        ((wave_phase_q[31] ^ wave_phase_q[27] ^ wave_phase_q[24]) ?
                            16'sd16383 : -16'sd16384);
            end
        end
        scaled_product = wave_sample * $signed({1'b0, wave_level_q});
        voice_sample = active[index] ? scaled_product >>> 16 : 24'sd0;
        env_rise = (({1'b0,target_level_w} - {1'b0,level_w}) >> attack_shift_w) + 1'b1;
        env_loss = ({1'b0,level_w} >> decay_shift_w) + 1'b1;
        next_step = step_w;
        if (pad[index] == 0 && step_w > step_floor_w) begin
            next_step = step_w - (step_w >> 9);
            if (next_step < step_floor_w) next_step = step_floor_w;
        end else if (is_tom(pad[index]) && step_w > step_floor_w) begin
            next_step = step_w - (step_w >> 9);
            if (next_step < step_floor_w) next_step = step_floor_w;
        end
        next_phase = phase_w + step_w;
        next_sum = $signed(accumulator) + (track_product_q>>>16);
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            index <= 0;strike_pending<=0;
            accumulator <= 0;
            sample_valid <= 0;
            sample <= 0;
            active <= 0;
            attack_done <= 0;forced_release<=0;wave_product_q<=0;track_product_q<=0;rise_q<=0;loss_q<=0;level_q<=0;target_q<=0;
            late_strikes <= 0;
            rejected_strikes <= 0;
            for (reset_i = 0; reset_i < VOICES; reset_i = reset_i + 1) begin
                pad[reset_i] <= 0;tracks[reset_i]<=4;layers[reset_i]<=0;
                 
                 
                 
                 
                 
                 history_valid[reset_i]<=0;history_positive[reset_i]<=0;
                 
                 
            end
        end else begin
            sample_valid <= 0;
            strike_pending<=0;
            // Commit the numeric strike record from a registered request.
            // Metadata reserves its slot at acceptance; one-cycle backpressure
            // prevents a second allocation before this record is complete.
            if(strike_pending)begin
                   
                  
                  
                 history_valid[pending_slot]<=0;history_positive[pending_slot]<=0;
            end
            if (strike_valid && strike_accepted) begin
                if (strike_pad == 5) begin
                    for (reset_i = 0; reset_i < VOICES; reset_i = reset_i + 1)
                        if (active[reset_i] && (pad[reset_i] == 6)) begin
                            forced_release[reset_i] <= 1;
                        end
                end
                active[strike_slot] <= 1;
                tracks[strike_slot]<=strike_track;
                layers[strike_slot]<=strike_layer;
                forced_release[strike_slot]<=0;
                pad[strike_slot] <= strike_pad;
                strike_pending<=1;pending_slot<=strike_slot;
                pending_step <= start_step(strike_pad);
                pending_floor <=
                    (strike_pad == 0 || is_tom(strike_pad)) ?
                        (start_step(strike_pad) >> 1) : start_step(strike_pad);
                attack_done[strike_slot] <= 0;
                pending_target <=
                    {strike_velocity, strike_velocity};
                pending_attack <= attack_rate(strike_pad);
                pending_decay <= decay_rate(strike_pad);
                pending_noise <=
                    16'h9e37 ^ {12'd0, noise_profile(strike_pad)};
            end
            if (sample_ce) begin
                if (state != IDLE) late_strikes <= late_strikes + 1'b1;
                state <= SCAN;
                index <= 0;
                accumulator <= 0;
            end else case (state)
                IDLE: begin end
                SCAN:state<=5;
                5:if(record_valid)begin
                    wave_pad_q<=pad[index];wave_noise_q<=noise_w[0];wave_history_q<=previous_noise[index];
                    wave_phase_q<=phase_w;wave_level_q<=level_w;state<=3;
                end
                3:begin
                    next_phase_q<=next_phase;next_step_q<=next_step;next_noise_q<=next_noise;
                    rise_q<=env_rise;loss_q<=env_loss;level_q<=level_w;target_q<=target_level_w;wave_product_q<=scaled_product;state<=4;
                end
                4:begin track_product_q<=shaped_voice_q*$signed({1'b0,selected_gain});state<=MIX;end
                MIX: begin
                    if (active[index]) begin
                        
                        
                        history_valid[index]<=1;history_positive[index]<=noise_w[0];
                        
                        if(WITH_TF&&pause_loops&&tracks[index]<4)begin end
                        else if(forced_release[index]) begin
                            
                            if(level_w<=128) active[index]<=0;
                        end else if (!attack_done[index] && level_q < target_q) begin
                            if ({1'b0, level_q} + rise_q >= {1'b0, target_q})
                                begin  attack_done[index] <= 1; end
                            else begin end
                        end else if (level_w <= loss_q) begin
                            
                            active[index] <= 0;
                        end else begin end
                    end
                    if (index == VOICES - 1) begin
                        if (next_sum > 24'sd524287) sample <= 20'sh7ffff;
                        else if (next_sum < -24'sd524288) sample <= 20'sh80000;
                        else sample <= next_sum[19:0];
                        sample_valid <= 1;
                        accumulator <= 0;
                        state <= IDLE;
                    end else begin
                        accumulator <= next_sum;
                        index <= index + 1'b1;
                        state <= SCAN;
                    end
                end
                default: state <= IDLE;
            endcase
            if(flush_all === 1'b1 || flush_valid === 1'b1)
                for(reset_i=0;reset_i<VOICES;reset_i=reset_i+1)
                    if(tracks[reset_i]<4 && (flush_all === 1'b1 || (tracks[reset_i]==flush_track && (flush_whole_track || layers[reset_i]==flush_layer)))) forced_release[reset_i]<=1;
            if(WITH_PRACTICE&&practice_clear_auto)begin
             for(reset_i=0;reset_i<VOICES;reset_i=reset_i+1)if(tracks[reset_i]<4)begin active[reset_i]<=0;forced_release[reset_i]<=0;end
            end
            if (strike_valid && strike_ready && (!pad_enabled(strike_pad) || (!free_found && !choke_found)))
                rejected_strikes <= rejected_strikes + 1'b1;
        end
    end
endmodule

// Ten16-bit transfers with16-word slot stride; one physical blockRAM.
// Request-edge forwarding also covers a strike committed on a sample boundary.
module drum_numeric_ram #(parameter N=8,AW=3)(input wire clk,rst,read_enable,input wire[AW-1:0]read_index,
 output reg read_valid,output wire[152:0]read_data,input wire write_enable,input wire[AW-1:0]write_index,
 input wire[152:0]write_data,output reg writing);
 (* syn_ramstyle="block_ram" *)reg[15:0]ram[0:N*16-1];
 reg reading,forward,forward_new;reg[3:0]phase,write_phase;reg[AW-1:0]read_slot,write_slot;
 reg[159:0]read_record,write_record;reg[15:0]q;
 wire[3:0]read_word=read_enable?4'd0:phase+4'd1;
 assign read_data=read_record[152:0];
 always @(posedge clk)begin
  q<=ram[{read_enable?read_index:read_slot,read_word}];
  if(!rst&&writing)ram[{write_slot,write_phase}]<=write_record[write_phase*16+:16];
 end
 always @(posedge clk)begin
  if(rst)begin reading<=0;writing<=0;phase<=0;write_phase<=0;read_slot<=0;write_slot<=0;read_valid<=0;forward<=0;forward_new<=0;end
  else begin
   read_valid<=0;
   if(writing)begin write_phase<=write_phase+1'b1;if(write_phase==9)writing<=0;end
   if(write_enable)begin write_record<={7'd0,write_data};write_slot<=write_index;write_phase<=0;writing<=1;end
   if(read_enable)begin
    read_slot<=read_index;phase<=0;reading<=1;read_record<=write_record;
    forward<=(write_enable&&write_index==read_index)||(writing&&write_slot==read_index);
    forward_new<=write_enable&&write_index==read_index;
   end else if(reading)begin
    phase<=phase+1'b1;
    if(phase==0&&forward_new)read_record<=write_record;
    else if(!forward)read_record[phase*16+:16]<=q;
    if(phase==9)begin reading<=0;read_valid<=1;end
   end
  end
 end
 // synthesis translate_off
 always @(posedge clk)if(!rst&&write_enable&&writing)$fatal(1,"overlapping drum numeric write");
 // synthesis translate_on
endmodule
