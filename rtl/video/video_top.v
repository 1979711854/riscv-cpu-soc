`timescale 1ns/1ps
// ============================================================================
// video_top —— HDMI 输出链壳层：PLL + video_core + TMDS
// ----------------------------------------------------------------------------
//   27MHz ──> pll_video ──┬─ pixel  25.5MHz ──> video_core ──> rgb2tmds ──> 4对TMDS
//                         └─ serial 127.5MHz ─────────────────────┘
//
// 本文件只做三件事：给 PLL、例化 video_core、把 RGB 送进 TMDS。
// 所有逻辑都在 video_core.v 里，这么做是为了能仿真：pll_video /
// GTP_OSERDES_E2 / GTP_OUTBUFDS 是 PDS 专有原语，iverilog 里不存在，留在这一层
// 就意味着整条显存+PPU 通路没法功能仿真。现在 sim/tb_video_core.v 直接例化
// video_core，逐像素比对。
//
// ----------------------------------------------------------------------------
// 时钟：为什么单独一个 PLL，且与 CPU 同源
// ----------------------------------------------------------------------------
//   TMDS 要求 serialclk = 5 × pixelclk 且相位对齐。本设计用一个视频 PLL、
//   两个输出来自同一个 VCO，天然满足 5:1：
//
//       27MHz ──(÷2 ×85 = 1147.5MHz VCO)──┬── ÷45 ──>  25.5MHz  pixelclk
//                                         └── ÷9  ──> 127.5MHz  serialclk (=5×)
//
//   VCO 与 CPU 那个 PLL 完全相同（ipcore/pll 也是 1147.5MHz），所以 clk_sys
//   与 pix_clk 同源锁相 —— 显存用真双口 BRAM 跨这两个域就不需要任何握手
//   （见 vram_b32.v）。
//
//   为什么不用标准 25.175MHz：25.175 与 27MHz 晶振不可通约（比 1007:1080），
//   一个 PLL 无法同时整除，故用 25.5MHz；由此带来的刷新率偏差在 video_core.v
//   里调行总周期压回标准档。
//
// ----------------------------------------------------------------------------
// 软件必须先做什么才有图（显存上电是随机内容）
// ----------------------------------------------------------------------------
//   1. 填调色板：VIDEO_PAL + i*4 = 24bit RGB（i = 0..255）
//   2. 填图块  ：VIDEO_PAT + tile*256 + py*16 + px = 颜色索引
//   3. 填图块表：VIDEO_NT  + row*256 + col = tile 号
//   再写 scroll_x/scroll_y。显存是字节使能 32 位口，1/2/3 都能用 sb 逐字节
//   写，不需要读-改-写。地址见 rtl/bus/addr_map.vh 的视频区小节。
//
// ----------------------------------------------------------------------------
// [!] 上板若黑屏，按此顺序排查
// ----------------------------------------------------------------------------
//   1. led[1]（video_locked）不亮 → 视频 PLL 没锁，先查 clock/PLL 配置。
//   2. 量 tmds_clk_p（N21）应为 25.5MHz。频率不对 → PLL 比值错。
//   3. 频率对但显示器"无信号" → 大概率同步极性；试去掉 ppu.v 里 sy0 的两个取反。
//   4. 能显示但有"雪花/彩色噪声" → 同步全对、显存还没被软件填过。这是正常的
//      中间状态，说明链路已经通了：把上面三步做完就该出图案。
//   5. 花屏/抖动 → 并串相位。DDR10TO1 要求 serialclk 与 pixelclk 特定相位，
//      改 pll_video 的 STATIC_PHASE1 微调。
// ============================================================================
module video_top (
    input  wire        clk27,       // D18：板载 27MHz 晶振（与 CPU PLL 同一个输入）
    input  wire        resetn,      // C22：KEY0，低有效（视频域用）

    input  wire        clk_sys,     // CPU 时钟 85.0051MHz：只给显存 A 口与滚动寄存器
    input  wire        sys_resetn,  // CPU 域复位（板上 = resetn & pll_locked）

    // ---- 显存 / 寄存器 CPU 口（来自 mem_bus 的译码，见 rtl/bus/mem_bus.v）----
    input  wire        vid_we,
    input  wire [1:0]  vid_vsel,
    input  wire [13:0] vid_waddr,
    input  wire [3:0]  vid_be,
    input  wire [31:0] vid_wdata,
    input  wire [1:0]  vid_vsel_d,
    input  wire [13:0] vid_waddr_d,
    output wire [31:0] vid_rdata,

    // ---- TMDS 差分输出：4 对，直连 HDMI 座 ----
    output wire        tmds_clk_p,  // N21
    output wire        tmds_clk_n,  // N22
    output wire [2:0]  tmds_data_p, // R25 / P23 / N23
    output wire [2:0]  tmds_data_n, // P25 / P24 / N24

    output wire        locked       // 视频 PLL 锁定（板上 led[1]）
);

    // ------------------------------------------------------------------
    // 视频 PLL：pixel 25.5MHz / serial 127.5MHz（IP 见 ipcore/pll_video/）
    // ------------------------------------------------------------------
    wire pix_clk, ser_clk;

    pll_video u_pll_video (
        .clkin1 (clk27),      // 27MHz
        .clkout0(pix_clk),    // 25.5MHz = VCO/45
        .clkout1(ser_clk),    // 127.5MHz = VCO/9 = 5 × pixel
        .lock   (locked)
    );

    // PLL 锁定前保持复位：锁定期输出不稳定，此时送 TMDS 会出乱码。
    // 这一位门控了 video_core 的整个 pix 域（包括 sync_vg / ppu / 同步链）。
    //
    // [!] vid_resetn 只由 PLL locked 门控，不与板上按钮复位相与：
    //     按钮复位会把视频域一起复位，vblank 永不出现，CPU 卡死在
    //     video_wait_vblank()（黑屏 + 串口静默）；完整复盘见 doc/reports/。
    //     代价：视频核心的寄存器（scroll 等）不被按钮复位，但 CPU 重启后
    //     main() 会重新写 scroll=0，无影响。
    wire vid_resetn = locked;

    // ------------------------------------------------------------------
    // 时序 + PPU + 显存 + 寄存器（全部逻辑在这里，可功能仿真）
    // ------------------------------------------------------------------
    wire [23:0] rgb;
    wire        de, hs, vs;

    video_core u_core (
        .pix_clk    (pix_clk),
        .vid_resetn (vid_resetn),
        .clk_sys    (clk_sys),
        .sys_resetn (sys_resetn),

        .vid_we      (vid_we),
        .vid_vsel    (vid_vsel),
        .vid_waddr   (vid_waddr),
        .vid_be      (vid_be),
        .vid_wdata   (vid_wdata),
        .vid_vsel_d  (vid_vsel_d),
        .vid_waddr_d (vid_waddr_d),
        .vid_rdata   (vid_rdata),

        .rgb (rgb),
        .de  (de),
        .hs  (hs),
        .vs  (vs)
    );

    // ------------------------------------------------------------------
    // RGB → TMDS（内部例化 4 个 outputserdes）
    // rgb/de/hs/vs 都已经是 ppu 输出的寄存器、负极性 —— 与 rgb2tmds 的
    // "输入必须已寄存" 要求一致。
    // ------------------------------------------------------------------
    rgb2tmds u_rgb2tmds (
        .tmds_clk_p (tmds_clk_p),
        .tmds_clk_n (tmds_clk_n),
        .tmds_data_p(tmds_data_p),
        .tmds_data_n(tmds_data_n),
        .rstn       (vid_resetn),
        .vid_pdata  (rgb),
        .vid_pvde   (de),
        .vid_phsync (hs),
        .vid_pvsync (vs),
        .pixelclk   (pix_clk),
        .serialclk  (ser_clk)
    );

endmodule
