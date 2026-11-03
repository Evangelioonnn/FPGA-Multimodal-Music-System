// row_low selects one row to pull down; other physical rows MUST be high impedance.
module matrix_scanner #(parameter ROWS=4,COLS=4,ROW_CYCLES=2500,DEBOUNCE_FRAMES=8,
    parameter HAS_DIODES=0,
    // Zero preserves the original raw-frame all_released contract. A private
    // nonzero mask selects a coherent debounced next_keys empty sideband.
    parameter [ROWS*COLS-1:0] DEBOUNCED_RELEASE_MASK=0,
    parameter ROW_W=(ROWS>1?$clog2(ROWS):1),
    parameter TICK_W=(ROW_CYCLES>1?$clog2(ROW_CYCLES):1),
    parameter DB_W=(DEBOUNCE_FRAMES>1?$clog2(DEBOUNCE_FRAMES):1))(
    input wire clk,rst,input wire [COLS-1:0] col_n,
    output reg [ROWS-1:0] row_low,
    output reg [ROWS*COLS-1:0] keys,
    output reg changed,frame_valid,ghost,all_released
);
    reg [COLS-1:0] sync1,sync2;
    reg [ROW_W-1:0] row;
    reg [TICK_W-1:0] tick;
    reg [ROWS*COLS-1:0] scanned;
    reg [DB_W-1:0] stable[0:ROWS*COLS-1];
    reg [ROWS*COLS-1:0] candidate,next_keys;
    reg ambiguous;
    integer i,a,b,c,common,d;
    always @* begin
        row_low=0;row_low[row]=!rst;
        candidate=scanned;candidate[row*COLS +: COLS]=~sync2;
        ambiguous=0;common=0;
        for(a=0;a<ROWS;a=a+1) for(b=a+1;b<ROWS;b=b+1) begin
            common=0;
            for(c=0;c<COLS;c=c+1) if(candidate[a*COLS+c] && candidate[b*COLS+c]) common=common+1;
            if(common>=2) ambiguous=1;
        end
        next_keys=keys;
        for(i=0;i<ROWS*COLS;i=i+1)
            if(candidate[i]!=keys[i] && stable[i]==DEBOUNCE_FRAMES-1) next_keys[i]=candidate[i];
        if(!HAS_DIODES && ambiguous) next_keys=0;
    end
    always @(posedge clk) begin
        if(rst) begin
            sync1<={COLS{1'b1}};sync2<={COLS{1'b1}};row<=0;tick<=0;scanned<=0;
            keys<=0;changed<=0;frame_valid<=0;ghost<=0;all_released<=DEBOUNCED_RELEASE_MASK!=0;
            for(d=0;d<ROWS*COLS;d=d+1) stable[d]<=0;
        end else begin
            sync1<=col_n;sync2<=sync1;changed<=0;frame_valid<=0;
            if(tick==ROW_CYCLES-1) begin
                tick<=0;scanned<=candidate;
                if(row==ROWS-1) begin
                    row<=0;frame_valid<=1;ghost<=!HAS_DIODES && ambiguous;all_released<=DEBOUNCED_RELEASE_MASK!=0 ? (next_keys & DEBOUNCED_RELEASE_MASK)==0 : candidate==0;
                    changed<=next_keys!=keys;keys<=next_keys;
                    for(d=0;d<ROWS*COLS;d=d+1)
                        if((!HAS_DIODES && ambiguous) || candidate[d]==keys[d] || stable[d]==DEBOUNCE_FRAMES-1) stable[d]<=0;
                        else stable[d]<=stable[d]+1'b1;
                end else row<=row+1'b1;
            end else tick<=tick+1'b1;
        end
    end
endmodule
