# =============================================================================
# ila_capture_20261019.tcl —— 抓 2026-10-19 调试版（双发射 + CoreMark，92 通道）
# -----------------------------------------------------------------------------
# 用法：PDS → TOOL → Debugger → 底部 TCLConsole（View → Console），然后
#         source D:/riscv-cpu-fpga_merged/scripts/ila_capture_20261019.tcl
#
# 配套文件（必须成对，来自同一次综合/布线）：
#   位流  pds/RV32I_1/cpu_top_board_ila_20261019_a6d0d877.sbit
#   fic   pds/RV32I_1/cpu_top_board_ila_20261019.fic
#   固件  CoreMark（mem.hex 22,728 行，coremark.elf md5 d83e…）
#
# [!] 前置条件
#   1) 板子里烧的是上面那份【调试版】位流，不是生产版；
#   2) 已连上 JTAG Server（127.0.0.1:65420）。
#      判据：先单独敲 dbg_list，应显示
#        Data sample width = 92
#        Number of trigger ports = 2
#      什么都不列 = 没连上，或 FPGA 里没有 DebugCore。别往下走。
#
# 通道映射（全在 u_soc/u_core 里，详见 rtl/core/ila_probes.vh）：
#   [0..14]   pc[14:0]            [15..29] if_id_pc[14:0]
#   [30..44]  id_ex_pc[14:0]      [45..59] ex_mem_pc[14:0]
#   [60..66]  if_id_instr[6:0]    [67] stall        [68] div_stall
#   [69] ex_flush                 [70] id_ex_mem_read
#   [71..74] fwd_a_ex / fwd_b_ex / fwd_a_wb / fwd_b_wb
#   [75] id_ex_branch             [76] branch_taken  [77] mem_we
#   [78] mem_re                   [79] mem_wb_reg_write
#   [80] bht_hit_p                [81] bht_taken_p   [82] p_pred_taken
#   [83] p_redirect               [84] ex_mispred    [85] id_ex_pred_taken
#   [86] pair_now                 [87] if_id_pair    [88] ex_mem_b_valid
#   [89] p_ras_hit                [90] p_btb_pred    [91] mem_wb_b_we
#
# 触发口只有 2 个：
#   TU0 = ila_ex_flush   分支/跳转冲刷（单拍脉冲，电平 1 与上升沿效果几乎一样）
#   TU1 = ila_trig_cm    pc ∈ [0x231C, 0x315C)，即 core_bench_list
#                        （地址已用当前 coremark.elf 的 nm 重新核对过）
# =============================================================================

set FIC D:/riscv-cpu-fpga_merged/pds/RV32I_1/cpu_top_board_ila_20261019.fic

# ---- 0) 链路自检：应为 width=92 / trigger ports=2 ----------------------------
# 没连服务端时先取消下面一行的注释：
# dbg_connect -ip 127.0.0.1 -port 65420
dbg_list

# ---- 1) 导入 fic：给 92 个通道安上信号名 --------------------------------
dbg_import_fic -file $FIC

# ---- 2) 合成 5 条总线 -------------------------------------------------------
# [!] 顺序不能颠倒：先建总线，再 add_all_to_waveform。
#     重复执行时先删掉旧的，避免 "bus name:XX already exists"。
foreach b {PC IFID_PC IDEX_PC EXMEM_PC OPCODE} {
    catch {dbg_del_bus -name $b}
}
dbg_add_bus -name PC        -channel 0-14
dbg_set_bus_radix -name PC -radix 2          ;# radix 2 = Hex
dbg_add_bus -name IFID_PC   -channel 15-29
dbg_set_bus_radix -name IFID_PC -radix 2
dbg_add_bus -name IDEX_PC   -channel 30-44
dbg_set_bus_radix -name IDEX_PC -radix 2
dbg_add_bus -name EXMEM_PC  -channel 45-59
dbg_set_bus_radix -name EXMEM_PC -radix 2
dbg_add_bus -name OPCODE    -channel 60-66
dbg_set_bus_radix -name OPCODE -radix 2
dbg_get_buses                                ;# 应为 5 条，且通道号正确

# ---- 3) 波形视图 ------------------------------------------------------------
dbg_clear_all_to_waveform
dbg_add_all_to_waveform

# ---- 4) 捕获设置：深度 4096（≈53.6 µs @76.5MHz）、触发点居中 -----------------
# [!] -windows 1 时深度自动取核的最大深度 4096，不能同时给 -depth。
#     触发点放在正中，才能看到触发前后的"前因后果"。
dbg_set_capture -type 0 -windows 1 -position 2048

# ---- 5) 默认触发：TU0 = ex_flush（分支冲刷）---------------------------------
# [!] 换触发必须改【两处】：dbg_set_unit 改 TU 的值，
#     再用 dbg_set_condition -select 0 -set "TU<N>" 把公式指过去。
#     只改 -unit 的话条件还指向旧 TU（2026-09-25 实踩）。
dbg_set_unit -unit 0 -func "==" -value 1
dbg_set_condition                            ;# 裸跑应先看到 TriggerCondition0
dbg_set_condition -select 0 -set "TU0"

# ---- 6) 开抓 -----------------------------------------------------------------
# 敲完 dbg_run 立刻按板上【丝印 KEY1】（手册 KEY0，管脚 C22，复位键），
# 让 CoreMark 从头重跑 —— 否则程序跑完停在 while(1) 自旋，等不到触发。
dbg_run

# =============================================================================
# 换触发：TU1 = core_bench_list（看链表热点区）
#   dbg_set_unit -unit 1 -func "==" -value 1
#   dbg_set_condition -select 0 -set "TU1"
#   dbg_run
#   （然后按 KEY1 复位）
#
# 抓完核对：Position=2048 居中，所以采样点 2048 那一拍，
#   对应的触发信号必须是 1。不是 1 说明触发没换成功。
#
# 导出：
#   File → Export sample data → VCD（GTKWave 可开）或 TXT（干净数值表）
#   File → Save Project As → .dprj（波形 + 总线 + 设置全部原样恢复）
#
# 波形窗口里会同时出现 5 条总线和 92 根裸位（组合成总线不会移除原信号）。
# 想要报告用的干净视图，手工：
#   1) 右键 DataPorts → Clear All → Waveform
#   2) ctrl 点选下面这些 + 5 条总线 → Add to View → Waveform
#   PC / IFID_PC / IDEX_PC / EXMEM_PC / OPCODE
#   ila_ex_flush(69)      ila_id_ex_branch(75)  ila_branch_taken(76)
#   ila_stall(67)         ila_id_ex_mem_read(70)
#   ila_bht_hit_p(80)     ila_bht_taken_p(81)   ila_p_pred_taken(82)
#   ila_p_redirect(83)    ila_ex_mispred(84)    ila_id_ex_pred_taken(85)
#   ila_pair_now(86)      ila_if_id_pair(87)    ila_ex_mem_b_valid(88)
#   ila_p_ras_hit(89)     ila_p_btb_pred(90)    ila_mem_wb_b_we(91)
# =============================================================================
