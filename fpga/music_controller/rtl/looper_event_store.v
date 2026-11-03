module looper_event_store #(
    parameter LANES = 16,
    parameter LAYERS_PER_TRACK = 4,
    parameter RECORD_TICK_INPUT = 0,
    parameter EVENTS_PER_LANE = 128,
    parameter ACTIVE_NOTES = 32,
    parameter SERIAL_NOTES = 0,
    parameter LANE_W = 4,
    parameter EVENT_AW = 7,
    parameter PATCH_W = 136
)(
    input wire clk,
    input wire rst,
    input wire play_enable,
    input wire playback_reset,
    input wire loop_wrap,
    input wire [11:0] loop_tick,
    input wire [11:0] loop_length,
    input wire [1:0] quantize_mode,
    input wire record_start,
    input wire [LANE_W-1:0] record_lane,
    input wire [PATCH_W-1:0] record_patch,
    input wire record_event_valid,
    input wire [11:0] record_tick,
    input wire record_busy,
    output wire record_event_ready,
    input wire [1:0] record_event_kind,
    input wire [6:0] record_note,
    input wire [15:0] record_note_id,
    input wire [7:0] record_velocity,
    output reg recording /* synthesis syn_maxfan=32 */,
    output reg record_commit,
    output reg record_overflow,
    output reg record_error,
    output reg [7:0] recorded_events,
    input wire record_cancel,
    input wire clear_valid,
    input wire [1:0] clear_track,
    output reg removed_valid,
    output reg [1:0] removed_track,removed_layer,
    input wire undo_valid,
    input wire [LANE_W-1:0] undo_lane,
    output wire [LANES-1:0] layer_valid,output wire edit_busy,
    output reg [LANES*4-1:0] layer_timbres,
    output reg event_valid,
    input wire event_ready,
    output reg event_off,
    output reg event_drum,
    output reg event_control,
    output reg [1:0] event_track,
    output reg [1:0] event_layer,
    output reg [11:0] event_tick,
    output reg [6:0] event_note,
    output reg [15:0] event_note_id,
    output reg [7:0] event_velocity,
    output wire [2:0] event_preset,
    output reg [PATCH_W-1:0] event_patch,
    output reg [31:0] event_late_count,
    input wire export_request,output wire export_ready,input wire export_kind,
    input wire [3:0] export_lane,input wire [6:0] export_address,
    output reg export_valid,input wire export_response_ready,
    output reg export_enabled,output reg[7:0]export_count,output wire[PATCH_W-1:0]export_patch,
    output reg[31:0]export_order,output reg[44:0]export_event
);
    localparam RAM_DEPTH = LANES * EVENTS_PER_LANE;
    reg [44:0] event_ram [0:RAM_DEPTH-1];
    reg [7:0] lane_count [0:LANES-1];
    reg [EVENT_AW:0] lane_cursor [0:LANES-1];
    // A136-bit16-entry RAM wasted eight physical narrow blocks after Gowin
    // width conversion. Store eight17-bit words per patch in one18K block.
    // This is layer metadata, read once per emitted event, not per audio slot.
    localparam PATCH_WORDS=(PATCH_W+16)/17,PATCH_WORD_AW=$clog2(PATCH_WORDS),PATCH_PAD=PATCH_WORDS*17;
    (* syn_ramstyle="block_ram" *) reg [16:0] patch_words[0:LANES*(1<<PATCH_WORD_AW)-1];
    reg patch_writing,patch_reading,patch_done,native_pending;
    reg [PATCH_WORD_AW-1:0] patch_write_index;
    reg [PATCH_WORD_AW:0] patch_read_index;
    reg [LANE_W-1:0] patch_write_lane,patch_read_lane_r;
    reg [PATCH_PAD-1:0] patch_write_shift,patch_assembly;
    reg [16:0] patch_q;
    wire patch_busy=patch_reading||patch_done;
    reg [31:0] layer_order [0:LANES-1];
    reg [31:0] order_counter;
    reg [LANES-1:0] layer_valid_r;
    reg [LANES-1:0] head_valid;
    // One synchronous read port: scan and the pending native event own it
    // at disjoint times. Valid bits, not RAM reset, define payload lifetime.
    // Three15-bit words instead of a45-bit wide16-entry RAM. A header
    // lookup is outside the sample renderer and overlaps the8-word patch read.
    (* syn_ramstyle="block_ram" *) reg [14:0] head_words [0:LANES*4-1];
    reg [44:0] head_read_q;
    reg [14:0] head_word_q;
    reg [LANE_W-1:0] head_read_lane;
    reg [1:0] head_phase;
    reg head_reading,head_done;
    wire head_start=native_patch_request||(!native_pending&&!patch_busy&&metadata_state==0);
    wire [LANE_W-1:0] head_start_lane=native_patch_request ? due_lane : scan_lane;
    wire [1:0] head_address_phase=head_start ? 2'd0 : head_phase+2'd1;
    always @(posedge clk)begin
        head_word_q<=head_words[{head_start ? head_start_lane : head_read_lane,head_address_phase}];
        if(!rst)case(fetch_state)
         2:head_words[{fetch_lane,2'd0}]<=read_data[14:0];
         3:head_words[{fetch_lane,2'd1}]<=read_data[29:15];
         4:head_words[{fetch_lane,2'd2}]<=read_data[44:30];
        endcase
    end
    always @(posedge clk)begin
      if(rst)begin head_read_lane<=0;head_phase<=0;head_reading<=0;head_done<=0;end
      else begin
       head_done<=0;
       if(head_start)begin head_read_lane<=head_start_lane;head_phase<=0;head_reading<=1;end
       else if(head_reading)begin
        case(head_phase)
         0:head_read_q[14:0]<=head_word_q;
         1:head_read_q[29:15]<=head_word_q;
         2:begin head_read_q[44:30]<=head_word_q;head_reading<=0;head_done<=1;end
        endcase
        head_phase<=head_phase+1'b1;
       end
      end
    end
    reg [7:0] write_count;
    reg musical_event;
    reg [LANE_W-1:0] active_record_lane;
    reg [PATCH_W-1:0] active_record_patch;
    reg [44:0] read_data;
    reg [LANE_W+EVENT_AW-1:0] read_address;
    reg [LANE_W+EVENT_AW-1:0] write_address;
    reg read_enable,write_enable;
    reg [44:0] write_data;
    reg [2:0] fetch_state;
    reg[2:0]export_state;reg export_kind_r;reg[3:0]export_lane_r;reg[6:0]export_address_r;
    assign export_ready=!play_enable&&!recording&&!edit_busy&&!patch_busy&&!native_pending&&export_state==0&&!export_valid;
    assign export_patch=event_patch;
    always @(posedge clk)begin
        if(rst)begin export_state<=0;export_valid<=0;export_enabled<=0;export_count<=0;export_order<=0;export_event<=0;
            export_kind_r<=0;export_lane_r<=0;export_address_r<=0;end
        else begin
            if(export_valid&&export_response_ready)export_valid<=0;
            case(export_state)
                0:if(export_request&&export_ready)begin export_kind_r<=export_kind;export_lane_r<=export_lane;export_address_r<=export_address;export_state<=1;end
                1:begin export_enabled<=layer_valid_r[export_lane_r];export_count<=lane_count[export_lane_r];
                    export_order<=layer_order[export_lane_r];export_state<=2;end
                2:if(export_kind_r||patch_done)export_state<=3;
                3:begin export_event<=read_data;export_valid<=1;export_state<=0;end
                default:export_state<=0;
            endcase
        end
    end
    reg wrap_pending;
    reg close_pending,closing_requested;
    reg [5:0] close_index;
    reg [ACTIVE_NOTES-1:0] active_note_valid;
    // One prefetched synchronous23-bit RAM replaces two64-way register muxes.
    // Lookup and closure are mutually exclusive; read the next index while
    // comparing/emitting the current one. External handshake clocks unchanged.
    (* syn_ramstyle="block_ram" *) reg [22:0] active_note_mem [0:ACTIVE_NOTES-1];
    reg [22:0] active_note_q;
    wire [5:0] active_read_address=close_pending ?
        (close_index==ACTIVE_NOTES-1 ? close_index : close_index+1'b1) : lookup_busy ?
        (lookup_index==ACTIVE_NOTES-1 ? lookup_index : lookup_index+1'b1) : 6'd0;
    always @(posedge clk)active_note_q<=active_note_mem[active_read_address];
    wire [22:0] closing_note=SERIAL_NOTES ? active_note_q : active_note_mem[close_index];
    reg [5:0] active_note_free_index,active_note_match_index;
    reg active_note_free_found,active_note_match_found;
    wire close_active = close_index < ACTIVE_NOTES && active_note_valid[close_index];
    wire close_overflow = close_active && write_count >= EVENTS_PER_LANE;
    wire [44:0] close_event = {8'd0,closing_note[22:7],
        closing_note[6:0],2'd1,(loop_length == 0 ? 12'd0 : loop_length-1'b1)};
    reg [LANE_W-1:0] fetch_lane;
    reg fetch_found;
    reg [LANE_W-1:0] fetch_candidate;
    reg due_found;
    reg [LANE_W-1:0] due_lane;
    reg [1:0] due_kind_rank;
    reg [1:0] scan_rank;
    reg undo_found;
    reg [LANE_W-1:0] undo_candidate;
    reg [31:0] undo_order;
    reg [LANE_W-1:0] scan_lane;
    reg scan_commit,undo_pending;reg [11:0] scan_tick;
    reg [1:0] undo_track_r;
    reg [LANE_W-1:0] output_lane;
    reg [44:0] scan_head;
    reg scan_head_valid,scan_layer_valid;
    reg [31:0] scan_order;
    reg [EVENT_AW:0] scan_cursor;
    reg [7:0] scan_count;
    reg [2:0] metadata_state;
    integer i;
    integer reset_i;
    integer undo_i;
    integer fetch_i;
    integer due_i;

    function [11:0] quantize_tick;
        input [11:0] tick;
        input [1:0] mode;
        input [11:0] length;
        reg [23:0] rounded;
        begin
            case (mode)
                1: rounded = ((tick + 12'd24) / 12'd48) * 12'd48;
                2: rounded = ((tick + 12'd12) / 12'd24) * 12'd24;
                3: rounded = ((tick + 12'd6) / 12'd12) * 12'd12;
                default: rounded = tick;
            endcase
            if (mode == 0) quantize_tick = tick;
            else if (length != 0 && rounded >= length) quantize_tick = length - 1'b1;
            else quantize_tick = rounded[11:0];
        end
    endfunction

    assign layer_valid = layer_valid_r;
    // Background constant-grid divider by repeated bounded subtraction.
    // At 240 BPM a PPQN tick is ~130k system clocks apart. Worst 344
    // clocks per new tick; no deep /48 combinational path in the recorder.
    reg [11:0] q_tick,q_result;
    reg [1:0] q_mode;
    reg [12:0] q_remaining,q_acc;
    reg [5:0] q_grid;
    reg q_busy,q_valid;
    wire [11:0] quantizer_tick=RECORD_TICK_INPUT && record_event_valid ? record_tick : loop_tick;
    wire q_current=q_valid && q_tick==quantizer_tick && q_mode==quantize_mode;
    wire [11:0] stored_tick=q_result;
    always @(posedge clk) begin
        if(rst) begin q_tick<=0;q_result<=0;q_mode<=0;q_remaining<=0;q_acc<=0;q_grid<=12;q_busy<=0;q_valid<=0;end
        else if(!q_busy && !q_current) begin
            q_tick<=quantizer_tick;q_mode<=quantize_mode;q_valid<=0;q_acc<=0;
            case(quantize_mode)
                1:begin q_grid<=48;q_remaining<={1'b0,quantizer_tick}+13'd24;q_busy<=1;end
                2:begin q_grid<=24;q_remaining<={1'b0,quantizer_tick}+13'd12;q_busy<=1;end
                3:begin q_grid<=12;q_remaining<={1'b0,quantizer_tick}+13'd6;q_busy<=1;end
                default:begin q_result<=quantizer_tick;q_valid<=1;end
            endcase
        end else if(q_busy) begin
            if(q_remaining>=q_grid) begin q_remaining<=q_remaining-q_grid;q_acc<=q_acc+q_grid;end
            else begin
                q_result<=loop_length!=0 && q_acc>=loop_length ? loop_length-1'b1 : q_acc[11:0];
                q_valid<=1;q_busy<=0;
            end
        end
    end
    wire [44:0] packed_event = {record_velocity, record_note_id,
        record_note, record_event_kind, stored_tick};
    wire record_lane_in_range = record_lane < LANES;
    wire record_lane_available = record_lane_in_range ? !layer_valid_r[record_lane] : 1'b0;
    reg lookup_busy,lookup_valid;reg [15:0] lookup_id;reg [5:0] lookup_index;
    wire lookup_current=lookup_valid && lookup_id==record_note_id;
    assign record_event_ready = recording && !close_pending &&
        write_count < EVENTS_PER_LANE && !record_overflow && q_current && (record_event_kind>1 || !SERIAL_NOTES || lookup_current);

    generate if(SERIAL_NOTES) begin: serial_note_lookup
        always @(posedge clk) begin
            if(rst || !recording || record_cancel===1'b1) begin
                lookup_busy<=0;lookup_valid<=0;lookup_id<=0;lookup_index<=0;
                active_note_free_found<=0;active_note_match_found<=0;
                active_note_free_index<=0;active_note_match_index<=0;
            end else if(record_event_valid && record_event_ready) begin lookup_valid<=0;lookup_busy<=0;end
            else if(!lookup_busy && record_event_valid && record_event_kind<=1 && !lookup_current) begin
                lookup_id<=record_note_id;lookup_index<=0;lookup_busy<=1;lookup_valid<=0;
                active_note_free_found<=0;active_note_match_found<=0;
            end else if(lookup_busy) begin
                if(!active_note_valid[lookup_index] && !active_note_free_found) begin
                    active_note_free_found<=1;active_note_free_index<=lookup_index;
                end
                if(active_note_valid[lookup_index] && active_note_q[22:7]==lookup_id && !active_note_match_found) begin
                    active_note_match_found<=1;active_note_match_index<=lookup_index;
                end
                if(lookup_index==ACTIVE_NOTES-1) begin lookup_busy<=0;lookup_valid<=1;end
                else lookup_index<=lookup_index+1'b1;
            end
        end
    end else begin: parallel_note_lookup
    always @* begin
        active_note_free_found = 0;
        active_note_match_found = 0;
        active_note_free_index = 0;
        active_note_match_index = 0;
        for (i = 0; i < ACTIVE_NOTES; i = i + 1) begin
            if (!active_note_valid[i] && !active_note_free_found) begin
                active_note_free_found = 1;
                active_note_free_index = i[5:0];
            end
            if (active_note_valid[i] && active_note_mem[i][22:7] == record_note_id &&
                !active_note_match_found) begin
                active_note_match_found = 1;
                active_note_match_index = i[5:0];
            end
        end
    end

    end endgenerate

    // Registered lane read, bounded comparisons, one lane per three clocks.
    // No combinational sixteen-lane priority cascade or 64-bit array fanout.
    always @(posedge clk) begin
        if(rst) begin
            scan_lane<=0;metadata_state<=0;scan_commit<=0;scan_tick<=0;
            due_found<=0;due_lane<=0;due_kind_rank<=3;
            fetch_found<=0;fetch_candidate<=0;undo_found<=0;undo_candidate<=0;
            undo_order<=0;undo_pending<=0;undo_track_r<=0;
            scan_head<=0;scan_head_valid<=0;scan_layer_valid<=0;
            scan_order<=0;scan_cursor<=0;scan_count<=0;
        end else begin
            scan_commit<=0;
            if(undo_valid && !recording && !close_pending) begin
                undo_pending<=1;undo_track_r<=undo_lane[1:0];
                scan_lane<=0;metadata_state<=0;undo_found<=0;undo_order<=0;
                due_found<=0;fetch_found<=0;
            end else if(scan_tick!=loop_tick) begin
                scan_tick<=loop_tick;scan_lane<=0;metadata_state<=0;due_found<=0;fetch_found<=0;
            end else if(native_pending||patch_busy)begin
                scan_lane<=0;metadata_state<=0;due_found<=0;fetch_found<=0;
                undo_found<=0;undo_order<=0;
            end else case(metadata_state)
                0:begin
                    scan_head_valid<=head_valid[scan_lane];
                    scan_layer_valid<=layer_valid_r[scan_lane];scan_order<=layer_order[scan_lane];
                    scan_cursor<=lane_cursor[scan_lane];scan_count<=lane_count[scan_lane];
                    metadata_state<=1;
                end
                1:if(head_done)begin scan_head<=head_read_q;metadata_state<=4;end
                4:begin
                    if(scan_layer_valid && !scan_head_valid && scan_cursor<scan_count && !fetch_found) begin
                        fetch_found<=1;fetch_candidate<=scan_lane;
                    end
                    if(scan_layer_valid && scan_head_valid && scan_head[11:0]<=loop_tick &&
                       (!due_found || (scan_head[13:12]==1 && due_kind_rank!=0))) begin
                        due_found<=1;due_lane<=scan_lane;
                        due_kind_rank<=scan_head[13:12]==1 ? 0 : 1;
                    end
                    if(undo_pending && scan_lane/LAYERS_PER_TRACK==undo_track_r && scan_layer_valid &&
                       (!undo_found || scan_order>undo_order)) begin
                        undo_found<=1;undo_candidate<=scan_lane;undo_order<=scan_order;
                    end
                    if(scan_lane==LANES-1) metadata_state<=2;
                    else begin scan_lane<=scan_lane+1'b1;metadata_state<=0;end
                end
                2:begin scan_commit<=1;metadata_state<=3;end
                3:begin
                    metadata_state<=0;scan_lane<=0;due_found<=0;fetch_found<=0;
                    undo_found<=0;undo_order<=0;undo_pending<=0;
                end
            endcase
        end
    end

    always @* begin
        read_enable = scan_commit && fetch_state == 0 && fetch_found && play_enable && !playback_reset && !loop_wrap &&
                      !event_valid;
        read_address = fetch_candidate * EVENTS_PER_LANE + lane_cursor[fetch_candidate];
        if(export_state==1&&export_kind_r)begin read_enable=1;read_address={export_lane_r,export_address_r};end
        write_enable = (recording && record_event_valid && record_event_ready) ||
                       (close_pending && close_active && !record_overflow && !close_overflow);
        write_address = active_record_lane * EVENTS_PER_LANE + write_count;
        write_data = close_pending ? close_event : packed_event;
    end

    // Immutable patch bank is a separate synchronous RAM port. Do not
    // export every RAM word as a parallel bus: that forces thousands of FFs.
    assign event_preset=event_patch[2:0];
    wire patch_commit=close_pending && close_index==ACTIVE_NOTES-1 &&
        !record_overflow && !close_overflow && musical_event && write_count+(close_active ? 1'b1 : 1'b0)!=0;
    wire export_patch_request=export_state==1&&!export_kind_r;
    wire native_patch_request=!event_valid&&scan_commit&&!fetch_found&&due_found&&head_valid[due_lane]&&
        layer_valid_r[due_lane]&&play_enable&&!record_start&&!undo_pending&&!playback_reset&&!loop_wrap&&!wrap_pending&&
        !patch_busy&&!patch_writing&&!native_pending;
    wire[LANE_W-1:0]patch_read_lane=export_patch_request ? export_lane_r : due_lane;
    wire patch_begin_write=patch_commit&&!rst&&!(record_cancel===1'b1);
    wire [PATCH_PAD-1:0]patch_read_result={patch_q,patch_assembly[PATCH_PAD-1:17]};
    // Registered single read/single write. No reset loop touches RAM payload.
    always @(posedge clk)begin
        patch_q<=patch_words[{patch_read_lane_r,patch_read_index[PATCH_WORD_AW-1:0]}];
        if(patch_begin_write)patch_words[{active_record_lane,{PATCH_WORD_AW{1'b0}}}]<=active_record_patch[16:0];
        else if(patch_writing&&!rst)patch_words[{patch_write_lane,patch_write_index}]<=patch_write_shift[16:0];
    end
    always @(posedge clk)begin
        if(rst)begin patch_writing<=0;patch_reading<=0;patch_done<=0;patch_write_index<=0;patch_read_index<=0;
            patch_write_lane<=0;patch_read_lane_r<=0;patch_write_shift<=0;patch_assembly<=0;end
        else begin
            patch_done<=0;
            if(patch_begin_write)begin
                patch_write_lane<=active_record_lane;patch_write_shift<=active_record_patch>>17;
                patch_write_index<=1;patch_writing<=PATCH_WORDS>1;
            end else if(patch_writing)begin
                patch_write_shift<=patch_write_shift>>17;patch_write_index<=patch_write_index+1'b1;
                if(patch_write_index==PATCH_WORDS-1)patch_writing<=0;
            end
            if(export_patch_request||native_patch_request)begin
                patch_read_lane_r<=patch_read_lane;patch_read_index<=0;patch_reading<=1;
            end else if(patch_reading)begin
                patch_read_index<=patch_read_index+1'b1;
                if(patch_read_index!=0)patch_assembly<=patch_read_result;
                if(patch_read_index==PATCH_WORDS)begin patch_reading<=0;patch_done<=1;end
            end
        end
    end
    // One synchronous read port and one write port map to simple dual-port RAM.
    always @(posedge clk) begin
        if (read_enable) read_data <= event_ram[read_address];
        if (write_enable) event_ram[write_address] <= write_data;
    end

    always @(posedge clk) begin
        if (rst) begin
            removed_valid<=0;removed_track<=0;removed_layer<=0;output_lane<=0;
            recording <= 0;
            record_commit <= 0;
            record_overflow <= 0;
            record_error <= 0;
            recorded_events <= 0;
            write_count <= 0; musical_event <= 0;
            active_record_lane <= 0;
            active_record_patch <= 0;
            layer_valid_r <= 0;layer_timbres<=0;
            head_valid <= 0;
            fetch_state <= 0;
            wrap_pending <= 0;
            close_pending <= 0;closing_requested<=0;
            close_index <= 0;
            active_note_valid <= 0;
            fetch_lane <= 0;
            event_valid <= 0;
            event_off <= 0;
            event_drum <= 0;
            event_control <= 0;
            event_track <= 0;
            event_layer <= 0;
            event_tick <= 0;
            event_note <= 0;
            event_note_id <= 0;
            event_velocity <= 0;
            event_patch <= 0;
            native_pending<=0;
            event_late_count <= 0;
            order_counter <= 0;
            for (reset_i = 0; reset_i < LANES; reset_i = reset_i + 1) begin
                lane_count[reset_i] <= 0;
                lane_cursor[reset_i] <= 0;
                layer_order[reset_i] <= 0;
            end
            for (reset_i = 0; reset_i < ACTIVE_NOTES; reset_i = reset_i + 1) begin
            end
        end else begin
            removed_valid<=0;
            record_commit <= 0;
            record_error <= 0;
            recorded_events <= write_count;

            if (record_start) begin
                if (recording || close_pending || !record_lane_available) begin
                    record_error <= 1;
                end else begin
                    recording <= 1;
                    write_count <= 0; musical_event <= 0;
                    active_record_lane <= record_lane;
                    active_record_patch <= record_patch;
                    record_overflow <= 0;
                end
            end

            if (recording && record_event_valid) begin
                if (record_event_ready) begin
                    write_count <= write_count + 1'b1;
                    if(record_event_kind==0 || record_event_kind==2) musical_event<=1;
                    if (record_event_kind == 0) begin
                        if (active_note_match_found || !active_note_free_found) begin
                            record_overflow <= 1;
                            record_error <= 1;
                        end else begin
                            active_note_valid[active_note_free_index] <= 1;
                            active_note_mem[active_note_free_index] <= {record_note_id,record_note};
                        end
                    end else if (record_event_kind == 1) begin
                        if (active_note_match_found)
                            active_note_valid[active_note_match_index] <= 0;
                        else begin
                            record_overflow <= 1;
                            record_error <= 1;
                        end
                    end
                end else if(write_count>=EVENTS_PER_LANE || record_overflow) record_overflow <= 1;
            end

            if(recording && loop_wrap) closing_requested<=1;
            if (recording && closing_requested && !(record_busy === 1'b1) && !record_event_valid) begin
                closing_requested<=0;recording <= 0;
                close_pending <= 1;
                close_index <= 0;
            end

            if (close_pending) begin
                if (close_active) begin
                    active_note_valid[close_index] <= 0;
                    if (write_count < EVENTS_PER_LANE && !record_overflow)
                        write_count <= write_count + 1'b1;
                    else begin
                        record_overflow <= 1;
                        record_error <= 1;
                    end
                end
                if (close_index == ACTIVE_NOTES-1) begin
                    close_pending <= 0;
                    if (!record_overflow && !close_overflow && musical_event &&
                        write_count + (close_active ? 1'b1 : 1'b0) != 0) begin
                        lane_count[active_record_lane] <=
                            write_count + (close_active ? 1'b1 : 1'b0);
                        layer_valid_r[active_record_lane] <= 1;
                        layer_timbres[active_record_lane*4+:4] <= active_record_patch[2:0]==1 ? 4'd10 : active_record_patch[2:0]==7 ? 4'd7+{2'd0,active_record_patch[126:125]} : {1'b0,active_record_patch[2:0]};
                        layer_order[active_record_lane] <= order_counter;
                        order_counter <= order_counter + 1'b1;
                        lane_cursor[active_record_lane] <= 0;
                        head_valid[active_record_lane] <= 0;
                        record_commit <= 1;
                    end else record_error <= 1;
                    write_count <= 0; musical_event <= 0;
                    active_note_valid <= 0;
                end else close_index <= close_index + 1'b1;
            end

            if (scan_commit && undo_pending) begin
                if (!recording && !close_pending && undo_found) begin
                    removed_valid<=1;removed_track<=undo_candidate/LAYERS_PER_TRACK;
                    removed_layer<=undo_candidate%LAYERS_PER_TRACK;
                    if(event_valid && output_lane==undo_candidate) event_valid<=0;
                    if(native_pending && output_lane==undo_candidate)native_pending<=0;
                    layer_valid_r[undo_candidate] <= 0;
                    lane_count[undo_candidate] <= 0;
                    lane_cursor[undo_candidate] <= 0;
                    head_valid[undo_candidate] <= 0;
                end else record_error <= 1;
            end

            // Select the address BEFORE the RAM, not two independent RAM reads
            // followed by a data mux. Export and playback are mutually exclusive.
            if(patch_done)event_patch<=patch_assembly[PATCH_W-1:0];
            if(patch_done&&native_pending)begin
                    event_tick <= head_read_q[11:0];
                    event_off <= head_read_q[13:12] == 1;
                    event_drum <= head_read_q[13:12] == 2;
                    event_control <= head_read_q[13:12] == 3;
                    event_note <= head_read_q[20:14];
                    event_note_id <= head_read_q[36:21];
                    event_velocity <= head_read_q[44:37];
                    if (head_read_q[11:0] < event_tick)
                        event_late_count <= event_late_count + 1'b1;
                native_pending<=0;
                if(layer_valid_r[output_lane]&&!(scan_commit&&undo_pending&&undo_found&&undo_candidate==output_lane))event_valid<=1;
            end
            if (playback_reset || !play_enable) begin
                head_valid <= 0;
                fetch_state <= 0;
                event_valid <= 0;
                native_pending<=0;
                wrap_pending <= 0;
                for (reset_i = 0; reset_i < LANES; reset_i = reset_i + 1)
                    lane_cursor[reset_i] <= 0;
            end else if (loop_wrap && event_valid && !event_ready) begin
                wrap_pending <= 1;
            end else if ((loop_wrap || wrap_pending) &&
                         !(event_valid && !event_ready)) begin
                head_valid <= 0;
                fetch_state <= 0;
                event_valid <= 0;
                native_pending<=0;
                wrap_pending <= 0;
                for (reset_i = 0; reset_i < LANES; reset_i = reset_i + 1)
                    lane_cursor[reset_i] <= 0;
            end else begin
                case (fetch_state)
                    0: if (read_enable) begin
                        fetch_lane <= fetch_candidate;
                        fetch_state <= 1;
                    end
                    1: fetch_state <= 2;
                    2:fetch_state<=3;
                    3:fetch_state<=4;
                    4:fetch_state<=5;
                    5: begin
                        head_valid[fetch_lane] <= 1;
                        fetch_state <= 0;
                    end
                    default: fetch_state <= 0;
                endcase

                if (event_valid && event_ready) begin
                    event_valid <= 0;
                    head_valid[output_lane] <= 0;
                    lane_cursor[output_lane] <=
                        lane_cursor[output_lane] + 1'b1;
                end else if (native_patch_request) begin
                    native_pending<=1;
                    output_lane<=due_lane;
                    event_track <= due_lane / LAYERS_PER_TRACK;
                    event_layer <= due_lane % LAYERS_PER_TRACK;
                    // valid is still low: retain dispatch time here until the
                    // synchronous head arrives. Publication replaces it with
                    // the musical event tick; no extra timestamp register.
                    event_tick <= loop_tick;

                end
            end
            if(record_cancel === 1'b1) begin
                recording<=0;close_pending<=0;closing_requested<=0;write_count<=0;active_note_valid<=0;
            end
            if(clear_valid === 1'b1 && !recording && !close_pending) begin
                for(reset_i=0;reset_i<LANES;reset_i=reset_i+1)
                    if(reset_i/LAYERS_PER_TRACK==clear_track) begin
                        layer_valid_r[reset_i]<=0;lane_count[reset_i]<=0;
                        lane_cursor[reset_i]<=0;head_valid[reset_i]<=0;
                    end
                if((event_valid||native_pending) && event_track==clear_track) event_valid<=0;
                if(native_pending && event_track==clear_track)native_pending<=0;
                fetch_state<=0;
            end
        end
    end
    assign edit_busy=undo_pending||close_pending||closing_requested||removed_valid||patch_writing;
endmodule
