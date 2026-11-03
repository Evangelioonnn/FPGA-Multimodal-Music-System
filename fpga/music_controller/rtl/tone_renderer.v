// Local playable-gallery fork; baseline sources remain unchanged.
// Isolated fork of palette module at db653ef; see SPEC.md.
// Four ROM read channels and one amplitude multiplier service all N voices.
// Result is signed Q4 PCM. PROFILE 0 is numerically the legacy MODE 1.
// Other profiles preserve weighted fractional bits and use a 4096-point sine.
module audio_v2_tone #(parameter PROFILE=6,parameter TONE_SHIFT=0,parameter BALANCE_MODE=0,parameter N=8,
    parameter IW=(N>1?$clog2(N):1))(
    input wire clk,rst,sample_ce,
    input wire [N*32-1:0] phases,
    input wire [N*16-1:0] envelopes,brightness,
    input wire [N*7-1:0] notes,
    input wire [N*3-1:0] voice_timbres,
    input wire [8:0] coeff0,coeff1,coeff2,coeff3,
    output reg signed [19:0] sample,
    output reg [N-1:0] valid,output reg deadline_missed
);
    reg [3:0] state;
    reg [IW-1:0] index;
    // The bank freezes per-voice inputs from tone_ce through the last valid.
    wire [N*32-1:0] phase_frame=phases;
    wire [N*16-1:0] env_frame=envelopes,bright_frame=brightness;
    wire [N*7-1:0] note_frame=notes;
    wire [N*3-1:0] timbre_frame=voice_timbres;
    reg [8:0] coeff0_frame,coeff1_frame,coeff2_frame,coeff3_frame;
    reg [1:0] custom_harmonic_index;
    reg signed [26:0] custom_acc,custom_product;
    reg [31:0] address_phase;
    wire [31:0] phase2=address_phase<<1,phase3=address_phase+(address_phase<<1),phase4=address_phase<<2;
    wire signed [15:0] a,b,c,d;
    generate if(PROFILE==0) begin: original_rom
        sine_rom r0(clk,address_phase[31:22],a);
        sine_rom r1(clk,phase2[31:22],b);
        sine_rom r2(clk,phase3[31:22],c);
        sine_rom r3(clk,phase4[31:22],d);
    end else begin: precision_rom
        refinement_sine r0(clk,address_phase[31:20],a);
        refinement_sine r1(clk,phase2[31:20],b);
        refinement_sine r2(clk,phase3[31:20],c);
        refinement_sine r3(clk,phase4[31:20],d);
    end endgenerate
    wire signed [25:0] wa={{10{a[15]}},a},wb={{10{b[15]}},b},wc={{10{c[15]}},c},wd={{10{d[15]}},d};
    reg signed [25:0] fundamental,upper,shape;
    reg signed [42:0] bright_product,product;
    reg signed [51:0] balance_product;
    reg signed [33:0] mod_product;
    reg signed [15:0] original_b,original_c;
    wire signed [15:0] custom_sine=custom_harmonic_index==0 ? a :
        custom_harmonic_index==1 ? b : custom_harmonic_index==2 ? c : d;
    wire [8:0] custom_coeff=custom_harmonic_index==0 ? coeff0_frame :
        custom_harmonic_index==1 ? coeff1_frame :
        custom_harmonic_index==2 ? coeff2_frame : coeff3_frame;
    wire signed [25:0] custom_product_next=$signed(custom_sine)*
        $signed({1'b0,custom_coeff});
    wire signed [27:0] custom_sum_next=$signed({custom_acc[26],custom_acc})+
        $signed({custom_product[26],custom_product});
    wire [15:0] current_env=env_frame[index*16+:16];
    wire [15:0] current_bright=bright_frame[index*16+:16];
    wire [6:0] current_note=note_frame[index*7+:7];
    wire [6:0] upper_note=current_note>48 ? current_note-7'd48 : 7'd0;
    wire [6:0] upper_span=upper_note>36 ? 7'd36 : upper_note;
    wire [8:0] balance_gain=9'd256-({2'b0,upper_span}<<1);
    wire [2:0] current_timbre=timbre_frame[index*3+:3];
    wire [8:0] applied_gain=current_timbre==3 ? 9'd256 : balance_gain;
    wire [15:0] note_brightness=16'd65535-({9'd0,upper_span}*16'd384);
    wire signed [31:0] mod_offset=mod_product >>> 1;
    wire signed [26:0] drive_in=$signed({shape[25],shape})<<<1;
    wire signed [26:0] drive_shape=drive_in>27'sd3000000 ?
        27'sd3000000+((drive_in-27'sd3000000)>>>2) :
        drive_in< -27'sd3000000 ?
        -27'sd3000000+((drive_in+27'sd3000000)>>>2) : drive_in;
    wire signed [42:0] rounded=product<0 ? -(((-product)+(43'sd4194304 << TONE_SHIFT))>>>(23+TONE_SHIFT)) : (product+(43'sd4194304 << TONE_SHIFT))>>>(23+TONE_SHIFT);
    wire signed [51:0] balanced=balance_product<0 ?
        -(((-balance_product)+52'sd128)>>>8) : (balance_product+52'sd128)>>>8;
    always @(posedge clk) begin
        if(rst) begin
            state<=0;index<=0;
            coeff0_frame<=256;coeff1_frame<=64;coeff2_frame<=32;coeff3_frame<=16;
            custom_harmonic_index<=0;custom_acc<=0;custom_product<=0;
            address_phase<=0;fundamental<=0;upper<=0;shape<=0;
            bright_product<=0;product<=0;balance_product<=0;mod_product<=0;original_b<=0;original_c<=0;
            sample<=0;valid<=0;deadline_missed<=0;
        end else begin
            valid<=0;
            if(sample_ce) begin
                // Deliberately outside the idle test: a short/overrun frame
                // must assert the sticky diagnostic rather than hide it.
                if(state!=0) deadline_missed<=1;
                state<=1;index<=0;
            end else case(state)
                1:begin
                    coeff0_frame<=coeff0;coeff1_frame<=coeff1;coeff2_frame<=coeff2;coeff3_frame<=coeff3;
                    state<=2;
                end
                2:begin address_phase<=phase_frame[index*32+:32];state<=3;end
                3:state<=4; // synchronous ROM read
                4:begin
                    case(current_timbre)
                        4:begin fundamental<=wa<<<7;
                            upper<=(wb<<<4)+(wc<<<6)+(wd<<<4);state<=5;end
                        3:begin original_b<=b;original_c<=c;
                            mod_product<=$signed(c)*$signed({1'b0,current_bright});
                            state<=9;end
                        5:begin custom_harmonic_index<=0;custom_acc<=0;state<=13;end
                        default:begin fundamental<=wa<<<7;
                            upper<=(wb<<<5)+(wc<<<4)+(wd<<<3);state<=5;end
                    endcase
                end
                5:begin bright_product<=upper*$signed({1'b0,BALANCE_MODE==2 && current_timbre!=3 ? note_brightness : current_bright});state<=6;end
                6:begin
                    shape<=fundamental+((current_timbre==3 || BALANCE_MODE==2) ? (bright_product>>>16) : upper);
                    state<=7;
                end
                7:begin product<=(current_timbre==4 ? drive_shape : $signed({shape[25],shape}))*
                    $signed({1'b0,current_env});state<=8;end
                8:begin
                    if(BALANCE_MODE==0) begin
                        if(PROFILE==0) sample<=(product>>>27)<<<4;
                        else sample<=rounded[19:0];
                        valid[index]<=1;
                        if(index==N-1) state<=0;
                        else begin index<=index+1'b1;state<=2;end
                    end else begin balance_product<=rounded*$signed({1'b0,applied_gain});state<=12;end
                end
                9:begin
                    address_phase<=phase_frame[index*32+:32]+mod_offset;
                    state<=10;
                end
                10:state<=11;
                11:begin
                    begin fundamental<=(wa<<<6)+(wa<<<5);
                        upper<=($signed(original_b)<<<4)+($signed(original_c)<<<4);end
                    state<=5;
                end
                12:begin
                    sample<=balanced[19:0];valid[index]<=1;
                    if(index==N-1) state<=0;
                    else begin index<=index+1'b1;state<=2;end
                end
                13:begin custom_product<=custom_product_next;state<=14;end
                14:begin
                    if(custom_harmonic_index==3) begin
                        shape<=custom_sum_next>>>1;
                        state<=7;
                    end else begin
                        custom_acc<=custom_sum_next[26:0];
                        custom_harmonic_index<=custom_harmonic_index+1'b1;
                        state<=13;
                    end
                end
                default:state<=0;
            endcase
        end
    end
endmodule
