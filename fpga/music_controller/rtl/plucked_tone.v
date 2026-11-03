// Derived from final_dual_timbre/pluck_voice.v; only initialization lookup is external.
// Fractional Karplus-Strong single voice; see ../README.md for transaction timing.
// State RAM is Q22, not PCM. RAM is never bulk reset.
module audio_v2_pluck #(parameter LOGIC_SCALE=0)(
    input wire clk, rst, sample_ce,
    input wire cmd_valid, input wire [1:0] cmd_kind,
    input wire [6:0] note, input wire [8:0] velocity,
    input wire [31:0] seed,
    input wire [9:0] table_length, input wire [15:0] table_fraction,
    input wire [24:0] table_reciprocal,
    output wire cmd_ready, output reg cmd_rejected, output reg active,
    output reg signed [15:0] sample, output reg sample_valid,
    output wire math_request,output wire signed [33:0] math_operand,
    output wire signed [25:0] math_factor,input wire math_grant,
    input wire signed [59:0] shared_math_product
);
    localparam IDLE=0, FILL=1, MEAN_MUL=2, MEAN_GET=3,
        CENTER_READ=4, CENTER_WAIT=5, CENTER_WRITE=6,
        READ_A=8, READ_B=9, GET_B=10, DIFF_MUL=11, INTERPOLATE=12,
        FEEDBACK_MUL=13, WRITE_FB=14, RAW_SCALE=15, VELOCITY_SCALE=16,
        RELEASE_SCALE=17, OUTPUT_SAMPLE=18;
    localparam RELEASE_SAMPLES=7212;
    reg [4:0] state;
    reg signed [23:0] memory [0:1023];
    reg signed [23:0] ram_q;
    reg [9:0] length, index, pointer;
    reg [15:0] fraction;
    reg [24:0] reciprocal;
    reg [31:0] rng;
    wire [31:0] xor1=rng^(rng<<13);
    wire [31:0] xor2=xor1^(xor1>>17);
    wire [31:0] next_rng=xor2^(xor2<<5);
    wire signed [23:0] noise={{1{next_rng[31]}},next_rng[31:9]};
    reg signed [33:0] noise_sum;
    reg signed [23:0] noise_mean;
    reg [8:0] held_velocity;
    reg releasing;
    reg [12:0] release_left;
    reg [24:0] release_gain;
    reg [16:0] held_release;
    reg signed [23:0] a,b,value,previous;
    wire signed [41:0] interpolation_product=shared_math_product[41:0];
    wire signed [40:0] feedback_product=shared_math_product[40:0];
    reg signed [37:0] raw_product;
    // Optional bit-exact constant scale using fabric adders, freeing DSP sites
    // for multitimbral integration. 7864 = 8192 - 256 - 64 - 8.
    wire signed [37:0] wide_value={{14{value[23]}},value};
    reg signed [15:0] raw_sample;
    reg signed [25:0] velocity_product;
    reg signed [15:0] velocity_sample;
    wire signed [33:0] release_product=shared_math_product[33:0];
    reg pending;
    wire initializing=(state>=FILL && state<=CENTER_WRITE);
    // A panic is always accepted, including a pending pipeline result.
    assign cmd_ready=!rst && (state==IDLE || initializing || cmd_kind==2);
    wire accepted=cmd_valid && cmd_ready;
    wire illegal=(cmd_kind==3) || (cmd_kind==0 && (note<36 || note>84));
    wire legal_command=accepted && !illegal;
    wire [9:0] read_a=(pointer>=length-2) ? pointer-(length-2) : pointer+2;
    wire [9:0] read_b=(pointer==length-1) ? 10'd0 : pointer+1'b1;
    reg [9:0] read_address;
    always @* begin
        if(initializing) read_address=index;
        else if(state==READ_A) read_address=read_a;
        else read_address=read_b;
    end
    wire signed [24:0] centered=$signed({ram_q[23],ram_q})-$signed({noise_mean[23],noise_mean});
    wire signed [24:0] difference=$signed({b[23],b})-$signed({a[23],a});
    wire signed [24:0] loop_sum=$signed({value[23],value})+$signed({previous[23],previous});
    assign math_request=!rst && (state==MEAN_MUL || state==DIFF_MUL || state==FEEDBACK_MUL || state==OUTPUT_SAMPLE);
    assign math_operand=state==MEAN_MUL ? noise_sum :
        state==DIFF_MUL ? {{9{difference[24]}},difference} :
        state==FEEDBACK_MUL ? {{9{loop_sum[24]}},loop_sum} : {{18{velocity_sample[15]}},velocity_sample};
    assign math_factor=state==MEAN_MUL ? $signed({1'b0,reciprocal}) :
        state==DIFF_MUL ? $signed({10'd0,fraction}) :
        state==FEEDBACK_MUL ? 26'sd32670 : $signed({9'd0,held_release});
    wire signed [41:0] interpolation_shift=interpolation_product>>>16;
    wire signed [24:0] interpolated=$signed({a[23],a})+interpolation_shift;
    // Truncation toward zero avoids a negative DC attractor in the feedback loop.
    wire signed [40:0] feedback_shift=feedback_product<0 ? -((-feedback_product)>>>16) : feedback_product>>>16;
    wire signed [33:0] output_shift=release_product<0 ? -((-release_product)>>>16) : release_product>>>16;
    function signed [23:0] sat24;
        input signed [24:0] x;
        begin
            if(x>25'sd8388607) sat24=24'sh7fffff;
            else if(x < -25'sd8388608) sat24=24'sh800000;
            else sat24=x[23:0];
        end
    endfunction
    function signed [15:0] sat16;
        input signed [33:0] x;
        begin
            if(x>32767) sat16=16'sh7fff;
            else if(x < -32768) sat16=16'sh8000;
            else sat16=x[15:0];
        end
    endfunction
    // One synchronous read port and one synchronous write port, with no reset.
    always @(posedge clk) begin
        ram_q<=memory[read_address];
        if(!rst && !legal_command) begin
            if(state==FILL) memory[index]<=noise;
            else if(state==CENTER_WRITE) memory[index]<=sat24(centered);
            else if(state==WRITE_FB) memory[pointer]<=feedback_shift[23:0];
        end
    end
    always @(posedge clk) begin
        sample_valid<=0;
        cmd_rejected<=0;
        if(rst) begin
            state<=IDLE; active<=0;sample<=0;pending<=0;
            length<=0;index<=0;pointer<=0;fraction<=0;reciprocal<=0;
            rng<=1;noise_sum<=0;noise_mean<=0;
            held_velocity<=0;releasing<=0;release_left<=0;
            release_gain<=25'd16777216;held_release<=17'd65536;
            a<=0;b<=0;value<=0;previous<=0;
            raw_product<=0;raw_sample<=0;
            velocity_product<=0;velocity_sample<=0;
        end else begin
            if(accepted && illegal) cmd_rejected<=1;
            if(legal_command) begin
                // Close any coincident/pending sample token when a command aborts work.
                if(sample_ce || pending) begin sample<=0;sample_valid<=1;end
                pending<=0;
                if(cmd_kind==2) begin
                    active<=0;state<=IDLE;sample<=0;previous<=0;releasing<=0;
                end else if(cmd_kind==0 && velocity!=0) begin
                    length<=table_length;fraction<=table_fraction;reciprocal<=table_reciprocal;
                    held_velocity<=velocity>256 ? 9'd256 : velocity;
                    rng<=seed==0 ? 32'h1 : seed;
                    noise_sum<=0;noise_mean<=0;index<=0;pointer<=0;previous<=0;
                    release_gain<=25'd16777216;release_left<=RELEASE_SAMPLES;
                    releasing<=0;active<=1;state<=FILL;
                end else if(initializing) begin
                    active<=0;state<=IDLE;sample<=0;
                end else begin
                    // Off is idempotent. A coincident sample enters the normal
                    // pipeline instead of introducing a one-sample mute click.
                    if(!releasing) begin
                        releasing<=1;
                        release_gain<=sample_ce && active ? 25'd16774889 : 25'd16777216;
                        release_left<=sample_ce && active ? RELEASE_SAMPLES-1 : RELEASE_SAMPLES;
                    end
                    if(sample_ce && active) begin
                        state<=READ_A;pending<=1;sample_valid<=0;
                        held_release<=releasing ? release_gain[24:8] : 17'd65536;
                        if(releasing) begin
                            if(release_left<=1) begin
                                release_left<=0;release_gain<=0;active<=0;held_release<=0;
                            end else begin
                                release_left<=release_left-1'b1;
                                release_gain<=release_gain>2327 ? release_gain-25'd2327 : 25'd0;
                            end
                        end
                    end
                end
            end else begin
                // Initialization consumes <60us at the lowest supported note.
                if(sample_ce && (initializing || !active)) begin
                    sample<=0;sample_valid<=1;
                end
                case(state)
                    IDLE: if(sample_ce && active) begin
                        state<=READ_A;pending<=1;held_release<=release_gain[24:8];
                        if(releasing) begin
                            if(release_left<=1) begin
                                release_left<=0;release_gain<=0;active<=0;
                                held_release<=0;
                            end else begin
                                release_left<=release_left-1'b1;
                                release_gain<=release_gain>2327 ? release_gain-25'd2327 : 25'd0;
                            end
                        end
                    end
                    FILL: begin
                        noise_sum<=noise_sum+noise;rng<=next_rng;
                        if(index==length-1) state<=MEAN_MUL;
                        else index<=index+1'b1;
                    end
                    MEAN_MUL: begin
                        if(math_grant) begin noise_mean<=shared_math_product>>>24;index<=0;state<=CENTER_READ;end
                    end
                    CENTER_READ: state<=CENTER_WAIT;
                    CENTER_WAIT: state<=CENTER_WRITE;
                    CENTER_WRITE: begin
                        if(index==length-1) state<=IDLE;
                        else begin index<=index+1'b1;state<=CENTER_READ;end
                    end
                    READ_A: state<=READ_B;
                    READ_B: begin a<=ram_q;state<=GET_B;end
                    GET_B: begin b<=ram_q;state<=DIFF_MUL;end
                    DIFF_MUL: begin
                        if(math_grant) begin value<=sat24(interpolated);state<=FEEDBACK_MUL;end
                    end
                    FEEDBACK_MUL: begin
                        if(math_grant) state<=WRITE_FB;
                    end
                    WRITE_FB: begin
                        previous<=value;
                        if(pointer==length-1) pointer<=0;else pointer<=pointer+1'b1;
                        if(LOGIC_SCALE)
                            raw_product<=(wide_value<<<13)-(wide_value<<<8)-(wide_value<<<6)-(wide_value<<<3);
                        else raw_product<=value*14'sd7864;
                        state<=RAW_SCALE;
                    end
                    RAW_SCALE: begin raw_sample<=raw_product>>>22;state<=VELOCITY_SCALE;end
                    VELOCITY_SCALE: begin
                        velocity_product<=raw_sample*$signed({1'b0,held_velocity});state<=RELEASE_SCALE;
                    end
                    RELEASE_SCALE: begin velocity_sample<=velocity_product>>>8;state<=OUTPUT_SAMPLE;end
                    OUTPUT_SAMPLE: begin
                        if(math_grant) begin sample<=sat16(output_shift);sample_valid<=1;pending<=0;state<=IDLE;end
                    end
                    default: state<=IDLE;
                endcase
            end
        end
    end
endmodule
