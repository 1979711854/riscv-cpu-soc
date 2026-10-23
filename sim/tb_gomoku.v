`timescale 1ns/1ps
// ============================================================================
// 五子棋固件端到端测试台（轨道 E2）
// ----------------------------------------------------------------------------
// 覆盖什么：**从按键到画面**的整条链，在真 CPU + 真 PPU 上跑固件。
//
//   [1] 固件能启动：串口打印出 banner
//   [2] 上电就把棋盘铺好了：探显存的 nametable，检查左上角/天元的图块号
//       （天元现在是星位点，不再是内部空格）
//   [3] 按键能开局：长按进 HUMAN 子菜单 + 短按 ↓↓ 到 START + 长按开局 -> 串口出现 "start,"
//   [4] 落子 + AI 应手：再注入一次长按 -> 串口出现 "AI moved"，
//       天元变成普通黑子，且棋盘上出现 1 颗带红标的最后一手白子（AI 那手）
//
// 覆盖不到（只能上板看）：pll_video 锁没锁、OSERDES/TMDS、显示器认不认时序。
// 所以本测试台 PASS 只说明"喂给 TMDS 之前的画面与交互全对"。
//
// [!] 跑的是 `build.ps1 -Sim` 的固件（按键阈值缩到 1ms / 5ms）。
//     板上口径是 10ms / 600ms —— 在 100MHz 仿真里跑 600ms 就是 6000 万周期，
//     整盘棋仿不完。**别拿板上的 mem.hex 喂这个测试台，会等到超时。**
//
// 时钟：clk 同时当 clk_sys 和 pix_clk（显存是真双口，仿真里同源无妨）。
// 换行一律用 CRLF 常量拼 —— Verilog 转义里没有 \r（见 项目约定文档 约定 3）。
// ============================================================================

`include "mem_model.vh"

