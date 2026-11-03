// One display bank is reused for wave, FFT and XY. Nothing here drives audio ready.
// Wave stores exactly the two normalized bytes consumed by the original renderer.
module pcb_analysis_capture #(parameter SAMPLE_CYCLES=1040)(
 input wire clk,rst,input wire [1:0] mode,input wire ready,pcm_valid,
 input wire signed [15:0] left,right,
 output wire wr,output wire [8:0] address,output wire [17:0] data,output wire publish);
 reg [1:0] previous_mode=0;
 always @(posedge clk)if(rst)previous_mode<=0;else previous_mode<=mode;
 wire mode_reset=rst || mode!=previous_mode;
 wire ww,wp,wrdy;wire [8:0] wa;wire [39:0] wd;
 wire xw,xp,xrdy;wire [7:0] xa;wire [15:0] xd;
 wire fw,fp;wire [6:0] fa;wire [17:0] fd;wire [31:0] gaps;
 assign wrdy=ready&&(mode==1 || (mode==3&&xrdy));
 av_wave_capture capture(clk,mode_reset||mode==2,wrdy,pcm_valid,left,right,ww,wa,wd,wp);
 pcb_liss_capture xy(clk,mode_reset||mode!=3,ready,ww&&mode==3,wa,wd,xrdy,xw,xa,xd,xp);
 av_spectrum_fft #(.SAMPLE_CYCLES(SAMPLE_CYCLES)) fft(clk,mode_reset||mode!=2,ready,pcm_valid,left,fw,fa,fd,fp,gaps);
 assign wr=!mode_reset && (mode==1 ? ww : mode==2 ? fw : mode==3 ? xw : 1'b0);
 assign publish=!mode_reset && (mode==1 ? wp : mode==2 ? fp : mode==3 ? xp : 1'b0);
 assign address=mode==1 ? wa : mode==2 ? {2'd0,fa} : {1'b0,xa};
 assign data=mode==1 ? {2'd0,wd[31:24],wd[15:8]} : mode==2 ? fd : {2'd0,xd};
endmodule
