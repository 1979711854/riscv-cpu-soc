`timescale 1ns/1ps
// ============================================================================
// tb_icache_dbg.v —— "仿真过、板上不过"的逐拍诊断台（2026-10-12 新增）
// ----------------------------------------------------------------------------
// 它是 tb_coremark.v 的副本 + 四路 dump（全在下面 [DBG] 段，不改 tb 主体）：
//   programs/dbg_trace.txt  TRAP 现场 / 前 20000 拍取指口 / IF-ID 锁存流
//                           / 8100~8130 拍的【快通路 load 细节】P 行
//                           （P 行就是定位 wb_rdata_snap 取错流水级的证据）
//   programs/dbg_bht.txt    分支/BHT 流 + flush/mispred
//   programs/dbg_wb.txt     寄存器写回流（找第一个算错的值）
//
// 跑法（**在仓库根**，配置必须与失败位流一致）：
//   iverilog -g2012 -DDUAL -DDCACHE -DICACHE -DEARLYLD \
//            -I rtl/core -I rtl/periph -I rtl/bus -I sim \
//            -o sim/tools/tb_icache_dbg.vvp sim/tools/tb_icache_dbg.v \
//            rtl/core/*.v rtl/periph/*.v rtl/bus/*.v
//   cd sim && vvp tools/tb_icache_dbg.vvp +ITER=1 +IMEM=programs/imem.hex +DMEM=programs/dmem.hex
//   [!] `include "mem_model.vh" 靠 -I sim；放 tools/ 是为了避开 run_sim.ps1 的通配
//       （同目录的 tb_debug_trap.v 也是这个原因），别把它挪回 sim/ 根。
// ============================================================================

// CoreMark 运行测试台：周期计数 + UART 字符拦截 + tohost 结束判分
//   - core 对 0xFFFC 的 store 视为输出一个字符（uart_send_char）
//   - core 对 0xFFF8 的 store 1 视为结束（start.S 里 main 返回后写）
//   - CoreMark/MHz = ITERATIONS * 1e6 / 总周期数

