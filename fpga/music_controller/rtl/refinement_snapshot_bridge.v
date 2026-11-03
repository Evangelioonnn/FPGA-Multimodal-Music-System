// A frozen narrow RAM bank crosses whole observation records, never live fields.
module refinement_snapshot_bridge #(
    parameter SNAPSHOT_W=2368,KEYS=25
)(
    input wire src_clk,dst_clk,arst,
    input wire src_snapshot_valid,
    input wire [SNAPSHOT_W-1:0] src_snapshot_data,
    input wire [255:0] src_snapshot_extension,
    input wire [KEYS-1:0] src_snapshot_keys,
    input wire [127:0] src_capabilities,
    output wire src_busy,
    output reg [31:0] src_drop_count,
    output wire dst_valid,
    input wire dst_ready,
    output wire [63:0] dst_data,
    output reg [5:0] dst_word_index,
    output wire dst_first,dst_last,dst_session_start
);
    localparam BASE_WORDS=(SNAPSHOT_W+63)/64;
    localparam RECORD_WORDS=BASE_WORDS+9;
    localparam HALFWORDS=RECORD_WORDS*4;
    localparam [7:0] BASE_COUNT=BASE_WORDS;
    localparam [7:0] RECORD_COUNT=RECORD_WORDS;
    localparam [7:0] KEY_COUNT=KEYS;
    wire src_rst,dst_rst;
    audio_transport_reset source_reset(src_clk,arst,src_rst);
    audio_transport_reset destination_reset(dst_clk,arst,dst_rst);
    reg [15:0] record_ram[0:255];
    reg copying,request_toggle,ack_toggle;
    reg [7:0] copy_address;
    reg [31:0] sequence_count,record_sequence,record_drop_count;
    (* async_reg = "true" *) reg ack_sync1,ack_sync2,request_sync1,request_sync2;
    wire bank_owned=request_toggle!=ack_sync2;
    assign src_busy=src_rst||copying||bank_owned;
    wire [BASE_WORDS*64-1:0] base_padded={{(BASE_WORDS*64-SNAPSHOT_W){1'b0}},src_snapshot_data};
    wire [63:0] keys_padded={{(64-KEYS){1'b0}},src_snapshot_keys};
    wire [63:0] header={16'h4c52,8'd1,RECORD_COUNT,BASE_COUNT,8'd4,KEY_COUNT,8'd0};
    wire [RECORD_WORDS*64-1:0] source_record={keys_padded,src_snapshot_extension,
        base_padded,src_capabilities,record_drop_count,record_sequence,header};
    always @(posedge src_clk) begin
        if(copying&&!src_snapshot_valid&&!src_rst)
            record_ram[copy_address]<=source_record[copy_address*16+:16];
    end
    always @(posedge src_clk or posedge arst) begin
        if(arst) begin
            copying<=0;copy_address<=0;request_toggle<=0;
            ack_sync1<=0;ack_sync2<=0;sequence_count<=0;
            record_sequence<=0;record_drop_count<=0;src_drop_count<=0;
        end else if(src_rst) begin
            copying<=0;copy_address<=0;request_toggle<=0;
            ack_sync1<=0;ack_sync2<=0;sequence_count<=0;
            record_sequence<=0;record_drop_count<=0;src_drop_count<=0;
        end else begin
            ack_sync1<=ack_toggle;ack_sync2<=ack_sync1;
            if(src_snapshot_valid) begin
                sequence_count<=sequence_count+1'b1;
                if(bank_owned) src_drop_count<=src_drop_count+1'b1;
                else begin
                    copying<=1;copy_address<=0;record_sequence<=sequence_count;
                    if(copying) begin
                        src_drop_count<=src_drop_count+1'b1;
                        record_drop_count<=src_drop_count+1'b1;
                    end else record_drop_count<=src_drop_count;
                end
            end else if(copying) begin
                if(copy_address==HALFWORDS-1) begin
                    copying<=0;request_toggle<=!request_toggle;
                end else copy_address<=copy_address+1'b1;
            end
        end
    end
    reg [2:0] read_phase;
    reg [15:0] read_halfword;
    reg [63:0] assembled_word;
    reg output_valid,first_session;
    wire record_pending=request_sync2!=ack_toggle;
    wire read_enable=!dst_rst&&record_pending&&!output_valid&&read_phase<4;
    wire [7:0] read_address={dst_word_index,2'b00}+read_phase[1:0];
    always @(posedge dst_clk) begin
        if(read_enable) read_halfword<=record_ram[read_address];
    end
    assign dst_valid=output_valid&&!dst_rst;
    assign dst_data=assembled_word;
    assign dst_first=dst_word_index==0;
    assign dst_last=dst_word_index==RECORD_WORDS-1;
    assign dst_session_start=first_session&&dst_first;
    always @(posedge dst_clk or posedge arst) begin
        if(arst) begin
            request_sync1<=0;request_sync2<=0;ack_toggle<=0;
            read_phase<=0;assembled_word<=0;output_valid<=0;dst_word_index<=0;first_session<=1;
        end else if(dst_rst) begin
            request_sync1<=0;request_sync2<=0;ack_toggle<=0;
            read_phase<=0;assembled_word<=0;output_valid<=0;dst_word_index<=0;first_session<=1;
        end else begin
            request_sync1<=request_toggle;request_sync2<=request_sync1;
            if(output_valid) begin
                if(dst_ready) begin
                    output_valid<=0;read_phase<=0;
                    if(dst_last) begin
                        ack_toggle<=request_sync2;dst_word_index<=0;
                    end else dst_word_index<=dst_word_index+1'b1;
                    if(dst_first) first_session<=0;
                end
            end else if(record_pending) begin
                case(read_phase)
                    1:assembled_word[15:0]<=read_halfword;
                    2:assembled_word[31:16]<=read_halfword;
                    3:assembled_word[47:32]<=read_halfword;
                    4:begin assembled_word[63:48]<=read_halfword;output_valid<=1;end
                    default:begin end
                endcase
                if(read_phase<4) read_phase<=read_phase+1'b1;
            end
        end
    end
endmodule
