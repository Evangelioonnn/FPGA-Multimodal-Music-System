// Source supplies a registered stable publication, held until next valid.
// A single frozen RAM bank crosses domains with request/ack toggles.
module session_ui_bridge(
    input wire src_clk,dst_clk,arst,input wire src_valid,input wire [639:0] src_data,
    output reg [31:0] src_drops,
    output wire dst_valid,input wire dst_ready,output reg [31:0] dst_data,
    output reg [4:0] dst_index,output wire dst_first,dst_last,dst_session_start
);
    wire src_rst,dst_rst;
    audio_transport_reset sreset(src_clk,arst,src_rst),dreset(dst_clk,arst,dst_rst);
    reg [31:0] ram[0:31];reg copying,request_toggle,ack_toggle;
    reg [4:0] address;reg [31:0] sequence,record_sequence,record_drops;
    (* async_reg="true" *) reg ack1,ack2,request1,request2;
    wire owned=request_toggle!=ack2;
    reg [31:0] write_data;
    always @* begin
        case(address)
            0:write_data=32'h4c550117;
            1:write_data=record_sequence;
            2:write_data=record_drops;
            default:write_data=src_data[(address-3)*32+:32];
        endcase
    end
    always @(posedge src_clk) if(copying&&!src_valid&&!src_rst) ram[address]<=write_data;
    always @(posedge src_clk or posedge src_rst) begin
        if(src_rst) begin copying<=0;request_toggle<=0;address<=0;sequence<=0;
            record_sequence<=0;record_drops<=0;src_drops<=0;ack1<=0;ack2<=0;end else begin
            ack1<=ack_toggle;ack2<=ack1;
            if(src_valid) begin
                sequence<=sequence+1'b1;
                if(owned) src_drops<=src_drops+1'b1;
                else begin
                    copying<=1;address<=0;record_sequence<=sequence;
                    if(copying) begin src_drops<=src_drops+1'b1;record_drops<=src_drops+1'b1;end
                    else record_drops<=src_drops;
                end
            end else if(copying) begin
                if(address==22) begin copying<=0;request_toggle<=!request_toggle;end
                else address<=address+1'b1;
            end
        end
    end
    reg pending_read,output_valid,first_session;
    wire pending=request2!=ack_toggle;
    assign dst_valid=output_valid&&!dst_rst;
    assign dst_first=dst_index==0;assign dst_last=dst_index==22;
    assign dst_session_start=first_session&&dst_first;
    always @(posedge dst_clk) if(!dst_rst&&pending&&!output_valid&&!pending_read) dst_data<=ram[dst_index];
    always @(posedge dst_clk or posedge dst_rst) begin
        if(dst_rst) begin request1<=0;request2<=0;ack_toggle<=0;dst_index<=0;
            pending_read<=0;output_valid<=0;first_session<=1;end else begin
            request1<=request_toggle;request2<=request1;
            if(output_valid) begin
                if(dst_ready) begin
                    output_valid<=0;
                    if(dst_first) first_session<=0;
                    if(dst_last) begin dst_index<=0;ack_toggle<=request2;end
                    else dst_index<=dst_index+1'b1;
                end
            end else if(pending_read) begin pending_read<=0;output_valid<=1;end
            else if(pending) pending_read<=1;
        end
    end
endmodule
