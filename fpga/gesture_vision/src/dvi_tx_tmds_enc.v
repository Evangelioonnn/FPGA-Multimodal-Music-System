module dvi_tx_tmds_enc(
	input					clock,
	input					rstn,

	input					den,
	input		[7: 0]		data,
	input		[1: 0]		ctrl,
	output reg	[9: 0]		tmds
);
	reg	[7: 0]		data_reg;
	reg				den_reg;
	reg	[1: 0]		ctrl_reg;
	wire [9: 0]		tmds_int;
    wire qm_flip;
	
	reg [8: 0]		cnt_q;
	reg [8: 0]		cnt_d;
	reg	[8: 0]		q_m;
	reg [8:0] q_m_pipe;
	reg [3:0] q_m_low_pipe, data_high_pipe;
	reg qm_flip_pipe, qm_flag_pipe;
	reg den_qm;
	reg [1:0] ctrl_qm;
	reg den_pipe;
	reg [1:0] ctrl_pipe;
    reg [3:0] ones_pipe;
	
	reg	[9: 0]		q_out;
	wire [8: 0]		q_m_temp;
	wire [8:0] q_m_complete;
	
	
/////////////////////////////////////////////////////////////
function [3:0] count_ones;
 input [7:0] data_in;
 reg [1:0] p0,p1,p2,p3;
 reg [2:0] q0,q1;
 begin
  p0={1'b0,data_in[0]}+{1'b0,data_in[1]}; p1={1'b0,data_in[2]}+{1'b0,data_in[3]};
  p2={1'b0,data_in[4]}+{1'b0,data_in[5]}; p3={1'b0,data_in[6]}+{1'b0,data_in[7]};
  q0={1'b0,p0}+{1'b0,p1}; q1={1'b0,p2}+{1'b0,p3}; count_ones={1'b0,q0}+{1'b0,q1};
 end
endfunction
/////////////////////////////////////////////////////////////
	
	
/////////////////////////////////////////////////////////////
always@(posedge clock or negedge rstn)begin
	
	if(!rstn)begin
		data_reg <= 0;
		ctrl_reg <= 0;
		den_reg <= 0;
		tmds <= 0;
		cnt_q <= 0;
		q_m_pipe <= 0;
		q_m_low_pipe <= 0;
		data_high_pipe <= 0;
		qm_flip_pipe <= 0;
		qm_flag_pipe <= 0;
		den_qm <= 0;
		ctrl_qm <= 0;
		den_pipe <= 0;
		ctrl_pipe <= 0;
        ones_pipe <= 0;
	end else begin
		data_reg <= data;
		den_reg <= den;
		ctrl_reg <= ctrl;
		q_m_low_pipe <= q_m_temp[3:0];
		data_high_pipe <= data_reg[7:4];
		qm_flip_pipe <= qm_flip;
		qm_flag_pipe <= q_m_temp[8];
		den_qm <= den_reg;
		ctrl_qm <= ctrl_reg;
		q_m_pipe <= q_m_complete;
		den_pipe <= den_qm;
		ctrl_pipe <= ctrl_qm;
        ones_pipe <= count_ones(q_m_complete[7:0]);
		tmds <= tmds_int;
		cnt_q <= cnt_d;
	end
end
/////////////////////////////////////////////////////////////
	
	
/////////////////////////////////////////////////////////////

assign qm_flip = (count_ones(data_reg) > 4) | ((count_ones(data_reg) == 4) & (!data_reg[0])) ? 1'b1 : 1'b0;

