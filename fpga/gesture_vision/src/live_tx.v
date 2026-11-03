// P20CI02 header64 + result64 + optional graypreview/gray64/RGB56532BE.
// All descriptors are latched at start; CRC covers header[8:64]+whole payload.
module p20_crop_live_tx #(parameter CLK_HZ=74250000,BAUD=115200,WIDTH=160,HEIGHT=120,MODEL=64,COLOR=32,ADDR_BITS=15)(
    input wire clk,rst,start,image,input wire [15:0] flags,progress,
    input wire [7:0] error,nack,input wire [31:0] sequence_id,frame_id,
    input wire [8:0] roi_x,input wire [7:0] roi_y,input wire [8:0] roi_side,
    input wire [511:0] result_payload,
    output wire [ADDR_BITS-1:0] read_address,input wire [7:0] read_data,input wire read_valid,
    output wire tx,busy,output reg done);
    localparam PN=WIDTH*HEIGHT,MN=MODEL*MODEL,CN=COLOR*COLOR*2,PIXELS=PN+MN+CN;
    reg [3:0] state;reg [6:0] header_index,result_index;reg [1:0] crc_index;
    reg [ADDR_BITS-1:0] index;reg [7:0] byte_value;
    reg [511:0] header,result_latched;reg is_image;reg [31:0] crc;
    assign read_address=index;assign busy=state!=0;
    wire valid=state==1 || state==3 || state==4 || state==6;
    wire [31:0] final_crc=~crc;
    wire [7:0] out_byte=state==1 ? header[511-:8]:state==3 ? result_latched[511-:8]:state==4 ? byte_value:
        crc_index==0 ? final_crc[7:0]:crc_index==1 ? final_crc[15:8]:crc_index==2 ? final_crc[23:16]:final_crc[31:24];
    wire ready;
    probe_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(clk,rst,valid,out_byte,ready,tx);
    function [31:0] crc_byte;input [31:0] previous;input [7:0] data;reg [31:0] temp;integer i;
        begin temp=previous^{24'b0,data};for(i=0;i<8;i=i+1)temp=temp[0] ? (temp>>1)^32'hedb88320:temp>>1;crc_byte=temp;end
    endfunction
    function [15:0] le16;input [15:0] a;begin le16={a[7:0],a[15:8]};end endfunction
    function [31:0] le32;input [31:0] a;begin le32={a[7:0],a[15:8],a[23:16],a[31:24]};end endfunction
    always @(posedge clk)begin
        if(rst)begin state<=0;header_index<=0;result_index<=0;crc_index<=0;index<=0;byte_value<=0;header<=0;result_latched<=0;is_image<=0;crc<=32'hffffffff;done<=0;end
        else begin
            done<=0;
            case(state)
                0:if(start)begin
                    header<={"P20CI02",8'h0a,(image ? 8'd1:8'd0),8'd2,
                        le16(WIDTH),le16(HEIGHT),le16(flags),le32(sequence_id),le32(image ? PIXELS+64:64),le32(frame_id),
                        le16(WIDTH*2),le16(HEIGHT*2),le16({7'b0,roi_x}),le16({8'b0,roi_y}),le16({7'b0,roi_side}),
                        le16(MODEL),le16(COLOR),8'd0,8'd1,
                        le32(image ? PN:0),le32(image ? MN:0),le32(image ? CN:0),le16(progress),error,nack,le32(32'h43490201)};
                    result_latched<=result_payload;is_image<=image;header_index<=0;result_index<=0;
                    index<=0;crc_index<=0;crc<=32'hffffffff;state<=1;
                end
                1:if(ready)begin
                    if(header_index>=8)crc<=crc_byte(crc,out_byte);
                    header<={header[503:0],8'b0};
                    if(header_index==63)state<=3;else header_index<=header_index+1'b1;
                end
                3:if(ready)begin
                    crc<=crc_byte(crc,out_byte);result_latched<={result_latched[503:0],8'b0};
                    if(result_index==63)state<=is_image ? 2:6;else result_index<=result_index+1'b1;
                end
                2:if(read_valid)begin byte_value<=read_data;state<=4;end
                4:if(ready)begin
                    crc<=crc_byte(crc,out_byte);
                    if(index==PIXELS-1)state<=6;else begin index<=index+1'b1;state<=2;end
                end
                6:if(ready)begin if(crc_index==3)state<=7;else crc_index<=crc_index+1'b1;end
                7:if(ready)begin state<=0;done<=1;end
                default:state<=0;
            endcase
        end
    end
endmodule
