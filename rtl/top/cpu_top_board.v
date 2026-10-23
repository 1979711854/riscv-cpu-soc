`timescale 1ns/1ps
// ============================================================================
// cpu_top_board —— 上板专用顶层（PDS 综合/布线的 top module）
// ----------------------------------------------------------------------------
// 与 cpu_top 的区别：
//   ① 不引出 pc[31:0] 和 done 这两个板级调试口，并把 cpu_top 的 key[7:4]
//      固定接 1（未按下）；
//   ② 用 PLL 把板上 27MHz 晶振倍频到 85.0051MHz 作为系统时钟；
//   ③ 用 DEBUG_LED 参数决定 led[2:0] 是调试信号还是 GPIO；
//   ④ 例化 video_top 输出 HDMI 480p（另一个独立 PLL，见 video_top.v），
//      并把 cpu_top 的视频口（显存读写 + scroll 寄存器）接到它上面。
//
// 为什么要单独一层（踩过的坑）：
//   PDS 会把未在 .fdc 里指定 LOC 的输出端口自动布到 BANKR5 的任意引脚上 ——
//   实测 pc[0]→M2、pc[10]→M5、led[0]→P6 … 而本板 BANKR5 接了 SFP/HSST 等
//   高速接口，32 位输出乱布上去有驱动冲突风险。所以上板这一层不引出它们。
//
// 为什么不在 cpu_top 里直接删端口：
//   pc 是仿真侧的分析数据源 —— tb_coremark 的 +TRACE/+PROF 逐拍 dump 和
//   各测试台的 TIMEOUT 诊断（`$display("TIMEOUT (pc=0x%h)", pc)`）都依赖它，
//   删掉会废掉 doc/ila_analysis.md 里那套分析方法。故仿真仍用 cpu_top 原样。
//
// 板上只有 5 个按键，其中手册 KEY0（丝印 KEY1）已用作 resetn，
// 剩手册 KEY1..KEY4（丝印 KEY2..KEY5）→ key[3:0]。
// 引脚表见 pds/RV32I_1/RV32I_1.fdc 头部注释（手册 3.4.1 节）。
// 已实测：从左到右依次按 key[0..3]，串口输出 0x01/0x02/0x04/0x08。
//
// ----------------------------------------------------------------------------
// [!] 时钟：上板 85.01MHz，仿真仍是 27MHz —— 两套口径不要混
// ----------------------------------------------------------------------------
//   * 仿真：测试台例化的是 cpu_top（不是本文件），不传 UART_DIV → 234（27MHz），
//     周期数与风险分析口径全部按 27MHz。本文件不参与仿真。
//   * 上板：PLL 27MHz→76.5052MHz，UART_DIV 传 664，CoreMark 的 EE_TICKS_PER_SEC=76505200。
//     （128KB 版在 85 MHz 收敛不了，STATIC_RATIO0 13.5→15.0。）
//   * 因此 板上的 CoreMark 时长 = Total ticks ÷ 76,505,200
//     （不再是 ÷85,005,100，也不是 ÷27e6）。文档里所有旧除数仅适用于对应时期。
//   * PLL 输出时钟约束由 PDS 从 IP 自动推导（`.fdc` 里只有 27MHz 的
//     `create_clock ... -period 37.037` 输入约束，综合报告会显示 76.5052 MHz）。
//   * 频率来历：VCO = 27 ÷ RATIOI(1) × RATIOM(2) × RATIOF(21.25) = 1147.5 MHz，
//     CLKOUT0 = VCO ÷ STATIC_RATIO0(15.0) = 76.5 MHz。
//     改频率只需改 ipcore/pll/pll.idf 的 STATIC_RATIO0 再跑
//     `ip_generate.exe -i pll.idf`（可命令行完成，不必开 GUI）。
//     [!] 改完必须同步 4 处常量：本文件的 UART_DIV、
//     coremark_port/core_portme.c 的 EE_TICKS_PER_SEC、demo/addr_map.h 的 CPU_HZ、
//     rtthread/bsp/board.h 的 BOARD_SYSTEM_CLOCK_HZ，并重算 ITER。
//   * [!] 为什么是 85：PDS 的 P&R 是"满足约束即收敛"，Estimated Frequency
//     从来不是设计上限，而是"这次被要求跑多快"。 同一份 RTL、只改 PLL 分频比：
//         请求 62.03 → 达 66.87 (slack +1.167)   ← 原设计，被自己卡住
//         请求 71.72 → 达 73.26 (slack +0.293)
//         请求 85.01 → 达 91.87 (slack +0.879)   ← 本次采用
//         请求 99.79 → 失败 (WNS −1.188、282 个失败端点)
//     故真实上限 ≈90 MHz；取 85 是留 ~7% 余量，与原设计 62.03/66.87 的 7.8% 同一风险档。
// ============================================================================
module cpu_top_board #(
    // LED 映射开关（PDS 综合时取默认值，切换需重新综合 —— 或加 `-D` 宏）：
    //   1 = led[1:0] 显示 pll_locked / done，led[7:2] 给 GPIO（上板调试用）
    //   0 = led[7:0] 全给 GPIO，回到"按开关位置重排"的演示映射（现场演示用）
    parameter DEBUG_LED = 1
) (
    input  wire        clk,         // D18：板载 27MHz
    input  wire        resetn,      // C22：KEY0，低有效

    // ---- UART：经 CP2102 接 USB Type-C ----
    output wire        uart_tx,     // C24：FPGA_UART_TXD
    input  wire        uart_rx,     // B24：FPGA_UART_RXD

    // ---- GPIO ----
    output wire [7:0]  led,         // LED0..LED7，输出高电平点亮
    input  wire [3:0]  key,         // KEY1..KEY4，按下 = 0

    // ---- HDMI 输出（4 对 TMDS 差分，直连 HDMI 座；管脚见 .fdc）----
    output wire        tmds_clk_p,  // N21
    output wire        tmds_clk_n,  // N22
    output wire [2:0]  tmds_data_p, // R25 / P23 / N23
    output wire [2:0]  tmds_data_n  // P25 / P24 / N24
);

    // ---- PLL：27MHz 晶振 → 85.0051MHz 系统时钟 ----
    // 例化的是 Pango IP Compiler 生成的 pll（pds/RV32I_1/ipcore/pll/pll.v，
    // 配置见同目录 pll.idf：CLKIN_FREQ=27.0、STATIC_RATIO0=13.5
    // —— 注意 STATIC_RATIO* 才是生成器认的字段，CLKOUT0_REQ_FREQ 改了无效）。
    // [!] 这个 IP 必须在 PDS 工程里以 IP 源文件形式引用（见 RV32I_1.pds 的
    //    wgt_my_ips_src），单纯把 pll.v 当普通源文件加进去综合会报黑盒。
    wire clk_sys;        // PLL 输出系统时钟（85.0051MHz）
    wire pll_locked;     // PLL 锁定指示

    pll u_pll (
        .clkin1 (clk),        // 27MHz 晶振输入
        .clkout0(clk_sys),    // 85.0051MHz 输出
        .lock   (pll_locked)
    );

    // PLL 锁定前保持复位：上电后 PLL 需几百 us 才锁定，期间 clkout0 不稳定，
    // 用 lock 门控 resetn 能保证 CPU 在稳定时钟下启动。
    wire sys_resetn = resetn & pll_locked;

    wire [7:0] led_gpio;    // CPU 的 GPIO LED 输出
    wire       done;        // CoreMark 完成标志（写 0xFFF8）

    // ---- 视频口：cpu_top 只做译码，显存本体在 video_top ----
    wire        vid_we;
    wire [1:0]  vid_vsel;
    wire [13:0] vid_waddr;
    wire [3:0]  vid_be;
    wire [31:0] vid_wdata;
    wire [1:0]  vid_vsel_d;
    wire [13:0] vid_waddr_d;
    wire [31:0] vid_rdata;

    cpu_top #(.UART_DIV(10'd664)) u_soc (   // 76.5052MHz → 115200 波特（76,505,200/115200 = 664.1）
        .clk      (clk_sys),
        .resetn   (sys_resetn),

        .uart_tx  (uart_tx),
        .uart_rx  (uart_rx),

        .led      (led_gpio),
        .key      ({4'b1111, key}),   // 高位恒定"未按下"

        // 板级调试口：上板不引出（见文件头注释）
        .pc       (),
        .done     (done),

        // 视频显存/寄存器，连到下面 video_top 的同一个口
        .vid_we      (vid_we),
        .vid_vsel    (vid_vsel),
        .vid_waddr   (vid_waddr),
        .vid_be      (vid_be),
        .vid_wdata   (vid_wdata),
        .vid_vsel_d  (vid_vsel_d),
        .vid_waddr_d (vid_waddr_d),
        .vid_rdata   (vid_rdata)
    );

    // ------------------------------------------------------------------
    // HDMI 输出：480p60 + tile PPU 背景层
    // 视频链用板上原始 27MHz 和原始 resetn，自带独立 video PLL，不碰 CPU 时钟域。
    // 唯一的跨域接口就是下面这一组 vid_*：显存是真双口 BRAM，A 口吃
    // clk_sys、B 口吃 pix_clk，所以跨域不需要握手/FIFO（见 vram_b32.v 文件头）。
    // 两个 PLL 同源（都是 1147.5MHz VCO）保证 clk_sys 与 pix_clk 锁相。
    //
    // [!] clk_sys 必须走CPU 那个 PLL 的输出而不是板上 27MHz：显存 A 口
    //   与 mem_bus 的 1 拍读契约是同一个时钟域里的约定，用 27MHz 会错拍。
    // ------------------------------------------------------------------
    wire video_locked;

    video_top u_video (
        .clk27      (clk),        // 27MHz 晶振（视频 PLL 的输入）
        .resetn     (resetn),     // 视频域复位用原始 resetn（PLL 锁定前内部自持复位）
        .clk_sys    (clk_sys),    // 显存 A 口 / 寄存器
        .sys_resetn (sys_resetn), // 与 u_soc 同一个复位，保证两边同时放开

        .vid_we      (vid_we),
        .vid_vsel    (vid_vsel),
        .vid_waddr   (vid_waddr),
        .vid_be      (vid_be),
        .vid_wdata   (vid_wdata),
        .vid_vsel_d  (vid_vsel_d),
        .vid_waddr_d (vid_waddr_d),
        .vid_rdata   (vid_rdata),

        .tmds_clk_p (tmds_clk_p),
        .tmds_clk_n (tmds_clk_n),
        .tmds_data_p(tmds_data_p),
        .tmds_data_n(tmds_data_n),
        .locked     (video_locked)
    );

    // ---- LED 映射 ----
    // DEBUG_LED=1（默认）：
    //   led[0] = pll_locked   ：亮 = CPU PLL 已锁定；不亮 = CPU 被一直复位
    //   led[1] = video_locked ：亮 = 视频 PLL 已锁定；HDMI 黑屏先看这一颗
    //   led[2] = done         ：亮 = CoreMark 已跑完（写 0xFFF8）
    //   led[7:3] = GPIO 原样
    // DEBUG_LED=0：
    //   led[7:0] = GPIO 原样 —— 演示程序 LED=KEY 的按键↔灯对应关系恢复，
    //   但上板现场看不到 PLL/done 这几个最关键的诊断信息，只在演示录像时切。
    generate
        if (DEBUG_LED) begin : g_debug_led
            assign led[0]   = pll_locked;
            assign led[1]   = video_locked;
            assign led[2]   = done;
            assign led[7:3] = led_gpio[7:3];
        end else begin : g_gpio_led
            assign led = led_gpio;
        end
    endgenerate

endmodule
