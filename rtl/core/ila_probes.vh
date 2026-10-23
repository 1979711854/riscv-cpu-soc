/* ============================================================================
 * ila_probes.vh —— ILA 硬件在环探针束（Pango Fabric Inserter）
 *
 * [!] 本文件默认不被 core.v 包含。抓 ILA 波形时：
 *      1) 在 rtl/core/core.v 的 endmodule 之前加一行
 *             `include "ila_probes.vh"
 *      2) 综合 → Fabric Inserter（GUI 或 ins_* TCL）生成 .fic → 登记进 .pds
 *      3) P&R 出调试位流 → 烧板 → 抓波形
 *      4) 采完必须删掉那行并重出生产位流 —— 探针会改净表 ⇒ 钉住的
 *         gplace_seed 5 余量作废（实测 LUT +122 就把 +0.277 打成 −0.156 ns）
 *
 * 通道分配见 doc/ila_analysis.md §7.1（本文按 rev1027 更新：BHT 信号改名 +
 * 新增 lane B / RAS / BTB）。
 *
 * [!] 属性格式是精确形式 `PAP_MARK_DEBUG="<核号/端口类型+序号/通道号>"`：
 *         0 = 调试核号；d = data port、t = trigger port、c = clock port
 *         例：`"<0/d0/0>"` = 核0 的数据口 0 的 channel 0
 *         `"<0/d0/69>,<0/t0/0>"` = 同一个信号同时进数据口和触发口
 *   [!] 不能只写 `<数字>` —— 那既不是模糊形式（true/1）也不是精确形式，
 *       Inserter 的通道分配会整体错位（症状：波形有信号但全不对，极难排查）。
 *       [!] 但 ex_flush / stall 这类触发信号不靠通道号排序 —— 它们由
 *       标记里的 t0/t1 显式指定，所以数据位增删不会挪动触发口。
 *
 * 三条承重约束（都踩过）：
 *   - 约定 30：属性挂在声明上、且在分号之前；syn_keep 与 PAP_MARK_DEBUG 两个都写
 *   - 约定 31：多比特 wire 上的 PAP_MARK_DEBUG 会被综合整条丢弃 ⇒ 总线拆单 bit
 *   - 约定 32：Inserter 不列模块端口 ⇒ 探针必须是内部别名 wire
 *============================================================================ */

// ---- 采样时钟：调试核 0 的 clock port（Clock/Reset 只有 1 个 channel）----
wire ila_clk_sys                   /* synthesis PAP_MARK_DEBUG="<0/c0/0>" syn_keep=1 */ = clk;


// ---- pc[14:0]  [0:14]  取指 PC（网表里叫 pc，不是 pc_r） ----
wire ila_pc_0                     /* synthesis PAP_MARK_DEBUG="<0/d0/0>" syn_keep=1 */ = pc[0];
wire ila_pc_1                     /* synthesis PAP_MARK_DEBUG="<0/d0/1>" syn_keep=1 */ = pc[1];
wire ila_pc_2                     /* synthesis PAP_MARK_DEBUG="<0/d0/2>" syn_keep=1 */ = pc[2];
wire ila_pc_3                     /* synthesis PAP_MARK_DEBUG="<0/d0/3>" syn_keep=1 */ = pc[3];
wire ila_pc_4                     /* synthesis PAP_MARK_DEBUG="<0/d0/4>" syn_keep=1 */ = pc[4];
wire ila_pc_5                     /* synthesis PAP_MARK_DEBUG="<0/d0/5>" syn_keep=1 */ = pc[5];
wire ila_pc_6                     /* synthesis PAP_MARK_DEBUG="<0/d0/6>" syn_keep=1 */ = pc[6];
wire ila_pc_7                     /* synthesis PAP_MARK_DEBUG="<0/d0/7>" syn_keep=1 */ = pc[7];
wire ila_pc_8                     /* synthesis PAP_MARK_DEBUG="<0/d0/8>" syn_keep=1 */ = pc[8];
wire ila_pc_9                     /* synthesis PAP_MARK_DEBUG="<0/d0/9>" syn_keep=1 */ = pc[9];
wire ila_pc_10                    /* synthesis PAP_MARK_DEBUG="<0/d0/10>" syn_keep=1 */ = pc[10];
wire ila_pc_11                    /* synthesis PAP_MARK_DEBUG="<0/d0/11>" syn_keep=1 */ = pc[11];
wire ila_pc_12                    /* synthesis PAP_MARK_DEBUG="<0/d0/12>" syn_keep=1 */ = pc[12];
wire ila_pc_13                    /* synthesis PAP_MARK_DEBUG="<0/d0/13>" syn_keep=1 */ = pc[13];
wire ila_pc_14                    /* synthesis PAP_MARK_DEBUG="<0/d0/14>" syn_keep=1 */ = pc[14];

