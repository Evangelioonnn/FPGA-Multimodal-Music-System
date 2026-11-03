// Common asynchronous assertion, local two-clock synchronous release.
module audio_transport_reset(
    input wire clk,arst,
    output wire rst
);
    (* async_reg = "true" *) reg [1:0] release_pipe;
    always @(posedge clk or posedge arst) begin
        if(arst) release_pipe<=2'b11;
        else release_pipe<={release_pipe[0],1'b0};
    end
    assign rst=release_pipe[1];
endmodule
