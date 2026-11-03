// Preserve all sample-latch/BCK timing from the proven transport. Only the
// output data/WS transition positions move within BCK's low half-cycle.
module output_tx #(parameter EDGE_SPACING=0)(
    input wire clk,rst,
    input wire signed [15:0] sample_left,sample_right,
    output wire sample_ce,hp_bck,hp_ws,hp_din
);
    wire raw_ws,raw_din;
    pt8211_tx base(clk,rst,sample_left,sample_right,sample_ce,hp_bck,raw_ws,raw_din);
    generate if(EDGE_SPACING) begin: separated
        reg [1:0] data_pipe=0;
        reg [3:0] ws_pipe=0;
        always @(posedge clk) begin
            if(rst) begin data_pipe<=0;ws_pipe<=0;end
            else begin data_pipe<={data_pipe[0],raw_din};ws_pipe<={ws_pipe[2:0],raw_ws};end
        end
        assign hp_din=data_pipe[1];
        assign hp_ws=ws_pipe[3];
    end else begin: original
        assign hp_din=raw_din;
        assign hp_ws=raw_ws;
    end endgenerate
endmodule
