`timescale 1ns/1ps
// ============================================================================
// cache_i —— L1 指令 Cache（默认 4 KB、2 路组相联、行 = 1 字；16 KB 把 IDX_BITS 改 11）
// ----------------------------------------------------------------------------
// 默认关（ICACHE_EN=0 时不被例化，取指通路逐位不变）。与 cache_d.v 同构，但有
// 两处结构性不同，改之前必须先看懂。
//
// [!] 一、停顿信号必须先过一级寄存器，否则与 fetch_addr 成组合环。
//   取指口没有就绪信号（契约是"地址发出后恰好 1 拍数据有效"），只能借 mem_ready
//   当取指停顿；而取指地址 fetch_addr 的组合 mux 里有一项 !mem_ready_int，
//   hit_any → stall → mem_ready → fetch_addr → hit_any 是真组合环（PDS 会报，
//   仿真解成不定态）。破法：i_stall_c 纯组合观察，stall_r 寄存一拍后进 mem_ready。
//   代价是停顿比缺失晚一拍，一次缺失共 2 拍（A = 缺失那一下的取指地址）：
//     N   ：发出地址 A，判定 miss → i_stall_c=1，IF/ID 照常锁存上一条
//     N+1 ：stall_r=1 → 冻结，fetch_addr 退回 A；后端 BRAM 读的正是 A，
//           本沿回填这一行（数据 = bram_rdata(N+1) = mem[A]）
//     N+2 ：stall_r=0 放行，imem_rd 走 bypass = mem[A]，IF/ID 对齐锁存
//   [!] 停顿期间地址冻在 A，回填地址直接用当拍 idx 即可，无需另存。
//
// [!] 二、只缓存 A1（imem_addr），A2（imem_addr2）仍直通 BRAM。
//   给 A2 也做 Cache 要多两个数据阵列 + 两套 tag（+16KB），换来的只是配对取指
//   少一次缺失；A2 恒 1 拍就绪、与 A1 天然同拍（停顿期间 imem_addr2 = imem_addr
//   + 1 是组合推导的，一起冻），不缓存它不引入停顿、也不破坏 A1/A2 对齐。
//
// 组织结构、替换策略、复位清扫同 cache_d.v（指令不被写，所以没有 store 通路）。
// ============================================================================
module cache_i #(
    parameter IDX_BITS = 9,         // set 索引位宽 → 512 组（4KB/侧；16KB 用 11）
    parameter TAG_BITS = 6          // tag 位宽 = 15 − IDX_BITS（IDX=9 → 6）
) (
    input  wire        clk,
    input  wire        resetn,

    // ---- 取指口 A1（每个周期都在取指，所以没有 req）----
    input  wire [14:0] word,        // = imem_addr（fetch_addr[16:2]）
    input  wire [31:0] bram_rdata,  // 后端 BRAM 的 A1 读数据（T+1 有效）

    // ---- 输出 ----
    output wire        stall,       // 已寄存的取指停顿，mem_bus 直接压 mem_ready
    output wire [31:0] rdata,       // T+1 的取指数据（= imem_rd）
    output wire        hit_pulse,
    output wire        miss_pulse
);

    localparam NSET = (1 << IDX_BITS);

    // ------------------------------------------------------------------
    // 地址切片
    // ------------------------------------------------------------------
    wire [IDX_BITS-1:0] idx      = word[IDX_BITS-1:0];
    wire [TAG_BITS-1:0] addr_tag = word[14:IDX_BITS];

    // ------------------------------------------------------------------
    // 复位清扫：2048 拍逐个把 tag 阵列的有效位清 0（理由同 cache_d.v）
    // ------------------------------------------------------------------
    reg              rst_busy;
    reg [IDX_BITS:0] rst_cnt;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rst_busy <= 1'b1;
            rst_cnt  <= {IDX_BITS+1{1'b0}};
        end else if (rst_busy) begin
            rst_cnt <= rst_cnt + 1'b1;
            if (rst_cnt == NSET - 1) rst_busy <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // tag 阵列（组合读 → LUTRAM；每项 {valid, recent, tag[TAG_BITS-1:0]}）
    // ------------------------------------------------------------------
    reg [TAG_BITS+1:0] tag0 [0:NSET-1];
    reg [TAG_BITS+1:0] tag1 [0:NSET-1];

    wire [TAG_BITS+1:0] t0 = tag0[idx];
    wire [TAG_BITS+1:0] t1 = tag1[idx];

    wire v0 = t0[TAG_BITS+1];
    wire r0 = t0[TAG_BITS];
    wire v1 = t1[TAG_BITS+1];
    wire r1 = t1[TAG_BITS];
    wire hit0 = !rst_busy && v0 && (t0[TAG_BITS-1:0] == addr_tag);
    wire hit1 = !rst_busy && v1 && (t1[TAG_BITS-1:0] == addr_tag);
    wire hit_any = hit0 | hit1;

    // ------------------------------------------------------------------
    // 数据阵列（同步读 1 拍 —— 与 unified_mem 的 A1 口同相）
    // ------------------------------------------------------------------
    reg [31:0] d0 [0:NSET-1];
    reg [31:0] d1 [0:NSET-1];
    reg [31:0] d0_q, d1_q;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            d0_q <= 32'd0;
            d1_q <= 32'd0;
        end else begin
            d0_q <= d0[idx];
            d1_q <= d1[idx];
        end
    end

    // ------------------------------------------------------------------
    // 停顿（必须是寄存过的，理由见文件头）
    // ------------------------------------------------------------------
    reg stall_r;
    // [!] `&& !stall_r` 是必需的：缺了它，停顿那一拍重新查同一行（还没回填）仍是
    //     miss，会把停顿无限延长。加上它，一次缺失恰好停 1 拍（共 2 拍完成）。
    wire stall_c = !hit_any && !stall_r && !rst_busy;

    // [!] 缺失那一下的 index / tag / 两路 tag 必须存成快照。
    //   停顿那一拍 fetch_addr 虽被冻在 if_addr_d，但 trap / ex_flush / ex_mispred
    //   优先级更高（core.v 的 mux 顺序）、不受 mem_ready 门控，当拍 imem_addr 可能
    //   已跳到重定向目标。若回填用当拍 idx，会把数据写进错误的行，之后命中的就是
    //   错指令 —— 静默坏缓存，完整复盘见 doc/reports/。
    reg [IDX_BITS-1:0] idx_r;
    reg [TAG_BITS-1:0] tag_r;
    reg [TAG_BITS+1:0] t0_r, t1_r;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) stall_r <= 1'b0;
        else         stall_r <= stall_c;
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            idx_r <= {IDX_BITS{1'b0}};
            tag_r <= {TAG_BITS{1'b0}};
            t0_r  <= {TAG_BITS+2{1'b0}};
            t1_r  <= {TAG_BITS+2{1'b0}};
        end else if (stall_c) begin
            idx_r <= idx;
            tag_r <= addr_tag;
            t0_r  <= t0;
            t1_r  <= t1;
        end
    end

    assign stall = stall_r;

    // 回填的 way：优先无效路，其次 recent=0 的那路（NRU）
    // [!] 用的是缺失那一下的快照 t0_r/t1_r，理由见上面 idx_r 的注释。
    wire fv0 = t0_r[TAG_BITS+1];
    wire fv1 = t1_r[TAG_BITS+1];
    wire fr0 = t0_r[TAG_BITS];
    wire fr1 = t1_r[TAG_BITS];
    wire way_fill = !fv0       ? 1'b0 :
                    !fv1       ? 1'b1 :
                    (fr0 & ~fr1) ? 1'b1 : 1'b0;

    // ------------------------------------------------------------------
    // tag 写入：清扫 > 回填 > 命中更新（三级优先）
    // ------------------------------------------------------------------
    wire [TAG_BITS+1:0] upd0 = hit0 ? {1'b1, 1'b1, t0[TAG_BITS-1:0]} :
                             {v0,   1'b0, t0[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] upd1 = hit1 ? {1'b1, 1'b1, t1[TAG_BITS-1:0]} :
                             {v1,   1'b0, t1[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] fil_hit  = {1'b1, 1'b1, tag_r};
    wire [TAG_BITS+1:0] fil_oth0 = {fv0, 1'b0, t0_r[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] fil_oth1 = {fv1, 1'b0, t1_r[TAG_BITS-1:0]};

    wire tag_req = hit_any && !stall_r;         // 命中：更新 recent
    wire tag_fil = stall_r && !rst_busy;        // 停顿那一拍：回填

    wire       tag_we   = rst_busy | tag_fil | tag_req;
    wire [IDX_BITS-1:0] tag_widx = rst_busy ? rst_cnt[IDX_BITS-1:0] :
                                   tag_fil ? idx_r : idx;

    reg [TAG_BITS+1:0] tag0_nxt, tag1_nxt;
    always @(*) begin
        if (rst_busy) begin
            tag0_nxt = {TAG_BITS+2{1'b0}};
            tag1_nxt = {TAG_BITS+2{1'b0}};
        end else if (tag_fil) begin
            tag0_nxt = way_fill ? fil_oth0 : fil_hit;
            tag1_nxt = way_fill ? fil_hit  : fil_oth1;
        end else begin
            tag0_nxt = upd0;
            tag1_nxt = upd1;
        end
    end

    always @(posedge clk) begin
        if (tag_we) begin
            tag0[tag_widx] <= tag0_nxt;
            tag1[tag_widx] <= tag1_nxt;
        end
    end

    // ------------------------------------------------------------------
    // 数据阵列写入：只有回填一条路（指令不被写）
    // ------------------------------------------------------------------
    wire data_fil = tag_fil;

    always @(posedge clk) begin
        if (data_fil) begin
            if (way_fill == 1'b0) d0[idx_r] <= bram_rdata;
            else                  d1[idx_r] <= bram_rdata;
        end
    end

    // ------------------------------------------------------------------
    // 读数据选择
    // ------------------------------------------------------------------
    // [!] 只有"上一拍真的命中"才用阵列数据，其余一律回退后端 BRAM，同时解决：
    //     1) 复位清扫期强制 miss，阵列未初始化的 X 不能送进 imem_rd → IF/ID → PC；
    //     2) 回填那一沿是同址读+写，数据阵列输出不定；
    //     3) 后端 BRAM 每拍都在读同一地址（冻住或没变），回退零代价。
    reg hit0_r, hit1_r;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            hit0_r <= 1'b0;
            hit1_r <= 1'b0;
        end else begin
            hit0_r <= hit0;
            hit1_r <= hit1;
        end
    end

    assign rdata = (hit0_r | hit1_r) ? (hit0_r ? d0_q : d1_q)
                                     : bram_rdata;

    // ------------------------------------------------------------------
    // 计数器脉冲
    // ------------------------------------------------------------------
    assign hit_pulse  = hit_any && !stall_r && !rst_busy;
    assign miss_pulse = stall_c;

endmodule
