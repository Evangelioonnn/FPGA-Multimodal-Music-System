// A transaction retains its owner through the backend ACK, including an
// illegal-value rejection. Round robin prevents panel/host starvation.
module refinement_config_arbiter(
    input wire clk,rst,
    input wire local_valid,output wire local_ready,input wire [4:0] local_addr,input wire [31:0] local_value,
    input wire remote_valid,output wire remote_ready,input wire [4:0] remote_addr,input wire [31:0] remote_value,
    output wire backend_valid,input wire backend_ready,output wire [4:0] backend_addr,output wire [31:0] backend_value,
    input wire ack_valid,input wire [4:0] ack_addr,input wire [31:0] ack_value,input wire ack_accepted,ack_applied,
    output wire remote_ack_valid,output wire [4:0] remote_ack_addr,output wire [31:0] remote_ack_value,
    output wire remote_ack_accepted,remote_ack_applied,output reg protocol_error
);
    reg busy,owner,prefer_remote;reg [4:0] pending_addr;
    wire choose_remote=remote_valid && (!local_valid || prefer_remote);
    wire sent=backend_valid && backend_ready;
    wire ack_owner=busy ? owner : choose_remote;
    wire ack_expected=busy || sent;
    wire address_match=ack_addr==(busy ? pending_addr : backend_addr);
    assign backend_valid=!rst && !busy && (local_valid || remote_valid);
    assign backend_addr=choose_remote ? remote_addr : local_addr;
    assign backend_value=choose_remote ? remote_value : local_value;
    assign local_ready=backend_valid && !choose_remote && backend_ready;
    assign remote_ready=backend_valid && choose_remote && backend_ready;
    assign remote_ack_valid=ack_valid && ack_expected && ack_owner && address_match;
    assign remote_ack_addr=ack_addr;assign remote_ack_value=ack_value;
    assign remote_ack_accepted=ack_accepted;assign remote_ack_applied=ack_applied;
    always @(posedge clk) begin
        if(rst) begin busy<=0;owner<=0;prefer_remote<=0;pending_addr<=0;protocol_error<=0;end
        else begin
            if(sent) begin busy<=1;owner<=choose_remote;pending_addr<=backend_addr;prefer_remote<=!choose_remote;end
            if(ack_valid) begin
                if(ack_expected && address_match) busy<=0;
                else protocol_error<=1;
            end
        end
    end
endmodule
