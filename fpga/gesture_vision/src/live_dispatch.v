// Exactly one queued capture-controller request; every completed job is reported.
module p20_crop_live_dispatch(input wire pixel_clk,vrst,control_start,control_image,
    input wire tx_busy,result_pending,terminal_current,
    output reg tx_start,tx_image,result_consumed,output wire control_busy,
    output reg [31:0] sequence_id);
    reg queued,queued_image;reg [31:0] packet_sequence;
    assign control_busy=tx_busy||tx_start||queued;
    // A capture request can wait for its held frame's terminal result. Only one
    // controller request exists until the final UART stop bit and blank release.
    always @(posedge pixel_clk)begin
        if(vrst)begin
            tx_start<=0;tx_image<=0;result_consumed<=0;queued<=0;queued_image<=0;
            packet_sequence<=0;sequence_id<=0;
        end else begin
            tx_start<=0;result_consumed<=0;
            if(control_start)begin queued<=1;queued_image<=control_image;end
            if(!tx_busy && !tx_start && !control_start)begin
                if(queued && (!queued_image || terminal_current))begin
                    tx_start<=1;tx_image<=queued_image;queued<=0;
                    sequence_id<=packet_sequence;packet_sequence<=packet_sequence+1'b1;
                    if(result_pending)result_consumed<=1;
                end else if(result_pending)begin
                    tx_start<=1;tx_image<=0;result_consumed<=1;
                    sequence_id<=packet_sequence;packet_sequence<=packet_sequence+1'b1;
                end
            end
        end
    end
endmodule
