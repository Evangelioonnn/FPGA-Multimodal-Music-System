// C connects this in the observer/pixel domain. Publish only complete LU1 frames.
module session_ui_unpacker(
    input wire clk,rst,input wire valid,output wire ready,input wire [31:0] data,
    input wire [4:0] index,input wire first,last,session_start,
    output reg updated,output reg [639:0] ui,
    output reg [31:0] sequence,drops,output reg new_session,protocol_error
);
    reg receiving;reg [4:0] expected;
    reg [639:0] pending;
    reg [31:0] pending_sequence,pending_drops;reg session_pending;
    assign ready=!rst;
    always @(posedge clk) begin
        if(rst) begin receiving<=0;expected<=0;pending<=0;pending_sequence<=0;pending_drops<=0;
            session_pending<=0;updated<=0;ui<=0;sequence<=0;drops<=0;new_session<=0;protocol_error<=0;end
        else begin
            updated<=0;new_session<=0;
            if(valid) begin
                if(first) begin
                    receiving<=0;expected<=0;
                    if(index==0 && !last && data==32'h4c550117) begin
                        receiving<=1;expected<=1;session_pending<=session_start;
                    end else protocol_error<=1;
                end else if(!receiving || index!=expected || session_start || last!=(index==22)) begin
                    receiving<=0;protocol_error<=1;
                end else begin
                    expected<=expected+1'b1;
                    if(index==1) pending_sequence<=data;
                    else if(index==2) pending_drops<=data;
                    else pending[(index-3)*32+:32]<=data;
                    if(last) begin
                        ui<={data,pending[607:0]};sequence<=pending_sequence;drops<=pending_drops;
                        updated<=1;new_session<=session_pending;receiving<=0;
                    end
                end
            end
        end
    end
endmodule
