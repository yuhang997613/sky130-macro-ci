// mlc_storage_macro.v -- SKY130 OpenRAM macro port of the MLC storage controller.
//
// Same external interface / CSR behaviour as mlc_storage.v, but the behavioural
// `reg [2:0] mem [0:79]` array is replaced by one OpenRAM
// sky130_sram_1kbyte_1rw1r_32x256_8 macro (256 x 32, 1rw1r, 8-bit write mask).
//
// Mapping
//   cell index 0..79  ==  macro address 0..79  (cell = a*5 + k)
//   port 0 (RW)  : writes, csb0=0 web0=0 wmask0=4'b0001 din0={29'b0, cell_value}
//   port 1 (R)   : reads,  csb1=0 addr1=cell, dout1[2:0] -> data, 1-cycle latency
//
// The OpenRAM behavioural model registers its inputs on the rising clock edge and
// drives dout1 on the following falling edge, so a read request issued in cycle N
// is sampled at the rising edge that ends cycle N+1.  The FSM therefore carries a
// dedicated wait state after every read request (S_W_WAIT / S_WV_WAIT / S_R_WAIT /
// S_INJ_CAP) and, because port 0 commits a write on the falling edge of the cycle
// after the write is driven, one extra commit state (S_W_COMMIT) keeps the
// write-verify read-back off the same address in the same cycle.
//
// The error-injection hook (inj_en/inj_idx/inj_mask) can no longer be a
// combinational array poke; it is a latched read-modify-write on the macro
// (S_INJ_RD -> S_INJ_CAP -> S_INJ_WR) performed when the FSM is idle.
`timescale 1ns/1ps
module mlc_storage_macro (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  addr,
    input  wire [7:0]  wdata,
    input  wire        we,
    input  wire        re,
    output reg  [7:0]  rdata,
    output reg         corrected,
    output reg         uncorrected,
    output reg         busy,
    output reg         done,
    output reg  [15:0] energy_q,
    output reg  [15:0] pulses,
    input  wire        inj_en,
    input  wire [6:0]  inj_idx,
    input  wire [2:0]  inj_mask
);
    localparam S_IDLE      = 5'd0;
    localparam S_W_LOAD    = 5'd1;
    localparam S_W_WAIT    = 5'd2;
    localparam S_W_CMP     = 5'd3;
    localparam S_W_PULSE   = 5'd4;
    localparam S_W_COMMIT  = 5'd5;
    localparam S_W_VER     = 5'd6;
    localparam S_WV_WAIT   = 5'd7;
    localparam S_W_NEXT    = 5'd8;
    localparam S_W_DONE    = 5'd9;
    localparam S_R_LOAD    = 5'd10;
    localparam S_R_WAIT    = 5'd11;
    localparam S_R_DEC     = 5'd12;
    localparam S_R_DONE    = 5'd13;
    localparam S_FAIL      = 5'd14;
    localparam S_INJ_RD    = 5'd15;
    localparam S_INJ_CAP   = 5'd16;
    localparam S_INJ_WR    = 5'd17;

    localparam MAX_PULSES = 4'd8;

    // ---------------- OpenRAM 256x32 1rw1r SRAM ----------------
    wire        sram_csb0, sram_web0;
    wire [3:0]  sram_wmask0;
    wire [7:0]  sram_addr0, sram_addr1;
    wire [31:0] sram_din0, sram_dout1;
    wire        sram_csb1;

    sky130_sram_1kbyte_1rw1r_32x256_8 u_sram (
        .clk0(clk),
        .csb0(sram_csb0),
        .web0(sram_web0),
        .wmask0(sram_wmask0),
        .addr0(sram_addr0),
        .din0(sram_din0),
        .dout0(),
        .clk1(clk),
        .csb1(sram_csb1),
        .addr1(sram_addr1),
        .dout1(sram_dout1)
    );

    reg [2:0] cur, tgt, step;
    reg [3:0] delta;
    reg [2:0] k;                 // cell index
    reg [4:0] state;
    reg [3:0] a;                 // latched address
    reg [7:0] wbuf;
    reg [12:0] cw;               // codeword being written / read
    reg [3:0] cell_pulses;
    reg [3:0] sy;
    reg       par;

    reg        inj_pend;
    reg [6:0]  inj_idx_q;
    reg [2:0]  inj_mask_q;
    reg [2:0]  inj_data_q;

    // ---------------- macro port drive ----------------
    wire [6:0] cell_idx = {3'b000, a} * 5 + {4'b0000, k};   // 0..79

    reg rd_cyc, wr_cyc;
    always @* begin
        rd_cyc = (state == S_W_LOAD)  || (state == S_W_WAIT)  ||
                 (state == S_W_VER)   || (state == S_WV_WAIT) ||
                 (state == S_R_LOAD)  || (state == S_R_WAIT)  ||
                 (state == S_INJ_RD)  || (state == S_INJ_CAP);
        wr_cyc = (state == S_W_PULSE) || (state == S_INJ_WR);
    end

    wire [2:0] pulse_val = (tgt > cur) ? (cur + step) : (cur - step);
    wire [2:0] inj_val   = inj_data_q ^ inj_mask_q;

    assign sram_csb1   = ~rd_cyc;                       // port 1 read enable
    assign sram_addr1  = ((state == S_INJ_RD) || (state == S_INJ_CAP))
                         ? {1'b0, inj_idx_q} : {1'b0, cell_idx};
    assign sram_csb0   = ~wr_cyc;                       // port 0 write enable
    assign sram_web0   = ~wr_cyc;
    assign sram_addr0  = (state == S_INJ_WR) ? {1'b0, inj_idx_q} : {1'b0, cell_idx};
    assign sram_din0   = {29'b0, (state == S_INJ_WR) ? inj_val : pulse_val};
    assign sram_wmask0 = 4'b0001;                       // byte lane 0 only

    // ---------------- SECDED (13,8) ----------------
    function [12:0] ecc_encode(input [7:0] d);
        reg [12:0] c;
        begin
            c = 13'd0;
            c[3]  = d[0];
            c[5]  = d[1];
            c[6]  = d[2];
            c[7]  = d[3];
            c[9]  = d[4];
            c[10] = d[5];
            c[11] = d[6];
            c[12] = d[7];
            c[1]  = c[3] ^ c[5] ^ c[7] ^ c[9] ^ c[11];
            c[2]  = c[3] ^ c[6] ^ c[7] ^ c[10] ^ c[11];
            c[4]  = c[5] ^ c[6] ^ c[7] ^ c[12];
            c[8]  = c[9] ^ c[10] ^ c[11] ^ c[12];
            c[0]  = ^c[12:1];
            ecc_encode = c;
        end
    endfunction

    function [7:0] ecc_data(input [12:0] c);
        ecc_data = {c[12], c[11], c[10], c[9], c[7], c[6], c[5], c[3]};
    endfunction

    function [2:0] cell_tgt(input [12:0] c, input [2:0] kk);
        case (kk)
            3'd0: cell_tgt = c[2:0];
            3'd1: cell_tgt = c[5:3];
            3'd2: cell_tgt = c[8:6];
            3'd3: cell_tgt = c[11:9];
            default: cell_tgt = {2'b00, c[12]};
        endcase
    endfunction

    task ecc_syndrome(input [12:0] c, output [3:0] s, output p);
        reg s1, s2, s4, s8;
        begin
            s1 = c[1] ^ c[3] ^ c[5] ^ c[7] ^ c[9] ^ c[11];
            s2 = c[2] ^ c[3] ^ c[6] ^ c[7] ^ c[10] ^ c[11];
            s4 = c[4] ^ c[5] ^ c[6] ^ c[7] ^ c[12];
            s8 = c[8] ^ c[9] ^ c[10] ^ c[11] ^ c[12];
            s  = {s8, s4, s2, s1};
            p  = ^c;
        end
    endtask

    always @* begin
        delta = (tgt > cur) ? (tgt - cur) : (cur - tgt);
        step = (delta * 3) >> 3;
        if (step == 3'd0) step = 3'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            corrected <= 1'b0;
            uncorrected <= 1'b0;
            energy_q <= 16'd0;
            pulses <= 16'd0;
            rdata <= 8'd0;
            k <= 3'd0;
            cell_pulses <= 4'd0;
            cur <= 3'd0;
            tgt <= 3'd0;
            cw <= 13'd0;
            a <= 4'd0;
            inj_pend <= 1'b0;
            inj_idx_q <= 7'd0;
            inj_mask_q <= 3'd0;
            inj_data_q <= 3'd0;
        end else begin
            // injection request: latched, executed as RMW when the FSM is idle
            if (inj_en && (state != S_INJ_RD) && (state != S_INJ_CAP) &&
                (state != S_INJ_WR)) begin
                inj_idx_q  <= inj_idx;
                inj_mask_q <= inj_mask;
                inj_pend   <= 1'b1;
            end
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    done <= 1'b0;
                    corrected <= 1'b0;
                    uncorrected <= 1'b0;
                    if (inj_pend) begin
                        inj_pend <= 1'b0;
                        state <= S_INJ_RD;
                    end else if (we) begin
                        a <= addr;
                        cw <= ecc_encode(wdata);
                        wbuf <= wdata;
                        k <= 3'd0;
                        cell_pulses <= 4'd0;
                        energy_q <= 16'd0;
                        pulses <= 16'd0;
                        busy <= 1'b1;
                        state <= S_W_LOAD;
                    end else if (re) begin
                        a <= addr;
                        cw <= 13'd0;
                        k <= 3'd0;
                        busy <= 1'b1;
                        state <= S_R_LOAD;
                    end
                end
                // ---- write one word: five cells ----
                // read current cell value (port 1), 1-cycle macro latency
                S_W_LOAD: begin
                    tgt <= cell_tgt(cw, k);
                    state <= S_W_WAIT;
                end
                S_W_WAIT: begin
                    cur <= sram_dout1[2:0];
                    state <= S_W_CMP;
                end
                S_W_CMP: begin
                    if (delta == 4'd0) begin
                        state <= S_W_NEXT;
                    end else if (cell_pulses >= MAX_PULSES) begin
                        state <= S_FAIL;
                    end else begin
                        state <= S_W_PULSE;
                    end
                end
                S_W_PULSE: begin
                    energy_q <= energy_q + 16'd1;
                    pulses <= pulses + 16'd1;
                    cell_pulses <= cell_pulses + 4'd1;
                    state <= S_W_COMMIT;
                end
                // write commits on the falling edge of this cycle
                S_W_COMMIT: begin
                    state <= S_W_VER;
                end
                S_W_VER: begin
                    state <= S_WV_WAIT;
                end
                S_WV_WAIT: begin
                    cur <= sram_dout1[2:0];
                    state <= S_W_CMP;
                end
                S_W_NEXT: begin
                    if (k == 3'd4) begin
                        state <= S_W_DONE;
                    end else begin
                        k <= k + 3'd1;
                        cell_pulses <= 4'd0;
                        state <= S_W_LOAD;
                    end
                end
                S_W_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    if (!we) state <= S_IDLE;
                end
                // ---- read one word: five cells ----
                S_R_LOAD: begin
                    state <= S_R_WAIT;
                end
                S_R_WAIT: begin
                    case (k)
                        3'd0: cw[2:0]  <= sram_dout1[2:0];
                        3'd1: cw[5:3]  <= sram_dout1[2:0];
                        3'd2: cw[8:6]  <= sram_dout1[2:0];
                        3'd3: cw[11:9] <= sram_dout1[2:0];
                        default: cw[12] <= sram_dout1[0];
                    endcase
                    if (k == 3'd4) state <= S_R_DEC;
                    else begin
                        k <= k + 3'd1;
                        state <= S_R_LOAD;
                    end
                end
                S_R_DEC: begin
                    ecc_syndrome(cw, sy, par);
                    if (sy == 4'd0 && par == 1'b0) begin
                        rdata <= ecc_data(cw);
                        corrected <= 1'b0;
                        uncorrected <= 1'b0;
                    end else if (sy == 4'd0 && par == 1'b1) begin
                        rdata <= ecc_data(cw);
                        corrected <= 1'b1;
                        uncorrected <= 1'b0;
                    end else if (par == 1'b1) begin
                        rdata <= ecc_data(cw ^ (13'd1 << sy));
                        corrected <= 1'b1;
                        uncorrected <= 1'b0;
                    end else begin
                        rdata <= 8'd0;
                        corrected <= 1'b0;
                        uncorrected <= 1'b1;
                    end
                    state <= S_R_DONE;
                end
                S_R_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    if (!re) state <= S_IDLE;
                end
                S_FAIL: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    if (!we) state <= S_IDLE;
                end
                // ---- error injection: read-modify-write on the macro ----
                S_INJ_RD: begin
                    state <= S_INJ_CAP;
                end
                S_INJ_CAP: begin
                    inj_data_q <= sram_dout1[2:0];
                    state <= S_INJ_WR;
                end
                S_INJ_WR: begin
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
