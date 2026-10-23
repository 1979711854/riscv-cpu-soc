`timescale 1ns/1ps
// ============================================================================
// unified_mem —— 统一（冯诺依曼）存储器 · 双读口取指 + 单口访存
// ----------------------------------------------------------------------------
// 指令与数据共用同一份 backing store，A1 口供取指、B 口供访存。这是 doc/spec.md
// 里写的 modified-Harvard 的落地：软件看到的地址空间统一，核内部取指/访存通路
// 仍然分离（将来加 I/D Cache 时，两块 Cache 共用这份 backing store）。
//
// 为什么必须统一：riscv-tests 的 fence_i 测的是自修改代码 —— 用 sh 把新
// 指令写进代码区，fence.i 后跳过去执行。哈佛结构（指令/数据各一块 BRAM）下
// store 永远改不到指令，该测试必然 TIMEOUT。
//
// ----------------------------------------------------------------------------
// 双发射：第二取指读口 A2
// ----------------------------------------------------------------------------
// 双发射要同拍拿到 word(pc) 与 word(pc+4)。BRAM 只有 2 个物理端口，而 A1 与 B
// 已经用掉了它们，所以把阵列复制一份：
//     mem0 —— A1 取指（读） + B 访存（读/写）    （真双口 BRAM：口A 读、口B 读写）
//     mem1 —— A2 取指（只读）                    （单口 BRAM）
//     mem2 —— C 口：提前 load 读（只读，EARLY_LD=1 时才例化）
// 写口广播到所有阵列 ⇒ fence_i（自改码）语义与单发射版逐位一致：
// store 写进去的东西，之后 A1/A2 取指与提前 load 读都能读到。
//
// [!] C 口（mem2）与 B 口是同拍写/读关系：store 在 MEM 级写 mem2 的那一拍，
//     若某条 load 正在提前读同一个 word，它读到的是旧值（非阻塞赋值）。
//     core.v 用"紧前一条是 store/AMO 就不走快通路"把这种情况整个排除掉了 ——
//     改这里（比如改成 write_first 语义）不会让 core 那侧变对，别只改一边。
//
// 为什么不用"64 位宽读 + 重整"：无 C 扩展时所有指令与分支目标都 4 字节对齐，
// 但不保证 8 字节对齐 —— 分支目标可以落在 word 索引为奇数处，64 位读就得
// 加一级对齐 mux。两个独立的 32 位读口则天然正好是下两条指令，零对齐逻辑。
//
// 端口时序（mem_bus 与 core 都依赖）：
//   A1/A2 口：同步读，恰好 1 拍延迟，只读，无仲裁
//   B 口：同步读 1 拍 + 按字节写；写与读同址时读到旧值(read_first)，
//         与 Pango BRAM 的 read-during-write 默认模式一致
//
// 本文件是 PDS 综合用的行为模型；仿真时由 testbench 提供同名模型
// （见 sim/mem_model.vh），所以 run_sim.ps1 显式不编译 rtl/mem/。
// ============================================================================
module unified_mem #(
    // 0 = 不例化第三份阵列（省掉相应 BRAM）。
    // 必须与 core.v / mem_bus.v / cpu_top.v 的 EARLY_LD 取值一致。
    parameter EARLY_LD = 0
) (
    // ---- A1 口：取指 1（只读）----
    input  wire [14:0] a_addr,
    output reg  [31:0] a_rd_data,
    input  wire        a_clk,
    input  wire        a_rst,

    // ---- A2 口：取指 2（只读，双发射第二读口；与 A1 同域，共用 a_clk/a_rst）----
    input  wire [14:0] a2_addr,
    output reg  [31:0] a2_rd_data,

    // ---- C 口：提前 load 读口（只读，与 A1/A2 同域、同延迟）----
    // 由 core 的 ID/EX 寄存器驱动（即 load 的 EX 级），数据下一拍（= 该 load 的
    // MEM 级）回来。再做一份阵列的理由与 A2 完全一样：BRAM 只有 2 个物理端口，
    // 而 A1 取指、B 访存已经用掉了它们，且 B 口的读/写地址是同一根 —— store 在
    // MEM 级占据 B 口时，load 的提前读没法共用。写口同样广播到三份阵列。
    input  wire [14:0] ld_addr,
    output reg  [31:0] ld_rd_data,

    // ---- B 口：访存（读写）----
    input  wire [14:0] b_addr,
    input  wire [31:0] b_wr_data,
    input  wire        b_wr_en,
    input  wire [3:0]  b_byte_en,
    output reg  [31:0] b_rd_data,
    input  wire        b_clk,
    input  wire        b_rst,

    // ---- B 口就绪（配合 core.v 的访存等待机制）----
    // 本模块是单周期 BRAM，恒 1。core 只在它为 1 时推进 MEM/WB。
    // 仿真模型 sim/mem_model.vh 里同一个端口可以被 +MEMWAIT=n 拉低，
    // 用来验证 core.v 那三处冻结逻辑真的生效。
    output wire        b_ready
);

    assign b_ready = 1'b1;
    // 32768 word = 128KB（每份）。若要再扩容，必须同步改 mem_bus 与 core 里的 [16:2]
    // 切片，否则高位被静默截断。
    (* syn_ramstyle = "block_ram" *) reg [31:0] mem0 [0:32767];  // A1 取指 + B 访存
    (* syn_ramstyle = "block_ram" *) reg [31:0] mem1 [0:32767];  // A2 取指

    // [!] 不要加整数组清零的 for 循环：PDS 循环展开上限 2000 次，会直接 compile
    //     失败。仿真侧的清零在 sim/mem_model.vh（防 X 传播）；硬件上 BRAM 由
    //     $readmemh 初始化，未覆盖到的位置按上电默认值（0）。
    initial begin
        $readmemh("mem.hex", mem0);
        $readmemh("mem.hex", mem1);
    end

    // ------------------------------------------------------------------
    // C 口阵列（提前 load 读口）：EARLY_LD=1 时才例化。
    //   独立成一份、独立 always 块，是为了让 EARLY_LD=0 时它整个不进网表
    //   （否则白占资源并改变布局/时序口径）。
    //   写口同样广播 —— 三份内容必须永远相同（fence_i / st_ld 正确性）。
    // ------------------------------------------------------------------
    generate
    if (EARLY_LD != 0) begin : g_ldmem
        (* syn_ramstyle = "block_ram" *) reg [31:0] mem2 [0:32767];
        initial $readmemh("mem.hex", mem2);

        always @(posedge b_clk) begin
            if (b_wr_en) begin
                if (b_byte_en[0]) mem2[b_addr][ 7: 0] <= b_wr_data[ 7: 0];
                if (b_byte_en[1]) mem2[b_addr][15: 8] <= b_wr_data[15: 8];
                if (b_byte_en[2]) mem2[b_addr][23:16] <= b_wr_data[23:16];
                if (b_byte_en[3]) mem2[b_addr][31:24] <= b_wr_data[31:24];
            end
        end

        always @(posedge b_clk or posedge b_rst) begin
            if (b_rst) ld_rd_data <= 32'd0;
            else       ld_rd_data <= mem2[ld_addr];
        end
    end else begin : g_noldmem
        always @(posedge b_clk or posedge b_rst) begin
            if (b_rst) ld_rd_data <= 32'd0;
            else       ld_rd_data <= 32'd0;
        end
    end
    endgenerate

    // A1 口：同步读（非阻塞赋值 ⇒ 与写同址时读到旧值）
    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a_rd_data <= 32'd0;
        else       a_rd_data <= mem0[a_addr];
    end

    // A2 口：同步读，与 A1 同域、同延迟
    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a2_rd_data <= 32'd0;
        else       a2_rd_data <= mem1[a2_addr];
    end

    // B 口：按字节写 + 同步读。必须按字节写 —— fence_i 用两条 sh 分别改写同一
    // word 的低半字和高半字，整字写会连带打坏相邻半字。
    // 写口广播到 mem0/mem1 两份阵列，保证两份永远相同（fence_i 正确性）。
    always @(posedge b_clk) begin
        if (b_wr_en) begin
            if (b_byte_en[0]) begin mem0[b_addr][ 7: 0] <= b_wr_data[ 7: 0]; mem1[b_addr][ 7: 0] <= b_wr_data[ 7: 0]; end
            if (b_byte_en[1]) begin mem0[b_addr][15: 8] <= b_wr_data[15: 8]; mem1[b_addr][15: 8] <= b_wr_data[15: 8]; end
            if (b_byte_en[2]) begin mem0[b_addr][23:16] <= b_wr_data[23:16]; mem1[b_addr][23:16] <= b_wr_data[23:16]; end
            if (b_byte_en[3]) begin mem0[b_addr][31:24] <= b_wr_data[31:24]; mem1[b_addr][31:24] <= b_wr_data[31:24]; end
        end
    end

    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) b_rd_data <= 32'd0;
        else       b_rd_data <= mem0[b_addr];
    end
endmodule