// ---- if_id_pc[14:0]  [15:29]  ID 级 PC ----
wire ila_if_id_pc_0               /* synthesis PAP_MARK_DEBUG="<0/d0/15>" syn_keep=1 */ = if_id_pc[0];
wire ila_if_id_pc_1               /* synthesis PAP_MARK_DEBUG="<0/d0/16>" syn_keep=1 */ = if_id_pc[1];
wire ila_if_id_pc_2               /* synthesis PAP_MARK_DEBUG="<0/d0/17>" syn_keep=1 */ = if_id_pc[2];
wire ila_if_id_pc_3               /* synthesis PAP_MARK_DEBUG="<0/d0/18>" syn_keep=1 */ = if_id_pc[3];
wire ila_if_id_pc_4               /* synthesis PAP_MARK_DEBUG="<0/d0/19>" syn_keep=1 */ = if_id_pc[4];
wire ila_if_id_pc_5               /* synthesis PAP_MARK_DEBUG="<0/d0/20>" syn_keep=1 */ = if_id_pc[5];
wire ila_if_id_pc_6               /* synthesis PAP_MARK_DEBUG="<0/d0/21>" syn_keep=1 */ = if_id_pc[6];
wire ila_if_id_pc_7               /* synthesis PAP_MARK_DEBUG="<0/d0/22>" syn_keep=1 */ = if_id_pc[7];
wire ila_if_id_pc_8               /* synthesis PAP_MARK_DEBUG="<0/d0/23>" syn_keep=1 */ = if_id_pc[8];
wire ila_if_id_pc_9               /* synthesis PAP_MARK_DEBUG="<0/d0/24>" syn_keep=1 */ = if_id_pc[9];
wire ila_if_id_pc_10              /* synthesis PAP_MARK_DEBUG="<0/d0/25>" syn_keep=1 */ = if_id_pc[10];
wire ila_if_id_pc_11              /* synthesis PAP_MARK_DEBUG="<0/d0/26>" syn_keep=1 */ = if_id_pc[11];
wire ila_if_id_pc_12              /* synthesis PAP_MARK_DEBUG="<0/d0/27>" syn_keep=1 */ = if_id_pc[12];
wire ila_if_id_pc_13              /* synthesis PAP_MARK_DEBUG="<0/d0/28>" syn_keep=1 */ = if_id_pc[13];
wire ila_if_id_pc_14              /* synthesis PAP_MARK_DEBUG="<0/d0/29>" syn_keep=1 */ = if_id_pc[14];

