`timescale 1ns/1ps
// ============================================================================
// CSR 文件（机器模式最小集）
// ----------------------------------------------------------------------------
// 本模块只提供"寄存器组 + 读写译码 + trap/mret 的副作用"，不含任何流水线逻辑。
// 混在 core.v 里会让那个文件难以维护，独立出来也更便于单测。
//
// ============================ 三处关键设计取舍 ============================
//
// 1) 只支持 M 模式 —— `mstatus.MPP` 硬连线 2'b11，`mret` 永远回 M 模式。
//    这不是偷懒。riscv-tests 的 reset_vector 会执行 `csrwi mstatus, 0` 把 MPP 清 0；
//    若如实实现，`mret` 会把特权级降到 U 模式，随后 `mcause` 里
//    ecall-from-U(8) / from-S(9) / from-M(11) 的区分就与测试的假设不符。
//    本设计没有特权级隔离，如实实现反而引入不一致。
//
// 2) CSR 写在 EX 级提交（本模块的 csr_we 由 core 在 EX 级给出，一拍脉冲）。
//    原因见 core.v：riscv-tests 里 `csrw mepc, t0` 与 `mret` 之间只隔 1 条指令，
//    若像寄存器堆那样从 WB 提交，`mret` 会读到复位值 0 → 跳回 _start → 无限重启。
//
// 3) 未实现的 CSR（`stvec`/`medeleg`/`mideleg`/`satp`/`pmp*`/`mnstatus` 等）
//    → 读 0、写忽略、不抛非法指令。
//    riscv-tests 的 init 段会访问上述全部；按规范对未知 CSR 抛非法指令
//    会让 50 个基线 ELF 当场全挂。这是明知与规范有偏差的工程取舍，
//    已在 doc/spec.md 的"已知限制"里记录。
//
// 唯一会抛非法指令的 CSR 情形：写只读 CSR（csr[11:10] == 2'b11），
// 例如 `unimp`（= `csrrw x0, cycle, x0`，写 0xC00）—— 这正是规范定义的语义。
// ============================================================================
module csr_file (
    input  wire        clk,
    input  wire        resetn,

    // ---- 读口（组合，EX 级；core 把它骑在 alu_result 上以白拿前递）----
    input  wire [11:0] rd_addr,
    output reg  [31:0] rd_data,

    // ---- 写口（EX 级提交，一拍脉冲；core 已用 !trap 门控过）----
    input  wire        wr_en,
    input  wire [11:0] wr_addr,
    input  wire [31:0] wr_data,
    output wire        wr_illegal,    // 写只读 CSR → 非法指令

    // ---- trap 副作用（一拍脉冲；与 mret 互斥）----
    input  wire        trap,
    input  wire [31:0] trap_pc,       // = id_ex_pc（肇事指令自己的 PC）
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_tval,

    // ---- mret 副作用（一拍脉冲）----
    input  wire        mret,

    // ---- 中断源（电平）----
    input  wire        irq_timer,     // → mip.MTIP
    input  wire        irq_ext,       // → mip.MEIP

    // ---- 给流水线用 ----
    output wire [31:0] mtvec_base,    // trap 入口地址
    output wire [31:0] mepc_out,      // mret 的跳转目标
    output wire        mstatus_mie,   // 全局中断使能
    output wire        mie_mtie,      // 定时器中断使能
    output wire        mie_meie       // 外部中断使能
);

    // ==========================================================================
    // 设计版本号 —— 由 `mimpid`（0xF13）读出。
    // --------------------------------------------------------------------------
    // 存在的理由：两版位流可以装着完全相同的固件，
    // 串口日志因此一模一样，事后分不出烧的是哪一版。把版本号放在RTL 侧，
    // 固件读出来打在第一行，日志就能自证。
    //   [!] 改任何 RTL 后、综合前，必须把它改成新值（见 项目约定文档 约定 42）。
    //       同一天改多次就用最低字节当序号（0x2026_1010 → 0x2026_1011 → …）。
    //   为什么用 mimpid 而不是新加一个 MMIO 寄存器：它是规范里的只读 ID 寄存器，
    //   加它不用动地址映射、不用动 mem_bus、不用改固件的板级头文件，
    //   固件一条 `csrr` 就能读到。
    //   覆盖的值（从新到旧）：
    //     2026_1024  [lane B 访存 · P2] core.v 落地 lane B load 的全部"管道"
    //                （新增流水线寄存器 / 访存口 b_mem_sel mux 腿 / 前递门控 /
    //                load-use 停顿 / 未对齐异常 / WB 解包），但 parameter
    //                LANEB_MEM=0（开关未翻） ⇒ 四条 CoreMark 基线
    //                （229,597 / 249,982 / 300,392 / 233,013）与四 CRC
    //                逐位不变。翻开关是 P3，判据见 doc/reports/ 相应任务书。
    //     2026_1023  A 扩展（RV32A）改为 parameter，默认关：
    //                AMO 的 opcode 判非法、`amo_unit` 用 generate 包住不例化。
    //                实测 −444 LUT / −224 FF、CPU 域余量 +0.034 → +0.160 ns，
    //                而 CoreMark 五配置的周期数与四 CRC 逐位不变（零性能代价）。
    //                赛题公式 Score=Iterations/(Total_Time×Frequency)=CoreMark/MHz
    //                ⇒ 主频与面积不进主分，面积进指标(3) CoreMark/LUTs（+5.8%）。
    //                开关：core/cpu_top 的 parameter A_EXT；验证口径见下文注释。
    //     2026_1022  B1-BTB：分支目标缓冲（间接跳转 jalr 在到达级预测目标，RAS>BTB>PC+imm；
    //                §7 校验放宽到所有被预测的 jalr）+ parameter BTB_EN
    //     2026_1021  B1-RAS：返回地址栈（ret 在到达级预测目标）+ §7 预测目标校验
    //                （ex_target_wrong 并入 ex_flush 纠正错目标）
    //     2026_1020  ex_flush/ex_mispred 补 mem_ready_int 门控（AMO 后紧跟分支用
    //                陈旧前递值解析方向并提交错误路径，tb_amo_cpu testnum 9 实测）
    //     2026_1019  CSR 写与 mret 副作用补 mem_ready 门控（Cache + RT-Thread 挂死根因 #2）
    //     2026_1016  I+D Cache 板级失败的根因修复（core.v 的 wb_rdata_snap
    //                停顿快照取错流水级，见 doc/reports/2026-10-12_icache_wb_snap_fix.md）
    //     2026_1015  任务 C（EARLY_LD：load 地址提前到 ID + 专用读口）
    //     2026_1011  分支预测重定向提前到到达级（阶段1：taken 分支省 1 拍气泡）
    //     2026_1010  imem_addr2 位宽修复（13→14 bit，64KB 取指不再回绕）
    //     （旧的位流读出 0 —— 那时 mimpid 恒 0，正好当"修复前"的标识）
    //     2026_1025  [P3] lane B 访存开关翻转：`parameter LANEB_MEM` 默认 0→1
    //                （PDS/上板口径），lane B 可以放 load。7 处时序门控保留：
    //                0 档仍折成常量（rev1023 网表可复现），1 档语义不变。
    //                功能全绿：CoreMark 217,088 拍（−5.45%，效率 4.3555→4.6064
    //                CoreMark/MHz）、四 CRC 逐位一致、riscv-tests 49/1/0、own_tests
    //                6/0（含 R1/R2/R5 定向用例）、RT-Thread 四配置全 PASS。
    //                [!] PDS 85 MHz 时序不过：CPU 域 WNS −0.701 ns / Fmax 80.22 MHz
    //                （P4 闸门未过）⇒ 交付位流仍是 rev1023 的 55fae69e（0 档）；
    //                修 fetch 路径上的 `alu_result_b` 锥（P3.5）之前，
    //                不要用本默认值出 85 MHz 交付位流。
    //     2026_1026  [P3.5] lane B 未对齐判定改 2 位窄加法（core.v 的
    //                `b_addr_low = rs1_val_b[1:0] + id_ex_b_imm[1:0]`）：把 32 位
    //                `alu_result_b` 加法器锥从取指路径（load_misaligned_b →
    //                if_addr_d → imem_addr）上摘掉，目标 = 收回 85 MHz 时序。
    //                严格等价（OP_LOAD ⇒ alu_a_sel=0/alu_b_sel=1/alu_op=ADD，
    //                且该信号只经 load_misaligned_b 使用）；exc_tval 不用窄值
    //                （它进 CSR 寄存器、不在取指路径）。CoreMark 语义判据同 1025。
    //                单独实测（[A]）：CPU 域 WNS −0.701 → −0.345 ns、Fmax
    //                80.22 → 82.58 MHz、LUT 8,029 → 7,763（位流 md5 a3a4d5a7；
    //                时序仍不过 ⇒ 未上板）。功能判据同 1025（CoreMark 217,088 +
    //                四 CRC 逐位一致、riscv-tests 49/1/0、own_tests 6/0）。
    //     2026_1027  [P3.5(B)] `imem_addr2 = fetch_addr[15:2] + 14'd1`：把第二取指
    //                地址那条 14 位加法从 `imem_addr` 之后解耦出来（[A] 之后
    //                的关键路径尾段 = if_addr_d → imem_addr → COUT → imem_addr2
    //                → BRAM ADB）。逐位等价：`imem_addr` 恒 = `fetch_addr[15:2]`，
    //                两式同为模 2^14 加法，只是把平级加法器的自由度还给综合器。
    //     （旧值 2026_1024 = lane B 访存管道落地但 LANEB_MEM=0，P2）
    //     2026_1028  [128KB] 统一存储器 64KB→128KB（15 位字地址）：
    //                core.v / cpu_top.v / mem_bus.v / unified_mem.v /
    //                cache_i.v / cache_d.v / mem_model.vh 的 word 索引全部
    //                14→15 位；兼容区判决加 `!addr[16]`（0x1FFF0 不再误中
    //                MMIO）；快通路 load 的 RAM 判定同步放宽到 0x0~0x1FFEF。
    //                语义上周期数不变（BRAM 仍是 1 拍读），时序需重扫 seed。
    // ==========================================================================
    localparam [31:0] DESIGN_REV = 32'h2026_1028;   // 128KB：15 位字地址 + 兼容区别名修复

    // ---- CSR 地址常量 ----
    localparam [11:0] CSR_MSTATUS  = 12'h300,
                      CSR_MISA     = 12'h301,
                      CSR_MIE      = 12'h304,
                      CSR_MTVEC    = 12'h305,
                      CSR_MSCRATCH = 12'h340,
                      CSR_MEPC     = 12'h341,
                      CSR_MCAUSE   = 12'h342,
                      CSR_MTVAL    = 12'h343,
                      CSR_MIP      = 12'h344,
                      CSR_MCYCLE   = 12'hB00,
                      CSR_MCYCLEH  = 12'hB80,
                      CSR_MINSTRET = 12'hB02,
                      CSR_MINSTRETH= 12'hB82,
                      CSR_MVENDORID= 12'hF11,
                      CSR_MARCHID  = 12'hF12,
                      CSR_MIMPID   = 12'hF13,
                      CSR_MHARTID  = 12'hF14;

    // ---- 寄存器 ----
    // mstatus 只实现 MIE(3) / MPIE(7)；MPP(12:11) 恒为 2'b11（只支持 M 模式）
    reg mstatus_mie_r, mstatus_mpie_r;
    reg [31:0] mtvec_r, mscratch_r, mepc_r, mcause_r, mtval_r;

    // mie 只实现 MTIE(7) / MEIE(11)
    reg mie_mtie_r, mie_meie_r;

    // mcycle：64 位自由跑计数器（面积可忽略，且是"读得到真实周期数"的常规做法）
    reg [63:0] mcycle_r;

    // mip 的 MTIP/MEIP 是只读的硬件输入，绝不接受软件写
    // （若允许软件写，会和硬件比较器抢同一位，把中断"写没"）
    wire mip_mtip = irq_timer;
    wire mip_meip = irq_ext;

    // ---- 读译码 ----
    always @(*) begin
        case (rd_addr)
            // 位布局（自 LSB）：[2:0]0 [3]MIE [6:4]0 [7]MPIE [10:8]0 [12:11]MPP=11 [31:13]0
            CSR_MSTATUS  : rd_data = {19'b0, 2'b11, 3'b0, mstatus_mpie_r,
                                      3'b0, mstatus_mie_r, 3'b0};
            CSR_MISA     : rd_data = 32'h4000_1100;   // MXL=RV32, 扩展 I + M
            // 位布局：MTIE/MTIP 在 bit7，MEIE/MEIP 在 bit11
            CSR_MIE      : rd_data = {20'b0, mie_meie_r, 3'b0, mie_mtie_r, 7'b0};
            CSR_MTVEC    : rd_data = mtvec_r;
            CSR_MSCRATCH : rd_data = mscratch_r;
            CSR_MEPC     : rd_data = mepc_r;
            CSR_MCAUSE   : rd_data = mcause_r;
            CSR_MTVAL    : rd_data = mtval_r;
            CSR_MIP      : rd_data = {20'b0, mip_meip, 3'b0, mip_mtip, 7'b0};
            CSR_MCYCLE   : rd_data = mcycle_r[31:0];
            CSR_MCYCLEH  : rd_data = mcycle_r[63:32];
            // minstret 未实现退休计数 —— 只读 0，属已知限制（见 doc/spec.md）
            CSR_MINSTRET : rd_data = 32'd0;
            CSR_MINSTRETH: rd_data = 32'd0;
            // 只读 ID 寄存器。mimpid 承载设计版本号（见上面的 DESIGN_REV），
            // 其余三个恒 0。
            // mhartid 必须是 0：riscv-tests 的 RISCV_MULTICORE_DISABLE 里有
            // `csrr a0, mhartid; bnez a0, 1b`，返回非 0 会原地自旋到超时。
            CSR_MVENDORID, CSR_MARCHID, CSR_MHARTID: rd_data = 32'd0;
            CSR_MIMPID   : rd_data = DESIGN_REV;
            // 未实现（含 stvec/medeleg/mideleg/satp/pmp*/mnstatus 等）
            // → 读 0、不抛异常（理由见文件头第 3 条）
            default      : rd_data = 32'd0;
        endcase
    end

    // 只读 CSR：csr[11:10] == 2'b11（0xC00 起的计数器区 与 0xF11 起的 ID 区）
    assign wr_illegal = (wr_addr[11:10] == 2'b11);

    // ---- 写 / trap / mret ----
    // 三者互斥由 core 保证：wr_en 已被 !trap 门控；trap 与 mret 天然互斥
    // （int_take 被 !id_ex_mret 门控，同步异常与 mret 不可能同拍）。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            mstatus_mie_r  <= 1'b0;    // [!] 复位必须为 0
            mstatus_mpie_r <= 1'b0;
            mie_mtie_r     <= 1'b0;    // [!] 复位必须为 0
            mie_meie_r     <= 1'b0;
            mtvec_r        <= 32'd0;   // [!] 复位取 0
            mscratch_r     <= 32'd0;
            mepc_r         <= 32'd0;
            mcause_r       <= 32'd0;
            mtval_r        <= 32'd0;
            mcycle_r       <= 64'd0;
        end else begin
            mcycle_r <= mcycle_r + 64'd1;

            if (trap) begin
                // 同步异常 / 中断的入口副作用。
                // [!] mstatus.MIE ← 0 是必须的：它让 int_take 在下一拍自动消掉。
                //   漏掉的话中断会每拍重新触发，PC 被钉死在 mtvec（handler 的
                //   第一条指令永远进不了 EX），表现是 PC 不动、周期数暴涨。
                mepc_r         <= trap_pc;
                mcause_r       <= trap_cause;
                mtval_r        <= trap_tval;
                mstatus_mpie_r <= mstatus_mie_r;
                mstatus_mie_r  <= 1'b0;
            end else if (mret) begin
                mstatus_mie_r  <= mstatus_mpie_r;
                mstatus_mpie_r <= 1'b1;
            end else if (wr_en) begin
                // 写只读 CSR 不生效（wr_illegal 会同时让 core 抛非法指令）
                case (wr_addr)
                    CSR_MSTATUS  : begin
                        mstatus_mie_r  <= wr_data[3];
                        mstatus_mpie_r <= wr_data[7];
                        // MPP 写入被忽略：恒为 M 模式（见文件头第 1 条）
                    end
                    CSR_MIE      : begin
                        mie_mtie_r <= wr_data[7];
                        mie_meie_r <= wr_data[11];
                    end
                    CSR_MTVEC    : mtvec_r    <= {wr_data[31:2], 2'b00}; // 只支持 direct
                    CSR_MSCRATCH : mscratch_r <= wr_data;
                    CSR_MEPC     : mepc_r     <= {wr_data[31:1], 1'b0};  // 指令对齐
                    CSR_MCAUSE   : mcause_r   <= wr_data;
                    CSR_MTVAL    : mtval_r    <= wr_data;
                    // mip 只读；mcycle 只读（其低位可写，本项目不支持 —— 见已知限制）；
                    // 未实现地址一律忽略
                    default      : ;
                endcase
            end
        end
    end

    // 只支持 direct 模式：trap 目标 = mtvec 的 BASE（低 2 位 MODE 被忽略）
    assign mtvec_base  = {mtvec_r[31:2], 2'b00};
    assign mepc_out    = mepc_r;
    assign mstatus_mie = mstatus_mie_r;
    assign mie_mtie    = mie_mtie_r;
    assign mie_meie    = mie_meie_r;

endmodule
