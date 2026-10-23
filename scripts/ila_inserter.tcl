# ============================================================================
# ila_inserter.tcl -- generate the ILA .fic in Fabric Inserter BATCH mode
# ----------------------------------------------------------------------------
# Why scripted instead of GUI (doc/ila_analysis.md §7.7 route 2):
#   the probes carry EXACT markers  PAP_MARK_DEBUG="<0/d0/N>"
#   => per the manual, when the project has no/empty .fic the Inserter
#      auto-connects from the RTL markers. So we only open a core, set the
#      sampling params and save. Reproducible + versionable.
#
# [!] ASCII ONLY. cdt_ins rejects non-English console input:
#     "E: Flow-0120: The console input is invalid, only English characters are allowed."
#     (Chinese comments in this file WILL abort the run. Keep all text English.)
#
# Run:
#   D:\pango\PDS_2022.2-SP6.4\bin\cdt_ins.exe
#       -device PG2L200H -package FBB676 -speedgrade -6
#       -netlist <repo>\pds\RV32I_1\synthesize\cpu_top_board_syn.adf
#       -file <repo>\scripts\ila_inserter.tcl
#
# [!] The .adf must come from the SAME synthesis run as the .sbit produced
#     afterwards. Any RTL change makes an old .fic's channel map wrong
#     (symptom: signals present but all wrong -- very hard to diagnose).
#
# Params from doc/ila_analysis.md §7.3 step 3:
#   Sample Depth 1024, Sample On Rising, Basic w/edges, multi-window off,
#   capture position 512 (trigger centred => 512 samples before/after).
#   Two trigger ports: ex_flush(t0) / stall(t1), assigned explicitly by the
#   probe markers, so adding/removing data probes never shifts them.
# ============================================================================

set REPO "D:/riscv-cpu-fpga_merged"

# ---- 1) input netlist from this synthesis run ----
ins_set_file -input "$REPO/pds/RV32I_1/synthesize/cpu_top_board_syn.adf"

# ---- 2) add one debug core ----
ins_add_core 1

# ---- 3) sampling and trigger params ----
# clock_edge 1 = rising; data_depth 1024; trig_num 2; multi_windows 0
ins_set_core -core 0 -data_depth 1024 -clock_edge 1 -trig_num 2 -multi_windows 0

# one match unit, type 1 = Basic w/edges
ins_set_trig -core 0 -trig 0 -unit_num 1 -type 1
ins_set_unit -core 0 -unit 0 -func == -value 1 -cnt_type 0
ins_set_condition -core 0 -trigger "TU0"

# capture window: one window, trigger centred (512 of 1024)
ins_set_capture -core 0 -type windows -windows 1 -position 512

# ---- 4) list connectable nets (evidence that the probes are there) ----
ins_list_nets

# ---- 5) save the .fic ----
ins_save "$REPO/pds/RV32I_1/cpu_top_board.fic"

puts "=== ila_inserter.tcl done: $REPO/pds/RV32I_1/cpu_top_board.fic ==="
