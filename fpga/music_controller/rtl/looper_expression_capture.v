// Timestamped controls for one take. Three initial controls establish its
// independent state; notes and controls are merged by timestamp in the core.
module looper_expression_capture #(
    parameter BEND_INTERVAL_FRAMES=1200, parameter BEND_THRESHOLD=256
)(
    input wire clk,rst,sample_ce,recording,capture_enable,
    input wire [11:0] tick,
    input wire pedal,sostenuto,input wire [16:0] bend,
    output wire valid,input wire ready,
    output wire [11:0] event_tick,output wire [1:0] kind,
    output wire [16:0] value,output wire busy,output reg overflow
);
    reg previous_recording;
    reg [30:0] fifo[0:7];reg [2:0] wr,rd;reg [3:0] count;
    reg [2:0] pending;reg [11:0] pending_tick;
    reg target_pedal,target_sost,previous_pedal,previous_sost;
    reg [16:0] target_bend,previous_bend;
    reg [15:0] bend_age;
    wire [17:0] bend_difference=bend>previous_bend ?
        {1'b0,bend}-{1'b0,previous_bend} : {1'b0,previous_bend}-{1'b0,bend};
    wire enqueue=recording && pending!=0 && (count<8 || (valid && ready));
    wire dequeue=valid && ready;
    wire [1:0] pending_kind=pending[0] ? 0 : pending[1] ? 1 : 2;
    wire [16:0] pending_value=pending[0] ? {16'd0,target_pedal} :
        pending[1] ? {16'd0,target_sost} : target_bend;
    assign valid=count!=0 && recording;
    assign {event_tick,kind,value}=fifo[rd];
    assign busy=recording && (count!=0 || pending!=0);
    always @(posedge clk) begin
        if(rst) begin
            previous_recording<=0;wr<=0;rd<=0;count<=0;pending<=0;pending_tick<=0;
            target_pedal<=0;target_sost<=0;previous_pedal<=0;previous_sost<=0;
            target_bend<=65536;previous_bend<=65536;bend_age<=0;overflow<=0;
        end else begin
            previous_recording<=recording;
            if(!recording) begin wr<=0;rd<=0;count<=0;pending<=0;bend_age<=0;overflow<=0;end
            else begin
                case({enqueue,dequeue}) 2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;endcase
                if(dequeue) rd<=rd+1'b1;
                if(enqueue) begin
                    fifo[wr]<={pending_tick,pending_kind,pending_value};wr<=wr+1'b1;
                    pending[pending_kind]<=0;
                end
                if(!previous_recording && capture_enable) begin
                    pending<=3'b111;pending_tick<=0;
                    target_pedal<=pedal;target_sost<=sostenuto;target_bend<=bend;
                    previous_pedal<=pedal;previous_sost<=sostenuto;previous_bend<=bend;
                    bend_age<=BEND_INTERVAL_FRAMES;overflow<=0;
                end else if(sample_ce && capture_enable) begin
                    if(bend_age<BEND_INTERVAL_FRAMES) bend_age<=bend_age+1'b1;
                    if(pedal!=previous_pedal || sostenuto!=previous_sost ||
                        (bend_age>=BEND_INTERVAL_FRAMES && bend_difference>=BEND_THRESHOLD)) begin
                        if(pending!=0) overflow<=1;
                        else begin
                            pending<={bend_age>=BEND_INTERVAL_FRAMES && bend_difference>=BEND_THRESHOLD,
                                sostenuto!=previous_sost,pedal!=previous_pedal};
                            pending_tick<=tick;target_pedal<=pedal;target_sost<=sostenuto;target_bend<=bend;
                            previous_pedal<=pedal;previous_sost<=sostenuto;
                            if(bend_age>=BEND_INTERVAL_FRAMES && bend_difference>=BEND_THRESHOLD)
                                begin previous_bend<=bend;bend_age<=0;end
                        end
                    end
                end
                // A bounded queue never overwrites unread automation.
                if(pending!=0 && count==8 && !dequeue) overflow<=1;
            end
        end
    end
endmodule
