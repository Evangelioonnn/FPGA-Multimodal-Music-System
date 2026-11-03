// Three verified board keys and an EC11 A/B pair. No encoder press assumed.
// Commands are held until the parameter service accepts them.
module looper_controls #(parameter LONG_CYCLES=50000000,WITH_TF=0)(
    input wire clk,rst,sample_ce,input wire edit_lock,input wire [2:0] down,released,
    input wire step_valid,input wire signed [1:0] step,
    input wire transport_run,input wire host_ready,input wire has_layers,
    output reg host_valid,output reg [4:0] host_addr,output reg [31:0] host_value,
    output reg [2:0] preset,page,mode,
    output reg [1:0] track,
    output reg start_req,stop_req,record_req,undo_req,clear_req,
    output reg met_enable,output reg [7:0] bpm,
    output reg [2:0] meter,bars,output reg [8:0] click_gain,
    output reg [1:0] quantize,
    output wire [67:0] track_gains,
    output reg [3:0] muted,output reg overflow,
    input wire sync_valid,sync_remote,input wire [4:0] sync_addr,input wire [31:0] sync_value,
    input wire mixer_valid,output wire mixer_ready,input wire [67:0] mixer_data,
    output wire [67:0] mixer_targets,output reg [3:0] mixer_invalidate,
    input wire ui_valid,output wire ui_ready,input wire [7:0] ui_addr,input wire [31:0] ui_value,
    input wire ui_recording,ui_armed,ui_count_in,ui_busy,ui_flushing,input wire [15:0] ui_layers,
    input wire menu_drums_commit,
    output reg ui_ack,ui_accepted,ui_applied,output reg [7:0] ui_reason,
    output reg [31:0] ui_result

);
    reg [25:0] duration[0:2];reg [2:0] long_fired;
    reg [16:0] gains[0:3],smooth[0:3];
    reg [16:0] master;
    reg [2:0] release_idx,glide_idx;
    reg sustain,sostenuto,fx;
    reg signed [4:0] bend;
    reg [6:0] vibrato;
    reg [11:0] raw[0:3];
    integer i;
    function [31:0] bounded;
        input [31:0] x,increment,maximum;input positive;
        begin bounded=positive ? (x+increment>maximum ? maximum : x+increment) :
            (x<increment ? 0 : x-increment);end
    endfunction
    task command;
        input [4:0] a;input [31:0] v;
        begin
            if(!host_valid || host_ready) begin host_valid<=1;host_addr<=a;host_value<=v;end
            else overflow<=1;
        end
    endtask
    genvar g;generate for(g=0;g<4;g=g+1) begin: gain_output
        assign track_gains[g*17+:17]=smooth[g];
        assign mixer_targets[g*17+:17]=gains[g];
    end endgenerate
    wire ui_fire=(ui_valid===1'b1) && ui_ready;
    assign ui_ready=!rst && !(|down) && !(|released) && !step_valid;
    assign mixer_ready=sample_ce && !ui_fire;
    wire destructive_busy=(ui_recording===1'b1)||(ui_armed===1'b1)||(ui_count_in===1'b1)||
        (ui_busy===1'b1)||(ui_flushing===1'b1);
    reg [7:0] validate_reason;
    reg [1:0] action_track;
    reg [3:0] action_layers;
    always @* begin
        validate_reason=0;action_track=ui_value[1:0];
        action_layers=ui_layers[action_track*4+:4];
        case(ui_addr)
            8'h20:if(ui_value>4) validate_reason=2;
            8'h21:if((page==0 && ui_value>7)||(page==3 && ui_value>2)||(page==4 && ui_value>3)||
                ((page==1||page==2)&&ui_value!=0)) validate_reason=2;
            8'h22:if(ui_value>3) validate_reason=2;else if(destructive_busy) validate_reason=3;
            8'h23:if(ui_value!=1) validate_reason=2;else if(transport_run || destructive_busy) validate_reason=3;
            8'h24:if(ui_value!=1) validate_reason=2;
            8'h25:if(ui_value!=1) validate_reason=2;else if(destructive_busy) validate_reason=3;
                else if(ui_layers[track*4+:4]==4'hf) validate_reason=5;
            8'h26:if(ui_value>3) validate_reason=2;else if(destructive_busy) validate_reason=3;
                else if(action_layers==0) validate_reason=4;
            8'h27:if(ui_value[31:2]!=(32'h434c5200>>2)) validate_reason=2;
                else if(destructive_busy) validate_reason=3;
            8'h28:if(ui_value[31:19]!=0 || ui_value[16:0]>65536) validate_reason=2;
            8'h29:if(ui_value>7) validate_reason=2;
            8'h2a:if(ui_value<40 || ui_value>240) validate_reason=2;
            8'h2b:if(ui_value<2 || ui_value>4) validate_reason=2;else if(transport_run||has_layers||destructive_busy) validate_reason=3;
            8'h2c:if(ui_value<1 || ui_value>4) validate_reason=2;else if(transport_run||has_layers||destructive_busy) validate_reason=3;
            8'h2d:if(ui_value>3) validate_reason=2;else if(destructive_busy) validate_reason=3;
            8'h2e:if(ui_value>1) validate_reason=2;
            8'h2f:if(ui_value>256) validate_reason=2;
            default:validate_reason=1;
        endcase
        if(edit_lock&&ui_addr>=8'h22&&ui_addr<=8'h2d)validate_reason=3;
    end
    always @(posedge clk) begin
        if(rst) begin
            ui_ack<=0;ui_accepted<=0;ui_applied<=0;ui_reason<=0;ui_result<=0;
            mixer_invalidate<=0;host_valid<=0;host_addr<=0;host_value<=0;preset<=0;page<=0;mode<=0;track<=0;
            start_req<=0;stop_req<=0;record_req<=0;undo_req<=0;clear_req<=0;
            met_enable<=0;bpm<=120;meter<=4;bars<=1;click_gain<=96;quantize<=2;
            muted<=0;overflow<=0;master<=8249;release_idx<=5;glide_idx<=0;
            sustain<=0;sostenuto<=0;fx<=0;bend<=0;vibrato<=0;long_fired<=0;
            for(i=0;i<3;i=i+1) duration[i]<=0;
            for(i=0;i<4;i=i+1) begin gains[i]<=65536;smooth[i]<=65536;end
            raw[0]<=4095;raw[1]<=1024;raw[2]<=512;raw[3]<=256;
        end else begin
            ui_ack<=0;ui_accepted<=0;ui_applied<=0;
            mixer_invalidate<=0;
            start_req<=0;stop_req<=0;record_req<=0;undo_req<=0;clear_req<=0;
            if(host_valid && host_ready) host_valid<=0;
            for(i=0;i<3;i=i+1) begin
                if(!down[i]) begin duration[i]<=0;long_fired[i]<=0;end
                else if(duration[i]<LONG_CYCLES) duration[i]<=duration[i]+1'b1;
            end
            if(sample_ce) for(i=0;i<4;i=i+1) begin
                if(muted[i]) smooth[i]<=smooth[i]>128 ? smooth[i]-17'd128 : 0;
                else if(smooth[i]<gains[i]) smooth[i]<=gains[i]-smooth[i]<=128 ? gains[i] : smooth[i]+17'd128;
                else if(smooth[i]>gains[i]) smooth[i]<=smooth[i]-gains[i]<=128 ? gains[i] : smooth[i]-17'd128;
            end
            if(ui_fire) begin
                ui_ack<=1;ui_reason<=validate_reason;ui_accepted<=validate_reason==0;ui_applied<=validate_reason==0;
                ui_result<={validate_reason,ui_addr,ui_result[15:0]+16'd1};
                if(validate_reason==0) case(ui_addr)
                    8'h20:begin page<=ui_value[2:0];mode<=0;end
                    8'h21:mode<=ui_value[2:0];
                    8'h22:track<=ui_value[1:0];
                    8'h23:start_req<=1;
                    8'h24:stop_req<=1;
                    8'h25:begin record_req<=1;if(!transport_run) start_req<=1;end
                    8'h26:begin track<=ui_value[1:0];undo_req<=1;end
                    8'h27:begin track<=ui_value[1:0];clear_req<=1;end
                    8'h28:begin gains[ui_value[18:17]]<=ui_value[16:0];mixer_invalidate[ui_value[18:17]]<=1;end
                    8'h29:muted[ui_value[2:1]]<=ui_value[0];
                    8'h2a:bpm<=ui_value[7:0];8'h2b:meter<=ui_value[2:0];8'h2c:bars<=ui_value[2:0];
                    8'h2d:quantize<=ui_value[1:0];8'h2e:met_enable<=ui_value[0];8'h2f:click_gain<=ui_value[8:0];
                    default:begin end
                endcase
            end else if(down[2] && duration[2]==LONG_CYCLES-1 && !long_fired[2]) begin
                long_fired[2]<=1;met_enable<=!met_enable;
            end else if(page==1 && down[0] && duration[0]==LONG_CYCLES-1 && !long_fired[0]) begin
                long_fired[0]<=1;clear_req<=1;
            end else if(page==1 && down[1] && duration[1]==LONG_CYCLES-1 && !long_fired[1]) begin
                long_fired[1]<=1;undo_req<=1;
            end else if(released[2] && !long_fired[2]) begin page<=page==4 ? 0 : page+1'b1;mode<=0;end
            else if(released[0] && !long_fired[0]) case(page)
                0:begin
                    case(preset)
                        0:begin preset<=3;command(0,3);end
                        2:begin preset<=3;command(0,3);end
                        3:begin preset<=4;command(0,4);end
                        4:begin preset<=5;command(0,5);end
                        5:begin preset<=6;command(0,0);end
                        default:begin preset<=0;command(0,0);end
                    endcase
                end
                1:if(transport_run) stop_req<=1;else start_req<=1;
                2:muted[track]<=!muted[track];
                3:met_enable<=!met_enable;
                4:begin preset<=5;command(0,5);end
            endcase
            else if(released[1] && !long_fired[1]) case(page)
                0:mode<=mode==7 ? 0 : mode+1'b1;
                1:begin record_req<=1;if(!transport_run) start_req<=1;end
                2:track<=track+1'b1;
                3:mode<=mode==2 ? 0 : mode+1'b1;
                4:mode<=mode==3 ? 0 : mode+1'b1;
            endcase
            else if(step_valid && page==1 && !transport_run && down[0]) begin
                quantize<=step>0 ? quantize+1'b1 : quantize-1'b1;long_fired[0]<=1;
            end else if(step_valid && page==1 && !transport_run && down[1]) begin
                if(!has_layers) bars<=step>0 ? (bars==4 ? 4 : bars+1'b1) : (bars==1 ? 1 : bars-1'b1);
                long_fired[1]<=1;
            end else if(step_valid) case(page)
                0:case(mode)
                    0:begin master<=bounded(master,2048,65536,step>0);command(1,bounded(master,2048,65536,step>0));end
                    1:begin release_idx<=bounded(release_idx,1,7,step>0);command(7,bounded(release_idx,1,7,step>0));end
                    2:begin sustain<=step>0;command(5,step>0);end
                    3:begin sostenuto<=step>0;command(6,step>0);end
                    4:begin glide_idx<=bounded(glide_idx,1,4,step>0);command(8,bounded(glide_idx,1,4,step>0));end
                    5:if((step>0 && bend<8)||(step<0 && bend> -8)) begin
                        bend<=bend+step;command(9,$signed(bend)+$signed(step));end
                    6:begin vibrato<=bounded(vibrato,4,64,step>0);command(16,bounded(vibrato,4,64,step>0));end
                    7:begin fx<=step>0;command(18,step>0);end
                endcase
                1:track<=step>0 ? track+1'b1 : track-1'b1;
                2:begin gains[track]<=bounded(gains[track],2048,65536,step>0);mixer_invalidate[track]<=1;end
                3:case(mode)
                    0:if(step>0 && bpm<240) bpm<=bpm+1'b1;else if(step<0 && bpm>40) bpm<=bpm-1'b1;
                    1:if(!transport_run && !has_layers) meter<=step>0 ? (meter==4 ? 2 : meter+1'b1) : (meter==2 ? 4 : meter-1'b1);
                    2:click_gain<=bounded(click_gain,8,256,step>0);
                endcase
                4:begin raw[mode[1:0]]<=bounded(raw[mode[1:0]],64,4095,step>0);
                    command(20+mode,bounded(raw[mode[1:0]],64,4095,step>0));end
            endcase
            if(mixer_valid===1'b1 && mixer_ready)
                for(i=0;i<4;i=i+1) gains[i]<=mixer_data[i*17+:17]>65536 ? 17'd65536 : mixer_data[i*17+:17];
            if(sync_valid===1'b1) case(sync_addr)
                0:if((!(preset==6 && sync_value==0) || sync_remote===1'b1) && (sync_value==0||sync_value==3||sync_value==4||sync_value==5||(sync_value>=7&&sync_value<=10))) preset<=sync_value==10 ? 3'd1 : sync_value>=7 ? 3'd7 : sync_value[2:0];
                1:master<=sync_value[16:0];
                5:sustain<=sync_value[0];6:sostenuto<=sync_value[0];
                7:release_idx<=sync_value[2:0];8:glide_idx<=sync_value[2:0];9:bend<=sync_value[4:0];
                16:vibrato<=sync_value[6:0];18:fx<=sync_value[0];
                20,21,22,23:raw[sync_addr-20]<=sync_value[11:0];
            endcase
            if(menu_drums_commit===1'b1) preset<=6;
        end
    end
endmodule
