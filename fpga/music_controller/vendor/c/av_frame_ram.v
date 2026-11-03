// Two independent banks. The producer cannot reuse a published bank until
// the pixel consumer swaps banks in vertical blanking and acknowledges it.
// Only single-bit toggles cross domains; RAM data is stable before publication.
module av_frame_ram #(parameter AW=11, DW=11)(
    input wire src_clk,src_rst,dst_clk,dst_rst,
    input wire wr_en,input wire [AW-1:0] wr_addr,
    input wire [DW-1:0] wr_data,input wire publish,
    output wire src_ready,
    input wire frame_start,input wire [AW-1:0] rd_addr,
    output reg [DW-1:0] rd_data,output reg have_frame,
    output reg frame_changed
);
    (* syn_ramstyle="block_ram" *) reg [DW-1:0] memory[0:(1<<(AW+1))-1];
    reg request=0,ack=0;
    (* async_reg="true" *) reg ack_meta=0,ack_sync=0,request_meta=0,request_sync=0;
    assign src_ready=!src_rst && (request==ack_sync);
    always @(posedge src_clk) begin
        if(wr_en && src_ready) memory[{!request,wr_addr}]<=wr_data;
        if(src_rst) begin request<=0;ack_meta<=0;ack_sync<=0;end
        else begin
            ack_meta<=ack;ack_sync<=ack_meta;
            if(publish && src_ready) request<=!request;
        end
    end
    always @(posedge dst_clk) begin
        rd_data<=memory[{ack,rd_addr}];
        if(dst_rst) begin ack<=0;request_meta<=0;request_sync<=0;have_frame<=0;frame_changed<=0;end
        else begin
            request_meta<=request;request_sync<=request_meta;frame_changed<=0;
            if(frame_start && request_sync!=ack) begin
                ack<=request_sync;have_frame<=1;frame_changed<=1;
            end
        end
    end
endmodule
