// Canonical one-write/one-read RAM, physically split into 18-bit slices.
// Concatenate bank with address so a 2-bank 80-bit guide RAM does not infer
// two independent writer ports or waste a 36-bit BSRAM column on its tail.
module fms_packed_ram #(parameter WIDTH=72,ADDR=13)(
 input wire clk,input wire write_enable,input wire [ADDR-1:0] write_address,
 input wire [WIDTH-1:0] write_data,input wire [ADDR-1:0] read_address,
 output wire [WIDTH-1:0] read_data);
 localparam SLICES=(WIDTH+17)/18;
 wire [SLICES*18-1:0] padded_write={{(SLICES*18-WIDTH){1'b0}},write_data};
 wire [SLICES*18-1:0] padded_read;
 genvar i;
 generate for(i=0;i<SLICES;i=i+1)begin: words
  (* syn_ramstyle="block_ram" *) reg [17:0] memory[0:(1<<ADDR)-1];
  reg [17:0] q;
  always @(posedge clk)begin
   if(write_enable)memory[write_address]<=padded_write[i*18+:18];
   q<=memory[read_address];
  end
  assign padded_read[i*18+:18]=q;
 end endgenerate
 assign read_data=padded_read[WIDTH-1:0];
endmodule
