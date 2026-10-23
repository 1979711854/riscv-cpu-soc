// ============================================================================
// 行为级统一存储器模型（仿真专用，由各 testbench `include）
// ----------------------------------------------------------------------------
// 端口与 rtl/mem/unified_mem.v 完全一致（含双发射的第二取指读口 A2）。
// 之所以单独一份、而不是直接编 rtl/mem/：仿真需要从 plusarg 动态指定固件路径
// （一个 vvp 跑几十个测试），而 rtl/mem/ 那份是给 PDS 综合用的固定路径。
//
// [!] 本文件必须与 rtl/mem/unified_mem.v 【逐行镜像】—— 改一处必改另一处。
//
// 用 `include 而不是每个 tb 抄一遍，是为了避免三份拷贝各自漂移。
//
// 固件加载：+IMEM=programs/imem.hex  +DMEM=programs/dmem.hex
//   两个文件都用 @word索引 形式，且索引集合【不相交】（elf2mem.py 有断言），
//   所以先后 $readmemh 进同一个数组是安全的。合并后的 mem.hex 也可以直接
//   用 +IMEM= 传进来。
//
// 双阵列 mem0/mem1 与 rtl 侧同构：mem0 服务 A1 取指 + B 访存，mem1 服务 A2
// 取指；两份内容永远相同（写口广播）。仿真里直接把 mem0 拷进 mem1 即可。
// ============================================================================
module unified_mem #(
    // [任务 C] 与 rtl/mem/unified_mem.v 的 EARLY_LD 一致（0 = 不例化第三份阵列）
    parameter EARLY_LD = 0
) (
    // ---- A1 口：取指 1（只读，同步读 1 拍）----
    input  wire [14:0] a_addr,
    output reg  [31:0] a_rd_data,
    input  wire        a_clk,
    input  wire        a_rst,

    // ---- A2 口：取指 2（只读，同步读 1 拍）----
    input  wire [14:0] a2_addr,
    output reg  [31:0] a2_rd_data,

    // ---- C 口：任务 C 的提前 load 读口（只读，同步读 1 拍；EARLY_LD=1 时有意义）----
    input  wire [14:0] ld_addr,
    output reg  [31:0] ld_rd_data,

    // ---- B 口：访存（读写，按字节写，同步读 1 拍）----
    input  wire [14:0] b_addr,
    input  wire [31:0] b_wr_data,
    input  wire        b_wr_en,
    input  wire [3:0]  b_byte_en,
    output reg  [31:0] b_rd_data,
    input  wire        b_clk,
    input  wire        b_rst,

    // ---- B 口就绪（新增，配合 core.v 的访存等待机制）----
    // 恒 1 表示"这次访存完成了"。默认（不加 plusarg）恒为 1，行为与以前【逐位相同】。
    // 加 +MEMWAIT=n 后每 n+1 拍才拉高一次，用来【验证】core.v 的停顿逻辑真的生效。
    output reg         b_ready
);
    reg [31:0] mem0 [0:32767];
    reg [31:0] mem1 [0:32767];
    reg [31:0] mem2 [0:32767];   // [任务 C] C 口阵列（提前 load 读；EARLY_LD=0 时不用）
    reg [1023:0] hexpath;
    integer i;

    // 访存额外等待周期。0 = 不等待（默认，与改动前一致）。
    // [!] 只作用于 B 口（数据访存）。A 口（取指）没有 ready 通路 —— 取指永远是
    //     1 拍，这是当前架构的既定事实，去零等待只在数据侧做验证。
    integer memwait = 0;
    integer wait_cnt = 0;

    initial begin
        // 必须先清零：未初始化地址读出 X，会让比较类测试莫名失败
        for (i = 0; i < 32768; i = i + 1) mem0[i] = 32'd0;
        if ($value$plusargs("IMEM=%s", hexpath)) begin
            // 显式给了 IMEM 就认它是主镜像（可以是 elf2mem.py 出的 mem.hex
            // 完整镜像，也可以是拆分的 imem.hex）；再给了 DMEM 才叠一份上去。
            $readmemh(hexpath, mem0);
            if ($value$plusargs("DMEM=%s", hexpath)) $readmemh(hexpath, mem0);
        end else begin
            // 都没给：用默认的拆分镜像
            $readmemh("programs/imem.hex", mem0);
            $readmemh("programs/dmem.hex", mem0);
        end
        // mem1/mem2 是 mem0 的镜像（rtl 侧写口广播，几份永远相同）
        for (i = 0; i < 32768; i = i + 1) begin
            mem1[i] = mem0[i];
            mem2[i] = mem0[i];
        end
        // [!] 不要写 void'(...)：iverilog 12.0（2021）不支持 void' 强转，会直接
        //     报 syntax error，且【所有 include 本文件的测试台】一起编不过。
        //     返回值本来就只用来丢弃，赋给 i 完全等价（i 的循环已用完）。
        i = $value$plusargs("MEMWAIT=%d", memwait);
    end

    // A1 口：同步读（非阻塞 ⇒ 与 B 口写同址时读到旧值，即 read_first）
    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a_rd_data <= 32'd0;
        else       a_rd_data <= mem0[a_addr];
    end

    // A2 口：同步读，与 A1 同域、同延迟
    always @(posedge a_clk or posedge a_rst) begin
        if (a_rst) a2_rd_data <= 32'd0;
        else       a2_rd_data <= mem1[a2_addr];
    end

    // B 口：按字节写 + 同步读（写口广播到 mem0/mem1/mem2 三份）
    always @(posedge b_clk) begin
        if (b_wr_en) begin
            if (b_byte_en[0]) begin mem0[b_addr][ 7: 0] <= b_wr_data[ 7: 0]; mem1[b_addr][ 7: 0] <= b_wr_data[ 7: 0]; mem2[b_addr][ 7: 0] <= b_wr_data[ 7: 0]; end
            if (b_byte_en[1]) begin mem0[b_addr][15: 8] <= b_wr_data[15: 8]; mem1[b_addr][15: 8] <= b_wr_data[15: 8]; mem2[b_addr][15: 8] <= b_wr_data[15: 8]; end
            if (b_byte_en[2]) begin mem0[b_addr][23:16] <= b_wr_data[23:16]; mem1[b_addr][23:16] <= b_wr_data[23:16]; mem2[b_addr][23:16] <= b_wr_data[23:16]; end
            if (b_byte_en[3]) begin mem0[b_addr][31:24] <= b_wr_data[31:24]; mem1[b_addr][31:24] <= b_wr_data[31:24]; mem2[b_addr][31:24] <= b_wr_data[31:24]; end
        end
    end

    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) b_rd_data <= 32'd0;
        else       b_rd_data <= mem0[b_addr];
    end

    // C 口：同步读（任务 C 的提前 load 读口）。与 B 口同址同拍时读到【旧值】，
    // core.v 用"紧前一条是 store/AMO 就不走快通路"排除这种情况（见 unified_mem.v）。
    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) ld_rd_data <= 32'd0;
        else       ld_rd_data <= mem2[ld_addr];
    end

    // ------------------------------------------------------------------
    // B 口就绪时序（+MEMWAIT=n 时才有等待）
    // ------------------------------------------------------------------
    // memwait = 0 时：每个沿 wait_cnt 都等于 0，于是 b_ready 恒 1、
    // b_rd_data 每个沿更新一次 —— 与改动前【逐位相同】。
    //
    // memwait = n > 0 时：数到 n 才拉高一次 b_ready，再从头数。
    // 因为停顿期间 CPU 会把 mem_addr 保持住（这正是 core.v 那三处冻结做的事），
    // 所以 mem[b_addr] 每次采的都是同一个地址，数据是对的。
    //
    // [!] 写操作在停顿期间会被重复执行 n+1 次。对 BRAM（同地址写同值）是幂等的，
    //     所以这里不处理。**但对 FIFO 类外设（UART TX）就不行** —— 真正的多拍
    //     设备要在桥里自己保证写只发生一次（见 task book §3 的接口约定）。
    always @(posedge b_clk or posedge b_rst) begin
        if (b_rst) begin
            wait_cnt <= 0;
            b_ready  <= 1'b1;
        end else if (wait_cnt == memwait) begin
            b_ready  <= 1'b1;          // 这一拍之后 ready 拉高，CPU 在下一个沿采数据
            wait_cnt <= 0;
        end else begin
            b_ready  <= 1'b0;
            wait_cnt <= wait_cnt + 1;
        end
    end
endmodule
