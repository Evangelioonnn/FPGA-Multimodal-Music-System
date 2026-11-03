// Local playable-gallery fork; baseline sources remain unchanged.
// Snapshot queue + per-strike identity. Never merges equal note pitches.
module looper_keys #(parameter DEPTH=8,parameter KEYS=24,parameter SPLIT=12,parameter DIATONIC=0,parameter KW=(KEYS>1?$clog2(KEYS):1))(
    input wire clk,rst,external_panic,changed,ghost,all_released,
    input wire [KEYS-1:0] keys,input wire [2:0] timbre, input wire [6:0] left_base,right_base,
    output wire event_valid,input wire event_ready,
    output reg event_off,output reg [31:0] event_token,
    output reg [6:0] event_note,output reg [2:0] event_timbre,
    output wire fault_pulse,output reg blocked,overflow_seen,token_exhausted,
    output reg [31:0] fault_count
);
    wire q_ready,q_valid;
    wire [KEYS+16:0] q_data;
    wire [$clog2(DEPTH+1)-1:0] level;
    reg working,previous_ghost,pending;
    reg [KW-1:0] event_key;
    reg [KEYS-1:0] target,owned;
    reg [2:0] target_timbre;
    reg [6:0] target_left,target_right;
    reg [7:0] mapped_note;reg [6:0] offset;
    reg [31:0] next_token;
    // Only OFF needs the immutable ON identity. One synchronous read port
    // replaces three parallel register muxes. Owned bits guard uninitialized
    // RAM; each accepted ON writes all42 bits before any OFF can request it.
    (* syn_ramstyle="block_ram" *) reg [41:0] owner_mem[0:KEYS-1];
    reg [41:0] owner_q;reg owner_wait;
    reg found,off;
    reg [KW-1:0] index,selected_index;reg selected_off,selection_valid;
    integer i,j;
    wire overflow=changed && !blocked && level==DEPTH && !external_panic && !ghost;
    // Exhaustion needs only the existence of an ON with no earlier OFF, not
    // the priority-selected key index. This is exactly the same predicate.
    wire exhausted_request=working && (|(target & ~owned)) && !(|(owned & ~target)) && next_token==0;
    // Break the fault fanout path before FIFO flush, token writes and recorder gates.
    // Fault handling is delayed one 50MHz clock; normal transactions are unchanged.
    reg fault_q;
    always @(posedge clk) if(rst) fault_q<=0;
      else fault_q<=overflow || (ghost && !previous_ghost) || (exhausted_request && !token_exhausted);
    assign fault_pulse=!rst && fault_q;
    wire flush=external_panic || blocked || fault_pulse;
    wire pop=!working && !flush;
    stream_fifo #(.WIDTH(KEYS+17),.DEPTH(DEPTH)) snapshots(clk,rst,flush,
        changed && !ghost && !flush,{left_base,right_base,timbre,keys},q_ready,q_valid,q_data,pop,level);
    wire [KEYS-1:0] off_requests=owned & ~target;
    wire [KEYS-1:0] requests=(|off_requests) ? off_requests : target & ~owned;
    wire [KEYS-1:0] first_request=requests & (~requests+1'b1);
    always @* begin
        found=|requests;off=|off_requests;index=0;
        for(i=0;i<KEYS;i=i+1) index=index | ({KW{first_request[i]}} & i);
    end
    always @* begin
        offset=selected_index<SPLIT ? selected_index : selected_index-SPLIT;
        if(DIATONIC) case(offset)
            0:offset=0;1:offset=2;2:offset=4;3:offset=5;
            4:offset=7;5:offset=9;6:offset=11;default:offset=12;
        endcase
        mapped_note=target_timbre==6 ? selected_index : {1'b0,(selected_index<SPLIT ? target_left : target_right)}+{1'b0,offset};
        if(target_timbre==6) case(selected_index)
            5:mapped_note=9;6:mapped_note=5;7:mapped_note=6;
            8:mapped_note=7;9:mapped_note=8;default:begin end
        endcase
    end
    // Register the transaction: key priority/token lookup must not feed the
    // bank's identity comparator/allocator in the same 50MHz timing path.
    assign event_valid=pending && !flush && !token_exhausted;
    always @(posedge clk)begin
        owner_q<=owner_mem[selected_index];
        if(!rst&&!flush&&event_valid&&event_ready&&!event_off)
            owner_mem[event_key]<={event_timbre,event_note,next_token};
    end
    always @(posedge clk) begin
        if(rst) begin
            blocked<=1;overflow_seen<=0;token_exhausted<=0;fault_count<=0;previous_ghost<=0;
            working<=0;target<=0;owned<=0;target_timbre<=0;target_left<=48;target_right<=60;next_token<=1;
            pending<=0;event_key<=0;event_off<=0;event_token<=0;event_note<=60;event_timbre<=0;
            owner_wait<=0;selection_valid<=0;selected_index<=0;selected_off<=0;
        end else begin
            previous_ghost<=ghost;
            if(overflow) overflow_seen<=1;
            if(exhausted_request) token_exhausted<=1;
            if(fault_pulse) fault_count<=fault_count+1'b1;
            if(external_panic || fault_pulse) blocked<=1;
            else if(blocked && all_released && keys==0 && !ghost && !token_exhausted) blocked<=0;
            if(flush) begin working<=0;target<=0;owned<=0;pending<=0;owner_wait<=0;selection_valid<=0;end
            else if(!working && q_valid) begin working<=1;target<=q_data[KEYS-1:0];target_timbre<=q_data[KEYS+2:KEYS];target_right<=q_data[KEYS+9:KEYS+3];target_left<=q_data[KEYS+16:KEYS+10];end
            else if(working) begin
                if(pending) begin
                    if(event_valid && event_ready) begin
                        pending<=0;selection_valid<=0;owned[event_key]<=!event_off;
                        if(!event_off) next_token<=next_token+1'b1;
                    end
                end else if(!selection_valid)begin
                    if(!found)working<=0;
                    else if(!exhausted_request)begin
                        selected_index<=index;selected_off<=off;selection_valid<=1;owner_wait<=0;
                    end
                end else if(!exhausted_request&&selected_off&&!owner_wait)owner_wait<=1;
                else if(!exhausted_request) begin
                    owner_wait<=0;
                    pending<=1;event_key<=selected_index;event_off<=selected_off;
                    event_token<=selected_off ? owner_q[31:0] : next_token;
                    event_note<=selected_off ? owner_q[38:32] : mapped_note>127 ? 7'd127 : mapped_note[6:0];event_timbre<=selected_off ? owner_q[41:39] : target_timbre;
                end
            end
        end
    end
endmodule
