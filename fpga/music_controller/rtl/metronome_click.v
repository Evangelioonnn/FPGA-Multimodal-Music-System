// Independent click oscillator. A beat is queued across sample boundaries;
// it never competes with the drum or melodic voice allocators.
module metronome_click(
    input wire clk,rst,sample_ce,trigger,accent,enable,
    input wire [8:0] gain_q8,
    output reg valid,output reg signed [15:0] sample,
    output reg onset,output reg [31:0] delivered
);
    reg pending,pending_accent;
    reg [9:0] age;
    reg [31:0] phase;
    reg active,strong;reg [8:0] gain_applied;
    wire [8:0] gain_target=gain_q8>256 ? 9'd256 : gain_q8;
    reg signed [15:0] wave;
    reg signed [24:0] product;
    reg stage;
    wire [15:0] envelope = active && age<480 ? (strong ? ((16'd480-{6'd0,age})<<4) : (((16'd480-{6'd0,age})<<3)+((16'd480-{6'd0,age})<<2))) : 0;
    always @(posedge clk) begin
        if(rst) begin
            pending<=0;pending_accent<=0;gain_applied<=96;age<=0;phase<=0;active<=0;strong<=0;
            sample<=0;valid<=0;onset<=0;delivered<=0;stage<=0;wave<=0;product<=0;
        end else begin
            onset<=0;valid<=stage;stage<=0;
            if(trigger && enable) begin pending<=1;pending_accent<=accent;end
            if(!enable) begin pending<=0;active<=0;end
            if(sample_ce) begin
                stage<=1;
                if(gain_applied<gain_target) gain_applied<=gain_applied+1'b1;
                else if(gain_applied>gain_target) gain_applied<=gain_applied-1'b1;
                if(enable && (pending || trigger)) begin
                    pending<=0;active<=1;strong<=trigger ? accent : pending_accent;
                    phase<=0;age<=0;onset<=1;delivered<=delivered+1'b1;
                    product<=((trigger ? accent : pending_accent) ? 17'sd7680 : 17'sd5760)*$signed({1'b0,gain_applied});
                end else begin
                    if(active) begin
                        age<=age+1'b1;phase<=phase+(strong ? 32'd178670640 : 32'd133002240);
                        if(age>=479) active<=0;
                    end
                    // Bipolar short square click with a linear fade. Bound:
                    // 7680 * 256 / 256 = 7680, no sustain or reverb.
                    product<=(phase[31] ? -$signed({1'b0,envelope}) : $signed({1'b0,envelope}))*$signed({1'b0,gain_applied});
                end
            end
            if(stage) sample<=enable ? (product>>>8) : 16'sd0;
        end
    end
endmodule
