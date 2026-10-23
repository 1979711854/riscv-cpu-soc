`timescale 1ns/1ps
// ============================================================================
// tb_combined -- single-image routing test for the 128KB build
// ----------------------------------------------------------------------------
// Purpose: prove that ONE mem.hex (boot selector + CoreMark + RT-Thread, merged
// by scripts/merge_images.py) really routes to both programs, i.e. the answer to
// the official Q53 "one bitstream for both score run and application".
//
//   +KEY=1  -> key[2] held low (SW6 pressed)  => boot.S must jump to 0x1000
//   +KEY=0  -> key[2] released                => boot.S must jump to 0x10000
//
// What is checked:
//   * ROUTING: the fetch PC must fall into the CoreMark region (0x1000..0xEFFF)
//     or the RT-Thread region (0x10000..0x1FFF0). This is the real assertion --
//     a broken link script or a stale image shows up here first.
//
//   [!] Do NOT compare pc against the exact entry addresses. core.v loads pc_r
//       with "target + 4" on every redirect (see core.v ~line 1686), so the pc
//       port never shows 0x1000 / 0x10000 themselves -- it jumps 0x14 -> 0x1004.
//       That is why the check is region-based, not equality-based.
//   * CONSOLE: every store to the UART TX address is captured into +LOG=<file>.
//     The PS wrapper greps that file for program-specific markers (CoreMark CRCs
//     vs. the RT-Thread banner). Baud timing is not modelled on purpose: we only
//     need the character stream, and strobe capture is deterministic.
//
// [!] ASCII-only on purpose. Other sim/*.v files are GBK; a new UTF-8 file in the
//     same directory is a trap for anyone opening them in the default editor.
//
// [!] vid_rdata is tied to 0 (not left dangling). A floating input becomes Z,
//     Z propagates into mem_rdata once any 0x8003_xxxx read happens, and the CPU
//     dies with PC=0xxxxxxxx (~16 ms in) -- exactly the failure documented in
//     tb_rtthread.v's header. We never expect vblank here, so 0 is fine.
//
// [i] cpu_top is instantiated WITHOUT parameter overrides: it therefore uses the
//     board configuration (DUAL_ISSUE=1, EARLY_LD=1, LANEB_MEM=1, caches off).
// ============================================================================
`include "mem_model.vh"

module tb_combined;
    reg         clk = 1'b0;
    reg         resetn;
    reg  [7:0]  key;
    wire        uart_tx;
    wire        done;
    wire [31:0] pc;
    wire [7:0]  led;

    // video ports of cpu_top (dummy -- see header note about vid_rdata)
    wire        vid_we;
    wire [1:0]  vid_vsel;
    wire [13:0] vid_waddr;
    wire [3:0]  vid_be;
    wire [31:0] vid_wdata;
    wire [1:0]  vid_vsel_d;
    wire [13:0] vid_waddr_d;

    always #5 clk = ~clk;          // 100 MHz sim clock (same as the other tbs)

    integer     keymode;
    integer     maxcyc;
    integer     stopchars;
    integer     fd;
    integer     nchar = 0;
    reg [1023:0] logpath;
    reg [63:0]  cyc = 0;
    // 0 = not yet decided, 1 = CoreMark region, 2 = RT-Thread region
    reg [1:0]   region   = 2'd0;
    reg [31:0]  first_pc = 32'hFFFF_FFFF;
    reg         finished = 1'b0;

    cpu_top u_soc (
        .clk        (clk),
        .resetn     (resetn),
        .pc         (pc),
        .uart_tx    (uart_tx),
        .uart_rx    (1'b1),         // idle high; RT-Thread console is write-only here
        .led        (led),
        .key        (key),
        .done       (done),
        .vid_we     (vid_we),
        .vid_vsel   (vid_vsel),
        .vid_waddr  (vid_waddr),
        .vid_be     (vid_be),
        .vid_wdata  (vid_wdata),
        .vid_vsel_d (vid_vsel_d),
        .vid_waddr_d(vid_waddr_d),
        .vid_rdata  (32'd0)
    );

    // ---- console capture: one character per store to the UART TX address ----
    // uart_tx_we / periph_wdata are cpu_top's internal wires to mem_bus; reading
    // them hierarchically avoids modelling the 234-cycle bit clock.
    always @(posedge clk) begin
        if (resetn && u_soc.uart_tx_we) begin
            $fwrite(fd, "%c", u_soc.periph_wdata[7:0]);
            nchar <= nchar + 1;
        end
    end

    // ---- routing + cycle bookkeeping ----
    // [!] Region-based on purpose: pc_r = target + 4 on redirects, so the exact
    //     entry address never appears on the pc port (see header note).
    always @(posedge clk) begin
        if (resetn) begin
            cyc <= cyc + 1;
            if (pc >= 32'h0000_1000 && pc < 32'h0000_F000) begin
                if (region == 2'd0) region <= 2'd1;
                if (first_pc == 32'hFFFF_FFFF) first_pc <= pc;
            end else if (pc >= 32'h0001_0000 && pc < 32'h0001_FFF0) begin
                if (region == 2'd0) region <= 2'd2;
                if (first_pc == 32'hFFFF_FFFF) first_pc <= pc;
            end
        end
    end

    task finish_now;
        input [127:0] reason;
        begin
            finished = 1'b1;
            $fclose(fd);
            $display("TB COMBINED RESULT : reason=%0s", reason);
            $display("TB COMBINED ROUTING: region=%0d (1=CoreMark 0x1000..0xEFFF, 2=RT-Thread 0x10000..0x1FFF0) first_pc=0x%08x KEY=%0d",
                     region, first_pc, keymode);
            $display("TB COMBINED STATS  : chars=%0d cycles=%0d", nchar, cyc);
            $finish;
        end
    endtask

    always @(posedge clk) begin
        if (!finished && resetn) begin
            if (done)                 finish_now("DONE_SIGNAL");
            else if (nchar >= stopchars) finish_now("STOP_CHARS");
            else if (cyc >= maxcyc)      finish_now("TIMEOUT");
        end
    end

    initial begin
        if (!$value$plusargs("KEY=%d", keymode))       keymode = 0;
        if (!$value$plusargs("MAXCYC=%d", maxcyc))     maxcyc = 30000000;
        if (!$value$plusargs("STOPCHARS=%d", stopchars)) stopchars = 900;
        if (!$value$plusargs("LOG=%s", logpath))       logpath = "combined_uart.log";
        fd = $fopen(logpath, "w");
        if (fd == 0) begin
            $display("TB COMBINED ERROR: cannot open log file %0s", logpath);
            $finish;
        end

        key = 8'hFF;
        if (keymode != 0) key = 8'hFB;      // bit2 = 0 => key[2] pressed
        $display("TB COMBINED START : KEY=%0d key[2]=%0d (1=released/RT-Thread, 0=held/CoreMark)",
                 keymode, key[2]);
        $display("TB COMBINED IMAGE : +IMEM must point at the MERGED mem.hex");

        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end
endmodule
