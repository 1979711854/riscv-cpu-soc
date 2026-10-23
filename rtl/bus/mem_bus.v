`timescale 1ns/1ps
`include "addr_map.vh"
// ============================================================================
// mem_bus —— 存储总线 / 地址译码（SoC 里唯一做地址译码的地方）
// ----------------------------------------------------------------------------
// 时序契约（core.v 依赖它，改这里必须同步看 core.v 的 MEM/WB 段）：
//   第 T   拍 (MEM)：core 给出 mem_addr / mem_wdata / mem_we / mem_byte_en
//   第 T+1 拍 (WB)：mem_rdata 必须是 mem_addr(T) 对应地址的读数据
// 由此推出两条硬约束，破坏任何一条都会让 load 读到错值：
//   1) 写通路零寄存器：mem_we/addr/wdata/byte_en 必须组合打进 RAM 写口。
//      [!] 若把写地址或写数据寄存一拍，store 在 T 提交、load 在 T+1 读回旧值，
//          st_ld / ld_st 这类"存完立刻读回"用例直接 FAIL。
//   2) 读选择位与读数据都在 MEM→WB 沿寄存（rsel_d 一族），读通路不得再插寄存器。
//      [!] 所有地址源（RAM/兼容区/外设区/视频区）一律 1 拍延迟，不搞特例 ——
//          冒险单元不知道内存有几拍，T+2 才出的数据没有任何 stall 机制能救。
//      RAM 与视频显存都是同步 BRAM，读数据在模块内部同沿寄存，天然满足约束 2；
//      视频区"1 拍必回"，mem_ready 对它恒 1，显示不走等待状态。
// 地址映射见 addr_map.vh。
// ============================================================================
module mem_bus (
    input  wire        clk,
    input  wire        resetn,

    // ---- 取指口（直通统一存储器的 A1/A2 口，不做任何仲裁/缓冲）----
    // A2 是双发射的第二取指读口：与 A1 同拍、同延迟，读 unified_mem 的复制阵列。
    // 单发射（DUAL_ISSUE=0）时 core 仍驱动它、但结果被丢弃，行为逐位不变。
    input  wire [14:0] imem_addr,
    output wire [31:0] imem_rd,
    input  wire [14:0] imem_addr2,   // 与 imem_addr 同宽（128KB = 32768 word），别改窄 —— 见 core.v 端口注释
    output wire [31:0] imem_rd2,

    // ---- 提前 load 读口（C 口，只读、同步读 1 拍）----
    // 由 core 的 ID/EX 寄存器驱动（= load 的 EX 级），数据下一拍回来。不做任何
    // 译码/仲裁：只镜像 RAM 段，core 侧的 ld_fast 判据已保证只对 RAM 地址启用。
    // [!] 它绕过 D-Cache 直接读真存储器，永远比 Cache 新；写通路本就写通到 BRAM，
    //     功能上安全。
    input  wire [14:0] ld_addr,
    output wire [31:0] ld_rdata,

    // ---- 访存口（来自 core 的 MEM 级）----
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,     // 已按 sb/sh/sw 做过字节复制
    input  wire [3:0]  mem_byte_en,
    input  wire        mem_we,
    input  wire        mem_re,
    output wire [31:0] mem_rdata,

    // ---- 访存就绪（core.v 的访存等待机制）----
    // 1 = 本次访存在固定 1 拍内完成；0 = 未完成，core 冻住 MEM/WB 及上游。
    // 现在只有 RAM 的 b_ready 接进来；日后 APB/AXI 桥在这里驱动。
    output wire        mem_ready,

    // ---- 外设：写选通 / 读回（外设寄存器本体在 rtl/periph/ 里）----
    output wire        gpio_we,       // 0x8000_0000 写 LED
    output wire        uart_tx_we,    // 0x8000_0008 或 0xFFFC 写一个字符
    output wire        uart_rx_ack,   // 0x8000_000C 读，清 rx valid
    output wire [31:0] periph_wdata,  // 送外设的写数据（字节复制后）
    input  wire [31:0] gpio_rdata,
    input  wire [31:0] uart_rx_rdata,

    // ---- 视频：显存 CPU 口 + 控制寄存器（本体在 rtl/video/video_top.v）----
    // 与其它外设不同，视频显存住在另一个模块、跨到 pix_clk 域，所以这里只出
    // 「一次访问落在哪个子窗口」+ 数据，由 video_top 自己分派。地址映射见
    // addr_map.vh 的视频区小节。
    output wire        vid_we,        // 写使能（子窗口由 vid_vsel 决定）
    output wire [1:0]  vid_vsel,      // 0=nametable 1=pattern 2=palette 3=寄存器
    output wire [13:0] vid_waddr,     // 区域相对字地址（写口用）
    output wire [3:0]  vid_be,        // = mem_byte_en，字节使能直通
    output wire [31:0] vid_wdata,
    output reg  [1:0]  vid_vsel_d,    // 与读数据同拍（= rsel_d 那一族）
    output reg  [13:0] vid_waddr_d,   // 同上，寄存器读回要按字偏移选
    input  wire [31:0] vid_rdata,

    // ---- 兼容区状态 ----
    output reg         done,          // 0xFFF8 写 1 → 拉高（板级 LED / 结束标志）

    // ---- 中断 ----
    // 定时器中断（mip.MTIP，bit7）。电平信号，直连 core.irq_timer。
    output wire        irq_timer,

    // ---- 假 AGU 观测口（AGU_PROBE=0 时上层给 0）----
    input  wire [31:0] agu_probe_in
);

    // ---- 假 tag 路径开关（只为综合量时序；逻辑见文件末尾 mem_rdata 之前）----
    // 0 = 逐位不变（访存读数据 = ram_rdata）。1 = 插入"假 tag 比较 + way mux"。
    // PDS 命令行传不了 -D 宏，靠参数默认值切换：量时序时临时把 cpu_top.v 里的
    // 默认值改成 1，量完改回 0。
    parameter CACHE_TAG_PROBE = 0;

    // ---- D-Cache 开关 ----
    // 0 = 默认不例化 cache_d，访存通路逐位不变。
    // 1 = 例化 2 路组相联 D-Cache（见 rtl/bus/cache_d.v）。
    // [!] 打开时 cpu_top.v 的默认值要一起改（仿真侧 tb_* 直接传参数）。
    parameter DCACHE_EN = 0;

    // ---- I-Cache 开关 ----
    // 0 = 默认不例化 cache_i，取指通路逐位不变。
    // 1 = 例化 2 路组相联 I-Cache（见 rtl/bus/cache_i.v）。
    parameter ICACHE_EN = 0;

    // ---- 假 AGU 观测开关（默认关；见 core.v 的 AGU_PROBE）----
    parameter AGU_PROBE = 0;

    // ---- load 地址提前（透传给 unified_mem：决定是否例化第三份阵列）----
    // [!] 必须与 core.v / cpu_top.v 的 EARLY_LD 取值一致，否则读口读的是空阵列。
    parameter EARLY_LD = 0;

    // ------------------------------------------------------------------
    // 32 位自由跑周期计数器（27MHz），兼容区 0xFFF4 与外设区 TIMER 共用同一个。
    // CoreMark 的 get_time() 与 ee_printf 的忙等都靠它，必须保持 1 拍可读。
    // ------------------------------------------------------------------
    reg [31:0] cyc;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) cyc <= 32'd0;
        else         cyc <= cyc + 32'd1;
    end

    // ------------------------------------------------------------------
    // CLINT：mtime 复用上面的 cyc（不另起计数器，避免两处漂移）；mtimecmp 可写。
    //
    // [!] MTIP 必须是纯电平比较器，绝不做锁存/脉冲：软件写新 mtimecmp 后下一拍
    //     自动落下，这是 mret 之后能继续正常工作的前提 —— 做成"置位保持到软件
    //     清除"会陷入 trap 死循环，PC 钉死在 mtvec。
    // [!] mtimecmp 复位值必须全 1：复位为 0 会让 mtime >= mtimecmp 恒真、上电即
    //     MTIP=1。mie.MTIE=0 只是第二道防线，不能依赖。
    // 比较器单独打一拍（mtip_r）：把 32 位比较从临界路径上切下来；电平语义下
    // 多这 1 拍无害（mtimecmp 极低频写、mtime 单调递增）。
    // ------------------------------------------------------------------
    reg [31:0] mtimecmp;
    reg        mtip_r;

    wire mtime_ge_cmp = (cyc >= mtimecmp);

    always @(posedge clk or negedge resetn) begin
        if (!resetn)              mtip_r <= 1'b0;
        else                      mtip_r <= mtime_ge_cmp;
    end

    // （mtimecmp 的写逻辑在文件末尾 —— 它要用到下面才声明的 periph_hit/periph_off，
    //   iverilog 14 严格要求先声明后使用。）

    assign irq_timer = mtip_r;

    // ------------------------------------------------------------------
    // 地址译码（只在这里做一次）
    // ------------------------------------------------------------------
    // 128KB：RAM = 0x0~0x1FFFF；兼容区只挖低 64KB 的 0xFFF0~0xFFFF。
    // [!] 0x1FFF0 的 `addr[15:4]` 也是 0xFFF，必须用 `!addr[16]` 区分，
    //     否则 0x1FFF0 会被误判成兼容区 MMIO（它正好在 RT-Thread 栈顶附近）。
    wire legacy_hit = (mem_addr[31:17] == 15'd0) && !mem_addr[16] &&
                      (mem_addr[15:4] == 12'hFFF);
    wire ram_hit    = (mem_addr[31:17] == 15'd0) && !legacy_hit;  // 0x0~0x1FFFF 挖掉兼容区

    // 高半区（addr[31]=1）一分为二，分界线在 addr[16]：
    //   addr[17:16] == 2'b00 → 外设区 0x8000_0000~0x8000_FFFF
    //   addr[17:16] != 2'b00 → 视频区 0x8001_0000~0x8003_FFFF
    // [!] 若只看 mem_addr[31]，写显存会顺带命中 GPIO 点亮 LED，高半区必须用
    //     addr[17:16] 切开。
    wire periph_hit = mem_addr[31] && (mem_addr[17:16] == 2'b00);
    wire video_hit  = mem_addr[31] && (mem_addr[17:16] != 2'b00);

    wire [1:0] legacy_off = mem_addr[3:2];
    wire [3:0] periph_off = mem_addr[5:2];                        // 字内偏移

    wire legacy_cycle = legacy_hit && (legacy_off == 2'b01);      // 0xFFF4
    wire legacy_done  = legacy_hit && (legacy_off == 2'b10);      // 0xFFF8
    wire legacy_utx   = legacy_hit && (legacy_off == 2'b11);      // 0xFFFC

    // ------------------------------------------------------------------
    // 视频区子窗口（地址含基址 0x8001_0000，即下面都是 mem_addr 的绝对值）
    //   四个窗口互斥，见 addr_map.vh 的视频区小节
    // ------------------------------------------------------------------
    wire v_nt_sel  = video_hit && (mem_addr[17:13] == 5'b01000);  // 0x8001_0000 8KB
    wire v_pat_sel = video_hit && (mem_addr[17:16] == 2'b10);     // 0x8002_0000 64KB
    wire v_pal_sel = video_hit && (mem_addr[17:10] == 8'hC0);     // 0x8003_0000 1KB
    wire v_reg_sel = video_hit && (mem_addr[17:10] == 8'hC1);     // 0x8003_0400 1KB

    wire [1:0] vsel = v_pat_sel ? 2'd1 :
                      v_pal_sel ? 2'd2 :
                      v_reg_sel ? 2'd3 : 2'd0;

    // 视频区里有大片未分配的地址（如 0x8003_0800 以上）。它们不能让 vsel 的
    // 默认值 0 变成"悄悄写 nametable"——所以写使能只在真命中四个子窗口时给。
    // （读方向未分配地址会读回 nametable 数据，属于"别这么干"，不额外防。）
    wire v_sel_any = v_nt_sel | v_pat_sel | v_pal_sel | v_reg_sel;

    assign vid_we      = mem_we && v_sel_any;
    assign vid_vsel    = vsel;
    assign vid_waddr   = mem_addr[15:2];   // 区域相对字地址：NT[10:0] PAT[13:0] PAL[7:0] REG[1:0]
    assign vid_be      = mem_byte_en;
    assign vid_wdata   = mem_wdata;

    // ------------------------------------------------------------------
    // 统一存储器：A 口取指 / B 口访存
    //   指令与数据共用一块，所以 store 写进去的东西，后续取指能读到 ——
    //   这正是 fence_i（自修改代码）能通过的原因。
    // ------------------------------------------------------------------
    wire [14:0] ram_word = mem_addr[16:2];
    wire [31:0] ram_rdata;
    wire        ram_ready;      // RAM 的就绪（恒 1；仿真里可被 +MEMWAIT 拉低）

    // [!] A1 口的读数据先落到内部线 a1_bram，再由下面的 I-Cache（或直通）驱动
    //     imem_rd。A2 口不经过 I-Cache，直连 imem_rd2（理由见 cache_i.v 文件头）。
    wire [31:0] a1_bram;

    unified_mem #(.EARLY_LD(EARLY_LD)) u_mem (
        // A1 口：取指 1（只读）
        .a_addr   (imem_addr),
        .a_rd_data(a1_bram),
        .a_clk    (clk),
        .a_rst    (~resetn),
        // C 口：提前 load 读（只读，EARLY_LD=0 时阵列不例化、恒 0）
        .ld_addr  (ld_addr),
        .ld_rd_data(ld_rdata),
        // A2 口：取指 2（只读，双发射第二读口；与 A1 同域）
        .a2_addr  (imem_addr2),
        .a2_rd_data(imem_rd2),
        // B 口：访存（读写）
        .b_addr   (ram_word),
        .b_wr_data(mem_wdata),
        .b_wr_en  (ram_hit && mem_we),
        .b_byte_en(mem_byte_en),
        .b_rd_data(ram_rdata),
        .b_clk    (clk),
        .b_rst    (~resetn),
        // [!] 输出端口只能接一根线，不能写条件表达式（iverilog 会报
        //     "expression not valid in assign l-value"）。选择逻辑放在下面。
        .b_ready  (ram_ready)
    );

    // ==================================================================
    // D-Cache（默认关）：夹在 core 访存口与 unified_mem B 口之间，只缓存读
    // ------------------------------------------------------------------
    // 写仍组合打进 BRAM（写通、零寄存器），st_ld / fence.i 语义与不开 Cache 一致；
    // 缺失停 1 拍走既有 freeze 通路。
    // [!] 唯一消费者是 load（store 的 WB 级不读 mem_rdata），store 命中的同址
    //     读写不会污染结果（见 cache_d.v）。
    // [!] 必须先于下面的 mem_ready 声明（iverilog 14 要求先声明后使用）。
    // ==================================================================
    wire        d_stall_w;
    wire [31:0] d_rdata_w;
    wire        d_hit_w;
    wire        d_miss_w;

    generate
    if (DCACHE_EN != 0) begin : g_dcache
        cache_d u_dcache (
            .clk       (clk),
            .resetn    (resetn),
            .req       (ram_hit && (mem_re || mem_we)),
            .we        (mem_we),
            .word      (ram_word),
            .wdata     (mem_wdata),
            .be        (mem_byte_en),
            .bram_rdata(ram_rdata),
            .stall     (d_stall_w),
            .rdata     (d_rdata_w),
            .hit_pulse (d_hit_w),
            .miss_pulse(d_miss_w)
        );
    end else begin : g_nodcache
        assign d_stall_w = 1'b0;
        assign d_rdata_w = 32'd0;
        assign d_hit_w   = 1'b0;
        assign d_miss_w  = 1'b0;
    end
    endgenerate

    // ------------------------------------------------------------------
    // Cache 命中/缺失计数器（只读；默认关时恒 0）
    // ------------------------------------------------------------------
    reg [31:0] dcache_hits;
    reg [31:0] dcache_misses;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            dcache_hits   <= 32'd0;
            dcache_misses <= 32'd0;
        end else begin
            if (d_hit_w)  dcache_hits   <= dcache_hits   + 32'd1;
            if (d_miss_w) dcache_misses <= dcache_misses + 32'd1;
        end
    end

    // ==================================================================
    // I-Cache（默认关）
    // ------------------------------------------------------------------
    // 只缓存 A1（imem_addr）；A2（imem_addr2）仍直连 BRAM —— 它恒 1 拍就绪、
    // 与 A1 天然同拍，缓存它只会多花 16KB BRAM 与两套 tag（见 cache_i.v）。
    // 缺失时用 mem_ready 当取指停顿（取指口没有就绪信号，理由见 cache_i.v）。
    // ==================================================================
    wire        i_stall_w;
    wire [31:0] i_rdata_w;
    wire        i_hit_w;
    wire        i_miss_w;

    generate
    if (ICACHE_EN != 0) begin : g_icache
        cache_i u_icache (
            .clk       (clk),
            .resetn    (resetn),
            .word      (imem_addr),
            .bram_rdata(a1_bram),
            .stall     (i_stall_w),
            .rdata     (i_rdata_w),
            .hit_pulse (i_hit_w),
            .miss_pulse(i_miss_w)
        );
    end else begin : g_noicache
        assign i_stall_w = 1'b0;
        assign i_rdata_w = 32'd0;
        assign i_hit_w   = 1'b0;
        assign i_miss_w  = 1'b0;
    end
    endgenerate

    assign imem_rd = (ICACHE_EN != 0) ? i_rdata_w : a1_bram;

    // ------------------------------------------------------------------
    // I-Cache 命中/缺失计数器（只读；默认关时恒 0）
    // ------------------------------------------------------------------
    reg [31:0] icache_hits;
    reg [31:0] icache_misses;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            icache_hits   <= 32'd0;
            icache_misses <= 32'd0;
        end else begin
            if (i_hit_w)  icache_hits   <= icache_hits   + 32'd1;
            if (i_miss_w) icache_misses <= icache_misses + 32'd1;
        end
    end

    // [!] 只在真的有 RAM 访存在途时才跟随 ram_ready：非访存指令的 alu_result 也常
    //     落在 RAM 段，若按地址命中就跟随，空闲期 mem_ready 会被自由跑的 ram_ready
    //     拉低，违反"空闲期 mem_ready 必须为 1"的总线契约。MEMWAIT=0 时逐位相同。
    // D-Cache 缺失再压 1 拍（缺失 1 拍期间后端 BRAM 读出的正是本条 load 的字）；
    // I-Cache 缺失也压 mem_ready（取指口没有就绪信号，见 cache_i.v）。
    // [!] I-Cache 停顿是无条件相与：外设访问也会被冻住几拍，所以下面的外设选通
    //     必须做 one-shot 门控（bus_first）。
    wire mem_ready_core = (ram_hit && (mem_re || mem_we)) ? (ram_ready && !d_stall_w) : 1'b1;
    assign mem_ready = mem_ready_core && !i_stall_w;

    // ------------------------------------------------------------------
    // 读数据选择位 + 非 RAM 源的读数据，都在 MEM→WB 沿寄存（约束 2）
    // ------------------------------------------------------------------
    reg [1:0]  rsel_d;            // 0 = RAM，1 = 兼容区，2 = 外设区，3 = 视频区
    reg [31:0] legacy_rdata_d;
    reg [31:0] periph_rdata_d;

    // 假 AGU 的只读回读（只为让综合器保留那条路径）
    reg [31:0] agu_probe_r;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) agu_probe_r <= 32'd0;
        else         agu_probe_r <= agu_probe_in;
    end

    wire [31:0] periph_rmux =
        (periph_off == `PERIPH_GPIO)       ? gpio_rdata      :
        (periph_off == `PERIPH_UART_RX)    ? uart_rx_rdata   :
        (periph_off == `PERIPH_TIMER)      ? cyc             :   // = mtime
        (periph_off == `PERIPH_MTIMECMP)   ? mtimecmp        :
        (periph_off == `PERIPH_DCACHE_HITS)? dcache_hits     :
        (periph_off == `PERIPH_DCACHE_MISS)? dcache_misses   :
        (periph_off == `PERIPH_ICACHE_HITS)? icache_hits     :
        (periph_off == `PERIPH_ICACHE_MISS)? icache_misses   :
        (periph_off == `PERIPH_AGU_PROBE) ? agu_probe_r     : 32'd0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rsel_d         <= 2'd0;
            legacy_rdata_d <= 32'd0;
            periph_rdata_d <= 32'd0;
            vid_vsel_d     <= 2'd0;
            vid_waddr_d    <= 14'd0;
        end else begin
            rsel_d         <= video_hit  ? 2'd3 :
                              legacy_hit ? 2'd1 : periph_hit ? 2'd2 : 2'd0;
            legacy_rdata_d <= legacy_cycle ? cyc : 32'd0;
            periph_rdata_d <= periph_hit ? periph_rmux : 32'd0;
            // 视频区：子窗口选择与字地址都要拖到与读数据同拍。显存本身在
            // video_top 里由 BRAM 寄存了 1 拍，寄存器读回是稳定的寄存器值、
            // 只靠这两根选择线对齐，所以 [1:0] 必须一起延。
            vid_vsel_d     <= vsel;
            vid_waddr_d    <= mem_addr[15:2];
        end
    end

    // ==================================================================
    // 假 tag 路径（CACHE_TAG_PROBE）—— 只为综合量时序，默认关
    // ------------------------------------------------------------------
    // 目的：量 Cache 路径（tag 读 → 比较 → way mux）压到访存关键路径上的深度。
    // [!] tag/数据必须借真实信号（ram_rdata/imem_rd/imem_rd2/vid_rdata）而非常数
    //     —— 恒命中的假逻辑是冗余的，会被综合器整个消掉，量出假的"无影响"结论。
    //     PROBE=1 时功能不正确，只综合量时序用；PROBE=0 时三目常量折叠成
    //     ram_rdata 直通，逐位不变。
    // ==================================================================
    wire [19:0] p_addr_tag = mem_addr[31:12];   // 地址 tag（20 位，同真实 Cache）
    wire [19:0] p_tag0     = ram_rdata[31:12];  // "way0 存的 tag"（借 BRAM 读数据）
    wire [19:0] p_tag1     = imem_rd2[31:12];   // "way1 存的 tag"（借第二取指口）
    wire        p_hit0     = (p_tag0 == p_addr_tag);
    wire        p_hit1     = (p_tag1 == p_addr_tag);
    wire [31:0] p_d0       = ram_rdata;         // way0 数据
    wire [31:0] p_d1       = imem_rd;           // way1 数据（独立真实源，防折叠）
    wire [31:0] p_fill     = vid_rdata;         // 缺失回填口（第三个真实源）
    // 两级 mux：way 选择（命中 way0 优先）+ 命中/回填选择 —— 与真实 Cache 同深
    wire [31:0] p_way_data = p_hit0 ? p_d0 : p_d1;
    wire [31:0] p_rdata    = (p_hit0 | p_hit1) ? p_way_data : p_fill;

    // DCACHE_EN=1 时读数据改走 cache_d（命中给阵列数据、缺失直通后端 BRAM）；
    // 两个开关互斥使用，默认都为 0 ⇒ 逐位是 ram_rdata。
    wire [31:0] ram_rdata_eff = (CACHE_TAG_PROBE != 0) ? p_rdata   :
                                (DCACHE_EN       != 0) ? d_rdata_w : ram_rdata;

    assign mem_rdata = (rsel_d == 2'd3) ? vid_rdata :
                       (rsel_d == 2'd1) ? legacy_rdata_d :
                       (rsel_d == 2'd2) ? periph_rdata_d : ram_rdata_eff;

    // ------------------------------------------------------------------
    // 外设写选通（组合，零拍；u8 写入按低字节取，与 sb/sh/sw 都兼容）
    // ------------------------------------------------------------------
    // [!] 这三个选通是电平敏感的，不是"沿上看一眼"。现在安全是因为外设访问恒
    //     不等待（mem_ready 对非 RAM 地址直接给 1），条件里又含 mem_we/mem_re，
    //     所以只高 1 拍。
    // [!] 若将来加 APB/AXI 桥并让外设等待，访问被停住时选通会一直高着 ——
    //     "发一次字符"变"发 N 次"，静默数据损坏。必须与"本次访问的首次那一拍"
    //     相与，完整复盘见 doc/reports/（bus_upgrade_plan §3）。
    // I-Cache 缺失会压 mem_ready，外设访问可能被冻住，所以这里已按上述方案做
    // one-shot 门控：bus_stall_r 是上一拍 mem_ready 的反相，缓存关时门控恒 1，
    // 行为逐位不变。
    reg bus_stall_r;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) bus_stall_r <= 1'b0;
        else         bus_stall_r <= !mem_ready;
    end
    wire bus_first = !bus_stall_r;

    assign gpio_we      = periph_hit && mem_we && (periph_off == `PERIPH_GPIO) && bus_first;
    assign uart_tx_we   = ((periph_hit && mem_we && (periph_off == `PERIPH_UART_TX))
                          || (legacy_utx && mem_we)) && bus_first;
    assign uart_rx_ack  = periph_hit && mem_re && (periph_off == `PERIPH_UART_RX) && bus_first;
    assign periph_wdata = mem_wdata;

    // ------------------------------------------------------------------
    // 结束标志：写 0xFFF8 低字节 = 1。
    // 用 byte_en[0] + 低字节比较（而不是整字 ==1），这样 sb/sh/sw 都能触发。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge resetn) begin
        if (!resetn) done <= 1'b0;
        else if (mem_we && legacy_done && mem_byte_en[0] && (mem_wdata[7:0] == 8'd1))
            done <= 1'b1;
    end

    // ------------------------------------------------------------------
    // CLINT：mtimecmp 写口
    // 只接受整字写（sw），sb/sh 静默忽略 —— 规范里 mtimecmp 也是按字访问的。
    // 复位值全 1 而不是 0，理由见上面 mtip_r 附近的注释。
    // ------------------------------------------------------------------
    always @(posedge clk or negedge resetn) begin
        if (!resetn) mtimecmp <= 32'hFFFF_FFFF;
        else if (periph_hit && mem_we && (periph_off == `PERIPH_MTIMECMP) &&
                 (mem_byte_en == 4'b1111))
            mtimecmp <= mem_wdata;
    end

endmodule
