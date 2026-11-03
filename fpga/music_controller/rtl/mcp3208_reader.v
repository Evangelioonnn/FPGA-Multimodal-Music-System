// MCP3208, mode 0, single-ended 8-channel coherent scans. At 50MHz,
// HALF_CYCLES=50 is 500kHz, conservative at VDD/VREF=3.3V.
module mcp3208_reader #(parameter HALF_CYCLES=50,SCAN_CYCLES=50000)(
    input wire clk,rst,input wire miso,
    output reg sclk,mosi,cs_n,
    output reg scan_valid,input wire scan_ready,
    output reg [95:0] scan_data,output reg [31:0] sequence,skipped_scans
);
    reg [1:0] state;reg [15:0] timer,half_count,gap_count;
    reg [2:0] channel;reg [4:0] bit_index;
    reg [23:0] command;reg [11:0] received;reg [95:0] working;
    wire due=timer==SCAN_CYCLES-1;
    always @(posedge clk) begin
        if(rst) begin
            state<=0;timer<=0;half_count<=0;gap_count<=0;channel<=0;bit_index<=23;
            command<=0;received<=0;working<=0;sclk<=0;mosi<=0;cs_n<=1;
            scan_valid<=0;scan_data<=0;sequence<=0;skipped_scans<=0;
        end else begin
            timer<=due ? 0 : timer+1'b1;
            if(scan_valid && scan_ready) scan_valid<=0;
            if(due) begin
                if(state==0 && (!scan_valid || scan_ready)) begin
                    channel<=0;command<=24'h060000;received<=0;bit_index<=23;
                    cs_n<=0;mosi<=0;sclk<=0;half_count<=0;state<=1;
                end else skipped_scans<=skipped_scans+1'b1;
            end
            if(state==1) begin
                if(half_count==HALF_CYCLES-1) begin
                    half_count<=0;
                    if(!sclk) begin
                        sclk<=1;
                        if(bit_index<=11) received<={received[10:0],miso};
                    end else begin
                        sclk<=0;
                        if(bit_index==0) begin
                            cs_n<=1;mosi<=0;working[channel*12+:12]<=received;
                            gap_count<=0;state<=2;
                            if(channel==7) begin
                                scan_data<={received,working[83:0]};scan_valid<=1;
                                sequence<=sequence+1'b1;
                            end
                        end else begin bit_index<=bit_index-1'b1;mosi<=command[bit_index-1'b1];end
                    end
                end else half_count<=half_count+1'b1;
            end else if(state==2) begin
                if(gap_count==HALF_CYCLES-1) begin
                    if(channel==7) state<=0;
                    else begin
                        channel<=channel+1'b1;command<=24'h060000|((channel+24'd1)<<14);
                        received<=0;bit_index<=23;cs_n<=0;mosi<=0;half_count<=0;state<=1;
                    end
                end else gap_count<=gap_count+1'b1;
            end
        end
    end
endmodule
