<#
.SYNOPSIS
    合并镜像（boot selector + CoreMark + RT-Thread）两条路径的仿真验证。

.DESCRIPTION
    这一步**必须**在两个程序各自上板之前做完：它证明是**同一份 mem.hex**、
    由 boot.S 按 key[2] 分叉到两个程序，而不是"我们分别烧了两次"。
    （官方答疑第 53 问 R99「跑分和应用同一个 bit 流」，这是唯一能自动验的部分。）

    做的事：
      1) 重编 boot / CoreMark（**ITER=1**，仿真跑得动）/ RT-Thread（-Sim 口径）
      2) scripts\merge_images.py 合成一份 sim\programs\combined\mem.hex
      3) 编 sim\tb_combined.v，跑两遍：
           +KEY=1  key[2] 按住  → 期望 PC 命中 0x1000，串口打 CoreMark 报告 + 四 CRC
           +KEY=0  key[2] 松开  → 期望 PC 命中 0x10000，串口打 RT-Thread banner
      4) 逐条核对，任一条不成立就非零退出

    [!] 仿真用的是 **ITER=1** 的 CoreMark，**不是**交付档的 ITER=3900：
        ITER=3900 在 iverilog 里是 8.4 亿拍，跑不完。这里验的是"路由 + 能跑起来"，
        分数与拍数由板上 CoreMark 那一档负责（217,088 拍/迭代，四 CRC 不变）。

    [!] RT-Thread 用 -Sim 口径编（100MHz + 短延时）。板载口径（76.5MHz + 500ms 心跳）
        在仿真里要等几千万拍才出 [hb]，且与 tb 的 100MHz 时钟不一致 —— 会误判。

.EXAMPLE
    scripts\run_combined_sim.ps1
    scripts\run_combined_sim.ps1 -SkipBuild      # hex 都在，只重跑仿真
#>
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$repo  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sim   = Join-Path $repo "sim"
$prog  = Join-Path $sim "programs"
$stage = Join-Path $prog "combined"
$Tool  = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
$env:PATH = "$Tool;$env:PATH"

New-Item -ItemType Directory -Force -Path $stage | Out-Null

function Fail($msg) { Write-Host "!! $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# 1) 三块固件
# ---------------------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host "[1/4] 编 boot selector ..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "boot\build.ps1") -Quiet
    if ($LASTEXITCODE -ne 0) { Fail "boot selector 构建失败" }
    Copy-Item (Join-Path $PSScriptRoot "boot\build\mem.hex") (Join-Path $stage "boot.hex") -Force

    Write-Host "[2/4] 编 CoreMark（ITER=1，仿真口径）..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "run_coremark.ps1") -Iter 1 -SkipSim
    if ($LASTEXITCODE -ne 0) { Fail "CoreMark 构建失败" }
    Copy-Item (Join-Path $prog "mem.hex") (Join-Path $stage "coremark.hex") -Force

    Write-Host "[3/4] 编 RT-Thread（-Sim：100MHz/短延时）..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "rtthread\build.ps1") -Sim
    if ($LASTEXITCODE -ne 0) { Fail "RT-Thread 构建失败" }
    Copy-Item (Join-Path $PSScriptRoot "rtthread\build\mem.hex") (Join-Path $stage "rtthread.hex") -Force
} else {
    Write-Host "[1/4] -SkipBuild：复用 $stage 下已有 hex" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 2) 合并（重叠/越界/兼容区/0x1FFF0 都会硬报错）
# ---------------------------------------------------------------------------
Write-Host "[3/4] 合并镜像 ..." -ForegroundColor Yellow
& python (Join-Path $PSScriptRoot "merge_images.py") `
         --boot (Join-Path $stage "boot.hex") `
         --coremark (Join-Path $stage "coremark.hex") `
         --rtthread (Join-Path $stage "rtthread.hex") `
         -o (Join-Path $stage "mem.hex")
if ($LASTEXITCODE -ne 0) { Fail "merge_images.py 失败 —— 三块镜像没通过布局校验" }

# ---------------------------------------------------------------------------
# 3) 编测试台
# ---------------------------------------------------------------------------
Write-Host "[4/4] 编 tb_combined 并跑两条路径 ..." -ForegroundColor Yellow
$vvp = Join-Path $sim "tb_combined.vvp"
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | ForEach-Object { $_.FullName }
}
# [!] 只编 mem_bus.v：mem_model.vh 已经提供了 unified_mem，再把 rtl\mem\unified_mem.v
#     编进来会重复定义。Cache 模块在 generate 关着的分支里，不编也不需要。
$rtl += (Join-Path $repo "rtl\bus\mem_bus.v")
$rtl += (Join-Path $repo "rtl\top\cpu_top.v")

