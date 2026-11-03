// Independent sensor setup for offline material capture, not an inference core.
// Register LUT: Sipeed TangMega-60K-example, pinned in references/; Apache-2.0.
module camera_capture_init #(
    parameter CLK_HZ=50000000, BUS_HZ=100000, TIMEOUT_CYCLES=100000,
    parameter WIDTH=320, HEIGHT=240, TEST_BARS=0,
    parameter POWER_CYCLES=CLK_HZ/100, RESET_CYCLES=CLK_HZ/200,
    parameter BOOT_CYCLES=CLK_HZ/20, WARMUP_CYCLES=CLK_HZ,
    parameter GAP_CYCLES=CLK_HZ/100000
)(
    input wire clk,rst,scl_in,sda_in,
    output wire scl_low,sda_low,
    output reg reset_n,pwdn,ready,
    output reg [3:0] error,nack_mask,
    output reg [15:0] progress
);
    reg [3:0] state;
    reg [31:0] count;
    reg [9:0] index;
    reg [2:0] read_index;
    reg read_start,write_start;
    wire [31:0] lut;
    // Keep the upstream analog/ISP settings. Scale its 4:3 window to QVGA.
    lut_ov5640_rgb565 #(.HActive(WIDTH),.VActive(HEIGHT),
        .HTotal(1896),.VTotal(984),.USE_4vs3_frame("true")) rom(index,lut);
    // Slower system divider than the upstream 60fps profile; not a measured fps.
    wire [31:0] write_word=(index==202) ? 32'h78303541 :
        (index==242) ? (TEST_BARS ? 32'h78503d80 : 32'h78503d00) : lut;
    reg [15:0] read_address;
    reg [7:0] expected;
    localparam [15:0] W=WIDTH,H=HEIGHT;
    always @* begin
        case(read_index)
            0:begin read_address=16'h300a;expected=8'h56;end
            1:begin read_address=16'h300b;expected=8'h40;end
            2:begin read_address=16'h3808;expected=W[15:8];end
            3:begin read_address=16'h3809;expected=W[7:0];end
            4:begin read_address=16'h380a;expected=H[15:8];end
            5:begin read_address=16'h380b;expected=H[7:0];end
            6:begin read_address=16'h4300;expected=8'h61;end
            default:begin read_address=16'h503d;expected=TEST_BARS ? 8'h80:8'h00;end
        endcase
    end
    wire rd_scl,rd_sda,rd_busy,rd_done,wr_scl,wr_sda,wr_busy,wr_done;
    wire [7:0] read_value;
    wire [1:0] rd_error,wr_error;
    wire [3:0] rd_nack,wr_nack;
    assign scl_low=rd_scl|wr_scl;
    assign sda_low=rd_sda|wr_sda;
    sccb_read #(.CLK_HZ(CLK_HZ),.BUS_HZ(BUS_HZ),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) reader(
        clk,rst,read_start,read_address,scl_in,sda_in,rd_scl,rd_sda,rd_busy,rd_done,
        read_value,rd_error,rd_nack);
    sccb_write #(.CLK_HZ(CLK_HZ),.BUS_HZ(BUS_HZ),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) writer(
        clk,rst,write_start,write_word[31:24],write_word[7:0],write_word[23:8],
        scl_in,sda_in,wr_scl,wr_sda,wr_busy,wr_done,wr_error,wr_nack);
    always @(posedge clk)begin
        if(rst)begin
            state<=0;count<=0;index<=0;read_index<=0;
            read_start<=0;write_start<=0;reset_n<=0;pwdn<=1;ready<=0;
            error<=0;nack_mask<=0;progress<=16'hffff;
        end else begin
            read_start<=0;write_start<=0;
            case(state)
                0:if(count==POWER_CYCLES-1)begin count<=0;pwdn<=0;state<=1;end
                  else count<=count+1'b1;
                1:if(count==RESET_CYCLES-1)begin count<=0;reset_n<=1;state<=2;end
                  else count<=count+1'b1;
                2:if(count==BOOT_CYCLES-1)begin count<=0;state<=3;end
                  else count<=count+1'b1;
                3:begin read_start<=1;progress<=16'h8000+read_index;state<=4;end
                4:if(rd_done)begin
                    if(rd_error!=0)begin error<={2'b0,rd_error};nack_mask<=rd_nack;state<=15;end
                    else if(read_value!=expected)begin
                        error<=(read_index<2) ? 4'd4:4'd5;state<=15;
                    end else if(read_index==0)begin read_index<=1;state<=3;end
                    else if(read_index==1)begin index<=0;state<=5;end
                    else if(read_index==7)begin count<=0;state<=8;end
                    else begin read_index<=read_index+1'b1;state<=3;end
                end
                5:begin write_start<=1;progress<={6'b0,index};state<=6;end
                6:if(wr_done)begin
                    if(wr_error!=0)begin error<={2'b0,wr_error};nack_mask<=wr_nack;state<=15;end
                    else if(index==247)begin read_index<=2;state<=3;end
                    else begin index<=index+1'b1;count<=0;state<=7;end
                end
                7:if(count==GAP_CYCLES-1)begin count<=0;state<=5;end
                  else count<=count+1'b1;
                8:if(count==WARMUP_CYCLES-1)begin ready<=1;progress<=16'hffff;state<=9;end
                  else count<=count+1'b1;
                9:state<=9;
                default:state<=15; // Fail closed; reset required after a setup error.
            endcase
        end
    end
endmodule
