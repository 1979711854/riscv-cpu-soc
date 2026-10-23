<#
.SYNOPSIS
    五子棋固件端到端仿真（轨道 E2）—— 一条命令跑完。

.DESCRIPTION
    做三件事：
      1) 用【仿真口径】编译固件（build.ps1 -Sim：按键阈值 1ms/5ms、AI 用 EASY）
      2) 编译 sim\tb_gomoku.v
      3) 跑：固件启动 -> 棋盘铺好 -> 长按开局 -> 落子 -> AI 应手

    [!] 为什么仿真必须用 -Sim 那套口径：
      * **按键阈值**：板上长按 600ms 在 62MHz 下是 3700 万拍，仿真里跑不完；
        缩到 5ms 才仿得动。
      * **AI 难度**：NORMAL(4 层) 一次搜索约 2 亿拍 —— 在仿真的 CPU 上要跑
        **十几分钟真实时间**（iverilog 约 20~50 万拍/秒）。EASY 是纯贪心，
        一次函数调用，秒出。
      所以脚本里写死 `-Sim`，不给你选 —— 用板上口径喂这个测试台只会等到超时。

.EXAMPLE
    scripts\gomoku\run_sim.ps1
#>
param(
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { chcp 65001 | Out-Null } catch { }

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$sim  = Join-Path $repo "sim"
$prog = Join-Path $sim "programs\gomoku_sim"

# ---- 1) 仿真口径的固件 ----
& (Join-Path $PSScriptRoot "build.ps1") -Sim -Toolchain $Toolchain
if ($LASTEXITCODE -ne 0) { throw "固件编译失败" }

# ---- 2) 编译测试台 ----
Write-Host "[2/2] 编译并运行 tb_gomoku ..." -ForegroundColor Yellow
$vvp = Join-Path $sim "tb_gomoku.vvp"

# rtl\top 只收 cpu_top.v（cpu_top_board.v 例化了 PDS 专有原语 pll/video_top，
# iverilog 会把列表里每个模块都当顶层展开 → "Unknown module type: pll"）
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | Sort-Object Name | ForEach-Object { $_.FullName }
}
$rtl += Join-Path $repo "rtl\top\cpu_top.v"
# 视频侧只收不含原语的那几个（与 run_video.ps1 同一张清单）
foreach ($f in @("video_core.v", "ppu.v", "sync_vg.v", "vram_b32.v", "vram_dp.v", "vram_pal.v")) {
    $rtl += Join-Path $repo "rtl\video\$f"
}

& iverilog -g2012 -I (Join-Path $repo "rtl\core") -I (Join-Path $repo "rtl\periph") `
    -I (Join-Path $repo "rtl\bus") -I (Join-Path $repo "rtl\video") -I $sim `
    -o $vvp (Join-Path $sim "tb_gomoku.v") @rtl
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

Push-Location $sim
try {
    & vvp $vvp "+IMEM=programs/gomoku_sim/imem.hex" "+DMEM=programs/gomoku_sim/dmem.hex"
    $rc = $LASTEXITCODE
}
finally { Pop-Location }
exit $rc