// ---- id_ex_pc[14:0]  [30:44]  EX 级 PC ----
wire ila_id_ex_pc_0               /* synthesis PAP_MARK_DEBUG="<0/d0/30>" syn_keep=1 */ = id_ex_pc[0];
wire ila_id_ex_pc_1               /* synthesis PAP_MARK_DEBUG="<0/d0/31>" syn_keep=1 */ = id_ex_pc[1];
wire ila_id_ex_pc_2               /* synthesis PAP_MARK_DEBUG="<0/d0/32>" syn_keep=1 */ = id_ex_pc[2];
wire ila_id_ex_pc_3               /* synthesis PAP_MARK_DEBUG="<0/d0/33>" syn_keep=1 */ = id_ex_pc[3];
wire ila_id_ex_pc_4               /* synthesis PAP_MARK_DEBUG="<0/d0/34>" syn_keep=1 */ = id_ex_pc[4];
wire ila_id_ex_pc_5               /* synthesis PAP_MARK_DEBUG="<0/d0/35>" syn_keep=1 */ = id_ex_pc[5];
wire ila_id_ex_pc_6               /* synthesis PAP_MARK_DEBUG="<0/d0/36>" syn_keep=1 */ = id_ex_pc[6];
wire ila_id_ex_pc_7               /* synthesis PAP_MARK_DEBUG="<0/d0/37>" syn_keep=1 */ = id_ex_pc[7];
wire ila_id_ex_pc_8               /* synthesis PAP_MARK_DEBUG="<0/d0/38>" syn_keep=1 */ = id_ex_pc[8];
wire ila_id_ex_pc_9               /* synthesis PAP_MARK_DEBUG="<0/d0/39>" syn_keep=1 */ = id_ex_pc[9];
wire ila_id_ex_pc_10              /* synthesis PAP_MARK_DEBUG="<0/d0/40>" syn_keep=1 */ = id_ex_pc[10];
wire ila_id_ex_pc_11              /* synthesis PAP_MARK_DEBUG="<0/d0/41>" syn_keep=1 */ = id_ex_pc[11];
wire ila_id_ex_pc_12              /* synthesis PAP_MARK_DEBUG="<0/d0/42>" syn_keep=1 */ = id_ex_pc[12];
wire ila_id_ex_pc_13              /* synthesis PAP_MARK_DEBUG="<0/d0/43>" syn_keep=1 */ = id_ex_pc[13];
wire ila_id_ex_pc_14              /* synthesis PAP_MARK_DEBUG="<0/d0/44>" syn_keep=1 */ = id_ex_pc[14];

// ---- ex_mem_pc[14:0]  [45:59]  MEM 级 PC ----
wire ila_ex_mem_pc_0              /* synthesis PAP_MARK_DEBUG="<0/d0/45>" syn_keep=1 */ = ex_mem_pc[0];
wire ila_ex_mem_pc_1              /* synthesis PAP_MARK_DEBUG="<0/d0/46>" syn_keep=1 */ = ex_mem_pc[1];
wire ila_ex_mem_pc_2              /* synthesis PAP_MARK_DEBUG="<0/d0/47>" syn_keep=1 */ = ex_mem_pc[2];
wire ila_ex_mem_pc_3              /* synthesis PAP_MARK_DEBUG="<0/d0/48>" syn_keep=1 */ = ex_mem_pc[3];
wire ila_ex_mem_pc_4              /* synthesis PAP_MARK_DEBUG="<0/d0/49>" syn_keep=1 */ = ex_mem_pc[4];
wire ila_ex_mem_pc_5              /* synthesis PAP_MARK_DEBUG="<0/d0/50>" syn_keep=1 */ = ex_mem_pc[5];
wire ila_ex_mem_pc_6              /* synthesis PAP_MARK_DEBUG="<0/d0/51>" syn_keep=1 */ = ex_mem_pc[6];
wire ila_ex_mem_pc_7              /* synthesis PAP_MARK_DEBUG="<0/d0/52>" syn_keep=1 */ = ex_mem_pc[7];
wire ila_ex_mem_pc_8              /* synthesis PAP_MARK_DEBUG="<0/d0/53>" syn_keep=1 */ = ex_mem_pc[8];
wire ila_ex_mem_pc_9              /* synthesis PAP_MARK_DEBUG="<0/d0/54>" syn_keep=1 */ = ex_mem_pc[9];
wire ila_ex_mem_pc_10             /* synthesis PAP_MARK_DEBUG="<0/d0/55>" syn_keep=1 */ = ex_mem_pc[10];
wire ila_ex_mem_pc_11             /* synthesis PAP_MARK_DEBUG="<0/d0/56>" syn_keep=1 */ = ex_mem_pc[11];
wire ila_ex_mem_pc_12             /* synthesis PAP_MARK_DEBUG="<0/d0/57>" syn_keep=1 */ = ex_mem_pc[12];
wire ila_ex_mem_pc_13             /* synthesis PAP_MARK_DEBUG="<0/d0/58>" syn_keep=1 */ = ex_mem_pc[13];
wire ila_ex_mem_pc_14             /* synthesis PAP_MARK_DEBUG="<0/d0/59>" syn_keep=1 */ = ex_mem_pc[14];

