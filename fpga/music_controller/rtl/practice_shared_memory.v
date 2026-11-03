// One physical array, two exclusive interpretations. Six16-bit columns:
// score: {control48,state48} x512; practice:4096 x48-bit heap units.
// Mode ownership is stable before any request. Score initialization rewrites
// every state/control word after acquiring the pool. No cached song survives it.
module practice_shared_memory(input wire clk,input wire score_owner,
 input wire heap_we,input wire[11:0]heap_wa,input wire[47:0]heap_wd,
 input wire[11:0]heap_ra,output reg[47:0]heap_rd,
 input wire score_read,input wire[8:0]score_ra,
 output wire[47:0]score_state,score_control,
 input wire score_state_we,input wire[8:0]score_state_wa,input wire[47:0]score_state_wd,
 input wire score_control_we,input wire[8:0]score_control_wa,input wire[47:0]score_control_wd);
 wire[95:0]read_columns;
 genvar i;
 generate for(i=0;i<6;i=i+1)begin: columns
  (* syn_ramstyle="block_ram" *)reg[15:0]memory[0:2047];reg[15:0]q;
  wire heap_select=heap_wa[0]==(i>=3);
  wire we=score_owner ? (i<3 ? score_state_we : score_control_we) : heap_we&&heap_select;
  wire[10:0]wa=score_owner ? {2'd0,(i<3 ? score_state_wa : score_control_wa)} : heap_wa[11:1];
  wire[15:0]wd=score_owner ? (i<3 ? score_state_wd[(i%3)*16+:16] : score_control_wd[(i%3)*16+:16]) : heap_wd[(i%3)*16+:16];
  wire[10:0]ra=score_owner ? {2'd0,score_ra} : heap_ra[11:1];
  always @(posedge clk)begin
   if(we)memory[wa]<=wd;
   if(!score_owner||score_read)q<=memory[ra];
  end
  assign read_columns[i*16+:16]=q;
 end endgenerate
 reg heap_half;
 always @(posedge clk)heap_half<=heap_ra[0];
 always @*heap_rd=heap_half ? read_columns[95:48] : read_columns[47:0];
 assign score_state=read_columns[47:0];assign score_control=read_columns[95:48];
endmodule
