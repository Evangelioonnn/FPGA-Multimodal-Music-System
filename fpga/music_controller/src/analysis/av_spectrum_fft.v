// 1024-point radix-2 DIT FFT, periodic Hann, fixed 1/N scaling.
// Independent observer of final_valid/left. Never backpressures the audio core.
// 18-bit complex data; 16-bit Q15 twiddles. Input gain 4 preserves precision.
module av_spectrum_fft #(parameter SAMPLE_CYCLES=1040)(
 input wire clk,rst,ready,pcm_valid,input wire signed [15:0] pcm,
 output reg wr=0,output reg [6:0] address=0,output reg [17:0] data=0,
 output reg publish=0,output reg [31:0] gap_count=0);
 localparam CAP=0,AR=1,AL=2,BR=3,BL=4,MUL=5,ROT=6,WA=7,WB=8,NEXT=9,WAIT=10,OR=11,OL=12,OW=13,PUB=14;
 reg [3:0] state=CAP;
 (* syn_ramstyle="block_ram" *) reg signed [17:0] real_mem[0:1023];
 (* syn_ramstyle="block_ram" *) reg signed [17:0] imag_mem[0:1023];
 reg [9:0] rd_addr=0;reg signed [17:0] qr,qi;
 always @(posedge clk)begin qr<=real_mem[rd_addr];qi<=imag_mem[rd_addr];end
 reg [9:0] count=0,base=0,j=0,half=1,tw=0;
 reg [3:0] stage=0;
 wire [9:0] a=base+j,b=base+j+half;
 wire [9:0] bit_reverse={count[0],count[1],count[2],count[3],count[4],count[5],count[6],count[7],count[8],count[9]};
 wire signed [15:0] hann,cosine,sine;
 av_spectrum_rom rom(clk,count,tw[8:0],hann,cosine,sine);
 reg signed [15:0] sample=0,window=0;
 reg signed [31:0] window_product=0;
 reg [1:0] pending=0;
 reg [15:0] elapsed=0;
 reg signed [17:0] ar,ai,br,bi,tr,ti;
 reg signed [33:0] p0,p1,p2,p3;
 wire signed [34:0] rr=$signed({p0[33],p0})-$signed({p1[33],p1});
 wire signed [34:0] ii=$signed({p2[33],p2})+$signed({p3[33],p3});
 wire signed [18:0] plus_r=$signed({ar[17],ar})+$signed({tr[17],tr});
 wire signed [18:0] plus_i=$signed({ai[17],ai})+$signed({ti[17],ti});
 wire signed [18:0] minus_r=$signed({ar[17],ar})-$signed({tr[17],tr});
 wire signed [18:0] minus_i=$signed({ai[17],ai})-$signed({ti[17],ti});
 reg [17:0] abs_r,abs_i;
 wire [18:0] magnitude=abs_r>=abs_i ? {1'b0,abs_r}+{2'b0,abs_i[17:1]} : {1'b0,abs_i}+{2'b0,abs_r[17:1]};
 always @(posedge clk)begin
  wr<=0;publish<=0;
  if(rst)begin state<=CAP;count<=0;pending<=0;elapsed<=0;gap_count<=0;address<=0;data<=0;rd_addr<=0;end
  else case(state)
   CAP:begin
    if(elapsed<SAMPLE_CYCLES+2)elapsed<=elapsed+1'b1;
    if(pcm_valid)begin
     // A missing/extra sample invalidates the whole current FFT window.
     if(count!=0 && elapsed!=SAMPLE_CYCLES-1)begin count<=0;pending<=0;gap_count<=gap_count+1'b1;end
     else begin sample<=pcm;window<=hann;pending<=1;end
     elapsed<=0;
    end else if(pending==1)begin window_product<=sample*window;pending<=2;end
    else if(pending==2)begin
     real_mem[bit_reverse]<=window_product>>>13;imag_mem[bit_reverse]<=0;pending<=0;
     if(count==1023)begin state<=AR;base<=0;j<=0;half<=1;tw<=0;stage<=0;count<=0;end
     else count<=count+1'b1;
    end
   end
   AR:begin rd_addr<=a;state<=AL;end
   AL:state<=BR;
   BR:begin ar<=qr;ai<=qi;rd_addr<=b;state<=BL;end
   BL:state<=MUL;
   MUL:begin br<=qr;bi<=qi;state<=ROT;end
   ROT:begin p0<=br*cosine;p1<=bi*sine;p2<=br*sine;p3<=bi*cosine;state<=WA;end
   WA:begin tr<=rr>>>15;ti<=ii>>>15;state<=WB;end
   WB:begin real_mem[a]<=plus_r>>>1;imag_mem[a]<=plus_i>>>1;state<=NEXT;end
   NEXT:begin
    real_mem[b]<=minus_r>>>1;imag_mem[b]<=minus_i>>>1;
    if(j==half-1)begin
     j<=0;tw<=0;
     if({1'b0,base}+({1'b0,half}<<1)>=1024)begin
      base<=0;
      if(stage==9)state<=WAIT;
      else begin stage<=stage+1'b1;half<=half<<1;state<=AR;end
     end else begin base<=base+(half<<1);state<=AR;end
    end else begin j<=j+1'b1;tw<=tw+(10'd512>>stage);state<=AR;end
   end
   WAIT:if(ready)begin address<=0;state<=OR;end
   OR:begin rd_addr<={3'd0,address}+10'd1;state<=OL;end
   OL:state<=OW;
   OW:begin abs_r<=qr[17] ? -qr : qr;abs_i<=qi[17] ? -qi : qi;state<=PUB;end
   PUB:begin
    wr<=1;data<=magnitude[18] ? 18'h3ffff : magnitude[17:0];
    // Separate emit and next-address cycles keep wr/address aligned.
    state<=14+1;
   end
   15:begin
    if(address==127)begin publish<=1;state<=CAP;count<=0;pending<=0;elapsed<=0;end
    else begin address<=address+1'b1;state<=OR;end
   end
   default:state<=CAP;
  endcase
 end
endmodule
