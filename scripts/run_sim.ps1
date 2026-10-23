param(
    [string]$Testbench = "",   # 单个测试台：如 "sim/tb_alu_div.v"（相对仓库根）
    [switch]$NoWave,           # 加此开关则不弹 GTKWave（CLI/CI 用）
    [switch]$WithCore          # 编入 core.v（跑整核测试台时需要；单测默认不编）
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$simRoot = Join-Path $repoRoot "sim"

# 需要外部程序镜像(hex) **或额外 RTL** 的测试台，由专用脚本运行，不参与 "Run All"
#   sim/tb_riscv.v    -> scripts/run_riscv_tests.ps1
#   sim/tb_coremark.v -> scripts/run_coremark.ps1
#   sim/tb_demo.v     -> scripts/run_demo.ps1（跑整个 SoC，还要编 rtl/top）
#   sim/tb_rtthread.v -> scripts/rtthread/run_sim.ps1（同样要编 rtl/top）
#   sim/tb_gomoku.v   -> scripts/gomoku/run_sim.ps1（同样要编 rtl/top + 视频六件）
#   sim/tb_amo_int.v  -> 手动（sim/tests/amo_int.S；见该文件头"跑法"）
#   ---- 下面四个要编 rtl/video（本脚本只编 core/periph/bus）----
#   sim/tb_video_bars.v -> scripts/run_video.ps1
#   sim/tb_video.v / tb_ppu.v / tb_video_core.v -> 目前【无专用脚本】，手动编
# [!] 这张表【必须】跟着 sim/ 下新增的 tb_*.v 一起维护：漏一个就会让
#     "跑全部"这条入口在它那里抛异常中断，排在它【后面】的测试台全部不跑，
#     看起来却像"只坏了一个"。已经踩过三次：
#       tb_rtthread.v（2026-09-28 发现）
#       tb_gomoku.v （2026-10-14 补）—— 报 "Unknown module type: cpu_top"
#       四个视频台   （2026-10-15 补）—— tb_ppu.v 报 "Unknown module type: sync_vg"，
#                     当时排在它后面的 tb_rvc/tb_uart_fifo/tb_uart_rx 全部【静默不跑】，
#                     而日志里只有一行 video 的编译错误，极易被忽略。
#     **判据**：Run All 的日志里必须能看到每一个 tb_*.v 的 "Compiling" 行，
#     或者它在下列清单里。对不上就是这张表漏了。
#
# [!] 另一类：**已知红的**。排除它们不是"把红变绿"，是把"一直红、没人知道"
#     变成"显式记录在案"。任何一条进这个清单都必须写明失败数 + 为什么不修。
#   sim/tb_rvc.v —— **32 项里 10 项 FAIL**（2026-10-15 首次真正跑到它时发现）。
#     失败的集中在 `c.addi16sp` / `c.j` / `c.jal` / `c.beqz` / `c.bnez` 的立即数
#     位域，以及保留编码没判非法（`illegal=0`/`is_jump=1` 应为相反）。
#     **为什么不修**：RVC 在 2026-10-11 已评估为【不做】—— 同一条命令行只换
#     `-march=rv32imc` 实测静态指令数 +0.7%（几乎不变），收益 ≈ 0，且不在赛题条目里。
#     `rtl/core/rvc_expand.v` **全仓没有任何模块例化它**（core.v 里 grep 不到）
#     ⇒ 这个译码 bug 对交付物【零影响】，纯属死代码。
#     详见 doc/reports/2026-10-11_rvc_feasibility.md。
#     想自己跑：直接 `iverilog -o /tmp/rvc.vvp sim/tb_rvc.v rtl/core/rvc_expand.v`
#     （它不依赖 core/periph，所以 Run All 之外跑很方便）。
#     处置建议（未决）：要么修 10 个位域，要么连 rvc_expand.v 一起删。**别只留下它一直红。**
$knownFailingTbs = @("tb_rvc.v")
$externalProgramTbs = @("tb_riscv.v", "tb_coremark.v", "tb_demo.v", "tb_template.v",
                        "tb_rtthread.v", "tb_amo_int.v", "tb_gomoku.v",
                        "tb_video.v", "tb_video_bars.v", "tb_video_core.v", "tb_ppu.v")

# 编译哪些 RTL：core + periph。
# 注意 1：存储器模型 imem/bram 在 testbench 里自带（行为级），所以【不要】编译 rtl/mem，
#         否则会与 tb 内的同名模块冲突；rtl/mem 只在 PDS 综合时使用。
# 注意 2：core.v 例化了 imem/bram，单测（tb_alu_*）不需要它，默认不编；
#         跑整核测试台时用 -WithCore（并把存储器模型交给 tb 提供）。
$rtlDirs = @("rtl\core", "rtl\periph", "rtl\bus")

function Get-RtlFiles {
    $files = @()
    foreach ($d in $rtlDirs) {
        $p = Join-Path $repoRoot $d
        if (Test-Path $p) {
            $files += Get-ChildItem -Path $p -Filter "*.v" | Sort-Object Name | ForEach-Object { $_.FullName }
        }
    }
    # SoC 级模块（core / mem_bus）例化了存储器，而单测（tb_alu_*）既不需要、
    # 也提供不了存储器模型，默认不编；跑整核/SoC 测试台时用 -WithCore，
    # 此时由 testbench 自己提供 imem/bram 的行为级模型。
    $socModules = @("core.v", "mem_bus.v")
    if (-not $WithCore) {
        $files = $files | Where-Object { $socModules -notcontains [System.IO.Path]::GetFileName($_) }
    }
    return $files
}

function Invoke-Testbench([string]$RelativeTestbench, [switch]$NoWave) {
    $filePath = Resolve-Path (Join-Path $repoRoot $RelativeTestbench)
    $simDir = Split-Path $filePath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $vvpPath = Join-Path $simDir "$baseName.vvp"
    $vcdPath = Join-Path $simDir "$baseName.vcd"

    if (Test-Path $vvpPath) { Remove-Item $vvpPath -Force }
    if (Test-Path $vcdPath) { Remove-Item $vcdPath -Force }

    $compileArgs = @("-g2012")
    foreach ($d in $rtlDirs) { $compileArgs += @("-I", (Join-Path $repoRoot $d)) }
    $compileArgs += @("-o", $vvpPath, $filePath.Path)
    $compileArgs += (Get-RtlFiles)

    Push-Location $simDir
    try {
        Write-Host "Compiling $RelativeTestbench"
        & iverilog @compileArgs
        if ($LASTEXITCODE -ne 0) { throw "iverilog failed for $RelativeTestbench" }

        Write-Host "Running VVP"
        & vvp $vvpPath
        if ($LASTEXITCODE -ne 0) { throw "vvp failed for $RelativeTestbench" }

        if ((Test-Path $vcdPath) -and -not $NoWave) {
            Write-Host "Opening GTKWave for $vcdPath"
            Start-Process -FilePath "gtkwave" -ArgumentList "$vcdPath" -WindowStyle Hidden | Out-Null
        }
    }
    finally {
        Pop-Location
    }
}

if (-not [string]::IsNullOrWhiteSpace($Testbench)) {
    # 用法：run_sim.ps1 -Testbench "sim/tb_alu_div.v"
    if ($Testbench -notlike "*.v") { $Testbench += ".v" }
    Invoke-Testbench $Testbench -NoWave:$NoWave
}
else {
    # 未指定参数：跑 sim/ 下所有 tb_*.v（模板、需要外部 hex 的、已知红的除外）
    $testbenches = @(Get-ChildItem -Path $simRoot -Filter "tb_*.v" |
        Where-Object { $externalProgramTbs -notcontains $_.Name -and
                       $knownFailingTbs    -notcontains $_.Name } |
        Sort-Object Name |
        ForEach-Object { "sim/$($_.Name)" })

    # 已知红的必须【每跑一次都提醒一次】—— 否则它就等于被静默删掉了。
    $skipped = @($knownFailingTbs | Where-Object { Test-Path (Join-Path $simRoot $_) })
    if ($skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "!! 本次【跳过】了 $($skipped.Count) 个已知失败的测试台（不是全绿）：" -ForegroundColor Yellow
        foreach ($s in $skipped) { Write-Host "     sim/$s" -ForegroundColor Yellow }
        Write-Host "   原因与处置建议见本脚本 $knownFailingTbs 定义处的注释。" -ForegroundColor Yellow
        Write-Host ""
    }

    if ($testbenches.Count -eq 0) {
        Write-Host "没有可自动运行的 tb_*.v（tb_riscv / tb_coremark 请用专用脚本）"
        exit 0
    }

    foreach ($testbench in $testbenches) {
        Invoke-Testbench $testbench -NoWave:$NoWave
    }
}
