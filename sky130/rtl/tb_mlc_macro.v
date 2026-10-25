// tb_mlc_macro.v -- self-checking TB for mlc_storage_macro (SKY130 OpenRAM port).
//
// Checks: word write / read-back over several addresses, SECDED single-error
// correction, double-error detection, overflow-free address mapping, counters.
//
// Compile (from repo root, iverilog at D:\iverilog\bin):
//   iverilog -g2012 -I sky130/macros/sky130_sram_1kbyte_1rw1r_32x256_8 ^
//       -o sky130/out/tb_mlc_macro.vvp sky130/rtl/tb_mlc_macro.v sky130/rtl/mlc_storage_macro.v
//   vvp sky130/out/tb_mlc_macro.vvp
//
// The OpenRAM behavioural model is `include`d here (after this file's `timescale)
// so its #DELAY/#T_HOLD carry 1ns/1ps; the DUT instantiates the macro directly.
`timescale 1ns/1ps

`include "sky130_sram_1kbyte_1rw1r_32x256_8.v"

module tb_mlc_macro;
    reg clk = 0;
    reg rst_n = 0;
    reg [3:0] addr = 0;
    reg [7:0] wdata = 0;
    reg we = 0, re = 0;
    wire [7:0] rdata;
    wire corrected, uncorrected, busy, done;
    wire [15:0] energy_q, pulses;
    reg inj_en = 0;
    reg [6:0] inj_idx = 0;
    reg [2:0] inj_mask = 0;

    mlc_storage_macro u_dut (
        .clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata),
        .we(we), .re(re), .rdata(rdata),
        .corrected(corrected), .uncorrected(uncorrected),
        .busy(busy), .done(done),
        .energy_q(energy_q), .pulses(pulses),
        .inj_en(inj_en), .inj_idx(inj_idx), .inj_mask(inj_mask)
    );

    always #5 clk = ~clk;           // 10 ns period

    integer errors = 0;
    integer checks = 0;
    integer w, i;
    reg [7:0] pat [0:15];
    reg [7:0] rd;
    reg c, u;

    // the OpenRAM behavioural model has no power-on contents; the RTL original
    // relied on `initial mem = 0`, so zero the macro array the same way here.
    initial begin
        for (i = 0; i < 256; i = i + 1) u_dut.u_sram.mem[i] = 32'd0;
    end

    task write_word(input [3:0] a, input [7:0] d);
        integer t;
        begin
            @(posedge clk);
            addr = a; wdata = d; we = 1;
            @(posedge clk);
            we = 0;
            t = 0;
            while (!done && t < 3000) begin
                @(posedge clk); #1;
                t = t + 1;
            end
            checks = checks + 1;
            if (!done) begin
                $display("TB: FAIL write timeout addr=%0d", a);
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask

    task read_word(input [3:0] a, output [7:0] d, output c, output u);
        integer t;
        begin
            @(posedge clk);
            addr = a; re = 1;
            @(posedge clk);
            re = 0;
            t = 0;
            while (!done && t < 3000) begin
                @(posedge clk); #1;
                t = t + 1;
            end
            checks = checks + 1;
            if (!done) begin
                $display("TB: FAIL read timeout addr=%0d", a);
                errors = errors + 1;
                d = 8'hxx; c = 0; u = 0;
            end else begin
                #1 d = rdata; c = corrected; u = uncorrected;
            end
            @(posedge clk);
        end
    endtask

    task inject(input [6:0] idx, input [2:0] m);
        begin
            @(posedge clk);
            inj_en = 1; inj_idx = idx; inj_mask = m;
            @(posedge clk);
            inj_en = 0;
            repeat (6) @(posedge clk);      // RMW on the macro needs 3 cycles
        end
    endtask

    initial begin
        pat[0] = 8'hA5;  pat[1] = 8'h3C;  pat[2] = 8'h0F;  pat[3] = 8'hF0;
        pat[4] = 8'h55;  pat[5] = 8'hAA;  pat[6] = 8'h01;  pat[7] = 8'h80;
        pat[8] = 8'h7F;  pat[9] = 8'hFE;  pat[10] = 8'h12; pat[11] = 8'h34;
        pat[12] = 8'h56; pat[13] = 8'h78; pat[14] = 8'h9A; pat[15] = 8'hBC;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // 1) write and read back all 16 words (exercises cell index 0..79)
        for (w = 0; w < 16; w = w + 1) begin
            write_word(w[3:0], pat[w]);
            read_word(w[3:0], rd, c, u);
            checks = checks + 3;
            if (rd !== pat[w]) begin
                $display("TB: FAIL w%0d exp=%02x got=%02x", w, pat[w], rd);
                errors = errors + 1;
            end
            if (c !== 1'b0 || u !== 1'b0) begin
                $display("TB: FAIL w%0d clean read corr=%0b unc=%0b", w, c, u);
                errors = errors + 1;
            end
        end
        $display("TB: write/read-back pass");

        // 2) overwrite a word that was already written
        write_word(4'd0, 8'h5A);
        read_word(4'd0, rd, c, u);
        checks = checks + 2;
        if (rd !== 8'h5A) begin
            $display("TB: FAIL overwrite w0 exp=5a got=%02x", rd);
            errors = errors + 1;
        end
        if (c !== 1'b0 || u !== 1'b0) begin
            $display("TB: FAIL overwrite w0 corr=%0b unc=%0b", c, u);
            errors = errors + 1;
        end
        write_word(4'd0, pat[0]);       // restore
        $display("TB: overwrite pass");

        // 3) single-bit error in word 3, cell 2 -> corrected
        inject(7'd3 * 5 + 7'd2, 3'b010);
        read_word(4'd3, rd, c, u);
        checks = checks + 3;
        if (rd !== pat[3]) begin
            $display("TB: FAIL single-error w3 exp=%02x got=%02x", pat[3], rd);
            errors = errors + 1;
        end
        if (c !== 1'b1 || u !== 1'b0) begin
            $display("TB: FAIL single-error flags w3 corr=%0b unc=%0b", c, u);
            errors = errors + 1;
        end
        if (rd === pat[3] && c === 1'b1) $display("TB: single-error corrected w3");

        // 4) two bit errors in word 5, cells 0 and 1 -> uncorrectable
        inject(7'd5 * 5 + 7'd0, 3'b001);
        inject(7'd5 * 5 + 7'd1, 3'b010);
        read_word(4'd5, rd, c, u);
        checks = checks + 1;
        if (u !== 1'b1) begin
            $display("TB: FAIL double-error not flagged w5 got=%02x", rd);
            errors = errors + 1;
        end else begin
            $display("TB: double-error flagged (uncorrectable)");
        end

        // 5) counters
        checks = checks + 2;
        if (pulses == 0 || energy_q == 0) begin
            $display("TB: FAIL counters stuck pulses=%0d energy_q=%0d", pulses, energy_q);
            errors = errors + 1;
        end
        $display("TB: pulses=%0d energy_q=%0d", pulses, energy_q);

        // 6) address mapping: no aliasing between the last word and word 0
        read_word(4'd15, rd, c, u);
        checks = checks + 1;
        if (rd !== pat[15]) begin
            $display("TB: FAIL aliasing w15 exp=%02x got=%02x", pat[15], rd);
            errors = errors + 1;
        end

        if (errors == 0) $display("TB: PASS (%0d/%0d checks)", checks, checks);
        else             $display("TB: FAIL (%0d errors / %0d checks)", errors, checks);
        #100 $finish;
    end

    // run-time watchdog
    initial begin
        #2000000;
        $display("TB: FAIL global timeout");
        $finish;
    end
endmodule
