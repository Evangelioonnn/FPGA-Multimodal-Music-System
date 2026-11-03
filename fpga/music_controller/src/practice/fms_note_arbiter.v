// Two guide clients share the compact heap reader. No assumed fixed RAM delay.
module fms_note_arbiter(input wire clk,rst,
 input wire a_req,output wire a_ready,input wire [10:0] a_index,output wire a_valid,input wire a_accept,output wire [79:0] a_data,
 input wire b_req,output wire b_ready,input wire [10:0] b_index,output wire b_valid,input wire b_accept,output wire [79:0] b_data,
 output wire [10:0] address,input wire [79:0] data,
 output wire request,input wire request_ready,input wire response,output wire response_accept);
 reg busy,owner,last;reg[10:0]held_index;
 wire choose_b=b_req && (!a_req || !last);
 assign request=!busy && (a_req || b_req) && !rst;
 assign address=busy ? held_index : choose_b ? b_index : a_index;
 assign a_ready=request && !choose_b && request_ready;
 assign b_ready=request && choose_b && request_ready;
 assign a_valid=busy && !owner && response;assign b_valid=busy && owner && response;
 assign a_data=data;assign b_data=data;
 assign response_accept=busy && (owner ? b_accept : a_accept);
 always @(posedge clk)begin
  if(rst)begin busy<=0;owner<=0;last<=0;held_index<=0;end
  else if(request && request_ready)begin busy<=1;owner<=choose_b;last<=choose_b;held_index<=choose_b ? b_index : a_index;end
  else if(response && response_accept)busy<=0;
 end
endmodule
