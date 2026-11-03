// V16: same frame validation/CRC/overflow, optional synchronous byte payload.
module bt_packet_rx #(parameter integer TIMEOUT_CLKS=5000000,BYTE_PORT=0)(
 input wire clk,rst,input wire[7:0]byte_data,input wire byte_valid,byte_error,
 output wire frame_valid,input wire frame_ready,output wire[7:0]command,
 output wire[31:0]session,output wire[15:0]sequence,output wire[6:0]length,
 output wire[511:0]payload,output wire[31:0]malformed_count,timeout_count,overflow_count,
 input wire[5:0]payload_read_addr,output wire[7:0]payload_byte,output wire[95:0]payload_header);
 generate if(BYTE_PORT)begin:bytes
  assign payload=0;
  bt_packet_rx_bytes #(.TIMEOUT_CLKS(TIMEOUT_CLKS)) core(clk,rst,byte_data,byte_valid,byte_error,
   frame_valid,frame_ready,command,session,sequence,length,payload_header,payload_read_addr,payload_byte,
   malformed_count,timeout_count,overflow_count);
 end else begin:parallel_compat
  bt_packet_rx_parallel #(.TIMEOUT_CLKS(TIMEOUT_CLKS)) core(clk,rst,byte_data,byte_valid,byte_error,
   frame_valid,frame_ready,command,session,sequence,length,payload,malformed_count,timeout_count,overflow_count);
  assign payload_header=payload[95:0];assign payload_byte=payload[payload_read_addr*8+:8];
 end endgenerate
endmodule

