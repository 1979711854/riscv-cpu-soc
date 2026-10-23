# =============================================================================
# ila_restore_view.tcl —— Debugger 关掉/崩溃后，一条命令恢复波形视图
# -----------------------------------------------------------------------------
# 用法：在 PDS 的 Debugger 里打开 TCLConsole，然后：
#         source D:/riscv-cpu-fpga/scripts/ila_restore_view.tcl
#
# 为什么需要这个：总线定义（PC / IFID_PC / ...）**不会**自动保存 ——
# 只有 File -> Save Project As 存出 .dprj 才会连总线一起落盘。
# 所以 Debugger 一关，SignalTree 里就只剩 86 根裸位，得重建。
# （波形数据本身会自动落到 pds/RV32I_1/data.wf，那个不会丢。）
#
# [!] 前置条件：得先连上 JTAG Server 并扫到核。没做的话先跑：
#         dbg_connect -ip 127.0.0.1 -port 65420
#         dbg_scan_chain
#     （报 "the connection is disconnected" 就是没连）
# =============================================================================

set FIC  D:/riscv-cpu-fpga/pds/RV32I_1/cpu_top_board.fic

# ---- 第 1 步：导入 .fic，给 86 个通道安上信号名 ----
dbg_import_fic -file $FIC

# ---- 第 2 步：重建 5 条总线（通道号见 doc/ila_analysis.md §7.1）----
# [!] 如果报 "bus name:XX already exists"，说明那条还在，跳过即可。
dbg_add_bus -name PC        -channel 0-14
dbg_set_bus_radix -name PC -radix 2

dbg_add_bus -name IFID_PC   -channel 15-29
dbg_set_bus_radix -name IFID_PC -radix 2

dbg_add_bus -name IDEX_PC   -channel 30-44
dbg_set_bus_radix -name IDEX_PC -radix 2

dbg_add_bus -name EXMEM_PC  -channel 45-59
dbg_set_bus_radix -name EXMEM_PC -radix 2

dbg_add_bus -name OPCODE    -channel 60-66
dbg_set_bus_radix -name OPCODE -radix 2

# ---- 第 3 步：核对 ----
# 应该列出 5 条总线，且每条包含正确的通道（dbg_pc0..dbg_pc14 等）
dbg_get_buses

# ---- 第 4 步：清空波形显示，再把（含总线的）全部信号加载进去 ----
# 顺序不能颠倒：add_all 加的是"此刻信号树里已有的东西"。
dbg_clear_all_to_waveform
dbg_add_all_to_waveform

# -----------------------------------------------------------------------------
# [!] 这一步之后波形里会是 5 条总线 **加** 86 根裸位 —— 因为组合成总线
#     并不会移除原信号（手册 §5.2.1），两者在 SignalTree 里并存。
#
#     想要清爽的视图，得手工挑一遍（TCL 没有"只加某一根"的命令）：
#       1. 右键 SignalTree 的 DataPorts 节点 -> Clear All -> Waveform
#       2. ctrl 点选下面这 13 根 + 5 条总线
#       3. 任选中项右键 -> Add to View -> Waveform
#
#     建议只加这些（通道号在括号里）：
#       dbg_ex_flush(69)  dbg_id_ex_br(75)  dbg_btaken(76)      <- 分支冲刷
#       dbg_stall(67)     dbg_idex_ld(70)                       <- load-use 停顿
#       dbg_bht_hit(80)   dbg_bht_taken(81)                     <- BHT 查表命中与预测方向
#       dbg_redirect(83)  dbg_mispred(84)                       <- 实际重定向与误判恢复
#
#     排好序后（工具栏 MoveUp/MoveDown）就是报告用的那张图：
#       PC -> IFID_PC -> IDEX_PC -> EXMEM_PC -> OPCODE -> 冲刷/预测 -> 停顿
#
# [!] 换触发信号要【改两处】：dbg_set_unit 改 TU 的值，
#     还要 dbg_set_condition -select 0 -set "TU<N>" 把条件公式指过去。
#     只改 -unit 的话条件仍指向 TU0，抓回来的还是上一个触发信号。
#
# [!] 整理完立刻 File -> Save Project As 存一份 .dprj ——
#     存了之后下次 File -> Open Project 能把【波形 + 总线 + 全部设置】
#     一次性恢复，不用再跑这个脚本。
# =============================================================================
