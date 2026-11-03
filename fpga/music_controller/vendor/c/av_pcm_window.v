// Observe full-resolution consecutive post-master/DAC-input PCM pairs.
// Capture starts on a left rising zero crossing, or after 2048 accepted
// samples without one. A completed bank waits for display ownership ACK.
module av_pcm_window(input wire clk,rst,ready,sample_valid,
    input wire signed [15:0] left,right,
    output wire wr_en,output wire [8:0] wr_addr,
    output wire [31:0] wr_data,output wire publish);
    reg capturing=0,previous_negative=0;
    reg [8:0] index=0;
    reg [10:0] wait_samples=0;
    wire trigger=(previous_negative && !left[15]) || (&wait_samples);
    assign wr_en=ready && sample_valid && !rst && (capturing || trigger);
    assign wr_addr=capturing ? index : 9'd0;
    assign wr_data={right,left};
    assign publish=wr_en && capturing && (&index);
    always @(posedge clk)begin
        if(rst)begin capturing<=0;index<=0;previous_negative<=0;wait_samples<=0;end
        else if(sample_valid)begin
            previous_negative<=left[15];
            if(capturing)begin
                if(ready)begin
                    if(&index)begin capturing<=0;index<=0;wait_samples<=0;end
                    else index<=index+1'b1;
                end
            end else if(ready)begin
                if(trigger)begin capturing<=1;index<=1;wait_samples<=0;end
                else wait_samples<=wait_samples+1'b1;
            end
        end
    end
endmodule
