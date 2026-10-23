# ============================================================================
# flash.tcl —— 无头烧录 Pango Logos2 PG2L200H（Fabric Configuration 批处理）
# ----------------------------------------------------------------------------
# 用法（详见 doc/board_bringup.md）：
#   1) 先起 JTAG Server：D:\pango\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
#   2) 再跑本脚本（把 %%s 换成要烧的 .sbit 绝对路径，正斜杠）：
#      D:\pango\PDS_2022.2-SP6.4\bin\cdt_cfg_shell.exe -file scripts\flash.tcl ^
#          -args { D:/riscv-cpu-fpga_merged/pds/RV32I_1/generate_bitstream/cpu_top_board.sbit }
#
# [!] 为什么不用 GUI：Programmer 会把"上次分配的那个文件"记住，只点 Program 极易烧成
#     上一版（2026-09-23 实踩：想烧跑分版结果烧成 demo）。脚本化后路径写在文件里，
#     不可能再烧错版本。
# [!] 语法出处：官方《Fabric Configuration User Guide》§4.5.1 / §4.5.2 / §4.6。
#     注意 cfg_program **不带文件参数** —— 它烧的是 cfg_assign_file 刚分配的那份。
#     所以 cfg_assign_file 这次调用是承重的，不能省。
# ============================================================================

cfg_connect -ip 127.0.0.1 -port 65420

# 扫描 JTAG 链，认器件（PG2L200H）
cfg_scan_chain
cfg_add_device -file %s

# [承重] 重新分配配置文件 —— 这就是"必须重新 Browse"那一步
cfg_assign_file -file %s -device_index 0

# 真正烧写（不带文件参数：烧的是上一条刚分配的那份）
cfg_program -device_index 0

# 回读校验
cfg_verify -device_index 0

cfg_disconnect
cfg_close
