// OV5640 16-bit sub-address read. Open drain; 7-bit slave address is 0x3c.
// Write 78/reg_hi/reg_lo, repeated START, read 79/value, master NACK, STOP.
module sccb_read #(
    parameter CLK_HZ=50000000, BUS_HZ=100000, TIMEOUT_CYCLES=100000
)(
    input wire clk,rst,start,
    input wire [15:0] register_address,
    input wire scl_in,sda_in,
    output reg scl_low,sda_low,busy,done,
    output reg [7:0] value,
    output reg [1:0] error,
    output reg [3:0] nack_mask
);
    localparam QUARTER=CLK_HZ/(BUS_HZ*4);
    reg [31:0] divider,stretch_count;
    reg [4:0] state;
    reg [23:0] packet;
    reg [7:0] received;
    reg [2:0] bit_index;
    reg [1:0] byte_index;
    (* ASYNC_REG="TRUE" *) reg scl1,scl2,sda1,sda2;
    always @(posedge clk) begin
        if(rst)begin
            divider<=0;stretch_count<=0;state<=0;packet<=0;received<=0;
            bit_index<=0;byte_index<=0;scl_low<=0;sda_low<=0;busy<=0;done<=0;
            value<=0;error<=0;nack_mask<=0;scl1<=1;scl2<=1;sda1<=1;sda2<=1;
        end else begin
            scl1<=scl_in;scl2<=scl1;sda1<=sda_in;sda2<=sda1;done<=0;
            if(busy)begin
                if(divider==QUARTER-1)divider<=0;else divider<=divider+1'b1;
                if(!scl_low && !scl2)stretch_count<=stretch_count+1'b1;else stretch_count<=0;
            end else begin divider<=0;stretch_count<=0;end
            if(busy && stretch_count>=TIMEOUT_CYCLES-1)begin
                scl_low<=0;sda_low<=0;busy<=0;done<=1;error<=2;state<=0;
            end else if(!busy)begin
                if(start)begin
                    value<=0;received<=0;error<=0;nack_mask<=0;
                    packet<={8'h78,register_address};bit_index<=0;byte_index<=0;
                    if(!scl2 || !sda2)begin error<=3;done<=1;end
                    else begin busy<=1;state<=1;end
                end
            end else if(divider==QUARTER-1)begin
                case(state)
                    1:begin sda_low<=1;state<=2;end
                    2:begin scl_low<=1;state<=3;end
                    3:begin sda_low<=!packet[23];state<=4;end
                    4:begin scl_low<=0;state<=5;end
                    5:if(scl2)state<=6;
                    6:begin
                        scl_low<=1;packet<={packet[22:0],1'b0};
                        if(bit_index==7)begin bit_index<=0;state<=7;end
                        else begin bit_index<=bit_index+1'b1;state<=3;end
                    end
                    7:begin sda_low<=0;state<=8;end
                    8:begin scl_low<=0;state<=9;end
                    9:if(scl2)begin
                        if(sda2)begin error<=1;nack_mask[byte_index]<=1;end
                        state<=10;
                    end
                    10:begin
                        scl_low<=1;
                        if(error!=0)state<=23;
                        else if(byte_index==3)begin bit_index<=0;state<=17;end
                        else if(byte_index==2)state<=11;
                        else begin byte_index<=byte_index+1'b1;state<=3;end
                    end
                    // Repeated START: release SDA while SCL low, then raise SCL.
                    11:begin sda_low<=0;state<=12;end
                    12:begin scl_low<=0;state<=13;end
                    13:if(scl2)state<=14;
                    14:begin sda_low<=1;state<=15;end
                    15:begin scl_low<=1;packet<=24'h790000;byte_index<=3;state<=3;end
                    // Receive one byte. Master leaves SDA released for final NACK.
                    17:begin sda_low<=0;state<=18;end
                    18:begin scl_low<=0;state<=19;end
                    19:if(scl2)begin received<={received[6:0],sda2};state<=20;end
                    20:begin
                        scl_low<=1;
                        if(bit_index==7)begin value<=received;state<=21;end
                        else begin bit_index<=bit_index+1'b1;state<=17;end
                    end
                    21:begin sda_low<=0;state<=22;end
                    22:begin scl_low<=0;state<=27;end
                    27:if(scl2)state<=28;
                    28:begin scl_low<=1;state<=23;end
                    23:begin scl_low<=1;sda_low<=1;state<=24;end
                    24:begin scl_low<=0;state<=25;end
                    25:if(scl2)begin sda_low<=0;state<=26;end
                    26:begin busy<=0;done<=1;state<=0;end
                    default:begin busy<=0;done<=1;error<=3;state<=0;scl_low<=0;sda_low<=0;end
                endcase
            end
        end
    end
endmodule
