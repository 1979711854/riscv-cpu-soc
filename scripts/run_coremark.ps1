param(
    [int]$Iter = 1,                                                        # CoreMark 迭代次数（上板要 ≥10s，见 build_bitstream.ps1 的默认值/注释）
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$SkipBuild,                                                    # 跳过编译，复用已有 ELF
    [switch]$SkipSim,                                                      # 只生成固件、不跑仿真
    [int]$MemWait = 0,                                                     # >0 时给访存注入等待（+MEMWAIT=n，验 mem_ready 停顿逻辑）；0 = 逐位不变
    [switch]$Single,                                                       # 切单发射（不传 -DDUAL）。默认【双发射】，与板上比特流一致
    [switch]$DCache,                                                       # 打开 D-Cache（-DDCACHE，DCACHE_EN=1）。默认关 —— 跑分一律用关的配置
    [switch]$ICache,                                                       # 打开 I-Cache（-DICACHE，ICACHE_EN=1）。默认关 —— 跑分一律用关的配置
    [switch]$EarlyLd,                                                      # [任务 C] load 地址提前（-DEARLYLD，EARLY_LD=1）。默认关
    [switch]$NoBtb,                                                       # [B1-BTB] 关分支目标缓冲（-DNOBTB，BTB_EN=0）。默认【开】，与板上一致
    [switch]$LanebMem                                                     # [lane B 访存] lane B 放 load（-DLANEBMEM，LANEB_MEM=1）。默认关（P2 口径）
)

# -SkipSim 的用途：上板流程只需要 mem.hex，不需要仿真。
#   ITER=700 的仿真要跑 3 亿周期（十几分钟），而生成固件只要十几秒。
#   想核实 CoreMark 数值时再去掉这个开关跑一遍。

# CoreMark 一键：编译 ELF -> 拆 hex 到 sim/programs -> iverilog 编译 tb_coremark -> vvp 跑分
#
# [重点] 配置必须显式、且与板上比特流对齐：
#   默认 = 双发射（传 -DDUAL，每迭代 **252,730** 拍；A1 前 262,018）；-Single = 单发射 **303,140** 拍（A1 前 312,428）。
#   两个都是本机实测（-O3 + 阶段1；-O2 时代分别是 313,886 / 363,515）。
#   得分 = 时钟 ÷ 每迭代周期数 ⇒ 配置不同得分不同，混了会把分数算错。
#   日志首行 "SIM CONFIG: DUAL_ISSUE=?" 会自证本次跑的是哪一种。
$ErrorActionPreference = "Stop"
$dualIssue = if ($Single) { 0 } else { 1 }
$dcacheEn  = if ($DCache) { 1 } else { 0 }
$icacheEn  = if ($ICache) { 1 } else { 0 }
$earlyLdEn = if ($EarlyLd) { 1 } else { 0 }
$btbEn     = if ($NoBtb)  { 0 } else { 1 }
# [lane B 访存] 默认 0 = P2 口径；-LanebMem = P3 口径（与翻开关后的板上默认一致）。
$lanebMemEn = if ($LanebMem) { 1 } else { 0 }

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$env:PATH = "$Toolchain;$env:PATH"
$env:RISCV_TOOLS = $Toolchain          # 供 elf2mem.py 使用

$prog = Join-Path $repo "sim\programs"
New-Item -ItemType Directory -Force -Path $prog | Out-Null
$elf = Join-Path $prog "coremark.elf"
$src = Join-Path $repo "third_party\coremark"
$port = Join-Path $repo "scripts\coremark_port"