module tb_gomoku;
    reg         clk = 1'b0;
    reg         resetn;
    wire [7:0]  led;
    wire        uart_tx;
    wire        done;
    wire [31:0] pc;

    // ---- 按键：**本测试台唯一驱动的东西**。低有效，走 cpu_top 的 8 位 key 口。
    //      bit k 对应 key[k]；按下 = 0。
    reg  [7:0]  key = 8'hFF;

    // 视频口（mem_bus 译码出来的显存口）
    wire        vid_we;
    wire [1:0]  vid_vsel;
    wire [13:0] vid_waddr;
    wire [3:0]  vid_be;
    wire [31:0] vid_wdata;
    wire [1:0]  vid_vsel_d;
    wire [13:0] vid_waddr_d;
    wire [31:0] vid_rdata;

    wire [23:0] rgb;
    wire        de, hs, vs;

    always #5 clk = ~clk;          // 100MHz 仿真时钟

    cpu_top u_soc (
        .clk        (clk),
        .resetn     (resetn),
        .pc         (pc),
        .uart_tx    (uart_tx),
        .uart_rx    (1'b1),
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
        .vid_rdata  (vid_rdata)
    );
    // 自证配置（与 tb_rtthread/tb_coremark/tb_riscv 同一格式，见 项目约定文档 约定 37）：
    //   t=0 打印本测试台【实际例化进去】的开关，日志首行自带口径。
    // [!] 本测试台【不给 cpu_top 传参】⇒ 这些值就是 rtl/top/cpu_top.v 的 parameter 默认值。
    //     2026-10-16 P3 起 LANEB_MEM 默认 1（= 1 档，lane B 放 load）⇒ 本台跑的就是当前生产档；
    //     想跑 0 档得改 cpu_top.v 的默认值（这也是"板上哪一档、仿真哪一档"对不上时的第一个检查点）。
    // [!] 2026-10-16 撤档：A1（`LANEB_ST`）判定【不采纳】并已退回，自证行不再有 LANEB_ST。
    initial $display("SIM CONFIG: DUAL_ISSUE=%0d EARLY_LD=%0d LANEB_MEM=%0d (来自 cpu_top.v 的默认值)",
                     u_soc.DUAL_ISSUE, u_soc.EARLY_LD, u_soc.LANEB_MEM);


    // video_top 那层壳（pll_video / rgb2tmds / OSERDES）是 PDS 专有原语，
    // iverilog 里不存在，所以直接例化 video_core（与 tb_video_bars.v 同理）。
    video_core u_vid (
        .pix_clk    (clk),
        .vid_resetn (resetn),
        .clk_sys    (clk),
        .sys_resetn (resetn),
        .vid_we     (vid_we),
        .vid_vsel   (vid_vsel),
        .vid_waddr  (vid_waddr),
        .vid_be     (vid_be),
        .vid_wdata  (vid_wdata),
        .vid_vsel_d (vid_vsel_d),
        .vid_waddr_d(vid_waddr_d),
        .vid_rdata  (vid_rdata),
        .rgb        (rgb),
        .de         (de),
        .hs         (hs),
        .vs         (vs)
    );

    // ========================================================================
    // 显存探针：直接读 video_core 里 nametable 的 BRAM 数组
    // ------------------------------------------------------------------------
    // nametable 是【字节寻址】的 8KB（rtl/video/vram_b32.v，AW=13 ⇒ 2048 字）。
    // 棋盘第 r 行第 c 列的字节地址 = (BOARD_ROW0+r)*256 + (BOARD_COL0+c)
    //                                  = (7+r)*256 + (12+c)
    // 换算成 32 位字 + 字节道。
    // ========================================================================
    // 绝对坐标版本（2026-10-18 加）：标题屏的 logo / 菜单框不在棋盘坐标里，
    // 要用 (行 0..29, 列 0..39) 直接寻址。
    function [7:0] nt_at;
        input integer row;
        input integer col;
        integer idx;
        begin
            idx = row * 256 + col;
            case (idx % 4)
                0: nt_at = u_vid.u_nt.mem[idx/4][ 7: 0];
                1: nt_at = u_vid.u_nt.mem[idx/4][15: 8];
                2: nt_at = u_vid.u_nt.mem[idx/4][23:16];
                default: nt_at = u_vid.u_nt.mem[idx/4][31:24];
            endcase
        end
    endfunction

    function [7:0] nt_byte;
        input integer r;
        input integer c;
        begin
            nt_byte = nt_at(7 + r, 12 + c);
        end
    endfunction

    // 图块编号：tile = shape*4 + state（与 scripts/gomoku/gen_tiles.py 一致）
    localparam [7:0] T_INNER_EMPTY  = 8'd0;    // shape 0 内部 + state 0 空
    localparam [7:0] T_INNER_BLACK  = 8'd1;    // shape 0 内部 + state 1 黑子
    localparam [7:0] T_TOPLEFT_EMPTY= 8'd20;   // shape 5 左上角 + state 0 空
    // 阶段 1 运行时合成图块（与 scripts/gomoku/render.h 同号）
    localparam [7:0] T_STAR         = 8'd149;  // 星位点（天元 + 四小目）
    localparam [7:0] T_LAST_BLACK   = 8'd131;  // 最后一手（shape 0 内部 + 黑子 + 红标）

    // ========================================================================
    // UART TX 解码（同 tb_demo.v / tb_video_bars.v）：字节依次左移进 rxtext，
    // 最近一个字节在 rxtext[7:0]。
    // ========================================================================
    localparam BIT_NS = 2340;                  // UART_DIV=234 拍 @100MHz 仿真时钟

    reg [8*768-1:0] rxtext  = 0;
    integer         rxcount = 0;
    reg  [7:0]      rxb;
    integer         bi;

    initial begin
        forever begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS / 2);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rxb[bi] = uart_tx;
                #(BIT_NS);
            end
            rxtext  = {rxtext[8*768-9:0], rxb};
            rxcount = rxcount + 1;
        end
    end

    // 在收到的文本里找子串。
    // [!] needle 固定【6 个字符】= 48 位。早先写成"最多 16 字符、按 128 位窗口比"，
    //     结果 15 字符的字面量会在高位补 0，而窗口的第 16 个字节是实际收到的
    //     前一个字符（空格/'='），永远比不中 —— banner 明明打出来了却判定"没收到"。
    //     **定长窗口 + 定长 needle，长度必须严格相等**，这是 Verilog 里做字符串
    //     比较最容易踩的坑（没有运行期长度可用）。
    function has_text;
        input [8*6-1:0] needle;                // 恰好 6 个字符
        integer i;
        reg found;
        begin
            found = 0;
            for (i = 0; i <= 760; i = i + 1)
                if (!found && rxtext[i*8 +: 48] == needle) found = 1;
            has_text = found;
        end
    endfunction

    // [!] FRAME_NS 必须声明在用到它的 task 之前 ——
    //     iverilog 14 严格要求"先声明后使用"（项目约定文档 约定 1）。
    localparam integer FRAME_NS = 3400000;   // 一帧 ≈ 640x525 像素 @100MHz

    // 等到某个文本出现为止（最多 max_frames 帧），比"死等固定时长"可靠得多。
    // [!] AI 是在固件主循环里【同步】跑的：落子那一拍 game_tick 要跑完一次
    //     alpha-beta 才返回。仿真里一次 4 层搜索约 2 秒（每节点约 2 万拍 ×
    //     上万节点），死等帧数是猜不准的。
    task wait_text;
        input [47:0] needle;
        input integer max_frames;
        integer w;
        begin
            for (w = 0; w < max_frames; w = w + 1) begin
                if (has_text(needle)) w = max_frames;   // 命中 -> 让循环退出
                else #(FRAME_NS);
            end
        end
    endtask

    // ========================================================================
    // 测试主流程
    // ========================================================================
    integer errors = 0;
    integer checks = 0;

    // ========================================================================
    // [2026-10-16 加] 进度可见性 —— 把"黑盒"变成"能看出卡在哪"
    // ------------------------------------------------------------------------
    // 为什么加：vvp 把 stdout **块缓冲**，重定向到文件时可能跑几小时一行都看不到。
    //   这个台子就先这么跑过一次黑盒：21:06 启动、125 min 墙钟、**日志 0 字节**、
    //   既没成功也没失败、也没有 VCD 可看 ⇒ 最后只能杀进程，什么都没学到。
    // 做法：每帧（negedge vs）flush 一次；每 60 帧（≈204 ms 仿真时间）打一行进度。
    //   **纯观测：不碰任何判据、不改任何激励**；checks/errors 就是下面自检在用的量。
    // 怎么读：进度行的 checks 不再增长 = 卡在那一步；哪一步看最后一个 [ok]/[FAIL]。
    //   （若卡在按完子之后的 AI 搜索，则会看到帧号一直涨、checks 停在 4。）
    // ========================================================================
    integer prog_f = 0;
    initial begin : g_progress
        forever begin
            @(negedge vs);
            prog_f = prog_f + 1;
            $fflush;
            if (prog_f % 60 == 0)
                $display("  [进度] t=%0d ns  帧=%0d  checks=%0d  errors=%0d",
                         $time, prog_f, checks, errors);
        end
    end

    // 一帧 ≈ 640×525 像素 @100MHz。等这么久足够固件跑完一轮主循环。

    task press_long;
        input integer k;                       // 按哪个键（0..3）
        integer n;
        begin
            key = 8'hFF & ~(8'h01 << k);       // 按下（低有效）
            // [!] 时长要按【固件端的采样节奏】倒推，不能只按"长按阈值"算。
            //     固件主循环是帧同步的，每帧只采样一次按键；而 input.c 的去抖要求
            //     "原始电平连续两帧都变了"才认账 ⇒ 一个边沿就要 2 帧，
            //     再加长按阈值本身 1 帧，共约 3 帧 ≈ 10ms。
            //     早先按 8ms 给（≈2.4 帧），卡在边界上：第一次侥幸过、第二次没过。
            //     现在给 20ms（≈6 帧），留一倍余量。
            //     另外【松手】也走同一套去抖（同样要 2 帧才认账）。
            //     早先在松手后只等 2 帧，正好卡边界：stable 一直停在"按下"，
            //     于是下一次按下形不成新的【按下沿】，long_sent 永远不重置，
            //     长按再也不会触发 —— 现象是"第一下有效、之后全无反应"。
            #20_000_000;
            key = 8'hFF;                        // 松手
            #(FRAME_NS * 5);                    // 松手要等够，才能形成下一次按下沿
            n = 0;
        end
    endtask

    // 短按：产生一次「短按」事件（阶段 1 菜单的 ↑/↓ 移动、←/→ 改值都用它）。
    // ------------------------------------------------------------------------
    // [重点] 按住时长是【从 input.c 的去抖逻辑倒推出来的】，不是按"几帧"拍脑袋。
    //   `-Sim` 口径（`scripts/gomoku/input.h:51`）：去抖 **1 ms**、长按阈值 **5 ms**；
    //   一帧 ≈ 3.4 ms（640×525 @100MHz）。
    //   而 `input.c:43-58` 的去抖是【电平稳定】判据，关键在 t_edge 的更新时机：
    //       if (lvl != raw[k]) { raw= lvl; t_edge = now; }            // 电平变了：记时刻
    //       if (lvl != stable && (now - t_edge) >= debounce) { …认账… }
    //   ⇒ **电平刚变的那一拍 `now - t_edge == 0`，永远判不过**；必须等【下一采样拍】
    //     电平仍是新值（`now - t_edge` = 1 帧）才认账。由此：
    //       · 按住 **1 帧** → 下一拍已经松手 ⇒ **永远认不了账**，等于没按 ✗
    //         （2026-10-17 实测验证过：改成 1 帧后台子对按键毫无反应）
    //       · 按住 **2 帧** → 认账恰好一次；且 `down_at` 从【认账那拍】起算，
    //         到松手认账只隔 1 帧 = 3.4 ms < 长按 5 ms ⇒ **正是短按** ✓
    //       · 按住 **3 帧** → 认账后到松手隔 2 帧 = 6.8 ms ≥ 5 ms ⇒ **变长按** ✗
    //   ⇒ **必须恰好 2 帧**。相位由对齐 vsync 固定：固件在 `video_wait_vblank()`
    //     返回那拍采样（VIDEO_STATUS bit0 = vsync 脉冲），那就是 `negedge vs`，
    //     所以"negedge vs 之后 1µs 按下"保证按下沿落在采样拍【之后】。
    //   [!] 注意长按的计时基准是【认账时刻 down_at】而不是物理按下时刻 —— 这一条
    //     最容易算错：按 2 帧物理上"按住 6.8ms > 5ms"，但固件量到的是 3.4ms。
    // vs 是负极性，negedge vs = vsync 起点 = 主循环刚采样完那一拍。
    task press_short;
        input integer k;
        begin
            @(negedge vs);                 // 对齐到 vsync 起点（主循环刚采样完那一拍）
            #1000;                         // 越过本帧采样，之后按下
            key = 8'hFF & ~(8'h01 << k);   // 按下（低有效）
            @(negedge vs);                 // 帧 1：主循环看到按下沿（t_edge 置此拍 ⇒ elapsed=0，不认账）
            @(negedge vs);                 // 帧 2：电平仍是按下 ⇒ elapsed=1帧 ≥ 去抖 ⇒ 认账（down_at=此拍）
            #100_000;                      // 越过帧 2 的采样之后再松手
            key = 8'hFF;                   // 松手
            @(negedge vs);                 // 帧 3：看到松手沿
            @(negedge vs);                 // 帧 4：松手认账 -> 发出短按事件（间隔只 1 帧 ⇒ 不是长按）
            @(negedge vs);                 // 帧 5：余量，确保 game_tick 消费完
        end
    endtask

    integer i;
    integer tr, tc;          // 棋盘扫描坐标（最后一手标记计数用）
    integer last_white_cnt;  // 棋盘上「最后一手白子」的个数

    // [2026-10-17 加] 把收到的串口文本按【收到顺序】打出来。
    //   为什么需要：固件在状态变化时会打 `menu=` / `mode=` / `you=` / `black=` /
    //   `start, level=…` 等 —— **这是唯一能看见"固件以为自己在哪一步"的窗口**。
    //   只报 "没等到 start" 是黑盒结论；看到固件自己打的行才能判断到底是
    //   "按键没被认成短按/长按" 还是 "菜单项顺序与 tb 假设不符"。
    //   （用 task 局部 reg，别复用 UART 解码器的 rxb —— 那个正在逐位收字节。）
    task dump_uart;
        integer n, j;
        reg [7:0] db;
        begin
            n = (rxcount > 768) ? 768 : rxcount;
            $display("  --- 已收到 %0d 字节；下面打印最后 %0d 字节（收到顺序）---", rxcount, n);
            for (j = n - 1; j >= 0; j = j - 1) begin
                db = rxtext[j*8 +: 8];
                if      (db == 8'h0D)                $write("<CR>");
                else if (db == 8'h0A)                $write("%c", 8'h0A);
                else if (db >= 8'h20 && db < 8'h7F)  $write("%c", db);
                else                                 $write("<%02h>", db);
            end
            $write("\n");
        end
    endtask

    // ========================================================================
    // [2026-10-17 加] **直接读固件内部的按键去抖状态机**（`g_input`，在 .bss）
    // ------------------------------------------------------------------------
    // 为什么：只报"没等到 start"是黑盒结论，它区分不出下面三种情况：
    //     ① 按键压根没被认成短按/长按（激励时序问题）
    //     ② 按键认了，但菜单项顺序与 tb 的假设不符（tb 问题）
    //     ③ 别的地方卡住
    //   `input_t` 就在 RAM 里，按地址读出来就能直接看见固件"以为"发生了什么。
    // 地址来源：`riscv-none-elf-nm sim/programs/gomoku_sim/gomoku_sim.elf`
    //     ⇒ `g_input` @ **0x8FD8**，大小 **0x38**（2026-10-18 标题屏改版后重量）。
    //   [!] 这个地址会随 .data/.text 大小漂移 —— 改完固件必须重新 nm 一次。
    //   存储器是【字寻址】（`mem0[0:32767]`，128KB）⇒ 字下标 = 0x8FD8/4 = **9206**。
    // 字段偏移（见 `scripts/gomoku/input.h` 的 input_t）：
    //     raw[4]@0  t_edge[4]@4  stable[4]@20  down_at[4]@24  long_sent[4]@40
    //     short_latch@44  long_latch@45  debounce_ticks@48  long_ticks@52
    // [!] `debounce_ticks` / `long_ticks` 是【固件真正编译进去的阈值】—— 它直接验证
    //     -Sim 口径与 CPU_HZ：若 CPU_HZ 写死 85,005,100 而仿真跑 100MHz，这里会显示
    //     85005 / 425025（而不是 100000 / 500000）。**这决定 2 帧按住到底算不算长按。**
    // 层次路径：unified_mem 例化在 mem_bus 里（`u_mem`），mem_bus 在 cpu_top 里（`u_bus`）。
    // ========================================================================
    localparam integer GI = 9206;                              // 0x8FD8 / 4
    wire [31:0] gi_raw_w  = u_soc.u_bus.u_mem.mem0[GI + 0];    // raw[0..3]      @0x6D7C
    wire [31:0] gi_stb_w  = u_soc.u_bus.u_mem.mem0[GI + 5];    // stable[0..3]   @0x6D90
    wire [31:0] gi_lsn_w  = u_soc.u_bus.u_mem.mem0[GI + 10];   // long_sent[0..3]@0x6DA4
    wire [31:0] gi_lat_w  = u_soc.u_bus.u_mem.mem0[GI + 11];   // short@0x6DA8 / long@0x6DA9
    wire [31:0] gi_dbg_t  = u_soc.u_bus.u_mem.mem0[GI + 12];   // debounce_ticks @0x6DAC
    wire [31:0] gi_lng_t  = u_soc.u_bus.u_mem.mem0[GI + 13];   // long_ticks     @0x6DB0

    // [!] 这几个数组是 `uint8_t x[4]` —— **每个键占一个字节**，不是一位。
    //   所以要取每字节的 bit0 拼成「按 bit k = 键 k」的 4 位量。
    //   第一版写成 `word[3:0]`（= 只是【键 0】那一个字节的低 4 位），
    //   于是永远只看见左键、看不见 tb 按的 **键 3（↓）**，白跑一轮 —— 已修。
    wire [3:0] gi_raw    = {gi_raw_w[24], gi_raw_w[16], gi_raw_w[8], gi_raw_w[0]};
    wire [3:0] gi_stable = {gi_stb_w[24], gi_stb_w[16], gi_stb_w[8], gi_stb_w[0]};
    wire [3:0] gi_lsent  = {gi_lsn_w[24], gi_lsn_w[16], gi_lsn_w[8], gi_lsn_w[0]};
    wire       gi_short  = gi_lat_w[0];                        // short_latch bit0（键 0）
    wire       gi_llat   = gi_lat_w[8];                        // long_latch  bit0（键 0）
    wire [7:0] gi_short8 = gi_lat_w[7:0];                      // 全部 4 键的短按锁存
    wire [7:0] gi_llat8  = gi_lat_w[15:8];                     // 全部 4 键的长按锁存

    // 一帧 = FRAME_NS ns；100MHz 下 1 tick = 10ns ⇒ 一帧 = FRAME_NS/10 个 tick。
    `define TICKS_PER_FRAME (FRAME_NS / 10.0)

    reg [31:0] gi_prev;
    initial begin : g_input_probe
        gi_prev = 32'hFFFF_FFFF;
        forever begin
            @(negedge vs);
            // 只在【状态真的变了】时打 —— 这样阈值也一定是固件 init 之后的真值。
            if ({gi_raw, gi_stable, gi_lsent, gi_short8, gi_llat8} !== gi_prev) begin
                gi_prev = {gi_raw, gi_stable, gi_lsent, gi_short8, gi_llat8};
                $display("  [输入] t=%0d ns  帧=%0d  raw=%b stable=%b long_sent=%b  short=%b long=%b | 阈值 debounce=%0d ticks（%0.2f 帧） long=%0d ticks（%0.2f 帧）",
                         $time, prog_f, gi_raw, gi_stable, gi_lsent, gi_short8, gi_llat8,
                         gi_dbg_t, gi_dbg_t / `TICKS_PER_FRAME,
                         gi_lng_t, gi_lng_t / `TICKS_PER_FRAME);
            end
        end
    end

    // 每帧无条件快照（只在按键窗口里打，避免刷屏）。
    //   用途：确认固件到底有没有"看见"按键 —— 若 raw 全程 0000，说明信号没到；
    //   若 raw 动了而 stable 不动，说明卡在去抖。
    integer gi_tick;
    initial begin : g_input_snap
        gi_tick = 0;
        forever begin
            @(negedge vs);
            gi_tick = gi_tick + 1;
            if (gi_tick >= 5 && gi_tick <= 45)
                $display("  [快照] 帧=%0d  raw=%b stable=%b  short=%b long=%b",
                         gi_tick, gi_raw, gi_stable, gi_short8, gi_llat8);
        end
    end

    initial begin
        resetn = 1'b0;
        key    = 8'hFF;
        #2000;
        resetn = 1'b1;

        $display("=== tb_gomoku：五子棋固件端到端 ===");
        $display("  跑的是 build.ps1 -Sim 的固件（按键阈值 1ms/5ms）");

        // ---- [1] 等 banner ----
        #(FRAME_NS * 4);
        checks = checks + 1;
        if (!has_text("GOMOKU")) begin
            errors = errors + 1;
            $display("  [FAIL] 没等到固件 banner —— 固件没跑起来，或卡在初始化里");
        end else begin
            $display("  [ok]   banner 收到：固件已启动");
        end

        // ---- [2] 标题屏（2026-10-18 改版）----
        // [!] 改版前标题屏是"空棋盘 + 左上角菜单"，这里查的是棋盘图块；
        //     改版后标题屏是**整屏 logo + 菜单**（不再画 15x15 棋盘），
        //     所以棋盘那两条断言挪到「开局之后」再查（见下面 [3b]）。
        #(FRAME_NS * 2);
        checks = checks + 1;
        if (nt_at(1, 14) < 8'd154 || nt_at(1, 14) > 8'd177) begin
            errors = errors + 1;
            $display("  [FAIL] 标题屏 logo 位置 (行1,列14) = %0d，期望 154..177（4x 大 logo）",
                     nt_at(1, 14));
        end else begin
            $display("  [ok]   标题屏 logo 已铺上（tile=%0d）", nt_at(1, 14));
        end

        checks = checks + 1;
        if (nt_at(5, 4) !== 8'd178) begin
            errors = errors + 1;
            $display("  [FAIL] 菜单选中框左上角 (行5,列4) = %0d，期望 178（BOX_TL）",
                     nt_at(5, 4));
        end else begin
            $display("  [ok]   标题屏选中框已画（tile=%0d）", nt_at(5, 4));
        end

        // ---- [3] 标准菜单导航（阶段 1）----
        //      默认主菜单选中 HUMAN。长按进 HUMAN 子菜单（选中 DIFF），
        //      短按 ↓ 两次到 START，再长按开局。
        press_long(3);                         // 长按：MAIN -> HUMAN 子菜单
        press_short(3);                        // 短按 ↓：DIFF -> COLOR
        press_short(3);                        // 短按 ↓：COLOR -> START
        press_long(3);                         // 长按：START -> 开始对局
        checks = checks + 1;
        if (!has_text("start,")) begin
            errors = errors + 1;
            $display("  [FAIL] 菜单确认到底后没等到 start —— 开局没生效");
            // [2026-10-17 加] **快速失败**：菜单开不了局 ⇒ 后面三项（天元落子 / 最后一手红标 /
            //   AI 应手）全部无意义，而 `wait_text("AI mov", 400)` 会**死等满 400 帧**（1.36 s
            //   仿真时间 ≈ 3.3 小时墙钟）才收工。没有这条时，一次"按不准键"的回退要烧掉一整夜
            //   才能读到一行 FAIL。这里直接收尾，把回归反馈从 3.4 h 压到 ~30 min。
            $display("  --- 提前收尾（菜单是后续用例的前置条件）---");
            dump_uart;                      // 让固件自己说它走到哪一步了
            $display("");
            $display("checks=%0d  errors=%0d", checks, errors);
            $display("=== FAIL ===");
            $finish;
        end else begin
            $display("  [ok]   菜单开局成功");
        end

        // ---- [3b] 开局后 15x15 棋盘才铺出来（标题屏不再画棋盘）----
        //   这两条原来是「上电就查」，改版后标题屏整屏是 logo + 菜单，
        //   棋盘要到进对局那一拍才画 ⇒ 断言挪到这里，覆盖不变。
        #(FRAME_NS * 2);
        checks = checks + 1;
        if (nt_byte(0, 0) !== T_TOPLEFT_EMPTY) begin
            errors = errors + 1;
            $display("  [FAIL] nametable(0,0) = %0d，期望 %0d（左上角空格）",
                     nt_byte(0, 0), T_TOPLEFT_EMPTY);
        end else begin
            $display("  [ok]   开局后棋盘左上角已铺好（tile=%0d）", nt_byte(0, 0));
        end

        checks = checks + 1;
        if (nt_byte(7, 7) !== T_STAR) begin
            errors = errors + 1;
            $display("  [FAIL] 天元 nametable = %0d，期望 %0d（星位点）",
                     nt_byte(7, 7), T_STAR);
        end else begin
            $display("  [ok]   天元是星位点（tile=%0d）", nt_byte(7, 7));
        end

        // ---- [4] 在天元落子，AI 应手（同步：同一帧内先落人子、再落 AI 子）----
        press_long(2);                         // 光标本来就在天元，直接长按落子

        // [!] AI 是在固件主循环里【同步】跑的 —— 落子那一拍 game_tick 里要
        //     跑完一次 alpha-beta 搜索才返回。测试台必须等它，否则断言会跑在
        //     固件还在搜索的时候（现象：落子日志打出来了，但画面和串口都还没更新）。
        //     实测 4 层搜索在仿真里要约 2 秒，所以这里等【条件】不等时长。
        wait_text("AI mov", 400);

        // 天元 = 普通黑子。注意不是"最后一手标记"：AI 应手后，最后一手已经
        // 挪到 AI 那手白子上（同步泵在同一帧里先落人子、再落 AI 子）。
        checks = checks + 1;
        if (nt_byte(7, 7) !== T_INNER_BLACK) begin
            errors = errors + 1;
            $display("  [FAIL] 天元 nametable = %0d，期望 %0d（普通黑子）—— 落子没落到天元",
                     nt_byte(7, 7), T_INNER_BLACK);
        end else begin
            $display("  [ok]   天元已落普通黑子（tile=%0d）", nt_byte(7, 7));
        end

        // 最后一手标记应落在 AI 的白子上：扫全盘，应恰有 1 颗「最后一手」图块，
        // 且是白子。最后一手 tile 号 = 131 + shape*2 + (黑?0:白?1)，shape 0..8，
        // 所以黑子落在奇数号 131..147、白子落在偶数号 132..148。
        last_white_cnt = 0;
        for (tr = 0; tr < 15; tr = tr + 1)
            for (tc = 0; tc < 15; tc = tc + 1) begin
                if (nt_byte(tr, tc) >= 8'd131 && nt_byte(tr, tc) <= 8'd148)
                    if ((nt_byte(tr, tc) % 2) == 8'd0)   // 偶数号 = 最后一手白子
                        last_white_cnt = last_white_cnt + 1;
            end
        checks = checks + 1;
        if (last_white_cnt !== 1) begin
            errors = errors + 1;
            $display("  [FAIL] 最后一手白子标记数 = %0d，期望 1（AI 应手应带红标）", last_white_cnt);
        end else begin
            $display("  [ok]   最后一手标记已落到 AI 白子上（共 1 处）");
        end

        checks = checks + 1;
        if (!has_text("AI mov")) begin
            errors = errors + 1;
            $display("  [FAIL] 没等到 AI moved —— AI 没应手，或它那一步非法");
        end else begin
            $display("  [ok]   AI 已应手");
        end

        // 把收到的串口文本打出来 —— 出问题时，这是唯一能看见固件"说了什么"的窗口
        $display("  --- 收到 %0d 字节的串口文本 ---", rxcount);
        for (i = 0; i < 220; i = i + 1) begin
            rxb = rxtext[(219-i)*8 +: 8];
            if (rxb == 8'h0D)      $write("<CR>");
            else if (rxb == 8'h0A) $write("%c", 8'h0A);
            else if (rxb >= 8'h20 && rxb < 8'h7F) $write("%c", rxb);
            else if (rxb != 8'h00) $write("<%02h>", rxb);
        end
        $write("%c", 8'h0A);

        $display("");
        $display("checks=%0d  errors=%0d", checks, errors);
        if (errors == 0) $display("=== PASS ===");
        else             $display("=== FAIL ===");
        $finish;
    end

    // 超时保护（正常跑完约 100M 周期上下，这里给足 10 倍余量）
    initial begin
        #6_000_000_000;
        $display("\n=== TIMEOUT (pc=0x%h) ===", pc);
        $display("  最后收到的串口文本尾部：");
        for (i = 0; i < 8; i = i + 1)
            $write("%c", rxtext[(7-i)*8 +: 8]);
        $write("\n");
        $display("checks=%0d  errors=%0d", checks, errors);
        $display("=== FAIL (timeout) ===");
        $finish;
    end
endmodule
