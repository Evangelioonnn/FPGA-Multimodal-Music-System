// Synchronous ready/valid FIFO. Full + simultaneous pop may accept a push.
module stream_fifo #(parameter WIDTH=25, DEPTH=16,
    parameter PTR_W=(DEPTH>1 ? $clog2(DEPTH) : 1),
    parameter COUNT_W=$clog2(DEPTH+1))(
    input wire clk,rst,flush,in_valid,
    input wire [WIDTH-1:0] in_data,
    output wire in_ready,out_valid,
    output wire [WIDTH-1:0] out_data,
    input wire out_ready,
    output reg [COUNT_W-1:0] level
);
    reg [WIDTH-1:0] mem[0:DEPTH-1];
    reg [PTR_W-1:0] rd,wr;
    wire pop=out_valid && out_ready;
    wire push=in_valid && in_ready;
    assign out_valid=!rst && !flush && level!=0;
    assign in_ready=!rst && !flush && (level<DEPTH || pop);
    assign out_data=mem[rd];
    always @(posedge clk) begin
        if(rst || flush) begin rd<=0;wr<=0;level<=0;end
        else begin
            case({push,pop})
                2'b10:level<=level+1'b1;
                2'b01:level<=level-1'b1;
                default:level<=level;
            endcase
            if(push) begin mem[wr]<=in_data;if(wr==DEPTH-1)wr<=0;else wr<=wr+1'b1;end
            if(pop) begin if(rd==DEPTH-1)rd<=0;else rd<=rd+1'b1;end
        end
    end
endmodule
