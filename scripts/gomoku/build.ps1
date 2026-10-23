<#
.SYNOPSIS
    五子棋固件构建 —— 编译 + 拆 hex，产物进 sim\programs\（轨道 E1）

.DESCRIPTION
    一条命令出 mem.hex。上板走 scripts\build_bitstream.ps1 gomoku（它内部会调本脚本）。

    复用 demo 的 start.S 与 link.ld（与 run_video.ps1 同样的做法）——
    内存布局只有一份真相，别在这里再抄一份链接脚本，否则迟早漂移。

    编译完会打印各段大小与一条"够不够装"的检查：RAM 只有 32KB，
    超了不会报错、只会在板上跑到一半崩掉，所以这里主动拦一道。

.PARAMETER Toolchain
    riscv-none-elf-gcc 所在目录。

.PARAMETER NoHex
    只编译 ELF，不拆 hex（调试用）。

.EXAMPLE
    scripts\gomoku\build.ps1
#>
param(
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$NoHex,
    [switch]$Sim           # 仿真空径：缩短按键阈值，产物叫 gomoku_sim.elf
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$env:PATH = "$Toolchain;$env:PATH"
$env:RISCV_TOOLS = $Toolchain

$demo = Join-Path $repo "scripts\demo"
# [!] 仿真产物必须放【另一个目录】。早先 -Sim 也写 sim\programs\mem.hex，
#     而那正是 build_bitstream.ps1 同步给 PDS 的那一份 —— 一次 -Sim 构建
#     就可能把"长按 5ms"的仿真固件送上板，而且全程零报错。
$prog = Join-Path $repo $(if ($Sim) { "sim\programs\gomoku_sim" } else { "sim\programs" })
New-Item -ItemType Directory -Force -Path $prog | Out-Null
$elf = Join-Path $prog $(if ($Sim) { "gomoku_sim.elf" } else { "gomoku.elf" })

# 源文件：本目录的 7 个模块 + main（应用逻辑）+ main_entry（裸机入口），
# 加上 demo 的启动代码。
# [!] 入口拆成两个文件是为了同时支持裸机与 RT-Thread —— 见 main_entry.c 的文件头。
#     **RT-Thread 的构建不能包含 main_entry.c**（那会多一个 main()）。
$srcs = @("board.c", "ai.c", "render.c", "video_port.c",
          "input.c", "hw_port.c", "game.c", "main.c", "main_entry.c",
          "coremark_screen.c") |
        ForEach-Object { Join-Path $PSScriptRoot $_ }
$srcs += Join-Path $demo "start.S"

Write-Host ("[1/2] 编译五子棋固件{0} ..." -f $(if ($Sim) { "（仿真口径：短按键阈值）" } else { "" })) -ForegroundColor Yellow
# -march=rv32ima：A 扩展（amoswap/lr/sc）已接入 CPU 且流水线跑通。
#   但五子棋是【纯单线程】应用，源码里没有 amoswap/amoadd/__sync_*，
#   编译器也不会凭空生成 —— 所以 A 扩展在这份固件里【跑但不用】。
#   这正是本任务的意义：证明 A 扩展【没有破坏既有应用】。
#   （CoreMark 同样不含 AMO 指令，应用层与 benchmark 层互为佐证。）
#   另：别退回 rv32i —— 那会让常量除法走软件例程，白白变慢（M 扩展用得上）。
# [!] **必须带 _zicsr**：main.c 的 design_rev() 用 `csrr mimpid` 读设计版本号
#     （打在串口第一行，用来区分装同一份固件的两版位流）。现代 RISC-V 规范把
#     CSR 指令从基础 I 里拆了出去，只写 rv32ima 的话汇编器直接报
#     "unrecognized opcode 'csrr ...' extension 'zicsr' required"。
$gccArgs = @(
    "-march=rv32ima_zicsr", "-mabi=ilp32", "-O2", "-mcmodel=medany", "-msmall-data-limit=0",
    "-ffreestanding", "-nostartfiles",
    "-Wall", "-Wextra",
    "-I$PSScriptRoot", "-I$demo",
    "-T$(Join-Path $demo 'link.ld')"
)
# [!] 仿真必须缩短按键阈值，否则长按 600ms = 3700 万周期，整盘棋仿不完。
#     见 input.h 里那段 [!]。这个变体【不能上板】。
if ($Sim) {
    $gccArgs += @("-DINPUT_DEBOUNCE_MS=1", "-DINPUT_LONG_MS=5",
                  "-DGOMOKU_AI_LEVEL=AI_EASY")   # [!] NORMAL 在仿真里要跑十几分钟
}
$gccArgs += $srcs + @("-o", $elf)

# [!] 2026-10-18：riscv-none-elf-ld 会往 stderr 打一行
#     `warning: ... has a LOAD segment with RWX permissions`，而本脚本设了
#     $ErrorActionPreference="Stop" ⇒ PS 5.1 会把原生命令的 stderr 包装成
#     【终态错误】（NativeCommandError），脚本在构建阶段当场死（ELF 其实已生成）。
#     这和 scripts/run_coremark.ps1 里记的是同一个坑，修法也一样：调 gcc 期间
#     临时把 EAP 切到 Continue（stderr 变成非终态、照常打印），真正的失败由退出码兜。
#     **别用 2>$null** —— 实测 PS 5.1 下仍然终态。
$eapSave = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & riscv-none-elf-gcc @gccArgs
} finally {
    $ErrorActionPreference = $eapSave
}
if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }

# ---- 打印段大小并检查装不装得下 ----
$sizeOut = & riscv-none-elf-size $elf
$sizeOut | ForEach-Object { Write-Host "      $_" }

$line = ($sizeOut | Select-Object -Last 1)
$parts = $line -split '\s+' | Where-Object { $_ -ne '' }
$text = [int]$parts[0]; $data = [int]$parts[1]; $bss = [int]$parts[2]

# 栈顶 0xF000（见 demo/link.ld），所以可用 RAM 是 0x0000~0xEFFF = 60KB。
# 兼容区 0xFFF0~0xFFFF 被 MMIO 挖掉，不能放东西。
# [!] 2026-10-10 统一存储器由 32KB 扩到 64KB，栈顶跟着从 0x7000 抬到 0xF000。
$RAM_TOP = 0xF000
$used = $text + $data + $bss
Write-Host ("      静态占用 {0} 字节（text {1} + data {2} + bss {3}），栈顶 0x{4:X}" -f $used, $text, $data, $bss, $RAM_TOP)
if ($used -gt $RAM_TOP) {
    Write-Host "!! 超出 RAM —— 板上会跑到一半崩掉，且没有任何报错。" -ForegroundColor Red
    Write-Host "   图块表 tiles.h 占 9216 字节，是第一个该压的（可改成运行时合成）。" -ForegroundColor Red
    exit 1
}
Write-Host ("      余量 {0} 字节给栈（AI 递归在里面）" -f ($RAM_TOP - $used)) -ForegroundColor Green

if ($NoHex) {
    Write-Host "已按 -NoHex 停在 ELF。"
    exit 0
}

Write-Host "[2/2] 拆 ELF -> mem.hex ..." -ForegroundColor Yellow
& python (Join-Path $repo "scripts\elf2mem.py") $elf $prog
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

Write-Host ""
Write-Host "固件：$prog\mem.hex" -ForegroundColor Green
Write-Host "上板：scripts\build_bitstream.ps1 gomoku（生成固件 -> 同步 -> 综合一条龙）"
