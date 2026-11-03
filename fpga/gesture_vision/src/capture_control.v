// S1 is active low. One press after release; no boot/held/repeated/busy queue.
// A scalar toggle crosses each way. Acknowledgment is completion, not receipt.
module p20_capture_control #(
    parameter DEBOUNCE=270000,REPORT_CYCLES=74250000
)(input wire sys_clk,sys_rst,button_n,video_clk,video_rst,
    input wire video_blank,have_frame,configured,input wire [31:0] displayed_frame,
    input wire tx_busy,tx_done,
    output wire hold_frame,output reg frozen,
    output reg tx_start,tx_image,output reg [31:0] sequence_id,capture_frame);
    (* ASYNC_REG="TRUE" *) reg button1,button2,ack1,ack2,ready1,ready2;
    reg stable,armed,request;
    reg [31:0] debounce_count;
    reg complete;
    wire available=have_frame && configured;
    always @(posedge sys_clk)begin
        if(sys_rst)begin
            button1<=1;button2<=1;ack1<=0;ack2<=0;ready1<=0;ready2<=0;
            stable<=1;armed<=0;request<=0;debounce_count<=0;
        end else begin
            button1<=button_n;button2<=button1;
            ack1<=complete;ack2<=ack1;ready1<=available;ready2<=ready1;
            if(button2==stable)begin
                debounce_count<=0;
                if(stable && debounce_count==0)begin
                    // Startup needs a complete stable high interval too.
                    if(armed)armed<=1;
                end
            end
            if(button2==stable && stable && !armed)begin
                if(debounce_count==DEBOUNCE-1)begin armed<=1;debounce_count<=0;end
                else debounce_count<=debounce_count+1'b1;
            end else if(button2!=stable)begin
                if(debounce_count==DEBOUNCE-1)begin
                    stable<=button2;debounce_count<=0;
                    if(button2)armed<=1;
                    else begin
                        armed<=0;
                        if(armed && ready2 && request==ack2)request<=!request;
                    end
                end else debounce_count<=debounce_count+1'b1;
            end
        end
    end
    (* ASYNC_REG="TRUE" *) reg request1,request2;
    reg image_pending,image_inflight,release_pending;
    reg [31:0] report_count;
    reg [31:0] packet_counter;
    assign hold_frame=frozen || (request2!=complete && have_frame);
    always @(posedge video_clk)begin
        if(video_rst)begin
            request1<=0;request2<=0;complete<=0;frozen<=0;
            image_pending<=0;image_inflight<=0;release_pending<=0;
            tx_start<=0;tx_image<=0;sequence_id<=0;packet_counter<=0;
            capture_frame<=0;report_count<=0;
        end else begin
            request1<=request;request2<=request1;tx_start<=0;
            if(report_count!=REPORT_CYCLES-1)report_count<=report_count+1'b1;
            if(video_blank && !frozen && request2!=complete && available)begin
                frozen<=1;capture_frame<=displayed_frame;image_pending<=1;
            end
            if(!tx_busy && !tx_start)begin
                if(image_pending)begin
                    tx_start<=1;tx_image<=1;image_pending<=0;image_inflight<=1;
                    sequence_id<=packet_counter;packet_counter<=packet_counter+1'b1;report_count<=0;
                end else if(!frozen && report_count==REPORT_CYCLES-1)begin
                    tx_start<=1;tx_image<=0;sequence_id<=packet_counter;
                    packet_counter<=packet_counter+1'b1;report_count<=0;
                end
            end
            if(tx_done && image_inflight)begin image_inflight<=0;release_pending<=1;end
            // Keep the last transmitted pixel and CRC on the same displayed bank.
            // Resume only in vertical blank; the next publication is another blank.
            if(video_blank && release_pending)begin
                frozen<=0;release_pending<=0;complete<=request2;
            end
        end
    end
endmodule
