module probe_uart_tx #(parameter CLK_HZ=50000000,BAUD=115200)(
    input wire clk,rst,valid,
    input wire [7:0] data,
    output wire ready,
    output reg tx
);
    localparam BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
    reg [31:0] count;
    reg [3:0] bit_index;
    reg [9:0] bits;
    reg busy;
    assign ready=!busy;
    always @(posedge clk)begin
        if(rst)begin tx<=1;count<=0;bit_index<=0;bits<=10'h3ff;busy<=0;end
        else if(!busy)begin
            tx<=1;
            if(valid)begin bits<={1'b1,data,1'b0};tx<=0;busy<=1;count<=0;bit_index<=0;end
        end else if(count==BIT_CYCLES-1)begin
            count<=0;
            if(bit_index==9)begin tx<=1;busy<=0;end
            else begin bits<={1'b1,bits[9:1]};tx<=bits[1];bit_index<=bit_index+1'b1;end
        end else count<=count+1'b1;
    end
endmodule

// One immutable ASCII snapshot per ID attempt; no dependency on C's UART protocol.
module probe_uart_report #(parameter CLK_HZ=50000000,BAUD=115200)(
    input wire clk,rst,report_valid,
    input wire [15:0] chip_id,sequence_id,
    input wire id_ok,
    input wire [1:0] error,
    input wire [3:0] nack_mask,
    output wire tx,
    output reg overrun
);
    function [7:0] hexchar;
        input [3:0] nibble;
        begin hexchar=(nibble<10 ? 8'd48+nibble : 8'd65+nibble-10);end
    endfunction
    // "OV ID=5640 OK=1 E=0 N=0 S=0001\r\n" (32 bytes).
    localparam LENGTH=32;
    reg [LENGTH*8-1:0] message;
    reg [5:0] index;
    reg sending;
    wire ready;
    wire [7:0] byte_out=message[LENGTH*8-1-:8];
    probe_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(clk,rst,sending,byte_out,ready,tx);
    always @(posedge clk)begin
        if(rst)begin message<=0;index<=0;sending<=0;overrun<=0;end
        else begin
            if(report_valid)begin
                if(sending)overrun<=1;
                else begin
                    message<={"OV ID=",hexchar(chip_id[15:12]),hexchar(chip_id[11:8]),
                        hexchar(chip_id[7:4]),hexchar(chip_id[3:0])," OK=",(id_ok ? 8'h31:8'h30),
                        " E=",hexchar({2'b0,error})," N=",hexchar(nack_mask)," S=",
                        hexchar(sequence_id[15:12]),hexchar(sequence_id[11:8]),
                        hexchar(sequence_id[7:4]),hexchar(sequence_id[3:0]),8'h0d,8'h0a};
                    index<=0;sending<=1;
                end
            end
            if(sending && ready)begin
                message<={message[LENGTH*8-9:0],8'b0};
                if(index==LENGTH-1)sending<=0;else index<=index+1'b1;
            end
        end
    end
endmodule