// ---- if_id_instr[6:0]  [60:66]  只取 opcode[6:0] ----
wire ila_if_id_instr_0            /* synthesis PAP_MARK_DEBUG="<0/d0/60>" syn_keep=1 */ = if_id_instr[0];
wire ila_if_id_instr_1            /* synthesis PAP_MARK_DEBUG="<0/d0/61>" syn_keep=1 */ = if_id_instr[1];
wire ila_if_id_instr_2            /* synthesis PAP_MARK_DEBUG="<0/d0/62>" syn_keep=1 */ = if_id_instr[2];
wire ila_if_id_instr_3            /* synthesis PAP_MARK_DEBUG="<0/d0/63>" syn_keep=1 */ = if_id_instr[3];
wire ila_if_id_instr_4            /* synthesis PAP_MARK_DEBUG="<0/d0/64>" syn_keep=1 */ = if_id_instr[4];
wire ila_if_id_instr_5            /* synthesis PAP_MARK_DEBUG="<0/d0/65>" syn_keep=1 */ = if_id_instr[5];
wire ila_if_id_instr_6            /* synthesis PAP_MARK_DEBUG="<0/d0/66>" syn_keep=1 */ = if_id_instr[6];
wire ila_stall                    /* synthesis PAP_MARK_DEBUG="<0/d0/67>" syn_keep=1 */ = stall;   // [67] load-use 停顿（只作数据，触发口改给 ila_trig_cm）
wire ila_div_stall                /* synthesis PAP_MARK_DEBUG="<0/d0/68>" syn_keep=1 */ = div_stall;   // [68] 多拍除法停顿
wire ila_ex_flush                 /* synthesis PAP_MARK_DEBUG="<0/d0/69>,<0/t0/0>" syn_keep=1 */ = ex_flush;   // [69] 冲刷  ← 兼作 Trigger Port 0（首推触发信号）
wire ila_id_ex_mem_read           /* synthesis PAP_MARK_DEBUG="<0/d0/70>" syn_keep=1 */ = id_ex_mem_read;   // [70] EX 级是 load
wire ila_fwd_a_ex                 /* synthesis PAP_MARK_DEBUG="<0/d0/71>" syn_keep=1 */ = fwd_a_ex;   // [71] EX/MEM 前递 rs1
wire ila_fwd_b_ex                 /* synthesis PAP_MARK_DEBUG="<0/d0/72>" syn_keep=1 */ = fwd_b_ex;   // [72] EX/MEM 前递 rs2
wire ila_fwd_a_wb                 /* synthesis PAP_MARK_DEBUG="<0/d0/73>" syn_keep=1 */ = fwd_a_wb;   // [73] MEM/WB 前递 rs1
wire ila_fwd_b_wb                 /* synthesis PAP_MARK_DEBUG="<0/d0/74>" syn_keep=1 */ = fwd_b_wb;   // [74] MEM/WB 前递 rs2
wire ila_id_ex_branch             /* synthesis PAP_MARK_DEBUG="<0/d0/75>" syn_keep=1 */ = id_ex_branch;   // [75] EX 级是分支
wire ila_branch_taken             /* synthesis PAP_MARK_DEBUG="<0/d0/76>" syn_keep=1 */ = branch_taken;   // [76] 分支条件结果
wire ila_mem_we                   /* synthesis PAP_MARK_DEBUG="<0/d0/77>" syn_keep=1 */ = mem_we;   // [77] 访存写使能
wire ila_mem_re                   /* synthesis PAP_MARK_DEBUG="<0/d0/78>" syn_keep=1 */ = mem_re;   // [78] 访存读使能
wire ila_mem_wb_reg_write         /* synthesis PAP_MARK_DEBUG="<0/d0/79>" syn_keep=1 */ = mem_wb_reg_write;   // [79] WB 回写
wire ila_bht_hit_p                /* synthesis PAP_MARK_DEBUG="<0/d0/80>" syn_keep=1 */ = bht_hit_p;   // [80] BHT 命中
wire ila_bht_taken_p              /* synthesis PAP_MARK_DEBUG="<0/d0/81>" syn_keep=1 */ = bht_taken_p;   // [81] BHT 预测方向
wire ila_p_pred_taken             /* synthesis PAP_MARK_DEBUG="<0/d0/82>" syn_keep=1 */ = p_pred_taken;   // [82] 到达级预测结果
wire ila_p_redirect               /* synthesis PAP_MARK_DEBUG="<0/d0/83>" syn_keep=1 */ = p_redirect;   // [83] 到达级实际生效的重定向
wire ila_ex_mispred               /* synthesis PAP_MARK_DEBUG="<0/d0/84>" syn_keep=1 */ = ex_mispred;   // [84] 预测 taken 实际 not-taken
wire ila_id_ex_pred_taken         /* synthesis PAP_MARK_DEBUG="<0/d0/85>" syn_keep=1 */ = id_ex_pred_taken;   // [85] 该指令在 ID 级实际预测重定向过
wire ila_pair_now                 /* synthesis PAP_MARK_DEBUG="<0/d0/86>" syn_keep=1 */ = pair_now;   // [86] 双发射：本拍真的配成一对
wire ila_if_id_pair               /* synthesis PAP_MARK_DEBUG="<0/d0/87>" syn_keep=1 */ = if_id_pair;   // [87] IF/ID 这一对是否成立
wire ila_ex_mem_b_valid           /* synthesis PAP_MARK_DEBUG="<0/d0/88>" syn_keep=1 */ = ex_mem_b_valid;   // [88] lane B 在 MEM 级有效
wire ila_p_ras_hit                /* synthesis PAP_MARK_DEBUG="<0/d0/89>" syn_keep=1 */ = p_ras_hit;   // [89] RAS 命中（ret）
wire ila_p_btb_pred               /* synthesis PAP_MARK_DEBUG="<0/d0/90>" syn_keep=1 */ = p_btb_pred;   // [90] BTB 预测 jalr 目标命中