$ivOut = & iverilog -g2012 `
    "-I" (Join-Path $repo "rtl\core") "-I" (Join-Path $repo "rtl\periph") `
    "-I" (Join-Path $repo "rtl\bus") "-I" $sim `
    -o $vvp (Join-Path $sim "tb_combined.v") @rtl 2>&1
$ivOut | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { Fail "iverilog 编译失败" }
$widthWarn = @($ivOut | Where-Object { $_ -match 'expects \d+ bit\(s\), given' })
if ($widthWarn.Count -gt 0) { Fail "iverilog 报了 $($widthWarn.Count) 条端口宽度不一致（静默截位）" }

Push-Location $sim
try {
    $runs = @(
        @{ Name = "CoreMark  "; Key = 1; Log = "combined_uart_coremark.log"; Extra = @("+MAXCYC=30000000") },
        # 路径 B 只验「跳过去了 + banner 出来了」：banner 在几万拍内就有，
        # 之后五子棋会去轮询 vblank（本 tb 把 vid_rdata 接 0，永远等不到），
        # 所以上限压到 800 万拍，别白等。
        # 800 = banner + [build] + 分隔线，够判"跳过去了且起来了"；再多会等到
        # 五子棋轮询 vblank（本 tb vid_rdata 接 0）后才超时，白等。
        @{ Name = "RT-Thread "; Key = 0; Log = "combined_uart_rtthread.log"; Extra = @("+MAXCYC=8000000", "+STOPCHARS=800") }
    )
    $results = @()
    foreach ($r in $runs) {
        Write-Host ""
        Write-Host "--- 路径：$($r.Name)（+KEY=$($r.Key)）---" -ForegroundColor Cyan
        # [!] 别用 $args 当变量名（PowerShell 自动变量，赋值行为不可靠）
        $vvpArgs = @($vvp, "+IMEM=programs/combined/mem.hex", "+KEY=$($r.Key)",
                     "+LOG=$($r.Log)") + $r.Extra
        $out = & vvp @vvpArgs 2>&1
        $out | ForEach-Object { Write-Host $_ }
        $results += [pscustomobject]@{ Run = $r; Text = ($out -join "`n"); LogPath = (Join-Path $sim $r.Log) }
    }
} finally { Pop-Location }

# ---------------------------------------------------------------------------
# 4) 判据
# ---------------------------------------------------------------------------
function Get-Text($p) { if (Test-Path $p) { [System.IO.File]::ReadAllText($p) } else { "" } }

$cm = $results | Where-Object { $_.Run.Key -eq 1 }
$rt = $results | Where-Object { $_.Run.Key -eq 0 }
$cmLog = Get-Text $cm.LogPath
$rtLog = Get-Text $rt.LogPath

$checks = @(
    # [!] 判 region 而不是 pc 精确值：core.v 的重定向把 pc_r 写成「目标+4」，
    #     pc 端口永远看不到 0x1000 / 0x10000 本身（见 sim\tb_combined.v 头注释）。
    @{ Desc = "路径 A：boot 跳到 CoreMark 区（region=1）"; Ok = ($cm.Text -match 'region=1 ') },
    @{ Desc = "路径 A：串口出 CoreMark 报告";  Ok = ($cmLog -match 'CoreMark 1\.0') },
    @{ Desc = "路径 A：Total ticks 行";        Ok = ($cmLog -match 'Total ticks') },
    @{ Desc = "路径 A：四 CRC e9f5/e714/1fd7/8e3a";
       Ok = (($cmLog -match 'e9f5') -and ($cmLog -match 'e714') -and ($cmLog -match '1fd7') -and ($cmLog -match '8e3a')) },
    @{ Desc = "路径 B：boot 跳到 RT-Thread 区（region=2）"; Ok = ($rt.Text -match 'region=2 ') },
    @{ Desc = "路径 B：串口出 RT-Thread banner"; Ok = ($rtLog -match 'RT-Thread') }
)

Write-Host ""
Write-Host "=== 合并镜像两条路径 ===" -ForegroundColor Cyan
$bad = 0
foreach ($c in $checks) {
    if ($c.Ok) { Write-Host ("  [PASS] " + $c.Desc) -ForegroundColor Green }
    else { Write-Host ("  [FAIL] " + $c.Desc) -ForegroundColor Red; $bad++ }
}
Write-Host ""
Write-Host "  串口日志：$($cm.LogPath)"
Write-Host "            $($rt.LogPath)"
if ($bad -gt 0) {
    Write-Host "!! $bad 条判据未过 —— 合并镜像不能用，别去综合" -ForegroundColor Red
    exit 1
}
Write-Host "全部通过：同一份 mem.hex 的两条路径都跑通了。" -ForegroundColor Green
exit 0
