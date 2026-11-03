// Complete natural strike and held continuation share ONE phase. max(), not addition.
module ensemble_envelope(input wire [19:0] age,input wire [15:0] body,accent,
 input wire [2:0] stage,input wire held,pedal,forced,
 input wire mode,input wire [1:0] minimum_index,maximum_index,input wire [2:0] release_index,
 input wire [4:0] release_shift,
 output reg [19:0] next_age,output reg [15:0] next_body,next_accent,
 output reg [2:0] next_stage,output reg [4:0] next_shift,
 output reg [15:0] render_body,render_accent,
 output wire [19:0] minimum_samples,maximum_samples,
 output wire [15:0] protected_level,output reg [2:0] base_stage);
 assign minimum_samples=minimum_index==0 ? 20'd24038 : minimum_index==1 ? 20'd48077 :
  minimum_index==2 ? 20'd72115 : 20'd96154;
 assign maximum_samples=maximum_index==0 ? 20'd192308 : maximum_index==1 ? 20'd384615 :
  maximum_index==2 ? 20'd576923 : 20'd769231;
 wire releasing=forced||age>=maximum_samples||(!held&&!pedal);
 reg [4:0] tail_shift,early_shift;
 reg [19:0] tail_count,remaining;
 reg [35:0] base_product;reg [15:0] protected_body;
 assign protected_level=protected_body;
 reg [16:0] body_loss,accent_loss;
 integer i;
 always @* begin
  next_age=age==20'hfffff ? age : age+1'b1;
  next_body=body;next_accent=accent;next_stage=stage;next_shift=release_shift;
  tail_shift=release_index+5'd9;
  if((20'd1<<tail_shift)>minimum_samples-96) tail_shift=minimum_index==0 ? 14 : minimum_index==1 ? 15 : 16;
  tail_count=20'd1<<tail_shift;
  remaining=age<minimum_samples ? minimum_samples-age : tail_count;
  early_shift=7;
  for(i=7;i<=16;i=i+1) if((20'd1<<i)<=remaining && i<=tail_shift) early_shift=i;
  body_loss=0;accent_loss=(accent>>9)+1;
  if(stage==1) begin
   if(body>=48640) begin next_body=49152;next_stage=2;end else next_body=body+512;
   if(age<32) next_accent=accent>=15872 ? 16384 : accent+512;
   else next_accent=accent<=accent_loss ? 0 : accent-accent_loss;
  end else if(stage==2) begin
   next_body=body>36000 ? body-((body>>13)+1'b1) : body;
   next_accent=accent<=accent_loss ? 0 : accent-accent_loss;
  end
  if(stage==4 || (stage!=0&&releasing)) begin
   next_stage=4;
   if(stage!=4) next_shift=!mode&&age<minimum_samples&&!forced ? early_shift : tail_shift;
   body_loss=(17'd49152>>next_shift)+1;
   next_body=body<=body_loss ? 0 : body-body_loss;
   next_accent=accent<=((17'd16384>>next_shift)+1) ? 0 : accent-((17'd16384>>next_shift)+1);
  end
  // Let the bank test completion after the registered floor/body values. This
  // avoids a floor multiply/shift -> stage-zero -> RAM write timing cascade.
  base_stage=next_stage;
  protected_body=0;base_product=0;
  if(!mode&&!forced&&age<minimum_samples) begin
   if(age<96) protected_body=(age+1'b1)<<9;
   else if(age<4480) protected_body=49152-(age-96)*3;
   else if(age<minimum_samples-tail_count) protected_body=36000;
   else begin base_product=remaining*16'd36000;protected_body=base_product>>tail_shift;end
  end
  render_body=next_body>protected_body ? next_body : protected_body;
  render_accent=next_accent;
  if(next_body==0&&next_accent==0&&protected_body==0) next_stage=0;
  if(stage==0) begin next_body=0;next_accent=0;render_body=0;render_accent=0;next_stage=0;end
 end
endmodule

// One registered partial result. R_FETCH captures; R_MULT consumes. This uses
// an existing bank stage and adds no frame or voice scheduling latency.
module ensemble_floor_pipeline(input wire clk,ce,input wire[19:0]age,
 input wire mode,forced,input wire[1:0]minimum_index,input wire[2:0]release_index,
 output wire[15:0]level);
 wire[19:0]minimum_samples=minimum_index==0 ? 20'd24038 : minimum_index==1 ? 20'd48077 : minimum_index==2 ? 20'd72115 : 20'd96154;
 reg[4:0]tail_shift;reg[19:0]tail_count,remaining;
 reg[15:0]small_level;reg tail;
 reg[35:0]product_q;reg[4:0]shift_q;reg[15:0]small_q;reg tail_q;
 always @*begin
  tail_shift=release_index+5'd9;
  if((20'd1<<tail_shift)>minimum_samples-96)tail_shift=minimum_index==0 ? 14 : minimum_index==1 ? 15 : 16;
  tail_count=20'd1<<tail_shift;
  remaining=minimum_samples-age;
  small_level=0;tail=0;
  if(!mode&&!forced&&age<minimum_samples)begin
   if(age<96)small_level=(age+1'b1)<<9;
   else if(age<4480)small_level=49152-(age-96)*3;
   else if(age<minimum_samples-tail_count)small_level=36000;
   else tail=1;
  end
 end
 always @(posedge clk)if(ce)begin
  product_q<=remaining*16'd36000;shift_q<=tail_shift;small_q<=small_level;tail_q<=tail;
 end
 assign level=tail_q ? (product_q>>shift_q) : small_q;
endmodule