assign q_m_temp[0] = data_reg[0];
assign q_m_temp[1] = (qm_flip) ? ~(q_m_temp[0] ^ data_reg[1]) : (q_m_temp[0] ^ data_reg[1]);
assign q_m_temp[2] = (qm_flip) ? ~(q_m_temp[1] ^ data_reg[2]) : (q_m_temp[1] ^ data_reg[2]);
assign q_m_temp[3] = (qm_flip) ? ~(q_m_temp[2] ^ data_reg[3]) : (q_m_temp[2] ^ data_reg[3]);
assign q_m_temp[4] = (qm_flip_pipe) ? ~(q_m_low_pipe[3] ^ data_high_pipe[0]) : (q_m_low_pipe[3] ^ data_high_pipe[0]);
assign q_m_temp[5] = (qm_flip_pipe) ? ~(q_m_temp[4] ^ data_high_pipe[1]) : (q_m_temp[4] ^ data_high_pipe[1]);
assign q_m_temp[6] = (qm_flip_pipe) ? ~(q_m_temp[5] ^ data_high_pipe[2]) : (q_m_temp[5] ^ data_high_pipe[2]);
assign q_m_temp[7] = (qm_flip_pipe) ? ~(q_m_temp[6] ^ data_high_pipe[3]) : (q_m_temp[6] ^ data_high_pipe[3]);
assign q_m_temp[8] = (qm_flip) ? 1'b0 : 1'b1;

assign q_m_complete[3:0] = q_m_low_pipe;
assign q_m_complete[7:4] = {q_m_temp[7:4]};
assign q_m_complete[8] = qm_flag_pipe;

always@(*)begin
	q_m <= q_m_temp;
end
/////////////////////////////////////////////////////////////

wire ones_equ_f;
wire ones_larg_f;
wire ones_sml_f;

assign ones_equ_f = (ones_pipe == 4) ? 1'b1 : 1'b0;
assign ones_larg_f = (ones_pipe > 4) ? 1'b1 : 1'b0;
assign ones_sml_f = (ones_pipe < 4) ? 1'b1 : 1'b0;

/////////////////////////////////////////////////////////////
always@(*)begin
	
	if(!den_pipe)begin
		
		case(ctrl_pipe)
			2'b00:   q_out = 10'b1101010100;
			2'b01:   q_out = 10'b0010101011;
			2'b10:   q_out = 10'b0101010100;
			2'b11:   q_out = 10'b1010101011;
		endcase
		
	end else if( ($signed(cnt_q) == 0) | ones_equ_f)begin
		
		q_out[9] = ~q_m_pipe[8];
		q_out[8] = q_m_pipe[8];
		
		if(q_m_pipe[8])begin
			q_out[7 : 0] = q_m_pipe[7 : 0];
		end else begin
			q_out[7 : 0] = ~q_m_pipe[7 : 0];
		end
		
	end else if(
		( ($signed(cnt_q) > 0) & ones_larg_f ) | 
		( ($signed(cnt_q) < 0) & ones_sml_f )
	)begin
		q_out[9] = 1'b1;
		q_out[8] = q_m_pipe[8];
		q_out[7 : 0] = ~q_m_pipe[7 : 0];
	end else begin
		q_out[9] = 1'b0;
		q_out[8] = q_m_pipe[8];
		q_out[7 : 0] = q_m_pipe[7 : 0];
	end
end

assign tmds_int = q_out;
/////////////////////////////////////////////////////////////


/////////////////////////////////////////////////////////////
always@(*)begin
	
	if(!den_pipe)begin

		cnt_d = 0;
		
	end else if( ($signed(cnt_q) == 0) | ones_equ_f )begin
		
		if(q_m_pipe[8])begin
			cnt_d = $signed(cnt_q) + 2 * (ones_pipe - 4);
		end else begin
			cnt_d = $signed(cnt_q) + 2 * (4 - ones_pipe);
		end
		
	end else if(
		( ($signed(cnt_q) > 0) & ones_larg_f ) | 
		( ($signed(cnt_q) < 0) & ones_sml_f )
	)begin
		
		if(q_m_pipe[8])begin
			cnt_d = $signed(cnt_q) + 2 + 2 * (4 - ones_pipe);
		end else begin
			cnt_d = $signed(cnt_q) + 2 * (4 - ones_pipe);
		end
		
	end else begin
		
		if(!q_m_pipe[8])begin
			cnt_d = ($signed(cnt_q) - 2) + 2 * (ones_pipe - 4);
		end else begin
			cnt_d = $signed(cnt_q) + 2 * (ones_pipe - 4);
		end
	end
end
/////////////////////////////////////////////////////////////

endmodule
