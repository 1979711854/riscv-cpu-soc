`timescale 1ns/1ps
// ============================================================================
// riscv-tests 运行测试台（不改 CPU，不动 riscv-tests 仓库）
// ----------------------------------------------------------------------------
// * 行为级统一存储器（sim/mem_model.vh）加载 elf2mem.py 生成的 imem.hex / dmem.hex
// * 监控 core 对 tohost 的 store，判 PASS/FAIL
//   - tohost 写 1            => PASS
//   - tohost 写奇数(>1)      => FAIL，testnum = (值-1)>>1
// ============================================================================

// 统一存储器行为模型（指令/数据共用一块，A 口取指、B 口访存）
`include "mem_model.vh"

// 顶层
module cpu_tb_riscv;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    // core ↔ mem_bus 的取指口与访存口
    wire [14:0] imem_addr;     // 与 core / mem_bus 的端口同宽（128KB = 32768 word），别改窄
    wire [31:0] imem_rd;
    wire [14:0] imem_addr2;    // 与 core / mem_bus 的端口同宽（128KB），别改窄
    wire [31:0] imem_rd2;
    // [任务 C] 提前 load 读口（C 口）：core 出地址、mem_bus 回数据。必须接上，
    // 悬空会让 core 的输入变 Z（约定 13）。
    wire [14:0] ld_addr;
    wire [31:0] ld_rdata;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_ready;   // 访存就绪：mem_bus 出，core 入（访存等待机制）
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;
    wire        irq_timer;      // mem_bus 里的 CLINT：mtime >= mtimecmp

    // 双发射开关：编译时加 -DDUAL 即用 DUAL_ISSUE=1 核跑回归。
    // [!] 脚本必须【显式】传该宏：run_riscv_tests.ps1 / run_own_tests.ps1 默认双发射，
    //     加 -Single 才切单发射。不传 = 单发射，会与板上（双发射）比特流对不上 ——
    //     这正是一条 49/1/0 单发射结果被拿去给双发射比特流背书的老坑（2026-10-06 修）。
`ifdef DUAL
    localparam DUAL_OUT = 1;
`else
    localparam DUAL_OUT = 0;
`endif

    // D-Cache 开关：编译时加 -DDCACHE 即用 DCACHE_EN=1（高阶任务①）。
    // 与 DUAL 同理：脚本必须【显式】传，默认关 —— 跑分一律用关的配置。
`ifdef DCACHE
    localparam DCACHE_OUT = 1;
`else
    localparam DCACHE_OUT = 0;
`endif

    // I-Cache 开关：编译时加 -DICACHE 即用 ICACHE_EN=1（高阶任务①）。默认关。
`ifdef ICACHE
    localparam ICACHE_OUT = 1;
`else
    localparam ICACHE_OUT = 0;
`endif

    // [任务 C] load 地址提前：编译时加 -DEARLYLD 即用 EARLY_LD=1。默认关。
    // [!] core 与 mem_bus 必须收同一个值（一个算地址、一个例化那份阵列）。
`ifdef EARLYLD
    localparam EARLYLD_OUT = 1;
`else
    localparam EARLYLD_OUT = 0;
`endif

    // [B1-BTB] 分支目标缓冲：编译时加 -DNOBTB 即用 BTB_EN=0。默认【开】（与板上一致）。
    // 与 DUAL/DCACHE 同理：脚本要跑"关掉"的对照必须【显式】传 -DNOBTB。
`ifdef NOBTB
    localparam BTB_OUT = 0;
`else
    localparam BTB_OUT = 1;
`endif

    // [面积优化] A 扩展（RV32A）：编译时加 -DAEXT 即用 A_EXT=1。**默认 0 = 关**，
    //   与生产位流一致（core 的参数默认值也是 0，见 core.v 文件头）。
    //   [!] `scripts\run_own_tests.ps1` 必须传 -DAEXT —— 它的套件里有 `tb_amo_cpu`
    //       （A 扩展的整核测试），不传会以 testnum 668 FAIL，那是预期行为不是 bug。
    //       `run_riscv_tests.ps1` 不传（回归集里没有 rv32ua，A_EXT=0 才是板上口径）。
`ifdef AEXT
    localparam AEXT_OUT = 1;
`else
    localparam AEXT_OUT = 0;
`endif

    // [lane B 访存] lane B 放 load：编译时加 -DLANEBMEM 即用 LANEB_MEM=1。
    // 默认 0（与 P2 阶段的 core.v 参数默认值一致）。P3 翻开关后：
    //   * core.v 的 parameter 默认值改 1（PDS/上板口径走它，cpu_top 不传这个参数）；
    //   * 仿真侧仍靠这个宏显式二选一 —— 同一份 RTL 下能跑 0/1 两档对照，
    //     这正是 tb_laneb_ld.S "先写用例再翻开关" 的玩法（run_own_tests.ps1 -LanebMem）。
