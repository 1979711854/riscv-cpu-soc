`timescale 1ns/1ps
// ============================================================================
// cache_d —— L1 数据 Cache（默认 4 KB、2 路组相联、行 = 1 字；16 KB 把 IDX_BITS 改 11）
// ----------------------------------------------------------------------------
// 默认关（mem_bus 的 DCACHE_EN=0 时不被例化，行为逐位不变）。后端是片内单周期
// BRAM，命中 1 拍（零收益）、缺失 2 拍（纯亏），属于"实现并评估后判定为负收益"
// 的功能项，不是涨分项。
//
// 组织结构：默认 512 组（IDX_BITS=9）、2 路、每行 1 字。字地址 = mem_addr[16:2]，
//   index = word[IDX_BITS-1:0]，tag = word[14:IDX_BITS]（128KB 地址空间，tag 很短）。
//   [!] tag 阵列必须组合读（LUTRAM）：访存契约要求 T 拍给地址、T+1 拍 mem_rdata
//       有效，命中/缺失必须在 T 拍当拍知道（mem_ready 是 T 拍组合信号，晚一拍 WB
//       就把错数据写进寄存器堆了），同步读的 tag 阵列做不到。
//
// 时序（T = 访问在 MEM 级的那一拍）：
//   T   ：req/word 有效，tag 组合读出；load 缺失 → stall=1 → core 冻结
//   T+1 ：数据阵列输出 d0_q/d1_q，way 选择用 T 拍寄存的 hit0_r/hit1_r；
//         缺失走 bypass（直通后端 BRAM），并在这一沿回填该行
//   T+2 ：缺失的 load 这时才进 WB，bypass 必须持续两拍（见 bypass_r 注释）
//
// 写策略：写通 + 写命中更新 + 缺失不分配。
//   任何 store 都照旧组合打进后端 BRAM，所以 st_ld / fence.i 语义与不带 Cache
//   时一致；store 命中时同一沿把数据写进命中路，后续 load 不用等回填；缺失不
//   分配，"存完立刻读回"两种情况都拿到 BRAM 新值，不存在读到陈旧行。
//   [!] 命中判定是组合的，store 的 way 在 T 拍就知道，"写通路零寄存器"契约
//       没有被破坏（store 仍 1 拍完成）。
//
// 替换策略：每项 1 位 recent（NRU 近似 LRU）—— 命中/回填置本路 1、另一路 0；
//   回填优先无效路，其次 recent=0 的路。
//
// [!] 复位：上电用 2048 拍清扫 tag 有效位；清扫期间强制命中为 0，所有访存走
//     BRAM 直通 —— 不读 LUTRAM 上电不定值，比指望 LUTRAM 上电为 0 可靠。
// ============================================================================
module cache_d #(
    parameter IDX_BITS = 9,         // set 索引位宽 → 512 组（4KB/侧；16KB 用 11）
    parameter TAG_BITS = 6          // tag 位宽 = 15 − IDX_BITS（IDX=9 → 6）
) (
    input  wire        clk,
    input  wire        resetn,

    // ---- MEM 拍的访问请求（与 mem_bus 的 ram_hit && (mem_re|mem_we) 同相）----
    input  wire        req,
    input  wire        we,          // 1 = store
    input  wire [14:0] word,        // 字索引 = mem_addr[16:2]
    input  wire [31:0] wdata,       // store 数据（已按字节复制）
    input  wire [3:0]  be,          // store 字节使能

    // ---- 后端 BRAM 读数据（T+1 有效，与 rsel_d 同拍）----
    input  wire [31:0] bram_rdata,

    // ---- 输出 ----
    output wire        stall,       // 1 = 本次 load 缺失，mem_bus 需压 mem_ready
    output wire [31:0] rdata,       // T+1 的访存读数据
    output wire        hit_pulse,   // 计数用：一次命中的 load
    output wire        miss_pulse   // 计数用：一次缺失的 load
);

    localparam NSET = (1 << IDX_BITS);

    // ------------------------------------------------------------------
    // 地址切片
    // ------------------------------------------------------------------
    wire [IDX_BITS-1:0] idx      = word[IDX_BITS-1:0];
    wire [TAG_BITS-1:0] addr_tag = word[14:IDX_BITS];

    // ------------------------------------------------------------------
    // 复位清扫：2048 拍逐个把两个 tag 阵列的有效位清 0
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
    // [!] 清扫期间强制不命中（理由见文件头）
    wire hit0 = !rst_busy && v0 && (t0[TAG_BITS-1:0] == addr_tag);
    wire hit1 = !rst_busy && v1 && (t1[TAG_BITS-1:0] == addr_tag);

    // ------------------------------------------------------------------
    // 数据阵列（同步读 1 拍 —— 与 unified_mem 的 B 口同相）
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
    // T 拍：命中/缺失判定 + 停顿
    // ------------------------------------------------------------------
    wire load = req && !we;

    // 回填那一拍（miss_r=1）不再判缺失，否则会无限停顿
    reg miss_r;
    wire stall_c = load && !hit0 && !hit1 && !miss_r;

    assign stall = stall_c;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) miss_r <= 1'b0;
        else         miss_r <= stall_c;
    end

    // T 拍命中的 way（组合），store 的回写与 recent 更新都用它
    wire hit_any = hit0 | hit1;
    wire way_hit = hit1 & ~hit0;            // 0 = way0 命中，1 = way1 命中

    // 回填的 way：优先无效路，其次 recent=0 的那路（NRU）
    wire way_fill = !v0       ? 1'b0 :
                    !v1       ? 1'b1 :
                    (r0 & ~r1) ? 1'b1 : 1'b0;

    // ------------------------------------------------------------------
    // tag 写入：清扫 > 回填 > 命中更新（三级优先）
    // ------------------------------------------------------------------
    // 命中更新：命中路 recent=1，另一路 recent=0（tag/valid 原样写回）
    wire [TAG_BITS+1:0] upd0 = hit0 ? {1'b1, 1'b1, t0[TAG_BITS-1:0]} :
                             {v0,   1'b0, t0[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] upd1 = hit1 ? {1'b1, 1'b1, t1[TAG_BITS-1:0]} :
                             {v1,   1'b0, t1[TAG_BITS-1:0]};
    // 回填：选中路装新 tag 且 recent=1，另一路 recent=0
    wire [TAG_BITS+1:0] fil_hit  = {1'b1, 1'b1, addr_tag};
    wire [TAG_BITS+1:0] fil_oth0 = {v0, 1'b0, t0[TAG_BITS-1:0]};
    wire [TAG_BITS+1:0] fil_oth1 = {v1, 1'b0, t1[TAG_BITS-1:0]};

    wire tag_req = req && hit_any;              // T 拍命中：更新 recent
    wire tag_fil = miss_r && !rst_busy;         // T+1 拍：回填

    wire       tag_we  = rst_busy | tag_fil | tag_req;
    wire [IDX_BITS-1:0] tag_widx = rst_busy ? rst_cnt[IDX_BITS-1:0] : idx;

    reg [TAG_BITS+1:0] tag0_nxt, tag1_nxt;
    always @(*) begin
        if (rst_busy) begin
            tag0_nxt = {TAG_BITS+2{1'b0}};                            // {valid=0, ...}
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
    // 数据写入：回填（T+1 拍，整字）> store 命中（T 拍，带字节使能）
    // ------------------------------------------------------------------
    // [!] 必须每路一个单写口：先把来源/地址/数据/字节使能 mux 好，再喂给唯一的
    //   always 写口。写成两个来源的 if/else if 会让综合器推不出 BRAM，把 2048x32
    //   阵列当 FF 展开、卡死在 DFF-inference。规则：一个存储阵列只能有一个写口，
    //   完整复盘见 doc/reports/。
    wire data_fil = tag_fil;                        // 与回填同拍
    wire data_st  = req && we && hit_any;           // store 命中

    wire [31:0] dw_data = data_fil ? bram_rdata : wdata;
    wire [3:0]  dw_be   = data_fil ? 4'b1111    : be;

    wire dw0 = data_fil ? (way_fill == 1'b0) : (data_st && (way_hit == 1'b0));
    wire dw1 = data_fil ? (way_fill == 1'b1) : (data_st && (way_hit == 1'b1));

    always @(posedge clk) begin
        if (dw0) begin
            if (dw_be[0]) d0[idx][ 7: 0] <= dw_data[ 7: 0];
            if (dw_be[1]) d0[idx][15: 8] <= dw_data[15: 8];
            if (dw_be[2]) d0[idx][23:16] <= dw_data[23:16];
            if (dw_be[3]) d0[idx][31:24] <= dw_data[31:24];
        end
    end

    always @(posedge clk) begin
        if (dw1) begin
            if (dw_be[0]) d1[idx][ 7: 0] <= dw_data[ 7: 0];
            if (dw_be[1]) d1[idx][15: 8] <= dw_data[15: 8];
            if (dw_be[2]) d1[idx][23:16] <= dw_data[23:16];
            if (dw_be[3]) d1[idx][31:24] <= dw_data[31:24];
        end
    end

    // ------------------------------------------------------------------
    // 读数据选择
    // ------------------------------------------------------------------
    // [!] bypass 必须持续两拍：
    //   T+1 拍 —— load 还冻在 MEM 级，这一沿才把行回填进去，数据阵列还没更新，
    //             所以只能借后端 BRAM 的 ram_rdata（它正是本条 load 的字）。
    //   T+2 拍 —— 缺失的 load 这时才进 WB 写寄存器堆，而 mem_rdata 服务的是
    //             「上一拍给出的地址」，也就是仍被冻住的这条 load 的地址；
    //             若此时改用数据阵列，会和刚发生的回填撞成"同址读写"（读出新旧
    //             不定），所以照样走 BRAM 直通，而 ram_rdata 仍是同一个字。
    reg [1:0] bypass_r;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) bypass_r <= 2'b00;
        else         bypass_r <= {bypass_r[0], stall_c};
    end

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

    assign rdata = (|bypass_r) ? bram_rdata :
                   (hit0_r    ? d0_q : d1_q);

    // ------------------------------------------------------------------
    // 计数器脉冲（只统计 load）
    // ------------------------------------------------------------------
    assign hit_pulse  = req && !we &&  hit_any     && !rst_busy;
    assign miss_pulse = stall_c;

endmodule