// 统一存储器行为模型（指令/数据共用一块，A 口取指、B 口访存）
`include "mem_model.vh"


module coremark_tb;
    reg         clk;
    reg         resetn;
    wire [31:0] pc;

    // 周期计数（提前声明：下面 core 例化就要用到 cycle_count）
    reg [63:0] cycle_count;

    // core ↔ mem_bus 的取指口与访存口
    wire [14:0] imem_addr;     // 与 core / mem_bus 的端口同宽（128KB = 32768 word），别改窄
    wire [31:0] imem_rd;
    wire [14:0] imem_addr2;    // 与 core / mem_bus 的端口同宽（128KB），别改窄
    wire [31:0] imem_rd2;
    // [任务 C] 提前 load 读口（C 口）：core 出地址、mem_bus 回数据。
    // [!] 必须接上 —— 悬空的 core 输入会变 Z（约定 13），会直接污染 load 数据。
    wire [14:0] ld_addr;
    wire [31:0] ld_rdata;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire        mem_ready;   // 访存就绪：mem_bus 出，core 入（访存等待机制）
    wire [3:0]  mem_byte_en;
    wire        mem_we, mem_re;
    wire        irq_timer;      // mem_bus 里的 CLINT：mtime >= mtimecmp

    // 双发射开关：编译时加 -DDUAL 即用 DUAL_ISSUE=1 核跑分。
    // [!] 脚本必须【显式】传该宏：run_coremark.ps1 默认双发射，加 -Single 才切单发射。
    //     不传 = 单发射，会与板上（双发射）比特流对不上 —— 每迭代周期数也随之不同
    //     （单发射 303,140 / 双发射 232,345），混了会把得分算错（2026-10-06 修）。
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

    // 自证配置：t=0 打印本测试台编译进去的 DUAL_ISSUE，每份日志首行自带口径。
    initial $display("SIM CONFIG: DUAL_ISSUE=%0d DCACHE_EN=%0d ICACHE_EN=%0d EARLY_LD=%0d",
                     DUAL_OUT, DCACHE_OUT, ICACHE_OUT, EARLYLD_OUT);

    core #(.DUAL_ISSUE(DUAL_OUT), .EARLY_LD(EARLYLD_OUT)) u_core (
        .clk(clk), .resetn(resetn), .pc(pc),
        .imem_addr(imem_addr), .imem_rd(imem_rd),
        .imem_addr2(imem_addr2), .imem_rd2(imem_rd2),
        .ld_addr(ld_addr), .ld_rdata(ld_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_byte_en(mem_byte_en),
        .mem_we(mem_we), .mem_re(mem_re), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .ebreak(),
        // CoreMark 全程不碰 CSR、中断关闭（mstatus.MIE=0、mie=0），
        // 接真实 MTIP 也不会被受理；接上是为了不让端口悬空成 Z。
        .irq_timer(irq_timer),
        .irq_ext  (1'b0)
    );

    // mem_bus 自带周期计数器（0xFFF4 的读回源），与 tb 的 cycle_count 同时复位、
    // 同步递增，故 get_time() 读数与改造前一致。
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
        .done(),           // 周期计数器已从 mem_bus 去掉（无使用者）
        // 接真实 MTIP：CoreMark 全程 MIE=0 且 mtimecmp 复位为全 1，
        // 所以它恒为低、不影响结果；接上是为了不让端口悬空成 Z。
        .irq_timer(irq_timer),
        .agu_probe_in(32'd0)   // [TASK-C 探针] 仿真恒 0（悬空会变 Z，约定 13）
    );

    // ========================================================================
    // 流水线效率剖析（+PROF / +TRACE，默认关闭）
    // ------------------------------------------------------------------------
    // 设计原则：**纯被动观测**。这里只读 core 的内部信号，不驱动 core 的任何
    // 输入。prof_on=0 时计数器不递增、不打印，所以 run_coremark.ps1 的默认运行
    // （不带 +PROF）周期数与加入本段之前完全一致 —— 这是回归纪律的硬要求。
    //
    // 之所以能这样做：core 的 stall / mc_stall / ex_flush / 四路
    // 前递判定都是模块内部信号，用层次引用（u_core.xxx）即可观测，不需要为了
    // 测量去改 RTL（改 RTL 会触发全量回归）。
    //
    //   +PROF              打印周期构成统计 + 每 5 万拍直方图
    //   +TRACE_START=<n>   第 n 拍起逐拍打印五级流水线状态
    //   +TRACE_LEN=<m>     连续打印 m 拍（默认 64）
    //   +TRACE_FILE=<path> trace 输出文件（默认 programs/trace.txt）
    // ========================================================================
    integer      prof_on;
    integer      trace_start_cyc, trace_len, trace_left, trace_fd;
    reg [1023:0] trace_fname;

    // +PAIRTRACE：默认关。**纯被动观测**（同 +PROF 纪律），不影响周期数。
    // 在 CoreMark 计时区间内逐条流出 retired {pc, instr}，供 Python 复放双发射
    // 配对规则、估算动态配对率 p。影子链镜像 v_* 的推进/清零，{pc,instr} 取自 IF/ID。
    integer      pairtr_on, pairtr_fd;
    reg [63:0]   pr_ex, pr_mem, pr_wb;   // {pc[31:0], instr[31:0]}

    // 周期构成累计
    reg [63:0] c_stall, c_div, c_mul, c_flush;
    reg [63:0] c_fwdex, c_fwdwb, c_mem, c_br_taken, c_jump;
    reg [63:0] c_commit, c_inst_in;

    // 条件分支的方向细分。
    // **设计分支预测器需要 not-taken 的条数** —— 现在 not-taken 是零代价的，
    // 预测器一旦猜错就会给它加上惩罚，所以必须知道分母。
    // 同时按 imm[31]（偏移正负）分出前向/后向，用来评估"后向分支预测跳转"
    // 这条静态规则的命中率。
    //
    // 这些计数一律挂在**解析结果**（id_ex_branch / branch_taken / id_ex_jump*）上，
    // 【不】挂在 ex_flush 上 —— 加了预测之后，预测正确的 taken 不再产生 ex_flush，
    // 挂在冲刷信号上的计数会塌掉，改造前后也就没法比。
    //   c_br_tot  = 到达 EX 的条件分支总数（每条恰好计一次：分支的 id_ex_is_div=0，
    //               所以 mc_stall=0，ID/EX 必在下一拍推进；stall/ex_flush 会清零
    //               id_ex_branch，也不会重复计）
    //   c_br_bwd  = 其中偏移为负（后向，通常是循环回边）
    reg [63:0] c_br_tot, c_br_bwd, c_br_bwd_tk;
    // jal / jalr 拆分：前者目标只依赖 if_id_pc+imm，ID 级就能算，可静态预测；
    // 后者目标是 (rs1+imm)&~1，依赖寄存器值，ID 级没有前递通路，预测不了。
    // 两者的条数比直接决定"ID 级预测"能覆盖多少冲刷事件。
    reg [63:0] c_jal, c_jalr;
    // 分支预测事件：ID 级重定向（预测生效）与 EX 级误判恢复
    reg [63:0] c_redir, c_mispred;

    // CoreMark 计时区间内的同类统计。
    // 依据：core_portme.c 里 start_time()/stop_time() 各是一次读 MMIO 0xFFF4
    // （barebones_clock），在访存口上是 mem_re && mem_addr==0xFFF4，可精确观测。
    // 有了区间边界才能把"纯 CoreMark 算法"的 CPI 从"含串口打印"的总 CPI 里剥出来
    // —— 打印区间是纯轮询，会把 CPI 严重拉高，两者混算没有意义。
    reg [63:0] t_timer_cyc [0:7];
    integer    t_timer_n;
    reg        in_timed;
    reg [63:0] tc_all, tc_stall, tc_div, tc_mul, tc_flush;
    reg [63:0] tc_fwdex, tc_fwdwb, tc_mem, tc_commit;
    reg [63:0] tc_br_tot, tc_br_tk, tc_br_bwd, tc_br_bwd_tk;
    reg [63:0] tc_jal, tc_jalr;
    reg [63:0] tc_redir, tc_mispred;

    // ---- [TASK-C 分析] 消除 load-use 停顿的可达收益分类（+LDANAL，默认关）----
    // 纯被动观测：只读 core 的内部信号（层次引用），不驱动任何输入，不影响周期数。
    // 判据：任务 C 只能让【部分】load 走"地址提前到 ID"的快通路（见下方 a_bad_* 四类
    // 成因），这里把停顿按成因分类，量出真正能兑现的比例 —— 免得改完才发现收益被吃掉。
    integer    ldan_on;
    reg [63:0] a_st_tot, a_st_fast;                    // 停顿总数 / 其中可消掉
    reg [63:0] a_s_ex, a_s_memld, a_s_ram, a_s_store, a_s_amo;   // 不可消的四类成因
    reg [63:0] a_ld_tot, a_ld_fast;                    // load 总数 / 可走快通路
    reg        f_ex, f_mem;                            // 影子：该 load 可走快通路吗
    reg  [2:0] cl_ex;                                  // 影子：不可走的原因码
    // [诊断] RTL 实际用量：真正写回的 load 条数 / 真正走了快通路的条数
    reg [63:0] a_rtl_ld, a_rtl_fast;
    // [诊断] 同一拍、同一条 ID 指令：模型 a_ok 与 RTL ld_fast 不一致的条数，
    //        并按 RTL 自己那四个 bad_* 线归类（哪一条把它们挡了）
    reg [63:0] a_mm, a_mm_base, a_mm_ram, a_mm_st, a_mm_amo;

    // 影子流水线 valid：逐级镜像 core 的清零/暂停条件，用来数"真正提交的指令数"。
    // 不能直接用 mem_wb_reg_write 计数 —— store/branch/jump 不回写寄存器，会被漏掉。
    reg v_id, v_ex, v_mem, v_wb;

    // 直方图：32 桶 × 5 万拍 = 160 万拍，覆盖 ITER=1 全程
    localparam NH = 32, HBUCKET = 50000;
    reg [63:0] h_stall [0:NH-1];
    reg [63:0] h_flush [0:NH-1];
    reg [63:0] h_mem   [0:NH-1];
    reg [63:0] h_cmt   [0:NH-1];
    integer    h_idx, h_cnt, pi, ph;

    initial clk = 1'b0;
    always #5 clk = ~clk;   // 100MHz

    initial begin
        resetn = 1'b0;
        #100;
        resetn = 1'b1;
    end

    // 周期计数
    initial cycle_count = 0;
    always @(posedge clk) begin
        if (resetn) cycle_count <= cycle_count + 1;
    end

    // 迭代次数（+ITER=）
    integer iter;
    initial begin
        if (!$value$plusargs("ITER=%d", iter)) iter = 1;
    end

    // 剖析开关与 trace 参数
    initial begin
        prof_on         = 0;
        ldan_on         = 0;
        pairtr_on       = 0;
        pairtr_fd       = 0;
        trace_start_cyc = -1;
        trace_len       = 64;
        trace_left      = 0;
        trace_fd        = 0;
        trace_fname     = "programs/trace.txt";
        if ($test$plusargs("PROF")) prof_on = 1;
        if ($test$plusargs("LDANAL")) ldan_on = 1;
        if ($test$plusargs("PAIRTRACE")) begin
            pairtr_on = 1;
            pairtr_fd = $fopen("programs/pairtrace.txt", "w");
        end
        $value$plusargs("TRACE_START=%d", trace_start_cyc);
        $value$plusargs("TRACE_LEN=%d",   trace_len);
        $value$plusargs("TRACE_FILE=%s",  trace_fname);
        t_timer_n = 0;
        for (pi = 0; pi < 8; pi = pi + 1) t_timer_cyc[pi] = 64'd0;
        for (pi = 0; pi < NH; pi = pi + 1) begin
            h_stall[pi] = 64'd0; h_flush[pi] = 64'd0;
            h_mem[pi]   = 64'd0; h_cmt[pi]   = 64'd0;
        end
    end

    // UART：core 对 0xFFFC 的 store 视为输出一个字符
    // （用真访存端口；mem_wdata 已按 sb 字节复制，[7:0] 与原始 store 数据一致）
    always @(posedge clk) begin
        if (resetn && u_core.mem_we && u_core.mem_addr == 32'hFFFC)
            $write("%c", u_core.mem_wdata[7:0]);
    end

    // tohost：core 对 0xFFF8 store 1 视为结束
    reg done;
    initial done = 0;
    always @(posedge clk) begin
        if (resetn && !done && u_core.mem_we
            && u_core.mem_addr == 32'hFFF8
            && u_core.mem_byte_en[0] && u_core.mem_wdata[7:0] == 8'd1) begin
            done <= 1;
            $display("\n=== CoreMark finished ===");
            $display("iterations   : %0d", iter);
            $display("total cycles : %0d", cycle_count);
            // ---- D-Cache 命中/缺失（高阶任务①）----
            // 直接层次化读 mem_bus 里的计数器，不改固件。DCACHE_EN=0 时两者恒 0。
            begin : dcache_report
                reg [31:0] dch, dcm, ich, icm;
                dch = u_bus.dcache_hits;
                dcm = u_bus.dcache_misses;
                if (dch + dcm > 0) begin
                    $display("DCACHE load hits  : %0d", dch);
                    $display("DCACHE load miss  : %0d", dcm);
                    $display("DCACHE hit rate   : %f%%",
                             (dch * 100.0) / (dch + dcm));
                end else begin
                    $display("DCACHE            : off (DCACHE_EN=0)");
                end
                ich = u_bus.icache_hits;
                icm = u_bus.icache_misses;
                if (ich + icm > 0) begin
                    $display("ICACHE fetch hits : %0d", ich);
                    $display("ICACHE fetch miss : %0d", icm);
                    $display("ICACHE hit rate   : %f%%",
                             (ich * 100.0) / (ich + icm));
                end else begin
                    $display("ICACHE            : off (ICACHE_EN=0)");
                end
            end
            if (cycle_count > 0)
                $display("CoreMark/MHz : %f",
                         (iter * 1000000.0) / cycle_count);
            // ---- 流水线效率剖析（+PROF 时才有内容）----
            if (prof_on) begin
                $display("");
                $display("=== pipeline profile ===");
                $display("committed instr  : %0d", c_commit);
                $display("if/id loads      : %0d", c_inst_in);
                if (c_commit > 0)
                    $display("CPI              : %f",
                             cycle_count / (c_commit * 1.0));
                $display("--- cycle composition ---");
                $display("load-use stall   : %0d  %f%%", c_stall,
                         (c_stall * 100.0) / cycle_count);
                $display("div stall        : %0d  %f%%", c_div,
                         (c_div * 100.0) / cycle_count);
                // mul 条数（每条恰好多占 1 拍 EX）。这是"乘法器拆成两拍"代价的
                // 唯一可靠口径 —— 静态推算（按每迭代一次 matrix_test 算 N 和条数）
                // 会小 5.8 倍：core_bench_matrix 其实是被 core_list_join.c 的
                // calc_func 在链表遍历中按数据相关次数调用的。
                // 2026-09-28 实测区间值 = 9,396 条/迭代。
                $display("mul executed     : %0d", c_mul);
                $display("br/jmp redirect  : %0d  %f%%", c_flush,
                         (c_flush * 100.0) / cycle_count);
                // 气泡数 = 总周期 − 提交指令数。这是【与冲刷实现无关】的口径：
                // 不去假设每次冲刷值几拍，直接看有多少拍没提交指令。
                // 历史教训：此前文档把分支惩罚误记为 2 拍，就是"拍数假设"惹的祸。
                $display("pipeline bubbles : %0d  %f%%", cycle_count - c_commit,
                         ((cycle_count - c_commit) * 100.0) / cycle_count);
                $display("--- events ---");
                $display("taken branches   : %0d", c_br_taken);
                $display("jumps jal/jalr   : %0d", c_jump);
                // 全局分支构成 —— 回归探针（total cycles）是【全局】周期数，
                // 所以推演"这次改动能省多少拍"必须用全局计数，
                // 拿 coremark 计时区间的计数去减全局周期是口径错误。
                $display("  cond branches  : %0d  (bwd %0d, bwd&taken %0d)",
                         c_br_tot, c_br_bwd, c_br_bwd_tk);
                $display("  jal %0d  jalr %0d", c_jal, c_jalr);
                $display("  arrival redirect %0d  mispredict %0d", c_redir, c_mispred);
                $display("fwd from ex/mem  : %0d", c_fwdex);
                $display("fwd from mem/wb  : %0d", c_fwdwb);
                $display("mem accesses     : %0d", c_mem);
                // ---- [TASK-C 分析] 消除 load-use 停顿的可达收益（+LDANAL）----
                if (ldan_on) begin
                    $display("--- task C: load-use stall classification (timed region) ---");
                    $display("loads (rtl wb)   : %0d   fast-path used: %0d", a_rtl_ld, a_rtl_fast);
                    $display("model/RTL mismatch: %0d  (base %0d ram %0d st %0d amo %0d)",
                             a_mm, a_mm_base, a_mm_ram, a_mm_st, a_mm_amo);
                    $display("loads total      : %0d", a_ld_tot);
                    $display("  fast-capable   : %0d  %f%%", a_ld_fast,
                             (a_ld_tot > 0) ? (a_ld_fast * 100.0) / a_ld_tot : 0.0);
                    $display("stalls total     : %0d", a_st_tot);
                    $display("  eliminable     : %0d  %f%%", a_st_fast,
                             (a_st_tot > 0) ? (a_st_fast * 100.0) / a_st_tot : 0.0);
                    $display("  blocked: base in EX        : %0d", a_s_ex);
                    $display("  blocked: base from ld/amo  : %0d", a_s_memld);
                    $display("  blocked: addr not in RAM   : %0d", a_s_ram);
                    $display("  blocked: prev is store     : %0d", a_s_store);
                    $display("  blocked: prev/curr is amo  : %0d", a_s_amo);
                end
                $display("--- coremark timed region (start_time -> stop_time) ---");
                $display("timer reads seen : %0d", t_timer_n);
                if (t_timer_n >= 1) $display("start_time cycle : %0d", t_timer_cyc[0]);
                if (t_timer_n >= 2) $display("stop_time  cycle : %0d", t_timer_cyc[1]);
                $display("region cycles    : %0d", tc_all);
                $display("region commit    : %0d", tc_commit);
                if (tc_commit > 0)
                    $display("region CPI       : %f", tc_all / (tc_commit * 1.0));
                if (tc_all > 0) begin
                    $display("region stall     : %0d  %f%%", tc_stall,
                             (tc_stall * 100.0) / tc_all);
                    $display("region div stall : %0d  %f%%", tc_div,
                             (tc_div * 100.0) / tc_all);
                    $display("region mul exec  : %0d", tc_mul);
                    $display("region flush     : %0d  %f%%", tc_flush,
                             (tc_flush * 100.0) / tc_all);
                    $display("region fwd ex    : %0d", tc_fwdex);
                    $display("region fwd wb    : %0d", tc_fwdwb);
                    $display("region mem acc   : %0d", tc_mem);
                    $display("--- branch direction (region) ---");
                    $display("cond branches    : %0d", tc_br_tot);
                    $display("  taken          : %0d", tc_br_tk);
                    $display("  not taken      : %0d", tc_br_tot - tc_br_tk);
                    $display("  backward       : %0d", tc_br_bwd);
                    $display("  bwd & taken    : %0d", tc_br_bwd_tk);
                    $display("  bwd & not-taken: %0d", tc_br_bwd - tc_br_bwd_tk);
                    $display("  forward        : %0d", tc_br_tot - tc_br_bwd);
                    $display("  fwd & taken    : %0d", tc_br_tk - tc_br_bwd_tk);
                    $display("--- jumps (region) ---");
                    $display("  jal            : %0d", tc_jal);
                    $display("  jalr           : %0d", tc_jalr);
                    $display("  arrival redirect : %0d", tc_redir);
                    $display("  mispredict     : %0d", tc_mispred);
                    if (tc_br_bwd > 0)
                        $display("  bwd taken rate : %f%%",
                                 (tc_br_bwd_tk * 100.0) / tc_br_bwd);
                    // 这里【只报原始计数】，不报"预测器能省多少拍" —— 那取决于
                    // 具体实现能达到几拍惩罚，是要随设计变的假设，混进测试台
                    // 会让人把假设当成实测。推演见 doc/ila_analysis.md 的优化章节。
                end
                $display("--- histogram (bucket = %0d cycles) ---", HBUCKET);
                for (ph = 0; ph < NH; ph = ph + 1)
                    $display("h %0d stall=%0d flush=%0d mem=%0d commit=%0d",
                             ph, h_stall[ph], h_flush[ph], h_mem[ph], h_cmt[ph]);
            end
            if (pairtr_on && pairtr_fd != 0) $fclose(pairtr_fd);
            $finish;
        end
    end


    // ==================== [DBG] 陷阱与取指诊断 ====================
    integer dbg_fd;
    initial dbg_fd = $fopen("programs/dbg_trace.txt", "w");
    // 每次 trap 打印现场（cause/mepc/pc）
    always @(posedge clk) begin
        if (resetn && u_core.trap)
            $fdisplay(dbg_fd, "TRAP cyc=%0d id_ex_pc=%h cause=%h tval=%h fetch=%h",
                cycle_count, u_core.id_ex_pc, u_core.trap_cause, u_core.trap_tval,
                u_core.imem_addr);
    end
    // 前 20000 拍逐拍打印取指口状态（地址/数据/命中/停顿）
    always @(posedge clk) begin
        if (resetn && cycle_count < 20000)
            $fdisplay(dbg_fd, "F cyc=%0d fa=%h rd=%h rd2=%h mrdy=%b istall=%b hit0=%b hit1=%b pc=%h",
                cycle_count, u_core.imem_addr, u_core.imem_rd, u_core.imem_rd2,
                u_bus.mem_ready, u_bus.i_stall_w,
`ifdef ICACHE
                u_bus.g_icache.u_icache.hit0, u_bus.g_icache.u_icache.hit1,
