# =============================================================================
# ila_capture.tcl —— Fabric Debugger 抓波形脚本（RISC-V CPU 项目）
# -----------------------------------------------------------------------------
# 用法：在 PDS 的 Debugger 里打开 TCLConsole（底部信息打印区，View -> Console），
#       然后：  source D:/riscv-cpu-fpga/scripts/ila_capture.tcl
#
# [!] 跑之前先确认两件事：
#   1) 已经连上 JTAG Server（`dbg_connect -ip 127.0.0.1 -port 65420`），
#      否则会报 "the connection is disconnected, please connect to server first"。
#   2) FPGA 里是【调试版】比特流。判据：`dbg_list` 应显示
#      "Data sample width = 86" 和 "Number of trigger ports = 4"。
#
# 通道映射（数据端口 0，共 86 位）见 doc/ila_analysis.md §7.1，也见 core.v 末尾
# 探针束的块头注释。摘要：
#   [0..14]   pc[14:0]        [15..29]  if_id_pc[14:0]
#   [30..44]  id_ex_pc[14:0]  [45..59]  ex_mem_pc[14:0]
#   [60..66]  if_id_instr[6:0]
#   [67] stall  [68] div_stall  [69] ex_flush  [70] id_ex_mem_read
#   [71..74] fwd_a_ex / fwd_b_ex / fwd_a_wb / fwd_b_wb
#   [75] id_ex_branch  [76] branch_taken  [77] mem_we  [78] mem_re
#   [79] mem_wb_reg_write  [80] bht_hit  [81] bht_taken  [82] id_pred_taken
#   [83] id_redirect  [84] ex_mispred  [85] id_ex_pred_taken
#
# 触发端口：t0=ex_flush  t1=stall  t2=bht_hit  t3=ex_mispred（各 1 位）
# =============================================================================

set FIC  D:/riscv-cpu-fpga/pds/RV32I_1/cpu_top_board.fic

# [!!] 顺序不能颠倒：先建总线，再 add_all_to_waveform。
#      如果之前已经抓过（波形里已有 86 根裸位），先清掉：
dbg_clear_all_to_waveform

# -----------------------------------------------------------------------------
# 第 1 步：导入 .fic —— 给 86 个通道安上信号名
# 不做这一步的话，波形里全是无名的裸通道，没法读。
# 注意：本地板的 Debugger 走工程里登记的那份也行，但这里显式指定最稳。
# -----------------------------------------------------------------------------
dbg_import_fic -file $FIC

# [!!] 如果报 "bus name:PC already exists"，说明总线【已经建过了】——
#      dbg_clear_all_to_waveform 只清波形显示，不清信号树里的总线定义。
#      这时【别重建】，直接跳到第 3 步的 dbg_add_all_to_waveform 即可。
#      想确认已有哪些：dbg_get_buses（它会列出每条总线含哪些通道，正好用来核对）
#      确实要重建某条：先 dbg_del_bus -name PC

# -----------------------------------------------------------------------------
# 第 2 步：先把 PC 那几组通道【合成总线】—— [!] 必须在 add_all_to_waveform 之前
#
# 踩过的坑（2026-09-25）：先 add_all_to_waveform 再 dbg_add_bus 是【没用】的 ——
# add_all 是把"当前信号树里的东西"全加进波形，那时总线还不存在，加进去的是
# 86 根裸位；之后建的总线不会自动替换波形里已有的裸位。顺序必须是
#   导 fic -> 建总线 -> add_all_to_waveform -> 抓
# 如果已经抓过一次波形，先 dbg_clear_all_to_waveform 清掉再按上面顺序来。
#
# [!] 总线进制的编号和 TriggerUnit 不一样，别混：
#       总线(dbg_set_bus_radix)： 0=二进制 1=八进制 2=十六进制 3=无符号 4=有符号
#       TriggerUnit(dbg_set_unit)： 0=Hex   1=Octal   2=Binary   3=Unsigned
# [!] 位序如果不对（PC 看起来像位反转、四个 PC 之间看不出"差 4/8/12"的关系），
#     取消下面那行 reverse 的注释再跑一次。
# -----------------------------------------------------------------------------
dbg_add_bus -name PC        -channel 0-14
dbg_set_bus_radix -name PC -radix 2
# dbg_reverse_bus -name PC

dbg_add_bus -name IFID_PC   -channel 15-29
dbg_set_bus_radix -name IFID_PC -radix 2
# dbg_reverse_bus -name IFID_PC

dbg_add_bus -name IDEX_PC   -channel 30-44
dbg_set_bus_radix -name IDEX_PC -radix 2
# dbg_reverse_bus -name IDEX_PC

dbg_add_bus -name EXMEM_PC  -channel 45-59
dbg_set_bus_radix -name EXMEM_PC -radix 2
# dbg_reverse_bus -name EXMEM_PC

dbg_add_bus -name OPCODE    -channel 60-66
dbg_set_bus_radix -name OPCODE -radix 2

