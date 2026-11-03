// Bundled-data request/ack mailbox: held multi-bit source stable until ack returns.
// Do not synchronise coordinates independently. Same reset event required in both domains.
module snapshot_cdc #(parameter WIDTH=64)(
    input wire src_clk,src_rst,src_valid,
    input wire [WIDTH-1:0] src_data,
    output wire src_ready,
    output reg src_overrun,
    input wire dst_clk,dst_rst,
    output reg dst_valid,
    output reg [WIDTH-1:0] dst_data
);
    reg [WIDTH-1:0] held;
    reg req,ack;
    (* ASYNC_REG="TRUE" *) reg ack1,ack2,req1,req2;
    assign src_ready=(ack2==req);
    always @(posedge src_clk)begin
        if(src_rst)begin held<=0;req<=0;ack1<=0;ack2<=0;src_overrun<=0;end
        else begin
            ack1<=ack;ack2<=ack1;
            if(src_valid)begin
                if(src_ready)begin held<=src_data;req<=!req;end
                else src_overrun<=1;
            end
        end
    end
    always @(posedge dst_clk)begin
        if(dst_rst)begin req1<=0;req2<=0;ack<=0;dst_data<=0;dst_valid<=0;end
        else begin
            req1<=req;req2<=req1;dst_valid<=0;
            if(req2!=ack)begin dst_data<=held;dst_valid<=1;ack<=req2;end
        end
    end
endmodule
