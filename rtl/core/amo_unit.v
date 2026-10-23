`timescale 1ns/1ps
// ============================================================================
// amo_unit.v —— A 扩展原子内存操作单元（RISC-V AMO / LR / SC）
// ----------------------------------------------------------------------------
// 为什么单独摘成一个模块，而不是塞进 alu 或直接写进 core.v：
//
//   1) AMO 是读-改-写，天然要占两拍MEM（先读回旧值，再写回新值）。
//   2) 但它不能像 multiplier / divider 那样走 mc_stall：mc_stall 会把
//      EX/MEM 清成气泡，而 AMO 恰恰就是那条正在跑状态机的指令 —— 清掉它等于
//      把读-改-写拦腰截断（这正是"接进流水线就坏"的历史真因）。
//      所以 AMO 改为占住 MEM 级：amo_stall 仍报出"忙"，但 core.v 用
//      mem_ready 那套保持语义把它冻在 EX/MEM 里，直到 mem_release
//      （ST_WRITE 拍）才放开。前端取指/译码时序因此仍然一行都不用改。
//   3) AMO 的关键路径是「读回值 → 一级 ALU 二选一 → 写回」，很短，
//      不会像单拍组合乘法那样吃掉 56% 的时序余量。
//
// ---- 时序契约（严格对齐 core.v 的 MEM 级）----
//   core.v 的访存契约：第 T 拍(MEM) 给出 mem_addr，第 T+1 拍(WB)
//   mem_rdata 才是 mem_addr(T) 对应地址的读数据。
//   注意 mem_rdata 是寄存器输出：它在 T+1 那个沿才被写入内存逻辑，
//   所以它从 T+2 整拍开始才稳定有效。逐拍实测（trace 验证）如下：
//     T  : ST_READ  re=1 给出 addr
//     T+1: ST_HOLD  re=0  —— mem_rdata 仍是上一条的值
//     T+2: ST_WRITE  re=0  —— mem_rdata 此时才有效，锁存它
//     T+3: ST_DONE  we=1 用锁存值写回
//   [踩过的坑] 初版只有两拍（READ→WRITE），在 WRITE 拍直接采 mem_rdata，
//   采到的是陈旧值 ⇒ amoadd 把内存写成 rs2 的原值。必须多一拍等数据回来。
//
// ---- LR/SC 预约 ----
//   LR 建立预约；SC 成功则写并返回 1，失败返回 0 且不写。
//   任何 store/AMO 写别的地址都会让预约失效（规格要求）。
//   本设计单核顺序执行，SC 失败的条件只有"地址不匹配"或"期间有别的store"。
//   [!] 语义仍必须完整 —— 否则在真多核机器上跑出来的程序会错。
// ============================================================================
module amo_unit (
    input  wire        clk,
    input  wire        resetn,

    // ---- 启动与操作数（来自 EX/MEM 级）----
    input  wire        start,        // 本拍有一条 AMO/LR/SC 进入 MEM
    input  wire [31:0] addr,         // rs1 的值（AMO/LR/SC 用 rs1，不是 rs1+imm）
    input  wire [31:0] rs2_val,
    input  wire [4:0]  funct5,
    input  wire [1:0]  funct3,       // 010=32位；011=64位（本设计判非法）
    input  wire [31:0] mem_rdata,    // MEM 级读回数据

    // ---- 访存端口（与 core.v 原有端口在 core.v 里做 or/mux）----
    output wire        amo_mem_re,
    output wire        amo_mem_we,
    output wire [3:0]  amo_byte_en,
    output wire [31:0] amo_wdata,

    // ---- 控制/数据 ----
    output wire        amo_stall,    // 占用中（四拍全程为 1）
    output wire        mem_release,  // 本拍 = ST_WRITE：core 据此放开 MEM 级占用
    output wire [31:0] wb_data,      // 写回值：AMO/LR = 旧值，SC = 成功标志
    output wire        illegal,
    // 预约被任何 store/AMO 写打断（core.v 里由真实 store 与 AMO 写回拉高）
    input  wire        store_commit
);

    localparam [4:0] F5_LR      = 5'b00010;
    localparam [4:0] F5_SC      = 5'b00011;
    localparam [4:0] F5_AMOSWAP = 5'b00001;
    localparam [4:0] F5_AMOADD  = 5'b00000;
    localparam [4:0] F5_AMOXOR  = 5'b00100;
    localparam [4:0] F5_AMOAND  = 5'b01100;
    localparam [4:0] F5_AMOOR   = 5'b01000;
    localparam [4:0] F5_AMOMIN  = 5'b10000;
    localparam [4:0] F5_AMOMAX  = 5'b10100;
    localparam [4:0] F5_AMOMINU = 5'b11000;
    localparam [4:0] F5_AMOMAXU = 5'b11100;

    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_READ  = 3'd1;   // T   ：给地址，发读
    localparam [2:0] ST_HOLD  = 3'd2;   // T+1 ：等（mem_rdata 此刻仍无效）
    localparam [2:0] ST_LATCH = 3'd3;   // T+2 ：锁存读回旧值
    localparam [2:0] ST_WRITE = 3'd4;   // T+3 ：用锁存值写回

    reg  [2:0]  st;
    reg  [31:0] amo_rdata_r;    // 读回的旧值
    reg  [31:0] amo_addr_r;
    reg  [31:0] amo_rs2_r;
    reg  [4:0]  amo_f5_r;
    reg         sc_fail_r;

    // LR 预约
    reg         resv_valid;
    reg  [31:0] resv_addr;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st          <= ST_IDLE;
            amo_rdata_r <= 32'd0;
            amo_addr_r  <= 32'd0;
            amo_rs2_r   <= 32'd0;
            amo_f5_r    <= 5'd0;
            sc_fail_r   <= 1'b0;
            resv_valid  <= 1'b0;
            resv_addr   <= 32'd0;
        end else begin
            case (st)
                ST_IDLE: begin
                    if (start) begin
                        amo_addr_r <= addr;
                        amo_rs2_r  <= rs2_val;
                        amo_f5_r   <= funct5;
                        st         <= ST_READ;
                        if (funct5 == F5_SC) begin
                            // SC 不读内存，成败在此刻就定下来
                            sc_fail_r <= ~(resv_valid && (resv_addr == addr));
                            resv_valid <= 1'b0;      // SC 无论成败都清预约
                        end else if (funct5 == F5_LR) begin
                            resv_valid <= 1'b1;      // LR 立即建立新预约
                            resv_addr  <= addr;
                        end
                    end
                end

                ST_READ: begin
                    // 这一拍 mem_rdata还无效（它在下一个沿才被写入）
                    st <= ST_HOLD;
                end

                ST_HOLD: begin
                    // 再等一拍，等读数据真的稳定
                    st <= ST_LATCH;
                end

                ST_LATCH: begin
                    // 此刻 mem_rdata 有效 → 锁存旧值
                    amo_rdata_r <= mem_rdata;
                    st          <= ST_WRITE;
                end

                ST_WRITE: begin
                    // 写动作发出；SC 成功后写内存，预约已在 IDLE 拍清掉
                    st <= ST_IDLE;
                end

                default: st <= ST_IDLE;
            endcase

            // 任何 store/AMO 写回都让 LR 预约失效
            if (store_commit && resv_valid && !(st == ST_WRITE && resv_addr == amo_addr_r))
                resv_valid <= 1'b0;
        end
    end

    assign amo_stall   = (st != ST_IDLE);
    // 状态机的最后一拍（写回拍）。core.v 用它在"这一拍末"放开被占住的 EX/MEM：
    //   同一拍里 amo_mem_we 已经把新值写进内存，而 "EX/MEM -> MEM/WB" 的沿也在
    //   这一拍，于是这条 AMO 恰好被 MEM/WB 捕获一次（mem_wb_is_amo=1），
    //   接着走原有的WB 写回通路 —— 不需要寄存器堆第三写口，也不需要自持写回。
    assign mem_release = (st == ST_WRITE);
    assign illegal   = (funct3 == 2'b11);      // RV32 不支持 64 位 AMO

    wire is_sc      = (amo_f5_r == F5_SC);
    wire is_lr      = (amo_f5_r == F5_LR);
    wire sc_success = ~sc_fail_r;

    // ---- 访存端口 ----
    // 读：AMO 与 LR 要读旧值；SC 不读。
    assign amo_mem_re   = (st == ST_READ) && !is_sc;
    // 写：SC 只在成功时写；LR 从不写；其余 AMO 都在 ST_WRITE 写。
    assign amo_mem_we   = (st == ST_WRITE) && !is_lr &&
                          (!is_sc || sc_success);
    assign amo_byte_en  = amo_mem_we ? 4'b1111 : 4'b0000;

    // ---- 新值 = f(旧值, rs2)----
    // [!] 用锁存的amo_rdata_r，不是当前的 mem_rdata —— 后者在 WRITE 拍
    //   已经是下一条访存的数据了。
    reg [31:0] fused;
    always @(*) begin
        case (amo_f5_r)
            F5_AMOSWAP: fused = amo_rs2_r;
            F5_AMOADD : fused = amo_rdata_r + amo_rs2_r;
            F5_AMOXOR : fused = amo_rdata_r ^ amo_rs2_r;
            F5_AMOAND : fused = amo_rdata_r & amo_rs2_r;
            F5_AMOOR  : fused = amo_rdata_r | amo_rs2_r;
            F5_AMOMIN : fused = ($signed(amo_rdata_r) < $signed(amo_rs2_r)) ? amo_rdata_r : amo_rs2_r;
            F5_AMOMAX : fused = ($signed(amo_rdata_r) > $signed(amo_rs2_r)) ? amo_rdata_r : amo_rs2_r;
            F5_AMOMINU: fused = (amo_rdata_r < amo_rs2_r) ? amo_rdata_r : amo_rs2_r;
            F5_AMOMAXU: fused = (amo_rdata_r > amo_rs2_r) ? amo_rdata_r : amo_rs2_r;
            default   : fused = amo_rdata_r;      // LR：只读
        endcase
    end

    assign amo_wdata = is_sc ? amo_rs2_r : fused;

    // ---- 写回给 rd 的值：AMO/LR 回旧值，SC 回成功标志 ----
    // [!] 写回值必须在整条指令结束那拍有效 —— core.v 的 WB 级看到的是
    //   MEM/WB 寄存下来的 wb_data，所以取当前锁存值即可（结束拍=ST_WRITE 末）。
    assign wb_data = is_sc ? {31'd0, sc_success} : amo_rdata_r;

endmodule