# -----------------------------------------------------------------------------
# 第 3 步：确认总线建好了，再把（含总线的）全部信号加进波形窗口
# -----------------------------------------------------------------------------
dbg_get_buses
dbg_add_all_to_waveform

# -----------------------------------------------------------------------------
# 第 4 步：冒烟测试 —— 强制触发一次，确认整条链路是通的
# TriggerImmediate 忽略触发条件，立刻抓满一个窗口。
# 波形里应该有数据；PC 应该在 0x0000 ~ 0x4200 之间跳动。
# 如果这一步没数据，别往下走，先查链路。
# -----------------------------------------------------------------------------
dbg_trig_immd

# -----------------------------------------------------------------------------
# 第 5 步：正式触发 —— 抓"分支冲刷"
# 手册对 Binary 进制的 Value 要求：每一位都必须显式给出。我们的触发端口是
# 1 位，所以只写一个字符即可：R=上升沿  F=下降沿  1=高电平  0=低电平
#                            X=不关心  B=任意翻转  N=不翻转
# 四个候选触发信号各占一个 1 位触发端口，换触发只需改 -unit 和下面的条件：
#       -unit 0  -> t0 = ex_flush    （分支/跳转冲刷）
#       -unit 1  -> t1 = stall       （load-use 停顿）
#       -unit 2  -> t2 = bht_hit     （BHT 查表命中）
#       -unit 3  -> t3 = ex_mispred  （预测 taken 但实际 not-taken）
# -----------------------------------------------------------------------------
# [!] `-radix` 的编号手册标错了（它的两个例子自相矛盾：一个明显是二进制却配
#     -radix 0，另一个明显是十进制却配 -radix 2），实机也报过
#     "value is illegal"。所以：
#       用边沿：先试 -radix 0（按手册例1 推断 0 才是 Binary）——
#               dbg_set_unit -unit 0 -func "==" -value R -radix 0
#       嫌麻烦：干脆【用电平触发】—— '1' 在任何进制下都合法，而 ex_flush 是
#               单拍脉冲，电平触发与上升沿效果几乎一样（Position 居中时看不出差别）
#       都不行：dbg_set_unit -help  看这个版本的实际参数说明（权威）
dbg_set_unit -unit 0 -func "==" -value 1

# 触发条件：先看现有的（不带选项就是列出全部），再建一个用 TU0 的
dbg_set_condition
dbg_set_condition -add 1
dbg_set_condition -select 1 -set "TU0"
dbg_set_condition -active 1

# -----------------------------------------------------------------------------
# 第 6 步：捕获设置 —— 单窗口 / 深度 1024 / 触发点居中（看到触发前后各一半）
# 用 -windows 1 时深度自动等于核的最大深度(1024)，不能同时给 -depth。
# -----------------------------------------------------------------------------
dbg_set_capture -type 0 -windows 1 -position 512

# -----------------------------------------------------------------------------
# 第 7 步：开抓。满足一次 ex_flush 上升沿后，buffer 填满即停，
#          数据自动显示在 Waveform / Listing 窗口。
# -----------------------------------------------------------------------------
dbg_run

# -----------------------------------------------------------------------------
# 换别的触发 —— [!] 必须【改两处】，只改 -unit 是不够的：
#     ① dbg_set_unit  改哪个 TU 的值
#     ② dbg_set_condition 把触发条件的公式指到那个 TU
#   2026-09-25 实踩：只改了 -unit，条件公式还是 TU0，结果抓回来的还是 ex_flush
#   （三份 VCD 在触发点全都是 ex_flush=1，文件名叫 stall/bhthit 却名不符实）。
#
#   [!] 条件索引是 0（`dbg_set_condition` 裸跑会显示 "TriggerCondition0"），
#       不是 1。先裸跑确认再改。
#
#   load-use 停顿（TU1 = dbg_stall）：
#       dbg_set_unit -unit 1 -func "==" -value 1
#       dbg_set_condition -select 0 -set "TU1"
#       dbg_run
#   BHT 命中（TU2 = dbg_bht_hit）：
#       dbg_set_unit -unit 2 -func "==" -value 1
#       dbg_set_condition -select 0 -set "TU2"
#       dbg_run
#   预测误判恢复（TU3 = dbg_mispred）：
#       dbg_set_unit -unit 3 -func "==" -value 1
#       dbg_set_condition -select 0 -set "TU3"
#       dbg_run
#
#   每次 dbg_run 之后都要【按板上的 KEY1】让 CoreMark 重跑（见 §7.2 的说明）。
#   抓完核对判据：波形里【采样 512】那一拍，对应的触发信号必须是 1
#   （Position=512 居中，所以触发点就在正中）。不是 1 就说明触发没换成功。
#
# 停抓并卸掉触发条件：  dbg_stop
# 导出这次波形设置：    dbg_export_fic -file D:/riscv-cpu-fpga/pds/RV32I_1/ila_captured.fic
# 查所有命令：          dbg_help       （每条都支持 -help，如 dbg_set_unit -help）
# =============================================================================
