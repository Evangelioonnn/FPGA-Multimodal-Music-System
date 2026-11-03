module dcl_receiver #(parameter LINK_CYCLES=5000000)(
 input wire clk,rst,byte_valid,input wire[7:0]byte_data,input wire uart_error,force_fault,
 output wire row_valid,input wire row_ready,output wire[1:0]row,
 output wire[7:0]closed,output wire[31:0]capture_us,output wire initial_sample,
 output reg rebase,fault,output reg synced,
 output reg[31:0]crc_errors,frame_errors,sequence_errors,duplicates,link_errors);

 (* syn_ramstyle="block_ram" *)reg[7:0]rxmem[0:63],packet[0:63];
 reg collecting,escape,overflow;reg[6:0]count,length,copy_index;reg[15:0]crc;reg[3:0]state,index;
 reg[31:0]last_session;reg[15:0]last_sequence,last_tag;reg[31:0]link_count;reg initialize;reg[3:0]records;
 reg[7:0]rx_payload_length,header_version,header_kind,header_length,header_flags,header_records;
 reg[31:0]packet_session;reg[15:0]packet_sequence,tag;reg metadata_ok;
 reg[7:0]rx_q,packet_q;reg[47:0]row_cache;reg[2:0]prefetch;
 wire[6:0]offset=7'd11+{index,2'd0}+{index,1'b0};
 wire[5:0]packet_address=offset[5:0]+(state==8 ? {3'd0,prefetch} : 6'd0);
 wire[5:0]rx_address=state==1 ? copy_index[5:0]+6'd1 : 6'd0;
 wire[7:0]unescaped=escape ? byte_data^8'h20 : byte_data;
 wire rx_write=byte_valid&&byte_data!=8'h7e&&collecting&&!overflow&&!(byte_data==8'h7d&&!escape)&&count<64;
 always @(posedge clk)begin
  rx_q<=rxmem[rx_address];
  if(!rst&&rx_write)rxmem[count[5:0]]<=unescaped;
  // The packet is immutable during validation/output. No write-cycle read.
  if(!rst&&state==1)packet[copy_index[5:0]]<=rx_q;
  else packet_q<=packet[packet_address];
 end
 function[15:0]crc_byte;input[15:0]c;input[7:0]b;reg[15:0]v;integer k;
 begin v=c^{b,8'd0};for(k=0;k<8;k=k+1)v=v[15]?(v<<1)^16'h1021:v<<1;crc_byte=v;end endfunction
 function[7:0]meta_expected;input[6:0]at;begin case(at)35:meta_expected=1;37:meta_expected=25;39:meta_expected=100;default:meta_expected=0;endcase end endfunction
 assign row_valid=state==5;assign row=row_cache[1:0];assign closed=row_cache[15:8];assign capture_us=row_cache[47:16];assign initial_sample=initialize;
 task fail;begin fault<=1;synced<=0;state<=0;end endtask
 always @(posedge clk)begin
  if(rst)begin
   collecting<=0;escape<=0;overflow<=0;count<=0;length<=0;copy_index<=0;crc<=16'hffff;state<=0;index<=0;
   rebase<=0;fault<=0;synced<=0;crc_errors<=0;frame_errors<=0;sequence_errors<=0;duplicates<=0;link_errors<=0;
   last_session<=0;last_sequence<=0;last_tag<=0;link_count<=0;initialize<=0;records<=0;
   rx_payload_length<=0;header_version<=0;header_kind<=0;header_length<=0;header_flags<=0;header_records<=0;packet_session<=0;packet_sequence<=0;tag<=0;metadata_ok<=0;row_cache<=0;prefetch<=0;
  end else begin
   rebase<=0;fault<=0;if(synced)link_count<=link_count+1'b1;else link_count<=0;
   case(state)
    1:begin
     case(copy_index)
      0:header_version<=rx_q;1:header_kind<=rx_q;2:header_length<=rx_q;
      3:packet_session[7:0]<=rx_q;4:packet_session[15:8]<=rx_q;5:packet_session[23:16]<=rx_q;6:packet_session[31:24]<=rx_q;
      7:packet_sequence[7:0]<=rx_q;8:packet_sequence[15:8]<=rx_q;9:header_flags<=rx_q;10:header_records<=rx_q;
     endcase
     if(header_kind==1&&copy_index>=35&&copy_index<=40&&rx_q!=meta_expected(copy_index))metadata_ok<=0;
     if(copy_index+7'd2==length)tag[15:8]<=rx_q;
     if(copy_index+7'd1==length)begin tag[7:0]<=rx_q;state<=2;end else copy_index<=copy_index+1'b1;
    end
    2:begin
     records<=header_records[3:0];index<=0;
     if(header_version!=1||!(header_kind==1||header_kind==2)||header_flags[7:3]!=0||header_records<1||header_records>8||
      (header_kind==2&&header_length!=2+6*header_records)||(header_kind==1&&(header_records!=4||header_length!=32||!metadata_ok)))begin frame_errors<=frame_errors+1'b1;fail();end
     else state<=3;
    end
    3:state<=6;
    6:state<=7;
    7:if(packet_q>3||(header_kind==1&&packet_q!=index))begin frame_errors<=frame_errors+1'b1;fail();end
      else if(index==records-1)state<=4;else begin index<=index+1'b1;state<=3;end
    4:begin
     index<=0;prefetch<=0;initialize<=0;
     if(synced&&packet_session==last_session&&packet_sequence==last_sequence)begin
      if(tag!=last_tag)begin sequence_errors<=sequence_errors+1'b1;fail();end
      else begin duplicates<=duplicates+1'b1;state<=0;end
     end else if(header_flags!=0||!synced||packet_session!=last_session)begin
      if(header_kind!=1)begin sequence_errors<=sequence_errors+1'b1;fail();end
      else begin rebase<=1;initialize<=1;synced<=1;last_session<=packet_session;last_sequence<=packet_sequence;last_tag<=tag;link_count<=0;state<=8;end
     end else if(packet_sequence!=last_sequence+16'd1)begin
      sequence_errors<=sequence_errors+1'b1;
      if(header_kind==1)begin fault<=1;rebase<=1;initialize<=1;synced<=1;last_sequence<=packet_sequence;last_tag<=tag;link_count<=0;state<=8;end
      else fail();
     end else begin last_sequence<=packet_sequence;last_tag<=tag;link_count<=0;state<=8;end
    end
    8:begin
     if(prefetch!=0)case(prefetch)
      1:row_cache[7:0]<=packet_q;2:row_cache[15:8]<=packet_q;3:row_cache[23:16]<=packet_q;
      4:row_cache[31:24]<=packet_q;5:row_cache[39:32]<=packet_q;6:row_cache[47:40]<=packet_q;
     endcase
     if(prefetch==6)state<=5;else prefetch<=prefetch+1'b1;
    end
    5:if(row_ready)begin if(index==records-1)state<=0;else begin index<=index+1'b1;prefetch<=0;state<=8;end end
   endcase
   // Collector faults have priority over the old packet-processing state.
   if(byte_valid)begin
    if(byte_data==8'h7e)begin
     collecting<=1;count<=0;crc<=16'hffff;escape<=0;overflow<=0;
     if(collecting&&count!=0)begin
      if(escape||overflow||count<11||{2'd0,count}!={1'b0,rx_payload_length}+9'd11)begin frame_errors<=frame_errors+1'b1;fail();end
      else if(crc!=0)begin crc_errors<=crc_errors+1'b1;fail();end
      else if(state!=0)begin frame_errors<=frame_errors+1'b1;fail();end
      else begin length<=count;copy_index<=0;metadata_ok<=1;state<=1;end
     end
    end else if(collecting&&!overflow)begin
     if(byte_data==8'h7d&&!escape)escape<=1;
     else begin
      escape<=0;
      if(count>=64)overflow<=1;
      else begin if(count==2)rx_payload_length<=unescaped;count<=count+1'b1;crc<=crc_byte(crc,unescaped);end
     end
    end
   end
   if(synced&&link_count==LINK_CYCLES-1)begin
    link_errors<=link_errors+1'b1;link_count<=0;fail();collecting<=0;count<=0;escape<=0;
   end
   if(uart_error||force_fault)begin frame_errors<=frame_errors+1'b1;fail();collecting<=0;count<=0;escape<=0;end
  end
 end
endmodule
