// Lock a source from first offer through the formatter's 64-byte capture ACK.
// The formatter owns its private RAM while the UART serializes the frame.
module library_tx_arbiter(input wire clk,rst,
 input wire core_valid,output wire core_ready,input wire[7:0]core_command,
 input wire[31:0]core_session,input wire[15:0]core_sequence,input wire[6:0]core_length,
 input wire[7:0]core_byte,
 input wire menu_valid,output wire menu_ready,input wire[7:0]menu_command,
 input wire[31:0]menu_session,input wire[15:0]menu_sequence,input wire[6:0]menu_length,
 input wire[7:0]menu_byte,
 output wire valid,input wire ready,output wire[7:0]command,
 output wire[31:0]session,output wire[15:0]sequence,output wire[6:0]length,
 output wire[7:0]data);
 reg locked,menu;
 wire select_menu=locked ? menu : !core_valid;
 assign valid=select_menu ? menu_valid : core_valid;
 assign command=select_menu ? menu_command : core_command;
 assign session=select_menu ? menu_session : core_session;
 assign sequence=select_menu ? menu_sequence : core_sequence;
 assign length=select_menu ? menu_length : core_length;
 assign data=select_menu ? menu_byte : core_byte;
 assign core_ready=ready&&!select_menu;
 assign menu_ready=ready&&select_menu;
 always @(posedge clk)begin
  if(rst)begin locked<=0;menu<=0;end
  else if(valid&&ready)locked<=0;
  else if(valid&&!locked)begin locked<=1;menu<=select_menu;end
 end
endmodule
