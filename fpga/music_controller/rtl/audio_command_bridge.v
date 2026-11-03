// One command and its held reply cross domains without backpressuring audio ACKs.
module audio_command_bridge(
    input wire client_clk,audio_clk,arst,
    input wire client_valid,
    output wire client_ready,
    input wire [4:0] client_addr,
    input wire [31:0] client_value,
    input wire [15:0] client_tag,
    output wire reply_valid,
    input wire reply_ready,
    output reg [4:0] reply_addr,
    output reg [31:0] reply_value,
    output reg [15:0] reply_tag,
    output reg reply_accepted,reply_applied,
    output wire host_valid,
    input wire host_ready,
    output reg [4:0] host_addr,
    output reg [31:0] host_value,
    input wire ack_valid,ack_source,
    input wire [4:0] ack_addr,
    input wire [31:0] ack_value,
    input wire ack_accepted,ack_applied,
    output reg audio_protocol_error
);
    wire client_rst,audio_rst;
    audio_transport_reset client_reset(client_clk,arst,client_rst);
    audio_transport_reset audio_reset(audio_clk,arst,audio_rst);
    reg request_toggle,ack_toggle,completed_toggle;
    (* async_reg = "true" *) reg ack_sync1,ack_sync2,request_sync1,request_sync2;
    reg [4:0] held_addr,held_reply_addr;
    reg [31:0] held_value,held_reply_value;
    reg [15:0] held_tag,audio_tag,held_reply_tag;
    reg held_reply_accepted,held_reply_applied,output_valid;
    reg [1:0] audio_state;
    localparam IDLE=0,SEND=1,WAIT_ACK=2;
    assign client_ready=!client_rst&&!output_valid&&request_toggle==completed_toggle;
    assign reply_valid=output_valid&&!client_rst;
    assign host_valid=!audio_rst&&audio_state==SEND;
    always @(posedge client_clk or posedge arst) begin
        if(arst) begin
            request_toggle<=0;completed_toggle<=0;ack_sync1<=0;ack_sync2<=0;
            held_addr<=0;held_value<=0;held_tag<=0;output_valid<=0;
            reply_addr<=0;reply_value<=0;reply_tag<=0;reply_accepted<=0;reply_applied<=0;
        end else if(client_rst) begin
            request_toggle<=0;completed_toggle<=0;ack_sync1<=0;ack_sync2<=0;
            held_addr<=0;held_value<=0;held_tag<=0;output_valid<=0;
            reply_addr<=0;reply_value<=0;reply_tag<=0;reply_accepted<=0;reply_applied<=0;
        end else begin
            ack_sync1<=ack_toggle;ack_sync2<=ack_sync1;
            if(output_valid&&reply_ready) output_valid<=0;
            if(client_valid&&client_ready) begin
                held_addr<=client_addr;held_value<=client_value;held_tag<=client_tag;
                request_toggle<=!request_toggle;
            end
            if(ack_sync2!=completed_toggle) begin
                reply_addr<=held_reply_addr;reply_value<=held_reply_value;reply_tag<=held_reply_tag;
                reply_accepted<=held_reply_accepted;reply_applied<=held_reply_applied;
                output_valid<=1;completed_toggle<=ack_sync2;
            end
        end
    end
    always @(posedge audio_clk or posedge arst) begin
        if(arst) begin
            request_sync1<=0;request_sync2<=0;ack_toggle<=0;audio_state<=IDLE;
            host_addr<=0;host_value<=0;audio_tag<=0;audio_protocol_error<=0;
            held_reply_addr<=0;held_reply_value<=0;held_reply_tag<=0;
            held_reply_accepted<=0;held_reply_applied<=0;
        end else if(audio_rst) begin
            request_sync1<=0;request_sync2<=0;ack_toggle<=0;audio_state<=IDLE;
            host_addr<=0;host_value<=0;audio_tag<=0;audio_protocol_error<=0;
            held_reply_addr<=0;held_reply_value<=0;held_reply_tag<=0;
            held_reply_accepted<=0;held_reply_applied<=0;
        end else begin
            request_sync1<=request_toggle;request_sync2<=request_sync1;
            case(audio_state)
                IDLE:if(request_sync2!=ack_toggle) begin
                    host_addr<=held_addr;host_value<=held_value;audio_tag<=held_tag;audio_state<=SEND;
                end
                SEND:if(host_ready) audio_state<=WAIT_ACK;
                default:begin end
            endcase
            if(ack_valid&&ack_source) begin
                if((audio_state==WAIT_ACK||(audio_state==SEND&&host_ready))&&ack_addr==host_addr) begin
                    held_reply_addr<=ack_addr;held_reply_value<=ack_value;held_reply_tag<=audio_tag;
                    held_reply_accepted<=ack_accepted;held_reply_applied<=ack_applied;
                    ack_toggle<=request_sync2;audio_state<=IDLE;
                end else audio_protocol_error<=1;
            end
        end
    end
endmodule
