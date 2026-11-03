// Versioned 8-bit client addresses. One outstanding transaction, tagged by CDC.
// UI actions have their own ACK; legacy audio transactions retain arbiter ownership.
module session_dispatcher(
    input wire clk,rst,
    input wire host_valid,output wire host_ready,input wire [7:0] host_addr,input wire [31:0] host_value,
    output reg ack_valid,output reg [7:0] ack_addr,output reg [31:0] ack_value,
    output reg ack_accepted,ack_applied,output reg [7:0] ack_reason,
    output wire audio_valid,input wire audio_ready,output wire [4:0] audio_addr,output wire [31:0] audio_value,
    input wire audio_ack_valid,input wire [4:0] audio_ack_addr,input wire [31:0] audio_ack_value,
    input wire audio_ack_accepted,audio_ack_applied,
    output wire ui_valid,input wire ui_ready,output wire [7:0] ui_addr,output wire [31:0] ui_value,
    input wire ui_ack,ui_accepted,ui_applied,input wire [7:0] ui_reason,
    output reg menu_drums_commit,output reg protocol_error
);
    localparam IDLE=0,AUDIO_SEND=1,AUDIO_WAIT=2,UI_SEND=3,UI_WAIT=4,REJECT=5;
    reg [2:0] state;reg [7:0] address;reg [31:0] value;
    wire drums=address==0 && value==6;
    assign host_ready=!rst && state==IDLE;
    assign audio_valid=!rst && state==AUDIO_SEND;
    assign audio_addr=address[4:0];assign audio_value=drums ? 32'd0 : value;
    assign ui_valid=!rst && state==UI_SEND;
    assign ui_addr=address;assign ui_value=value;
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;address<=0;value<=0;ack_valid<=0;ack_addr<=0;ack_value<=0;
            ack_accepted<=0;ack_applied<=0;ack_reason<=0;menu_drums_commit<=0;protocol_error<=0;end
        else begin
            ack_valid<=0;menu_drums_commit<=0;
            case(state)
                IDLE:if(host_valid) begin
                    address<=host_addr;value<=host_value;
                    state<=host_addr<32 ? AUDIO_SEND : host_addr<48 ? UI_SEND : REJECT;
                end
                AUDIO_SEND:if(audio_ready) state<=AUDIO_WAIT;
                UI_SEND:if(ui_ready) state<=UI_WAIT;
                REJECT:begin
                    ack_valid<=1;ack_addr<=address;ack_value<=value;
                    ack_accepted<=0;ack_applied<=0;ack_reason<=1;state<=IDLE;
                end
                default:begin end
            endcase
            if(audio_ack_valid) begin
                if((state==AUDIO_WAIT||(state==AUDIO_SEND&&audio_ready)) && audio_ack_addr==address[4:0]) begin
                    ack_valid<=1;ack_addr<=address;ack_value<=drums ? value : audio_ack_value;
                    ack_accepted<=audio_ack_accepted;ack_applied<=audio_ack_applied;
                    ack_reason<=audio_ack_accepted ? 8'd0 : 8'd6;state<=IDLE;
                    if(drums && audio_ack_accepted && audio_ack_applied) menu_drums_commit<=1;
                end else protocol_error<=1;
            end
            if(ui_ack) begin
                if(state==UI_WAIT || (state==UI_SEND&&ui_ready)) begin
                    ack_valid<=1;ack_addr<=address;ack_value<=value;
                    ack_accepted<=ui_accepted;ack_applied<=ui_applied;ack_reason<=ui_reason;state<=IDLE;
                end else protocol_error<=1;
            end
        end
    end
endmodule
