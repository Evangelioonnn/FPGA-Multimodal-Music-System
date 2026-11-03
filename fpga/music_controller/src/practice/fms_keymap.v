// One permutation of 25 source keys. The audio/judge/recorder consume one
// coherent, registered logical snapshot. No combinational 25x25 crossbar.
module fms_keymap(
 input wire clk,rst,input wire [24:0] source_keys,
 input wire [24:0] targets,correct,wrong,
 input wire allowed,swap,restore,input wire [31:0] expected_revision,
 input wire [4:0] source_a,source_b,
 output reg busy,done,flush,output reg [7:0] error,
 output reg [31:0] revision,output wire [124:0] table_bits,
 output reg [24:0] mapped_keys,output reg changed,
 output reg [24:0] source_targets,source_correct,source_wrong);
 reg [4:0] mapping[0:24];
 reg [1:0] phase;reg [4:0] index,note;reg held;
 reg [24:0] key_snapshot,target_snapshot,correct_snapshot,wrong_snapshot;
 reg [24:0] key_build,target_build,correct_build,wrong_build;
 genvar g;generate for(g=0;g<25;g=g+1)begin: export_table
  assign table_bits[g*5+:5]=mapping[g];
 end endgenerate
 integer k;
 always @(posedge clk)begin
  if(rst)begin
   for(k=0;k<25;k=k+1)mapping[k]<=k;
   busy<=0;done<=0;flush<=0;error<=0;revision<=1;phase<=0;index<=0;note<=0;held<=0;
   mapped_keys<=0;changed<=0;source_targets<=0;source_correct<=0;source_wrong<=0;
   key_snapshot<=0;target_snapshot<=0;correct_snapshot<=0;wrong_snapshot<=0;
   key_build<=0;target_build<=0;correct_build<=0;wrong_build<=0;
  end else begin
   done<=0;flush<=0;changed<=0;
   if(swap || restore)begin
    if(busy || !allowed || source_keys!=0 || mapped_keys!=0)begin done<=1;error<=3;end
    else if(expected_revision!=revision)begin done<=1;error<=4;end
    else if(swap && (source_a>24 || source_b>24))begin done<=1;error<=2;end
    else begin
     if(restore)begin for(k=0;k<25;k=k+1)mapping[k]<=k;end
     else begin mapping[source_a]<=mapping[source_b];mapping[source_b]<=mapping[source_a];end
     revision<=revision+1'b1;busy<=1;flush<=1;phase<=0;error<=0;
    end
   end else case(phase)
    0:begin
     key_snapshot<=source_keys;target_snapshot<=targets;correct_snapshot<=correct;wrong_snapshot<=wrong;
     key_build<=0;target_build<=0;correct_build<=0;wrong_build<=0;index<=0;phase<=1;
    end
    1:begin note<=mapping[index];held<=key_snapshot[index];phase<=2;end
    2:begin
     key_build[note]<=held;target_build[index]<=target_snapshot[note];
     correct_build[index]<=correct_snapshot[note];wrong_build[index]<=wrong_snapshot[note];
     if(index==24)phase<=3;else begin index<=index+1'b1;phase<=1;end
    end
    3:begin
     mapped_keys<=key_build;changed<=key_build!=mapped_keys;
     source_targets<=target_build;source_correct<=correct_build;source_wrong<=wrong_build;phase<=0;
     if(busy)begin busy<=0;done<=1;error<=0;end
    end
   endcase
  end
 end
endmodule