// ---- [91] lane B 写回 —— 双发射提交计数（只探 lane A 的 mem_wb_reg_write 会漏算一半）----
wire ila_mem_wb_b_we              /* synthesis PAP_MARK_DEBUG="<0/d0/91>" syn_keep=1 */ = mem_wb_b_reg_write;

// ---- 触发口 1：PC 落在 CoreMark 关键算法区时触发 ----
//   区间来自 sim/programs/coremark.elf 的 nm 符号表：
//     core_bench_list  0x231C..0x315C（链表：CoreMark 最热的一段）
//     matrix_test      0x3E44..0x4B2C
//     core_bench_state 0x5D80..0x6358
//     crc16/crcu*      0x63C0..0x6D2C
//   [!] 换了固件 / 链接脚本 / ITER 之外的编译选项，地址都会变 —— 重抓前用
//       `riscv-none-elf-nm -S coremark.elf` 重新核对，别照抄。
//   [!] pc 是字节地址，探针只取 pc[14:0]（32 KB）。本区间 <0x8000 不受影响；
//       若要观察 ee_printf(0x899C) 等 0x8000 以上的区段，需把低位探针扩到 16 位。
wire ila_trig_cm                  /* synthesis PAP_MARK_DEBUG="<0/t1/0>" syn_keep=1 */ =
        (pc >= 32'h0000_231C) && (pc < 32'h0000_315C);

/* 合计 91 位数据通道 + 1 个时钟通道 + 2 个触发口(ex_flush=t0, stall=t1)。
 * DebugCore 触发比较单元上限 256 位，余量充足（doc §7.1）。 */