if (-not $SkipBuild) {
    Write-Host "[1/3] 编译 CoreMark (ITER=$Iter) ..."
    # 用参数数组调用，避免 PowerShell 原生参数解析把 -DITERATIONS=$Iter 当字面量
    $gccArgs = @(
        # [!] 必须带 _zicsr：core_portme.c 的 portable_init() 用 `csrr mimpid`
        #     读设计版本号（打在 CoreMark 报告之前，用来区分装同一份固件的
        #     两版位流）。只写 rv32im 的话汇编器报 "extension 'zicsr' required"。
        #     理论上不影响正确性（纯 C 不会自己用 CSR），但**改完要复核
        #     `Total ticks` 双发射 = **252,730** 拍**（A1 前 262,018；-O3 + 阶段1 的到达级重定向）。
        "-march=rv32im_zicsr", "-mabi=ilp32", "-O3",
        "-funroll-loops", "-funroll-all-loops", "-fpeel-loops",
        "-falign-functions=4", "-falign-loops=4",
        "-mcmodel=medany", "-msmall-data-limit=0",
        "-nostartfiles",
        "-I$src", "-I$port",
        "-DITERATIONS=$Iter",
        "-T$port\link.ld",
        "$src\core_main.c", "$src\core_list_join.c", "$src\core_matrix.c",
        "$src\core_state.c", "$src\core_util.c",
        # video_text.c = HDMI 文本控制台（任务 B）：ee_printf 的字符同时上屏。
        # 字库/调色板直接 include scripts\gomoku 的那两份，不复制副本。
        # [!] 顺序有讲究：video_text.o 必须排在**最后**。链接次序决定代码地址，
        #     而 CoreMark 的计时区间对取指/分支预测的地址对齐极其敏感 ——
        #     把它插在 core_portme 之前，实测 Total ticks 会从 217,088 变成 217,089
        #     （跑分"变了 1 拍"，验收要求逐位相同）。放到最后，benchmark 那批
        #     .o 的地址与不开屏时完全一致。
        "$port\core_portme.c", "$port\ee_printf.c", "$port\start.S", "$port\video_text.c",
        "-o", $elf
    )
    # [!] 2026-10-16：riscv-none-elf-ld 会往 stderr 打一行
    #    `warning: ... has a LOAD segment with RWX permissions`，而本脚本设了
    #    $ErrorActionPreference="Stop" ⇒ PS 5.1 会把原生命令的 stderr 包装成
    #    【终态错误】（NativeCommandError），脚本在构建阶段当场死（ELF 其实已生成）。
    #    修法：调 gcc 期间临时把 EAP 切到 Continue（stderr 变成非终态、照常打印），
    #    真正的失败由退出码兜。**别用 2>$null** —— 实测 PS 5.1 下仍然终态。
    $eapSave = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & riscv-none-elf-gcc @gccArgs
    } finally {
        $ErrorActionPreference = $eapSave
    }
    if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }
}
else { Write-Host "[1/3] 跳过编译（-SkipBuild）" }

Write-Host "[2/3] 拆 ELF -> imem.hex / dmem.hex / mem.hex ..."
& python (Join-Path $repo "scripts\elf2mem.py") $elf $prog
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

if ($SkipSim) {
    Write-Host "      已跳过仿真（-SkipSim）"
    Write-Host "      固件:     $prog\mem.hex  （ITER=$Iter）"
    Write-Host "      下一步:   scripts\sync_firmware.ps1  同步到 PDS 工程目录"
    exit 0
}

$vvpName = if ($dualIssue -eq 1) { "tb_coremark_dual.vvp" } else { "tb_coremark_single.vvp" }
if ($dcacheEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_dcache.vvp" }
if ($icacheEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_icache.vvp" }
if ($earlyLdEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_earlyld.vvp" }
if ($btbEn     -eq 0) { $vvpName = $vvpName -replace "\.vvp$", "_nobtb.vvp" }
if ($lanebMemEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_lanebmem.vvp" }
Write-Host "[3/3] 编译 testbench 并仿真 ... DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn LANEB_MEM=$lanebMemEn（$vvpName）"
$sim = Join-Path $repo "sim"
$vvp = Join-Path $sim $vvpName
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | ForEach-Object { $_.FullName }
}
$defs = @()
if ($dualIssue -eq 1) { $defs += "-DDUAL" }
if ($dcacheEn  -eq 1) { $defs += "-DDCACHE" }
if ($icacheEn  -eq 1) { $defs += "-DICACHE" }
if ($earlyLdEn -eq 1) { $defs += "-DEARLYLD" }
if ($btbEn     -eq 0) { $defs += "-DNOBTB" }
if ($lanebMemEn -eq 1) { $defs += "-DLANEBMEM" }
$iverilogArgs = @("-g2012") + $defs + @(
    "-I", (Join-Path $repo "rtl\core"), "-I", (Join-Path $repo "rtl\periph"),
    "-I", (Join-Path $repo "rtl\bus"), "-I", $sim,
    "-o", $vvp, (Join-Path $sim "tb_coremark.v")
) + $rtl
$ivOut = & iverilog @iverilogArgs 2>&1
$ivOut | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }
# [!] **端口宽度不一致 = 静默截位，必须当错误处理**（2026-10-10 实踩，同 run_riscv_tests.ps1）。
$widthWarn = @($ivOut | Where-Object { $_ -match 'expects \d+ bit\(s\), given' })
if ($widthWarn.Count -gt 0) {
    $widthWarn | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "iverilog 报了 $($widthWarn.Count) 条端口宽度不一致 —— 那是静默截位，先把宽度对齐再跑回归"
}

Push-Location $sim
try {
    # [!] 2026-10-18：vvp 会往 stderr 打一条
    #     `tb_coremark.v:307: Warning: Calling system function $value$plusargs() as a task.`
    #     PS 5.1 + $ErrorActionPreference="Stop" 会把它变成 NativeCommandError，
    #     仿真**其实照跑**，但脚本当场报错退出（技能 §1 记过这个坑）。
    #     修法与构建阶段一致：调外部命令期间临时切 Continue。
    $eapSave = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & vvp $vvp "+ITER=$Iter" "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+MEMWAIT=$MemWait"
    } finally {
        $ErrorActionPreference = $eapSave
    }
}
finally { Pop-Location }
