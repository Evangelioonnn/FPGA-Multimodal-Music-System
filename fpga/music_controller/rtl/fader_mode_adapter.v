// CH0 always goes to the audio parameter service. CH1..4 have separate
// pickup in harmonic-edit and track-mixer modes. Applied targets are supplied
// by the authoritative services; invalidate accompanies external edits.
module fader_mode_adapter #(parameter TOLERANCE=16,JITTER=4)(
    input wire clk,rst,mix_mode,
    input wire scan_valid,output wire scan_ready,input wire [59:0] scan_data,
    input wire [47:0] harmonic_targets,input wire [67:0] mixer_targets,
    input wire [3:0] invalidate,
    output reg adc_valid,input wire adc_ready,output reg [59:0] adc_data,
    output reg mixer_valid,input wire mixer_ready,output reg [67:0] mixer_data,
    output reg [3:0] acquired
);
    reg previous_mode,have_previous;
    reg [11:0] previous[0:3],last_applied[0:3];
    integer i;reg [11:0] raw,target;reg signed [12:0] distance,movement;reg crossing;
    wire mode_changed=previous_mode!=mix_mode;
    assign scan_ready=!adc_valid && !mixer_valid;
    function [16:0] raw_gain;input [11:0] x;
        begin raw_gain=x==4095 ? 17'd65536 : {1'b0,x,4'd0};end
    endfunction

    // Default pickup is an inclusive16-code interval. Nine-bit group adds
    // retain overflow at4095 instead of wrapping into group0.
    function near16;input[11:0]p,t;reg[8:0]pn,tn;begin
      pn={1'b0,p[11:4]}+9'd1;tn={1'b0,t[11:4]}+9'd1;
      near16=(p[11:4]==t[11:4]) ||
        ({1'b0,p[11:4]}==tn && p[3:0]<=t[3:0]) ||
        ({1'b0,t[11:4]}==pn && t[3:0]<=p[3:0]);
    end endfunction
    function moved4;input[11:0]p,t;reg[10:0]pn,tn;begin
      pn={1'b0,p[11:2]}+11'd1;tn={1'b0,t[11:2]}+11'd1;
      moved4=!((p[11:2]==t[11:2]) ||
        ({1'b0,p[11:2]}==tn && p[1:0]<t[1:0]) ||
        ({1'b0,t[11:2]}==pn && t[1:0]<p[1:0]));
    end endfunction
    always @(posedge clk) begin
        if(rst) begin
            previous_mode<=0;have_previous<=0;acquired<=0;
            adc_valid<=0;adc_data<=0;mixer_valid<=0;mixer_data<=0;
            for(i=0;i<4;i=i+1) begin previous[i]<=0;last_applied[i]<=0;end
        end else begin
            if(adc_valid && adc_ready) adc_valid<=0;
            if(mixer_valid && mixer_ready) mixer_valid<=0;
            if(mode_changed) begin previous_mode<=mix_mode;have_previous<=0;acquired<=0;end
            else acquired<=acquired & ~invalidate;
            if(scan_valid && scan_ready) begin
                adc_valid<=1;adc_data<={harmonic_targets,scan_data[11:0]};
                mixer_valid<=mix_mode;mixer_data<=mixer_targets;
                have_previous<=1;
                for(i=0;i<4;i=i+1) begin
                    raw=scan_data[(i+1)*12+:12];
                    target=mix_mode ? (mixer_targets[i*17+:17]>=65536 ? 12'd4095 : mixer_targets[i*17+4+:12]) : harmonic_targets[i*12+:12];
                    distance=$signed({1'b0,raw})-$signed({1'b0,target});
                    movement=$signed({1'b0,raw})-$signed({1'b0,last_applied[i]});
                    crossing=have_previous && !mode_changed &&
                        ((previous[i]<=target && raw>=target)||(previous[i]>=target && raw<=target));
                    previous[i]<=raw;
                    if(!mode_changed && !invalidate[i] &&
                        (acquired[i] || (TOLERANCE==16 ? near16(raw,target) : (distance<=TOLERANCE&&distance>=-TOLERANCE)) || crossing)) begin
                        acquired[i]<=1;
                        if(!acquired[i] || (JITTER==4 ? moved4(raw,last_applied[i]) : (movement>=JITTER||movement<=-JITTER))) begin
                            last_applied[i]<=raw;
                            if(mix_mode) mixer_data[i*17+:17]<=raw_gain(raw);
                            else adc_data[(i+1)*12+:12]<=raw;
                        end else begin
                            if(mix_mode) mixer_data[i*17+:17]<=raw_gain(last_applied[i]);
                            else adc_data[(i+1)*12+:12]<=last_applied[i];
                        end
                    end else last_applied[i]<=target;
                end
            end
        end
    end
endmodule
