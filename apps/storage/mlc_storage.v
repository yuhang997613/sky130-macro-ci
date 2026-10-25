// mlc_storage.v -- application B: 8-level (3-bit/cell) eMRAM storage word
// controller with SECDED ECC and write-verify.
//
// * 16 words x 8-bit data; each word is encoded to a (13,8) SECDED codeword
//   and stored in 5 cells x 3 bits (15 bits, 2 spare).
// * Word write: per-cell write-verify with the mean-step policy
//   (step = 3/8 distance, >= 1 LSB, max 8 pulses/cell).
// * Word read: 5 cells -> 13-bit codeword -> single-error correct,
//   double-error detect.
// * Counters: energy (0.01 pJ LSB), total pulses, corrected/uncorrected flags.
`timescale 1ns/1ps
module mlc_storage (
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
    localparam S_IDLE   = 4'd0;
    localparam S_W_LOAD = 4'd1;
    localparam S_W_CMP  = 4'd2;
    localparam S_W_PULSE= 4'd3;
    localparam S_W_VER  = 4'd4;
    localparam S_W_NEXT = 4'd5;
    localparam S_W_DONE = 4'd6;
    localparam S_R_LOAD = 4'd7;
    localparam S_R_DEC  = 4'd8;
    localparam S_R_DONE = 4'd9;
    localparam S_FAIL   = 4'd10;

    localparam MAX_PULSES = 4'd8;

    reg [2:0] mem [0:79];        // 16 words x 5 cells
    reg [2:0] cur, tgt, step;
    reg [3:0] dist;
    reg [2:0] k;                 // cell index
    reg [3:0] state;
    reg [3:0] a;                 // latched address
    reg [7:0] wbuf;
    reg [12:0] cw;               // codeword being written / read
    reg [3:0] cell_pulses;
    reg [3:0] sy;
    reg       par;

    integer i;
    initial begin
        for (i = 0; i < 80; i = i + 1) mem[i] = 3'd0;
    end

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
        dist = (tgt > cur) ? (tgt - cur) : (cur - tgt);
        step = (dist * 3) >> 3;
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
        end else begin
            if (inj_en) mem[inj_idx] <= mem[inj_idx] ^ inj_mask;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    done <= 1'b0;
                    corrected <= 1'b0;
                    uncorrected <= 1'b0;
                    if (we) begin
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
                S_W_LOAD: begin
                    cur <= mem[a * 5 + k];
                    tgt <= cell_tgt(cw, k);
                    state <= S_W_CMP;
                end
                S_W_CMP: begin
                    if (dist == 4'd0) begin
                        state <= S_W_NEXT;
                    end else if (cell_pulses >= MAX_PULSES) begin
                        state <= S_FAIL;
                    end else begin
                        state <= S_W_PULSE;
                    end
                end
                S_W_PULSE: begin
                    if (tgt > cur) mem[a * 5 + k] <= cur + step;
                    else           mem[a * 5 + k] <= cur - step;
                    energy_q <= energy_q + 16'd1;
                    pulses <= pulses + 16'd1;
                    cell_pulses <= cell_pulses + 4'd1;
                    state <= S_W_VER;
                end
                S_W_VER: begin
                    cur <= mem[a * 5 + k];
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
                    case (k)
                        3'd0: cw[2:0]   <= mem[a * 5 + k];
                        3'd1: cw[5:3]   <= mem[a * 5 + k];
                        3'd2: cw[8:6]   <= mem[a * 5 + k];
                        3'd3: cw[11:9]  <= mem[a * 5 + k];
                        default: cw[12] <= mem[a * 5 + k][0];
                    endcase
                    if (k == 3'd4) state <= S_R_DEC;
                    else k <= k + 3'd1;
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
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