// Bounded HDLC-like frame receiver. Output slot is immutable while stalled.
module bt_packet_rx_parallel #(parameter integer TIMEOUT_CLKS=5000000)(
    input wire clk, input wire rst,
    input wire [7:0] byte_data, input wire byte_valid, input wire byte_error,
    output reg frame_valid, input wire frame_ready,
    output reg [7:0] command, output reg [31:0] session,
    output reg [15:0] sequence, output reg [6:0] length,
    output reg [511:0] payload,
    output reg [31:0] malformed_count, timeout_count, overflow_count
);
    reg active, escaped, discard;
    reg [6:0] count;
    localparam integer TIMER_W=(TIMEOUT_CLKS>1) ? $clog2(TIMEOUT_CLKS) : 1;
    reg [TIMER_W-1:0] timer;
    wire [5:0] payload_index=count[5:0]-6'd10;
    reg [7:0] header_version, header_command;
    reg [31:0] header_session;
    reg [15:0] header_sequence, header_length, crc, received_crc;
    reg [511:0] buffer;
    wire [7:0] payload_end={1'b0,header_length[6:0]}+8'd10;
    wire [7:0] decoded=escaped ? (byte_data ^ 8'h20) : byte_data;
    function [15:0] crc_next;
        input [15:0] previous;
        input [7:0] value;
        integer i;
        reg [15:0] c;
        begin
            c=previous ^ {value,8'b0};
            for(i=0;i<8;i=i+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_next=c;
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            active<=0; escaped<=0; discard<=0; count<=0; timer<=0;
            frame_valid<=0; command<=0; session<=0; sequence<=0; length<=0; payload<=0;
            malformed_count<=0; timeout_count<=0; overflow_count<=0;
            header_version<=0; header_command<=0; header_session<=0;
            header_sequence<=0; header_length<=0; crc<=16'hffff; received_crc<=0; buffer<=0;
        end else begin
            if(frame_valid && frame_ready) frame_valid<=0;
            if(byte_error) begin
                active<=0; escaped<=0; count<=0; timer<=0;
            end else if(byte_valid) begin
                timer<=0;
                if(byte_data==8'h7e) begin
                    if(active && (count!=0 || escaped || discard)) begin
                        if(discard || escaped || count<12 || header_version!=1 ||
                           header_length>64 || {1'b0,count}!=payload_end+8'd2 || received_crc!=crc)
                            malformed_count<=malformed_count+1'b1;
                        else if(frame_valid && !frame_ready) overflow_count<=overflow_count+1'b1;
                        else begin
                            frame_valid<=1; command<=header_command; session<=header_session;
                            sequence<=header_sequence; length<=header_length[6:0]; payload<=buffer;
                        end
                    end
                    active<=1; escaped<=0; discard<=0; count<=0;
                    crc<=16'hffff; received_crc<=0; header_length<=0; buffer<=0;
                end else if(active && !discard) begin
                    if(!escaped && byte_data==8'h7d) escaped<=1;
                    else if(escaped && byte_data!=8'h5d && byte_data!=8'h5e) begin
                        escaped<=0; discard<=1;
                    end else begin
                        escaped<=0;
                        if(count>=76) discard<=1;
                        else begin
                            count<=count+1'b1;
                            if(count<10 || {1'b0,count}<payload_end) crc<=crc_next(crc,decoded);
                            case(count)
                                0: header_version<=decoded;
                                1: header_command<=decoded;
                                2: header_session[7:0]<=decoded;
                                3: header_session[15:8]<=decoded;
                                4: header_session[23:16]<=decoded;
                                5: header_session[31:24]<=decoded;
                                6: header_sequence[7:0]<=decoded;
                                7: header_sequence[15:8]<=decoded;
                                8: header_length[7:0]<=decoded;
                                9: begin
                                    header_length[15:8]<=decoded;
                                    if(decoded!=0 || header_length[7:0]>64) discard<=1;
                                end
                                default: begin
                                    if({1'b0,count}<payload_end) buffer[payload_index*8 +: 8]<=decoded;
                                    else if({1'b0,count}==payload_end) received_crc[7:0]<=decoded;
                                    else if({1'b0,count}==payload_end+8'd1) received_crc[15:8]<=decoded;
                                    else discard<=1;
                                end
                            endcase
                        end
                    end
                end
            end else if(active && (count!=0 || escaped || discard)) begin
                if(timer==TIMEOUT_CLKS-1) begin
                    timeout_count<=timeout_count+1'b1; active<=0; escaped<=0; count<=0; timer<=0;
                end else timer<=timer+1'b1;
            end
        end
    end
endmodule

// Bounded HDLC-like frame receiver. Output slot is immutable while stalled.
module bt_packet_rx_bytes #(parameter integer TIMEOUT_CLKS=5000000)(
    input wire clk, input wire rst,
    input wire [7:0] byte_data, input wire byte_valid, input wire byte_error,
    output reg frame_valid, input wire frame_ready,
    output reg [7:0] command, output reg [31:0] session,
    output reg [15:0] sequence, output reg [6:0] length,
    output reg [95:0] payload_header,
    input wire [5:0] payload_read_addr,output wire [7:0] payload_byte,
    output reg [31:0] malformed_count, timeout_count, overflow_count
);
    reg active, escaped, discard;
    reg [6:0] count;
    localparam integer TIMER_W=(TIMEOUT_CLKS>1) ? $clog2(TIMEOUT_CLKS) : 1;
    reg [TIMER_W-1:0] timer;
    wire [5:0] payload_index=count[5:0]-6'd10;
    reg [7:0] header_version, header_command;
    reg [31:0] header_session;
    reg [15:0] header_sequence, header_length, crc, received_crc;
    reg [95:0] header_buffer;
    reg capture_bank,published_bank;
    (* syn_ramstyle="block_ram" *)reg [7:0] payload_ram[0:127];
    reg[7:0] byte_q;reg[5:0] byte_addr_q;
    wire payload_write=!rst&&!byte_error&&byte_valid&&byte_data!=8'h7e&&active&&!discard&&
        (escaped ? (byte_data==8'h5d||byte_data==8'h5e) : byte_data!=8'h7d)&&
        count>=10&&count<76&&{1'b0,count}<payload_end;
    always @(posedge clk)begin
        byte_q<=payload_ram[{published_bank,payload_read_addr}];
        byte_addr_q<=payload_read_addr;
        if(payload_write)payload_ram[{capture_bank,payload_index}]<=decoded;
    end
    // Old receiver zero-filled every byte beyond the advertised length.
    // The RAM need not be reset: stale bytes are masked at the read boundary.
    assign payload_byte={1'b0,byte_addr_q}<length ? byte_q : 8'd0;
    wire [7:0] payload_end={1'b0,header_length[6:0]}+8'd10;
    wire [7:0] decoded=escaped ? (byte_data ^ 8'h20) : byte_data;
    function [15:0] crc_next;
        input [15:0] previous;
        input [7:0] value;
        integer i;
        reg [15:0] c;
        begin
            c=previous ^ {value,8'b0};
            for(i=0;i<8;i=i+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_next=c;
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            active<=0; escaped<=0; discard<=0; count<=0; timer<=0;
            frame_valid<=0; command<=0; session<=0; sequence<=0; length<=0; payload_header<=0;capture_bank<=0;published_bank<=1;
            malformed_count<=0; timeout_count<=0; overflow_count<=0;
            header_version<=0; header_command<=0; header_session<=0;
            header_sequence<=0; header_length<=0; crc<=16'hffff; received_crc<=0; header_buffer<=0;
        end else begin
            if(frame_valid && frame_ready) frame_valid<=0;
            if(byte_error) begin
                active<=0; escaped<=0; count<=0; timer<=0;
            end else if(byte_valid) begin
                timer<=0;
                if(byte_data==8'h7e) begin
                    if(active && (count!=0 || escaped || discard)) begin
                        if(discard || escaped || count<12 || header_version!=1 ||
                           header_length>64 || {1'b0,count}!=payload_end+8'd2 || received_crc!=crc)
                            malformed_count<=malformed_count+1'b1;
                        else if(frame_valid && !frame_ready) overflow_count<=overflow_count+1'b1;
                        else begin
                            frame_valid<=1; command<=header_command; session<=header_session;
                            sequence<=header_sequence; length<=header_length[6:0];payload_header<=header_buffer;
                            published_bank<=capture_bank;capture_bank<=!capture_bank;
                        end
                    end
                    active<=1; escaped<=0; discard<=0; count<=0;
                    crc<=16'hffff; received_crc<=0; header_length<=0; header_buffer<=0;
                end else if(active && !discard) begin
                    if(!escaped && byte_data==8'h7d) escaped<=1;
                    else if(escaped && byte_data!=8'h5d && byte_data!=8'h5e) begin
                        escaped<=0; discard<=1;
                    end else begin
                        escaped<=0;
                        if(count>=76) discard<=1;
                        else begin
                            count<=count+1'b1;
                            if(count<10 || {1'b0,count}<payload_end) crc<=crc_next(crc,decoded);
                            case(count)
                                0: header_version<=decoded;
                                1: header_command<=decoded;
                                2: header_session[7:0]<=decoded;
                                3: header_session[15:8]<=decoded;
                                4: header_session[23:16]<=decoded;
                                5: header_session[31:24]<=decoded;
                                6: header_sequence[7:0]<=decoded;
                                7: header_sequence[15:8]<=decoded;
                                8: header_length[7:0]<=decoded;
                                9: begin
                                    header_length[15:8]<=decoded;
                                    if(decoded!=0 || header_length[7:0]>64) discard<=1;
                                end
                                default: begin
                                    if({1'b0,count}<payload_end)begin
                                        if(payload_index<12)header_buffer[payload_index*8+:8]<=decoded;
                                    end
                                    else if({1'b0,count}==payload_end) received_crc[7:0]<=decoded;
                                    else if({1'b0,count}==payload_end+8'd1) received_crc[15:8]<=decoded;
                                    else discard<=1;
                                end
                            endcase
                        end
                    end
                end
            end else if(active && (count!=0 || escaped || discard)) begin
                if(timer==TIMEOUT_CLKS-1) begin
                    timeout_count<=timeout_count+1'b1; active<=0; escaped<=0; count<=0; timer<=0;
                end else timer<=timer+1'b1;
            end
        end
    end
endmodule