`ifdef LANEBMEM
    localparam LANEBMEM_OUT = 1;
`else
    localparam LANEBMEM_OUT = 0;
`endif

    // 自证配置：t=0 打印本测试台编译进去的配置，每份日志首行自带口径。
    // [!] 2026-10-16 撤档：A1（lane B 放 store，parameter `LANEB_ST`）已判定【不采纳】，
    //   实现也已从树里退回 —— 完整实现/量化数据/否掉的理由见
    //   `doc/reports/2026-10-16_a1_laneb_store.md`，提交 `a5d6682` 留在 git 历史里。
    //   **所以自证行里【不再有 LANEB_ST】；哪天又看到它 = A1 被重新启用了。**
    initial $display("SIM CONFIG: DUAL_ISSUE=%0d DCACHE_EN=%0d ICACHE_EN=%0d EARLY_LD=%0d BTB_EN=%0d A_EXT=%0d LANEB_MEM=%0d",
                     DUAL_OUT, DCACHE_OUT, ICACHE_OUT, EARLYLD_OUT, BTB_OUT, AEXT_OUT, LANEBMEM_OUT);

    core #(.DUAL_ISSUE(DUAL_OUT), .EARLY_LD(EARLYLD_OUT), .BTB_EN(BTB_OUT),
           .A_EXT(AEXT_OUT), .LANEB_MEM(LANEBMEM_OUT)) u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .ld_addr(ld_addr), .ld_rdata(ld_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .ebreak(),
        // 定时器中断由 mem_bus 的 CLINT 直接驱动 —— 本测试台就能测中断。
        // 外部中断（MEIP）来自外设，本层没有，恒 0。
        .irq_timer(irq_timer),
        .irq_ext  (1'b0)
    );

    // 统一存储器（指令+数据）的行为模型由本 tb 提供（sim/mem_model.vh）
    mem_bus #(.DCACHE_EN(DCACHE_OUT), .ICACHE_EN(ICACHE_OUT),
              .EARLY_LD(EARLYLD_OUT)) u_bus (
        .clk(clk), .resetn(resetn),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .ld_addr(ld_addr), .ld_rdata(ld_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .gpio_we(), .uart_tx_we(), .uart_rx_ack(),
        .periph_wdata(), .gpio_rdata(32'd0), .uart_rx_rdata(32'd0),
        .done(),           // 本测试台不关心 done（判分靠 tohost）
        // [重点] 必须接！漏了它 irq_timer 悬空为 Z，core 里
        //   `int_timer = mie.MTIE & Z` 会是不定态，中断行为随机 ——
        //   表现为测试台与调试台跑出完全不同的结果（2026-09-23 实踩）。
        .irq_timer(irq_timer),
        .agu_probe_in(32'd0)   // [TASK-C 探针] 仿真恒 0（悬空会变 Z，约定 13）
    );

    // ------------------------------------------------------------------
    // [调试] +LDBUG：把每次 load 写回的原始字/地址 dump 出来（默认关，纯观测）。
    //   用途：EARLY_LD 打开后比对"快通路 vs 旧通路"两次跑的 load 序列，
    //   定位第一条读错数据的 load。稳定后本段可以删。
    // ------------------------------------------------------------------
    integer ldbug_on;
    initial if ($test$plusargs("LDBUG")) ldbug_on = 1; else ldbug_on = 0;
    always @(posedge clk) begin
        if (ldbug_on && resetn && u_core.mem_wb_reg_write && (u_core.mem_wb_wb_sel == 2'b01))
            $display("LD pc=%h rd=%0d snap_en=%b raw=%h out=%h",
                     u_core.mem_wb_pc, u_core.mem_wb_rd,
                     u_core.wb_rdata_snap_en, u_core.wb_rdata_snap, u_core.load_data);
    end

    // ------------------------------------------------------------------
    // [B1-BTB] +BTBTRACE：统计 BTB 预测命中（到达级 u_core.p_btb_pred）与训练
    //   （EX 级 u_core.btb_upd_en）次数。**纯被动观测**（同 +LDBUG/+JALRTRACE 纪律，
    //   不改变周期数）。用途：CoreMark 的 jalr ≈ 100% 是 ret（被 RAS 捕获）⇒ BTB 一次
    //   不触发，"跑分逐位不变"证明不了 BTB 生效/正确；本探针配合 btb_indirect.S 证明
    //   BTB 真在预测（pred>0），并用 -DNOBTB 对照（pred=0）。
    // ------------------------------------------------------------------
    integer btbtrace_on, btbpred_cnt, btbtrain_cnt;
    initial begin
        btbtrace_on  = 0;
        btbpred_cnt  = 0;
        btbtrain_cnt = 0;
        if ($test$plusargs("BTBTRACE")) btbtrace_on = 1;
    end
    always @(posedge clk) begin
        if (resetn && btbtrace_on) begin
            if (u_core.p_btb_pred) btbpred_cnt  = btbpred_cnt  + 1;
            if (u_core.btb_upd_en) btbtrain_cnt = btbtrain_cnt + 1;
        end
    end
    final begin
        if (btbtrace_on)
            $display("BTBTRACE: btb pred = %0d, btb train = %0d", btbpred_cnt, btbtrain_cnt);
    end

    // ------------------------------------------------------------------
    // [lane B 访存] +PAIRTRACE：被动打印 ID/EX 每次锁存的配对（lane A/B 的 PC 与
    //   lane B opcode），以及 lane B load 驱动访存口（b_mem_sel）的事件。
    //   **纯被动观测**（同 +LDBUG/+BTBTRACE 纪律，不改变周期数）。
    //   用途：tb_laneb_ld.S 的定向图案依赖"X 与 L1 真的配成了对"—— 若因某个
    //   配对约束看漏导致 L1 落到 lane A，测试会【通过但什么都没测】。跑一遍
    //   +PAIRTRACE 即可从日志自证配对发生（L1 的 PC 出现在 PAIR 行、且随后有
    //   对应的 BMEM 行）。P3 翻开关后的回归也建议带上，留档。
    // ------------------------------------------------------------------
    integer pairtrace_on;
    initial if ($test$plusargs("PAIRTRACE")) pairtrace_on = 1; else pairtrace_on = 0;
    always @(posedge clk) begin
        if (pairtrace_on && resetn) begin
            if (u_core.if_id_pair)
                $display("PAIR a_pc=%h b_pc=%h b_op=%02d",
                         u_core.if_id_pc, u_core.if_id_pc + 32'd4, u_core.if_id_instr_b[6:0]);
            if (u_core.b_mem_sel)
                $display("BMEM b_pc=%h addr=%h", u_core.ex_mem_b_pc, u_core.mem_addr);
        end
    end

    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100MHz

    initial begin
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end

    // ------------------------------------------------------------------
    // tohost 监控：core 对 tohost 做 store 即判定
    // ------------------------------------------------------------------
    // tohost 地址从 elf2mem.py 生成的 tohost_addr.hex 读（不同测试 .tohost 段 VMA 不同，
    // 例如 ld_st 在 0x2000），别硬编码 0x1000。
    reg [31:0] tohost_addr_mem [0:0];
    reg [1023:0] hexpath_tohost;
    initial begin
        tohost_addr_mem[0] = 32'h1000;  // 兜底
        if (!$value$plusargs("TOHOST=%s", hexpath_tohost)) hexpath_tohost = "programs/tohost_addr.hex";
        $readmemh(hexpath_tohost, tohost_addr_mem);
    end
    wire [31:0] TOHOST_ADDR = tohost_addr_mem[0];
    reg [31:0] tohost_val;
    reg        tohost_written;
    initial begin
        tohost_val = 32'd0;
        tohost_written = 1'b0;
    end
    // 用 core 的【真访存端口】而不是层次化引用内部信号；mem_wdata 已按 sb/sh/sw
    // 做过字节复制，riscv-tests 写 tohost 一律用 sw，故与原始 store 数据一致。
    always @(posedge clk) begin
        if (!resetn) begin
            tohost_written <= 1'b0;
        end else if (u_core.mem_we && u_core.mem_addr == TOHOST_ADDR) begin
            tohost_written <= 1'b1;
            tohost_val     <= u_core.mem_wdata;
        end
    end

    initial begin
        wait(tohost_written);
        #1;
        if (tohost_val == 32'd1)
            $display("=== PASS ===");
        else if (tohost_val[0])
            $display("=== FAIL (testnum %0d) ===", (tohost_val - 32'd1) >> 1);
        else
            $display("=== UNEXPECTED tohost=0x%h ===", tohost_val);
        $finish;
    end

    // 超时保护：50000 周期
    initial begin
        #500000;
        if (!tohost_written) begin
            $display("=== TIMEOUT (pc=0x%h) ===", pc);
            $finish;
        end
    end

    // 波形导出（批量跑时注释掉以提速；调试单个失败测试时再打开）
    // initial begin
    //     $dumpfile("cpu_tb_riscv.vcd");
    //     $dumpvars(0, cpu_tb_riscv);
    // end
endmodule