`else
                1'b0, 1'b0,
`endif
                pc);
    end

    // [DBG] IF/ID 锁存流：与基线逐条 diff，找第一条错指令
    always @(posedge clk) begin
        if (resetn && !u_core.ex_flush && !u_core.ex_mispred && !u_core.trap
            && !u_core.stall_int && !u_core.mc_stall && u_core.mem_ready_int)
            $fdisplay(dbg_fd, "L pc=%h ins=%h insb=%h pair=%b pred=%b",
                u_core.if_addr_d, u_core.imem_rd, u_core.imem_rd2,
                u_core.pair_now, u_core.p_redirect);
    end

    // [DBG] BHT 更新流 + 冻结中的分支
    integer dbg2_fd;
    initial dbg2_fd = $fopen("programs/dbg_bht.txt", "w");
    always @(posedge clk) begin
        if (resetn) begin
            if (u_core.id_ex_branch)
                $fdisplay(dbg2_fd, "B pc=%h taken=%b hit=%b mrdy=%b",
                    u_core.id_ex_pc, u_core.branch_taken, u_core.bht_hit_w, u_core.mem_ready_int);
            if (u_core.ex_flush)
                $fdisplay(dbg2_fd, "FLUSH pc=%h", u_core.id_ex_pc);
            if (u_core.ex_mispred)
                $fdisplay(dbg2_fd, "MISPR pc=%h", u_core.id_ex_pc);
        end
    end

    // [DBG] 寄存器写回流：第一个算错的值
    integer dbg3_fd;
    initial dbg3_fd = $fopen("programs/dbg_wb.txt", "w");
    always @(posedge clk) begin
        if (resetn) begin
            if (u_core.mem_wb_reg_write && u_core.mem_ready_int && (u_core.mem_wb_rd != 5'd0))
                $fdisplay(dbg3_fd, "W cyc=%0d rd=%0d data=%h", cycle_count, u_core.mem_wb_rd, u_core.wb_data);
            if (u_core.mem_wb_b_reg_write && u_core.mem_ready_int && (u_core.mem_wb_b_rd != 5'd0))
                $fdisplay(dbg3_fd, "WB cyc=%0d rd=%0d data=%h", cycle_count, u_core.mem_wb_b_rd, u_core.wb_data_b);
        end
    end

    // [DBG] 快通路 load 细节（8100~8130 拍）
    always @(posedge clk) begin
        if (resetn && cycle_count >= 8100 && cycle_count <= 8130)
            $fdisplay(dbg_fd, "P cyc=%0d idx_pc=%h ex_pc=%h wb_pc=%h ldfx_i=%b ldfx_e=%b ldaddr=%h ldrdata=%h snen=%b snap=%h wbsen=%b wbsnap=%h mrdata=%h mrdy=%b",
                cycle_count, u_core.id_ex_pc, u_core.ex_mem_pc, u_core.mem_wb_pc,
                u_core.id_ex_ld_fast, u_core.ex_mem_ld_fast, u_core.ld_addr,
                u_core.ld_rdata, u_core.ld_snap_en, u_core.ld_snap,
                u_core.wb_rdata_snap_en, u_core.wb_rdata_snap, u_core.mem_rdata,
                u_core.mem_ready_int);
    end
    // ==================== [DBG] end ====================

    // 超时保护
    initial begin
        #1000000000;
        $display("\n=== TIMEOUT (pc=0x%h) ===", pc);
        $finish;
    end

    // ========================================================================
    // 剖析主逻辑（只在 +PROF 时工作）
    // ========================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            c_stall <= 64'd0; c_div <= 64'd0; c_mul <= 64'd0; c_flush <= 64'd0;
            c_fwdex <= 64'd0; c_fwdwb <= 64'd0; c_mem <= 64'd0;
            c_br_taken <= 64'd0; c_jump <= 64'd0;
            c_br_tot <= 64'd0; c_br_bwd <= 64'd0; c_br_bwd_tk <= 64'd0;
            c_jal <= 64'd0; c_jalr <= 64'd0;
            c_redir <= 64'd0; c_mispred <= 64'd0;
            c_commit <= 64'd0; c_inst_in <= 64'd0;
            v_id <= 1'b0; v_ex <= 1'b0; v_mem <= 1'b0; v_wb <= 1'b0;
            pr_ex <= 64'd0; pr_mem <= 64'd0; pr_wb <= 64'd0;
            h_idx <= 0; h_cnt <= 0;
            t_timer_n <= 0;
            in_timed  <= 1'b0;
            tc_all <= 64'd0; tc_stall <= 64'd0; tc_div <= 64'd0; tc_mul <= 64'd0;
            tc_flush <= 64'd0;
            tc_fwdex <= 64'd0; tc_fwdwb <= 64'd0; tc_mem <= 64'd0;
            tc_commit <= 64'd0;
            tc_br_tot <= 64'd0; tc_br_tk <= 64'd0;
            tc_br_bwd <= 64'd0; tc_br_bwd_tk <= 64'd0;
            tc_jal <= 64'd0; tc_jalr <= 64'd0;
            tc_redir <= 64'd0; tc_mispred <= 64'd0;
        end else if (prof_on || pairtr_on) begin
            // ---- 影子流水线（镜像 core 各段寄存器的清零/暂停条件）----
            // [!] 冻结判据一律用 core 的 mc_stall（多拍功能单元停顿的并集：
            //     除法 or 乘法），不能只用 div_stall —— 那样乘法的 1 拍停顿
            //     会被当成"流水线正常推进"，提交指令数会被多算。
            v_wb  <= v_mem;
            v_mem <= u_core.mc_stall ? 1'b0 : v_ex;
            v_ex  <= (u_core.ex_flush || u_core.ex_mispred || u_core.stall) ? 1'b0 :
                     (u_core.mc_stall ? v_ex : v_id);
            v_id  <= (u_core.ex_flush || u_core.ex_mispred) ? 1'b0 :
                     ((!u_core.stall && !u_core.mc_stall) ? 1'b1 : v_id);
            if (v_wb) c_commit <= c_commit + 64'd1;

            // ---- +PAIRTRACE 影子链：镜像 v_* 的推进/清零，携带 {pc,instr} ----
            pr_wb  <= pr_mem;
            pr_mem <= u_core.mc_stall ? 64'd0 : pr_ex;
            pr_ex  <= (u_core.ex_flush || u_core.ex_mispred || u_core.stall) ? 64'd0 :
                      (u_core.mc_stall ? pr_ex : {u_core.if_id_pc, u_core.if_id_instr});
            if (pairtr_on && in_timed && v_wb)
                $fdisplay(pairtr_fd, "%08h %08h", pr_wb[63:32], pr_wb[31:0]);
            if (!u_core.ex_flush && !u_core.ex_mispred &&
                !u_core.stall && !u_core.mc_stall)
                c_inst_in <= c_inst_in + 64'd1;

            // ---- 周期构成 ----
            if (u_core.stall)      c_stall  <= c_stall + 64'd1;
            if (u_core.div_stall)  c_div    <= c_div + 64'd1;
            // mul_start 每条 mul 恰好高 1 拍（见 multiplier.v），所以它直接就是
            // 动态 mul 条数 —— 这也是"乘法器拆成两拍"代价的唯一实测口径。
            if (u_core.mul_start)  c_mul    <= c_mul + 64'd1;
            if (u_core.ex_flush)   c_flush  <= c_flush + 64'd1;
            if (u_core.fwd_a_ex || u_core.fwd_b_ex) c_fwdex <= c_fwdex + 64'd1;
            if (u_core.fwd_a_wb || u_core.fwd_b_wb) c_fwdwb <= c_fwdwb + 64'd1;
            if (u_core.mem_re  || u_core.mem_we)    c_mem   <= c_mem + 64'd1;
            // 事件计数一律挂在【解析结果】上，而不是 ex_flush。
            // 理由：加了分支预测之后，预测正确的 taken 不再产生 ex_flush，
            // 挂在冲刷信号上的计数会直接塌掉，改造前后也就没法比。
            // 每条指令在 EX 只停留一拍（见声明处注释），所以不会重复计数。
            if (u_core.id_ex_branch) begin
                c_br_tot <= c_br_tot + 64'd1;
                if (u_core.id_ex_imm[31]) c_br_bwd <= c_br_bwd + 64'd1;
                if (u_core.branch_taken) begin
                    c_br_taken <= c_br_taken + 64'd1;
                    if (u_core.id_ex_imm[31]) c_br_bwd_tk <= c_br_bwd_tk + 64'd1;
                end
            end
            if (u_core.p_redirect) c_redir   <= c_redir   + 64'd1;
            if (u_core.ex_mispred)  c_mispred <= c_mispred + 64'd1;
            if (u_core.id_ex_jump)     c_jal  <= c_jal  + 64'd1;
            if (u_core.id_ex_jump_reg) c_jalr <= c_jalr + 64'd1;
            if (u_core.id_ex_jump || u_core.id_ex_jump_reg)
                c_jump <= c_jump + 64'd1;

            // ---- CoreMark 计时区间（start_time→stop_time，即两次读 0xFFF4）----
            if (u_core.mem_re && u_core.mem_addr == 32'hFFF4) begin
                if (t_timer_n < 8) begin
                    t_timer_cyc[t_timer_n] <= cycle_count;
                    t_timer_n <= t_timer_n + 1;
                end
                in_timed <= (t_timer_n == 0) ? 1'b1 : 1'b0;
            end
            if (in_timed) begin
                tc_all <= tc_all + 64'd1;
                if (u_core.stall)     tc_stall  <= tc_stall + 64'd1;
                if (u_core.div_stall) tc_div    <= tc_div + 64'd1;
                if (u_core.mul_start) tc_mul    <= tc_mul + 64'd1;
                if (u_core.ex_flush)  tc_flush  <= tc_flush + 64'd1;
                if (u_core.fwd_a_ex || u_core.fwd_b_ex) tc_fwdex <= tc_fwdex + 64'd1;
                if (u_core.fwd_a_wb || u_core.fwd_b_wb) tc_fwdwb <= tc_fwdwb + 64'd1;
                if (u_core.mem_re || u_core.mem_we)     tc_mem   <= tc_mem + 64'd1;
                if (v_wb)             tc_commit <= tc_commit + 64'd1;
                if (u_core.id_ex_branch) begin
                    tc_br_tot <= tc_br_tot + 64'd1;
                    if (u_core.id_ex_imm[31]) tc_br_bwd <= tc_br_bwd + 64'd1;
                    if (u_core.branch_taken) begin
                        tc_br_tk <= tc_br_tk + 64'd1;
                        if (u_core.id_ex_imm[31])
                            tc_br_bwd_tk <= tc_br_bwd_tk + 64'd1;
                    end
                end
                if (u_core.p_redirect) tc_redir   <= tc_redir   + 64'd1;
                if (u_core.ex_mispred)  tc_mispred <= tc_mispred + 64'd1;
                if (u_core.id_ex_jump)     tc_jal  <= tc_jal  + 64'd1;
                if (u_core.id_ex_jump_reg) tc_jalr <= tc_jalr + 64'd1;
            end

            // ---- 直方图 ----
            if (h_idx < NH) begin
                if (u_core.stall)     h_stall[h_idx] <= h_stall[h_idx] + 64'd1;
                if (u_core.ex_flush)  h_flush[h_idx] <= h_flush[h_idx] + 64'd1;
                if (u_core.mem_re || u_core.mem_we)
                                      h_mem[h_idx]   <= h_mem[h_idx] + 64'd1;
                if (v_wb)             h_cmt[h_idx]   <= h_cmt[h_idx] + 64'd1;
            end
            if (h_cnt == HBUCKET - 1) begin
                h_cnt <= 0;
                if (h_idx < NH - 1) h_idx <= h_idx + 1;
            end else begin
                h_cnt <= h_cnt + 1;
            end
        end
    end

    // ========================================================================
    // [TASK-C 分析] 消除 load-use 停顿的可达收益（+LDANAL）
    // ------------------------------------------------------------------------
    // 任务 C 的做法：把 load 的地址算到 ID 级、用【专用提前读口】早一拍取回数据，
    // 于是紧跟其后的 load-use 停顿不再需要。但只有一部分 load 能走这条快通路：
    //   ① 基址寄存器正被【EX 级那条指令】写       → ID 级拿不到（结果还在 ALU 里）
    //   ② 基址寄存器正被 EX/MEM 里的 load/AMO 写  → 数据还没回来
    //   ③ 地址不在 RAM 段                        → 专用读口只镜像 RAM
    //   ④ 紧前一条（任一 lane）是 store/AMO       → 与提前读口同址读写会读到旧值
    // ①③④ 在 ID 级就看得出（地址/寄存器号都是 ID 级的信号），② 要靠影子标志。
    // 本段把停顿按上面五类（含"可消"）计数，给出**上界**。
    // ========================================================================
    // ID 级基址估算：镜像将要实现的 ID 前递网（不含 EX 级本身 —— 那正是 ①）
    wire        a_f_exb = u_core.ex_mem_b_reg_write && (u_core.ex_mem_b_rd != 5'd0) &&
                          (u_core.ex_mem_b_rd == u_core.rs1);
    wire        a_f_ex  = u_core.ex_mem_reg_write && (u_core.ex_mem_rd != 5'd0) &&
                          (u_core.ex_mem_rd == u_core.rs1) &&
                          (u_core.ex_mem_wb_sel != 2'b01) && !u_core.ex_mem_is_amo;
    wire        a_f_wbb = u_core.mem_wb_b_reg_write && (u_core.mem_wb_b_rd != 5'd0) &&
                          (u_core.mem_wb_b_rd == u_core.rs1);
    wire        a_f_wb  = u_core.mem_wb_reg_write && (u_core.mem_wb_rd != 5'd0) &&
                          (u_core.mem_wb_rd == u_core.rs1);
    wire [31:0] a_base  = a_f_exb ? u_core.ex_mem_forward_val_b :
                          a_f_ex  ? u_core.ex_mem_forward_val :
                          a_f_wbb ? u_core.wb_data_b :
                          a_f_wb  ? u_core.wb_data : u_core.rdata1;
    wire [31:0] a_addr  = a_base + u_core.imm;
    wire        a_in_ram = (a_addr[31:17] == 15'd0) &&
                           !((a_addr[16] == 1'b0) && (a_addr[15:4] == 12'hFFF));
    wire        a_bad_ex = (u_core.id_ex_reg_write   && (u_core.id_ex_rd   != 5'd0) &&
                            (u_core.id_ex_rd   == u_core.rs1)) ||
                           (u_core.id_ex_b_reg_write && (u_core.id_ex_b_rd != 5'd0) &&
                            (u_core.id_ex_b_rd == u_core.rs1));
    // ②：EX/MEM 里那条是 load/AMO 且【不是】快通路 load（快通路 load 的数据已经在
    //    提前读口上，可以先借 f_mem 免掉）—— f_mem 是它自己在 ID 级算出来的标志。
    wire        a_bad_memld = (u_core.ex_mem_rd != 5'd0) && (u_core.ex_mem_rd == u_core.rs1) &&
                              (u_core.ex_mem_mem_read || u_core.ex_mem_is_amo) && !f_mem;
    // [!] 2026-10-16 撤档：A1 的 lane B store 已退回 ⇒ 与 core.v 的 ld_bad_st 同款只剩 lane A。
    wire        a_bad_store = u_core.id_ex_mem_write;
    wire        a_bad_amo   = u_core.id_ex_is_amo || u_core.ex_mem_is_amo;
    wire [2:0]  a_code = a_bad_ex    ? 3'd1 :
                         a_bad_memld ? 3'd2 :
                         (!a_in_ram) ? 3'd3 :
                         a_bad_store ? 3'd4 :
                         a_bad_amo   ? 3'd5 : 3'd0;
    wire        a_is_ld = u_core.mem_read;
    wire        a_ok    = a_is_ld && (a_code == 3'd0);
    // ID→EX 真的推进了吗（与 ID/EX 寄存器的清零条件一致）
    wire        a_adv   = !u_core.ex_flush && !u_core.ex_mispred && !u_core.trap &&
                          !u_core.mc_stall && u_core.mem_ready_int;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            a_st_tot <= 64'd0; a_st_fast <= 64'd0;
            a_s_ex <= 64'd0; a_s_memld <= 64'd0; a_s_ram <= 64'd0;
            a_s_store <= 64'd0; a_s_amo <= 64'd0;
            a_ld_tot <= 64'd0; a_ld_fast <= 64'd0;
            a_rtl_ld <= 64'd0; a_rtl_fast <= 64'd0;
            a_mm <= 64'd0; a_mm_base <= 64'd0; a_mm_ram <= 64'd0;
            a_mm_st <= 64'd0; a_mm_amo <= 64'd0;
            f_ex <= 1'b0; f_mem <= 1'b0; cl_ex <= 3'd0;
        end else if (ldan_on) begin
            // 影子推进（与 +PROF 的 v_* 链同构，另加访存冻结时【保持】）
            f_ex  <= (u_core.ex_flush || u_core.ex_mispred || u_core.trap) ? 1'b0 :
                     (u_core.mc_stall || !u_core.mem_ready_int) ? f_ex :
                     (u_core.stall ? 1'b0 : a_ok);
            f_mem <= (u_core.mc_stall || u_core.trap) ? 1'b0 :
                     (!u_core.mem_ready_int ? f_mem : f_ex);
            cl_ex <= (u_core.ex_flush || u_core.ex_mispred || u_core.trap) ? 3'd0 :
                     (u_core.mc_stall || !u_core.mem_ready_int) ? cl_ex :
                     (u_core.stall ? 3'd0 : a_code);
            // [!] a_adv 必须含 !stall：停顿那拍 IF/ID 是【保持】的，
            //     不排除就会把同一条 load 重复计几次（实测基线里多算 2,499 条）。
            if (a_is_ld && a_adv && !u_core.stall && in_timed) begin
                a_ld_tot  <= a_ld_tot  + 64'd1;
                if (a_ok) a_ld_fast <= a_ld_fast + 64'd1;
            end
            if (in_timed && a_is_ld && (a_ok !== u_core.ld_fast)) begin
                a_mm <= a_mm + 64'd1;
                if (u_core.ld_bad_base) a_mm_base <= a_mm_base + 64'd1;
                if (u_core.ld_bad_ram)  a_mm_ram  <= a_mm_ram  + 64'd1;
                if (u_core.ld_bad_st)   a_mm_st   <= a_mm_st   + 64'd1;
                if (u_core.ld_bad_amo)  a_mm_amo  <= a_mm_amo  + 64'd1;
            end
            // RTL 实际口径（不依赖影子模型）：load 写回拍 / 快通路 load 的 MEM 级
            if (in_timed && u_core.mem_wb_reg_write && (u_core.mem_wb_wb_sel == 2'b01))
                a_rtl_ld   <= a_rtl_ld   + 64'd1;
            if (in_timed && u_core.ex_mem_ld_fast)
                a_rtl_fast <= a_rtl_fast + 64'd1;
            // [!] 分类计数【只统计 CoreMark 计时区间】（in_timed）—— 全局窗口被
            //     UART 忙等打印段（读 0xFFF4/0xFFF8，属于兼容区、且紧跟依赖）淹没，
            //     那些停顿占全局 92%，与跑分无关。与 +PROF 的 tc_* 口径一致。
            if (u_core.stall && in_timed) begin
                a_st_tot <= a_st_tot + 64'd1;
                if (f_ex) a_st_fast <= a_st_fast + 64'd1;
                else case (cl_ex)
                    3'd1: a_s_ex    <= a_s_ex    + 64'd1;
                    3'd2: a_s_memld <= a_s_memld + 64'd1;
                    3'd3: a_s_ram   <= a_s_ram   + 64'd1;
                    3'd4: a_s_store <= a_s_store + 64'd1;
                    3'd5: a_s_amo   <= a_s_amo   + 64'd1;
                    default: ;
                endcase
            end
        end
    end

    // ========================================================================
    // 逐拍五级流水线 trace（+TRACE_START/+TRACE_LEN），用于画时序波形图。
    // 输出到独立文件，避免与 UART 的 $write 字符流混在一起。
    // ========================================================================
    always @(posedge clk) begin
        if (resetn && prof_on && trace_start_cyc >= 0) begin
            if (trace_left == 0 && cycle_count == trace_start_cyc) begin
                trace_fd   = $fopen(trace_fname, "w");
                trace_left = trace_len;
            end
            if (trace_left > 0 && trace_fd != 0) begin
                $fdisplay(trace_fd,
                    "T cyc=%0d pc=%h ipc=%h ins=%h epc=%h eop=%h erd=%h mpc=%h mrd=%h mwe=%b mre=%b wrd=%h wwe=%b st=%b dv=%b fl=%b fd=%b ir=%b faex=%b fbex=%b fawb=%b fbwb=%b vid=%b vex=%b vmem=%b vwb=%b br=%b bt=%b jmp=%b jr=%b",
                    cycle_count, pc,
                    u_core.if_id_pc, u_core.if_id_instr,
                    u_core.id_ex_pc, u_core.id_ex_alu_op, u_core.id_ex_rd,
                    u_core.ex_mem_pc, u_core.ex_mem_rd,
                    u_core.mem_we, u_core.mem_re,
                    u_core.mem_wb_rd, u_core.mem_wb_reg_write,
                    u_core.stall, u_core.mc_stall,
                    u_core.ex_flush, u_core.ex_mispred, u_core.p_redirect,
                    u_core.fwd_a_ex, u_core.fwd_b_ex,
                    u_core.fwd_a_wb, u_core.fwd_b_wb,
                    v_id, v_ex, v_mem, v_wb,
                    u_core.id_ex_branch, u_core.branch_taken,
                    u_core.id_ex_jump, u_core.id_ex_jump_reg);
                trace_left = trace_left - 1;
                if (trace_left == 0) $fclose(trace_fd);
            end
        end
    end
endmodule
