module looper_event_router #(
    parameter VOICES = 32,
    parameter PATCH_W = 136,
    parameter USE_ACK = 0,
    parameter SW = (VOICES > 1 ? $clog2(VOICES) : 1)
)(
    input wire clk,
    input wire rst,
    input wire live_valid,
    output wire live_ready,
    input wire [11:0] live_tick,output wire [11:0] record_tick,
    input wire live_off,
    input wire live_source,live_force_release,live_record,flush_source_valid,flush_source,
    input wire[7:0]live_velocity,input wire[PATCH_W-1:0]live_patch,
    input wire [31:0] live_token,
    input wire [6:0] live_note,
    input wire [2:0] live_preset,
    input wire recording,
    input wire record_ready,output wire record_busy,
    input wire bank_accepted,bank_rejected,
    input wire flush_all,flush_valid,
    input wire [1:0] flush_track,flush_layer,
    input wire flush_whole_track,
    output wire flushing,
    output wire record_valid,
    output wire [1:0] record_kind,
    output wire [6:0] record_note,
    output wire [15:0] record_local_id,
    output wire [7:0] record_velocity,
    input wire loop_valid,
    output wire loop_ready,
    input wire loop_off,
    input wire loop_drum,
    input wire loop_control,
    input wire [1:0] loop_track,
    input wire [1:0] loop_layer,
    input wire [15:0] loop_local_id,
    input wire [6:0] loop_note,
    input wire [7:0] loop_velocity,
    input wire [2:0] loop_preset,
    input wire [PATCH_W-1:0] loop_patch,
    output wire bank_source,output wire router_busy,
    output wire bank_valid,
    input wire bank_ready,
    output wire bank_off,
    output wire [31:0] bank_token,
    output wire [6:0] bank_note,
    output wire [2:0] bank_preset,
    output wire [2:0] bank_track,
    output wire [PATCH_W-1:0] bank_patch,
    output wire bank_loop,
    output wire [1:0] bank_layer,
    output wire bank_force_release,
    output wire [7:0] bank_velocity,
    output wire expression_valid,
    output wire [1:0] expression_kind,expression_track,expression_layer,
    output wire [16:0] expression_value,
    output wire drum_valid,
    input wire drum_ready,
    input wire drum_accepted,
    output wire [1:0] drum_layer,output wire [2:0] drum_track,
    output wire [3:0] drum_pad,
    output wire [7:0] drum_velocity,
    output reg [31:0] route_faults,
    output reg [31:0] unmatched_offs,input wire flush_live
);
    localparam IDLE=0,SCAN=1,SEND=2,ACK=3,FLUSH_SCAN=4,FLUSH_SEND=5,FLUSH_ACK=6,READ=7,FLUSH_READ=8,MAP_WRITE=9;
    reg [3:0] state;
    reg [VOICES-1:0] map_valid,map_is_live,map_recorded;
    // One synchronous 100-bit metadata RAM, masked by resettable valid bits.
    // No bulk RAM reset; note-on writes a complete record.
    (* syn_ramstyle="block_ram" *)reg[31:0]map_words[0:VOICES*4-1];
    reg[31:0]map_q;reg[2:0]read_phase;reg[1:0]write_phase;
    reg[100:0]map_data,matched_data;
    reg[47:0]write_identity;
    wire[127:0]write_record={27'd0,c_source,c_token,write_identity[47:16],c_track,c_layer,c_local,write_identity[15:0]};
    wire[SW+1:0]map_address=state==MAP_WRITE ? {free_slot,write_phase} : {scan,read_phase[1:0]};
    always @(posedge clk)begin
      if(!rst&&state==MAP_WRITE)map_words[map_address]<=write_record[write_phase*32+:32];
      else map_q<=map_words[map_address];
    end
    wire [31:0] map_source_token_w=map_data[99:68];
    wire [31:0] map_runtime_token_w=map_data[67:36];
    wire [1:0] map_track_w=map_data[35:34],map_layer_w=map_data[33:32];
    wire [15:0] map_local_id_w=map_data[31:16],map_record_id_w=matched_data[15:0];
    reg [31:0] next_runtime_token;
    reg [15:0] next_record_id;
    reg recording_prev;
    reg [SW-1:0] scan,free_slot,match_slot;
    reg free_found,match_found;
    reg c_source,c_force;reg flush_source_r,flush_source_only;
    reg c_live,c_off,c_drum,c_record,match_recorded,c_control;reg [11:0] c_tick;
    reg [31:0] c_token;
    reg [6:0] c_note;
    reg [2:0] c_preset;
    reg [1:0] c_track,c_layer;
    reg [15:0] c_local;
    reg [7:0] c_velocity;
    wire[PATCH_W-1:0]c_patch=c_live ? live_patch : loop_patch;
    reg flush_pending,flush_all_r,flush_whole_r,flush_live_r;
    reg [1:0] flush_track_r,flush_layer_r;
    reg flush_latched,flush_upgrade;
    integer i;
    wire invalid_on=!free_found || match_found || next_runtime_token==0;
    wire drop=c_off ? !match_found : invalid_on;
    wire can_record=record_ready !== 1'b0;
    wire sending=state==SEND && (!c_record || can_record);
    wire sent= sending && (c_control ? bank_ready : c_drum ? (c_off || drum_ready) : drop || bank_ready);
    assign record_busy=(state==READ || state==SCAN || state==SEND || state==ACK || state==MAP_WRITE) && c_record;
    assign flushing=flush_pending || (state==FLUSH_SCAN || state==FLUSH_SEND || state==FLUSH_ACK || state==FLUSH_READ);
    assign live_ready=sent && c_live;
    assign loop_ready=sent && !c_live;
    assign bank_valid=(sending && !c_control && !c_drum && !drop) || state==FLUSH_SEND;
    assign bank_off=state==FLUSH_SEND ? 1'b1 : c_off;
    assign bank_token=state==FLUSH_SEND ? map_runtime_token_w :
        c_off ? matched_data[67:36] : next_runtime_token;
    assign bank_note=c_note;
    assign bank_preset=c_preset;assign bank_source=c_source;assign router_busy=state!=IDLE;
    assign bank_track=c_live ? 3'd4 : {1'b0,c_track};
    assign bank_patch=c_patch;
    assign bank_loop=state==FLUSH_SEND || !c_live;
    assign bank_layer=c_layer;
    assign bank_force_release=state==FLUSH_SEND || c_force || (!c_live && c_off && c_velocity==0);
    assign bank_velocity=c_velocity;
    assign expression_valid=sending && c_control && bank_ready;
    assign expression_kind=c_note[1:0];assign expression_track=c_track;assign expression_layer=c_layer;
    assign expression_value={c_velocity[0],c_local};
    assign drum_valid=sending && c_drum && !c_off;
    assign drum_layer=c_layer;
    assign drum_track=c_live ? 3'd4 : {1'b0,c_track};
    assign drum_pad=c_note[3:0];assign drum_velocity=c_velocity;
    assign record_valid=!c_control && (USE_ACK && !c_drum && !drop ? state==ACK && bank_accepted : sent) && c_live && c_record &&
        ((c_drum && !c_off && drum_accepted !== 1'b0) || (!c_drum && !drop && (!c_off || match_recorded)));
    assign record_tick=c_tick;
    assign record_kind=c_drum ? 2'd2 : c_off ? 2'd1 : 2'd0;
    assign record_note=c_drum ? {3'd0,c_note[3:0]} : c_note;
    assign record_local_id=c_off ? map_record_id_w : next_record_id;
    assign record_velocity=c_velocity;
    task finish_immediate;
        input ok;
        begin
            if(!c_control && !c_drum && !drop && ok) begin
                if(c_off) map_valid[match_slot]<=0;
                else begin
                    map_valid[free_slot]<=1;map_is_live[free_slot]<=c_live;
                    map_recorded[free_slot]<=c_record && recording;
                    next_runtime_token<=next_runtime_token+1'b1;
                    if(c_record) next_record_id<=next_record_id+1'b1;
                end
            end
            if(!ok || (!c_control && !c_off && drop && !c_drum)) route_faults<=route_faults+1'b1;
            if(!c_control && c_off && drop) unmatched_offs<=unmatched_offs+1'b1;
            state<=IDLE;
        end
    endtask
    task finish_command;input ok;begin
      finish_immediate(ok);
      if(ok&&!c_control&&!c_drum&&!drop&&!c_off)begin
        write_identity<={next_runtime_token,(c_record ? next_record_id : 16'd0)};
        write_phase<=0;state<=MAP_WRITE;
      end
    end endtask
    always @(posedge clk) begin
        if(rst) begin
            write_identity<=0;read_phase<=0;write_phase<=0;map_data<=0;state<=IDLE;map_valid<=0;map_is_live<=0;map_recorded<=0;
            next_runtime_token<=1;next_record_id<=1;recording_prev<=0;
            scan<=0;free_slot<=0;match_slot<=0;free_found<=0;match_found<=0;
            c_source<=0;c_force<=0;flush_source_r<=0;flush_source_only<=0;
            c_tick<=0;match_recorded<=0;c_live<=0;c_off<=0;c_drum<=0;c_record<=0;c_token<=0;c_note<=0;c_preset<=0;
            c_track<=0;c_layer<=0;c_local<=0;c_velocity<=255;
            flush_pending<=0;flush_all_r<=0;flush_live_r<=0;flush_whole_r<=0;flush_track_r<=0;flush_layer_r<=0;
            flush_latched<=0;flush_upgrade<=0;route_faults<=0;unmatched_offs<=0;
            matched_data<=0;c_control<=0;
        end else begin
            // Loop identity is only meaningful after an IDLE admission. Capture
            // it throughout IDLE, independently of the combined live-valid mux.
            // The admitted event sees the same edge/data; inactive payload may
            // vary. This removes the measured C-scene -> c_local CE path.
            if(state==IDLE)c_local<=loop_local_id;
            recording_prev<=recording;
            if(recording && !recording_prev) next_record_id<=1;
            if(!recording && recording_prev) map_recorded<=0;
            // Requests are held by the control arbiter until !flushing. A
            // rising one-cycle flush_all may upgrade any outstanding request.
            if(flush_all === 1'b1 || flush_live === 1'b1) begin flush_pending<=1;flush_source_only<=0;if(flush_all === 1'b1)flush_all_r<=1;if(flush_live === 1'b1)flush_live_r<=1;if(flushing) flush_upgrade<=1;end
            else if(flush_source_valid === 1'b1)begin flush_pending<=1;flush_source_only<=1;flush_source_r<=flush_source;flush_live_r<=1;if(flushing)flush_upgrade<=1;end
            else if(flush_valid === 1'b1 && !flushing) begin
                flush_pending<=1;flush_all_r<=0;flush_track_r<=flush_track;
                flush_layer_r<=flush_layer;flush_whole_r<=flush_whole_track;
            end
            case(state)
                IDLE:if(flush_pending) begin scan<=0;state<=FLUSH_READ;end
                else if(live_valid || loop_valid) begin
                    c_live<=live_valid;c_off<=live_valid ? live_off : loop_off;
                    c_control<=!live_valid && loop_control===1'b1;
                    c_drum<=live_valid ? live_preset==6 : loop_drum;
                    c_record<=live_valid && recording && live_record!==1'b0;c_source<=live_source===1'b1;c_force<=live_valid&&(live_force_release===1'b1);c_tick<=live_tick;c_token<=live_token;
                    c_note<=live_valid ? live_note : loop_note;c_preset<=live_valid ? live_preset : loop_preset;

                    c_track<=loop_track;c_layer<=loop_layer;
                    c_velocity<=live_valid ? ((^live_velocity)===1'bx ? 8'd255 : live_velocity) : loop_velocity;
                    scan<=0;free_found<=0;match_found<=0;match_recorded<=0;state<=READ;
                end
                READ:begin
                  case(read_phase)
                    1:map_data[31:0]<=map_q;
                    2:map_data[63:32]<=map_q;
                    3:map_data[95:64]<=map_q;
                    4:map_data[100:96]<=map_q[4:0];
                  endcase
                  if(read_phase==4)begin read_phase<=0;state<=SCAN;end
                  else read_phase<=read_phase+1'b1;
                end
                SCAN:begin
                    if(!map_valid[scan] && !free_found) begin free_found<=1;free_slot<=scan;end
                    if(map_valid[scan] && (c_live ?
                        map_is_live[scan] && map_data[100]==c_source && map_source_token_w==c_token :
                        !map_is_live[scan] && map_track_w==c_track && map_layer_w==c_layer && map_local_id_w==c_local))
                        begin match_found<=1;match_slot<=scan;match_recorded<=map_recorded[scan];matched_data<=map_data;end
                    if(scan==VOICES-1) state<=SEND;else begin scan<=scan+1'b1;state<=READ;end
                end
                SEND:if(sent) begin
                    if(c_control) finish_command(1'b1);
                    else if(c_drum) finish_command(c_off || drum_accepted !== 1'b0);
                    else if(drop || !USE_ACK) finish_command(1'b1);
                    else state<=ACK;
                end
                ACK:if(bank_accepted || bank_rejected) finish_command(bank_accepted);
                FLUSH_READ:begin
                  case(read_phase)
                    1:map_data[31:0]<=map_q;
                    2:map_data[63:32]<=map_q;
                    3:map_data[95:64]<=map_q;
                    4:map_data[100:96]<=map_q[4:0];
                  endcase
                  if(read_phase==4)begin read_phase<=0;state<=FLUSH_SCAN;end
                  else read_phase<=read_phase+1'b1;
                end
                FLUSH_SCAN:begin
                    if(map_valid[scan] && (map_is_live[scan] ? (flush_live_r&&(!flush_source_only||map_data[100]==flush_source_r)) :
                       (flush_all_r || (map_track_w==flush_track_r && (flush_whole_r || map_layer_w==flush_layer_r))))) state<=FLUSH_SEND;
                    else if(scan==VOICES-1) begin
                        if(flush_upgrade) begin scan<=0;state<=FLUSH_READ;flush_upgrade<=0;end
                        else begin state<=IDLE;flush_pending<=0;flush_all_r<=0;flush_live_r<=0;end
                    end
                    else begin scan<=scan+1'b1;state<=FLUSH_READ;end
                end
                FLUSH_SEND:if(bank_ready) begin
                    if(USE_ACK) state<=FLUSH_ACK;
                    else begin map_valid[scan]<=0;state<=FLUSH_SCAN;end
                end
                FLUSH_ACK:if(bank_accepted || bank_rejected) begin map_valid[scan]<=0;state<=FLUSH_SCAN;end
                MAP_WRITE:if(write_phase==3)state<=IDLE;else write_phase<=write_phase+1'b1;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
