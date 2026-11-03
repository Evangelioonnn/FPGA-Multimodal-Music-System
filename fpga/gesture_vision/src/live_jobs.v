// One computation for each newly published display bank. Hold until its result
// has been latched into a UART packet; the descriptor never changes mid packet.
module p20_crop_live_jobs #(
    parameter WATCHDOG=5000000,MAX_AGE=74250000,SECOND_CYCLES=74250000
)(input wire clk,rst,have_frame,configured,input wire [3:0] camera_error,
    input wire [31:0] frame_id,input wire [8:0] roi_x,input wire [7:0] roi_y,
    input wire [8:0] roi_side,input wire result_consumed,memory_pause,
    output wire hold_frame,output wire loading,
    output wire [9:0] color_address,input wire [15:0] color_data,
    output wire result_pending,terminal_current,
    output reg [511:0] result_payload);
    `include "assets/model_id.vh"
    localparam IDLE=0,REQUEST=1,WAIT0=2,WAIT1=3,WAIT2=4,WAIT3=5,
        WRITE=6,START=7,RUN=8,REPORT=9;
    reg [3:0] state;
    reg attempted;
    reg [31:0] attempted_frame,job_frame,result_frame;
    reg [8:0] job_x,job_side,result_x,result_side;
    reg [7:0] job_y,result_y;
    reg [9:0] index;
    reg [31:0] watchdog,age,second_count,completed;
    reg [15:0] fps_count,fps;
    reg have_result,fault,core_reset;
    reg [7:0] fault_code;
    reg signed [7:0] saved_o,saved_f,saved_r,saved_a;
    reg [31:0] saved_cycles,saved_ic,saved_fc,saved_hc;
    wire busy,done,error;
    wire signed [7:0] o,f,r,a;
    wire [31:0] cycles,ic,fc,hc;
    wire need=have_frame && configured && camera_error==0 && !memory_pause &&
        (!attempted || attempted_frame!=frame_id);
    assign hold_frame=need || state!=IDLE;
    assign loading=state>=REQUEST && state<=WRITE;
    assign color_address=index;
    assign result_pending=state==REPORT;
    assign terminal_current=have_result && result_frame==frame_id &&
        result_x==roi_x && result_y==roi_y && result_side==roi_side;
    p20_crop_cnn cnn(clk,rst||core_reset,state==WRITE,index,color_data,state==START,
        busy,done,error,o,f,r,a,cycles,ic,fc,hc);

    wire signed [8:0] pdiff=$signed({saved_o[7],saved_o})-$signed({saved_f[7],saved_f});
    wire [8:0] pgap=pdiff<0 ? -pdiff:pdiff;
    wire signed [8:0] agap=$signed({saved_a[7],saved_a})-$signed({saved_r[7],saved_r});
    reg [1:0] result_state,final_class;
    reg [7:0] reason;
    function [15:0] le16;input [15:0] v;begin le16={v[7:0],v[15:8]};end endfunction
    function [31:0] le32;input [31:0] v;begin le32={v[7:0],v[15:8],v[23:16],v[31:24]};end endfunction
    always @* begin
        result_state=0;final_class=0;reason=0;
        if(!configured || camera_error!=0)begin result_state=3;reason=4;end
        else if(terminal_current)begin
            if(fault)begin result_state=3;reason=8;end
            else if(age>=MAX_AGE)begin result_state=2;reason=16;end
            else begin
                result_state=1;reason={6'b0,(agap<9'sd8),(pgap<9'd8)};
                if(reason==0)final_class=saved_o>=saved_f ? 1:2;
            end
        end
        result_payload={8'd1,{6'd0,result_state},{6'd0,final_class},reason,
            le32(result_frame),saved_o,saved_f,saved_r,saved_a,
            le16({7'd0,pgap}),le16({{7{agap[8]}},agap}),le32(saved_cycles),
            le32(saved_ic),le32(saved_fc),le32(saved_hc),P20_CROP_MODEL_ID,
            le32(completed),le16(fps),fault_code,8'd1,
            le16({7'd0,result_x}),le16({8'd0,result_y}),le16({7'd0,result_side}),16'd0};
    end
    always @(posedge clk)begin
        if(rst)begin
            state<=IDLE;attempted<=0;attempted_frame<=0;job_frame<=0;result_frame<=0;
            job_x<=0;job_y<=0;job_side<=160;result_x<=80;result_y<=40;result_side<=160;
            index<=0;watchdog<=0;age<=0;second_count<=0;completed<=0;fps_count<=0;fps<=0;
            have_result<=0;fault<=0;fault_code<=0;core_reset<=0;
            saved_o<=0;saved_f<=0;saved_r<=0;saved_a<=0;
            saved_cycles<=0;saved_ic<=0;saved_fc<=0;saved_hc<=0;
        end else begin
            core_reset<=0;
            if(age<MAX_AGE)age<=age+1'b1;
            if(second_count==SECOND_CYCLES-1)begin
                second_count<=0;fps<=fps_count;fps_count<=0;
            end else second_count<=second_count+1'b1;
            if(state!=IDLE && state!=REPORT)watchdog<=watchdog+1'b1;
            case(state)
                IDLE:if(need)begin
                    attempted<=1;attempted_frame<=frame_id;job_frame<=frame_id;
                    job_x<=roi_x;job_y<=roi_y;job_side<=roi_side;
                    index<=0;watchdog<=0;state<=REQUEST;
                end
                REQUEST:state<=WAIT0;
                WAIT0:state<=WAIT1;
                WAIT1:state<=WAIT2;
                WAIT2:state<=WAIT3;
                WAIT3:state<=WRITE;
                WRITE:if(index==1023)state<=START;else begin index<=index+1'b1;state<=REQUEST;end
                START:state<=RUN;
                RUN:if(done)begin
                    have_result<=1;result_frame<=job_frame;result_x<=job_x;result_y<=job_y;result_side<=job_side;
                    saved_o<=o;saved_f<=f;saved_r<=r;saved_a<=a;
                    saved_cycles<=cycles;saved_ic<=ic;saved_fc<=fc;saved_hc<=hc;
                    fault<=error;fault_code<=error ? 1:0;age<=0;completed<=completed+1'b1;
                    if(second_count==SECOND_CYCLES-1)fps_count<=1;else fps_count<=fps_count+1'b1;
                    state<=REPORT;
                end
                REPORT:if(result_consumed)state<=IDLE;
                default:begin state<=IDLE;core_reset<=1;end
            endcase
            if(state!=IDLE && state!=REPORT && watchdog==WATCHDOG-1)begin
                core_reset<=1;state<=REPORT;have_result<=1;fault<=1;fault_code<=2;age<=0;
                result_frame<=job_frame;result_x<=job_x;result_y<=job_y;result_side<=job_side;
                saved_cycles<=watchdog;saved_ic<=0;saved_fc<=0;saved_hc<=0;
                saved_o<=0;saved_f<=0;saved_r<=0;saved_a<=0;
            end
            if(!configured || !have_frame || camera_error!=0)begin
                state<=IDLE;attempted<=0;have_result<=0;core_reset<=1;
            end
        end
    end
endmodule
