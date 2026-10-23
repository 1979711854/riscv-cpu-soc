<#
.SYNOPSIS
    逐 place seed 的 CPU 域余量取证：P&R 跑动中抢拷 seed_*/cpu_top_board.rtr，跑完自动打表。

.DESCRIPTION
    为什么需要它（P3.6 的三条实证，详见 doc/reports/2026-10-16_p3_6_margin_plan.md §6）：
      * **PDS 的多 seed 选种口径在本设计上是错的**：multiseed_result.csv 按 `Setup(Slow)` 排序，
        那是**跨域 CPU→pix_clk 伪影**（本设计恒为 −1.0 ~ −1.2 ns），与 CPU 域余量无关。
        4 批默认分别挑到 CPU 域 +0.014 / +0.166 / **−0.111** / **−0.091 ns**（后两批时序不过）。
      * P&R 结束只保留被选中的那个 seed 目录，其余全删 ⇒ 想拿全部 seed 的时序**只能跑动中抢拷**。
        `saved_outcome` 无效（PDS 跑完把键删掉，日志逐条 "Work directory … has been removed"）。
      * `report_timing/cpu_top_board.rtr` 在整个 P&R 期间**不更新**，只在出位流时生成一份
        ⇒ 排 seed **必须读 `seed_*/` 里那份**，别读 `report_timing/`。
      * **钉了 `gplace_seed`（单 seed 模式）时 P&R 阶段两个地方都不出 `.rtr`**（2026-10-16 实测）
        ⇒ 本工具会在 PDS 跑完后从 `report_timing\` 兜底收一份（存成 `final_*`），
        **别以为"没抢到就是没跑"**。
    ⇒ 出 1 档位流的正确姿势 = 先跑多 seed + 本脚本取全量 → 选最优点 → 钉 `gplace_seed` → 重出位流。

    两段式用法：
      1) 另一个窗口起 P&R：`scripts\build_bitstream.ps1 coremark`
      2) 本脚本盯住它：    `scripts\capture_seed_timing.ps1 -Tag p37_b1`
    P&R 一结束自动打表（CPU 域 WNS 降序 + 最优 seed + 复现用的 .pds 改法）。

    [!] **每轮必须换独立 -Tag**：P3.6 踩过"把新一批拷进同名旧目录、脚本判文件已存在直接跳过"。

.PARAMETER Tag
    本轮证据子目录名（默认 = 时间戳）。落地 `<OutRoot>\<Tag>\`。

.PARAMETER OutRoot
    证据根目录，默认 `pds\_capture_seeds`（相对仓库根；也可给绝对路径）。

.PARAMETER Parse
    只解析、不盯 P&R：给一个目录（递归找 *.rtr）或单个 .rtr 文件。

.PARAMETER IntervalSeconds
    轮询间隔，默认 4 秒（P3.6 实测 24 个 seed 全部拿到）。

.PARAMETER MaxMinutes
    盯守上限，默认 90 分钟（防呆：到点就用手上的文件打表退出）。

.EXAMPLE
    scripts\capture_seed_timing.ps1 -Tag p37_b1
    scripts\capture_seed_timing.ps1 -Parse pds\_capture_p36
    scripts\capture_seed_timing.ps1 -Parse pds\_capture_p36\seed_5_cpu_top_board.rtr
#>
param(
    [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss"),
    [string]$OutRoot = "pds\_capture_seeds",
    [string]$Parse,
    [int]$IntervalSeconds = 4,
    [int]$MaxMinutes = 90
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$prDir = Join-Path $repo "pds\RV32I_1\place_route"

# CPU 域那一行的判据：Setup Summary(Slow Corner) 里 launch == capture == 这个时钟名。
# （跨域 CPU→pix_clk 行也在这个表里，但它**永远**是负的、不是回归 —— 别拿它排 seed。）
$CpuClk = 'clk|u_pll/u_gpll/CLKOUT0_Inferred'
$SeedRtrName = 'cpu_top_board.rtr'

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 读可能被 PDS 占用的文件（共享读），避免 "正被另一进程使用"
function Read-TextShared {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        return $sr.ReadToEnd()
    } catch { return $null }
    finally { if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() } }
}

# 从一份 .rtr 里取出 CPU 时钟的**请求周期**（ns），用来算可达 Fmax。
# [!] 2026-10-17 实踩：原先 Fmax 按 85MHz 的 11.764 写死，拿它解析 76.5MHz 的报告
#     会打印 87.26 MHz（错 11%）。周期必须从报告本身读：
#     时钟声明表里 CPU 时钟那一行的第一个数字就是请求周期
#     （85 档 11.764 / 76.5 档 13.071）。
function Read-CpuPeriod {
    param([string]$File)
    $txt = Read-TextShared $File
    if (-not $txt) { return $null }
    foreach ($l in ($txt -split "`r?`n")) {
        if ($l.TrimStart().StartsWith($CpuClk)) {
            $n = @($l.Trim() -split '\s+')
            if ($n.Count -ge 2) {
                $v = 0.0
                if ([double]::TryParse($n[1], [ref]$v) -and $v -gt 0) { return $v }
            }
        }
    }
    return $null
}

# 从一份 .rtr 里取出 CPU 域那一行（WNS / TNS / 失败端点 / 总端点）
function Read-CpuWns {
    param([string]$File)
    $txt = Read-TextShared $File
    if (-not $txt) { return $null }
    $lines = $txt -split "`r?`n"
    $inSetup = $false
    for ($i = 0; $i -lt ($lines.Count - 2); $i++) {
        $l = $lines[$i]
        if (-not $inSetup) {
            if ($l -match 'Setup Summary\(Slow Corner\)') { $inSetup = $true }
            continue
        }
        # 出了 setup 段就收工（后面还有 Hold / Recovery / Fast Corner 等段，时钟名会重复出现）
        if ($l -match '^\s*(Hold|Recovery|Removal|Minimum Pulse Width|Setup) Summary') { break }
        if ($l.Trim() -ne $CpuClk) { continue }
        if ($lines[$i + 1].Trim() -ne $CpuClk) { continue }
        $n = @($lines[$i + 2].Trim() -split '\s+')
        if ($n.Count -lt 4) { continue }
        return [pscustomobject]@{ Wns = [double]$n[0]; Tns = [double]$n[1]
                                  FailEP = [int]$n[2]; TotalEP = [int]$n[3] }
    }
    return $null
}

# 打表（降序）+ 落 CSV，返回最优行
function Show-CpuWnsTable {
    param([string]$Dir, [string]$CsvPath)

    # 收 *.rtr，也收抢拷时另存的 *_rtr.txt（P3.6 的 batch4 / route_sweep 就是这种命名）
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '\.rtr$' -or $_.Name -match '_rtr\.txt$' } |
               Sort-Object FullName | ForEach-Object { $_.FullName })
    if ($files.Count -eq 0) {
        Write-Host "  （$Dir 下没有 .rtr 可解析）" -ForegroundColor Yellow
        return $null
    }

    $rows = @()
    foreach ($f in $files) {
        $w = Read-CpuWns $f
        $label = $f
        if ($label.StartsWith($Dir, [System.StringComparison]::OrdinalIgnoreCase)) {
            $label = $label.Substring($Dir.Length).TrimStart('\', '/')
        }
        $m = [regex]::Match($label, 'seed_(\d+)')
        $seed = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
        $rows += [pscustomobject]@{
            Seed = $seed; Label = $label
            Wns  = if ($w) { $w.Wns } else { $null }
            Period = if ($w) { Read-CpuPeriod $f } else { $null }
            FailEP = if ($w) { $w.FailEP } else { $null }
            TotalEP = if ($w) { $w.TotalEP } else { $null }
            # [?] 读不出 Setup Summary 的（拷到半截 / 不是 CPU 域报告）
            Bad = (-not $w)
        }
    }

    $ok = @($rows | Where-Object { -not $_.Bad })
    if ($ok.Count -eq 0) {
        Write-Host "  [!] $($rows.Count) 份 .rtr 里没有一行能解析出 CPU 域 Setup Summary —— 全是半截文件？" -ForegroundColor Yellow
        return $null
    }
    $sorted = @($ok | Sort-Object -Property Wns -Descending)

    Write-Host ""
    Write-Host "=== CPU 域余量（$CpuClk）—— 判据行，降序 ===" -ForegroundColor Cyan
    Write-Host ("  {0,-6} {1,-10} {2,-9} {3,-9} {4}" -f "seed", "WNS(ns)", "failEP", "totalEP", "文件")
    foreach ($r in $sorted) {
        $col = if ($r.Wns -lt 0) { "Yellow" } else { "Gray" }
        $seedTxt = if ($r.Seed -ge 0) { $r.Seed } else { "-" }
        Write-Host ("  {0,-6} {1,-10} {2,-9} {3,-9} {4}" -f $seedTxt, ("{0:+0.000;-0.000;0.000}" -f $r.Wns),
                    $r.FailEP, $r.TotalEP, $r.Label) -ForegroundColor $col
    }
    if ($rows.Count -ne $ok.Count) {
        Write-Host "  [!] 另有 $($rows.Count - $ok.Count) 份解析失败（半截拷贝），已忽略" -ForegroundColor DarkYellow
    }

    $best = $sorted[0]
    $bestTag = if ($best.Seed -ge 0) { "seed $($best.Seed)" } else { "（钉 seed / 单 seed 模式，只有一份）" }
    # Fmax = 1000 / (请求周期 − WNS)。周期从报告里读，**不能写死**
    # （写死 11.764 会把 76.5 档算成 87.26 MHz，2026-10-17 实踩）。
    $period = $best.Period
    if (-not $period) {
        $period = 11.764
        Write-Host "  [!] 这份报告读不到 CPU 时钟的请求周期，按 85MHz 的 11.764 算 —— 换过频的话这个 Fmax 不可信" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host ("  最优：{0}  WNS {1} ns / 可达 Fmax {2} MHz  （请求周期 {3} ns，totalEP {4}，{5}）" -f `
        $bestTag, `
        ("{0:+0.000;-0.000;0.000}" -f $best.Wns), `
        ([math]::Round(1000.0 / ($period - $best.Wns), 4)), $period, $best.TotalEP, $best.Label) -ForegroundColor Green
    if ($best.Seed -ge 0) {
        Write-Host "  复现该布局：把 pds\RV32I_1\RV32I_1.pds 的 cmd_pnr 里 gplace_times 换成" -ForegroundColor Green
        Write-Host "             (_option gplace_seed (_integer $($best.Seed)))" -ForegroundColor Green
        Write-Host "             再跑 scripts\build_bitstream.ps1 coremark 出位流（钉后不再产生 seed_*/）。" -ForegroundColor Green
    }
    Write-Host "  [!] 跨域 CPU→pix_clk 那行（−1.0 ~ −1.2 ns）是既有伪影，别拿它排序。" -ForegroundColor DarkGray

    if ($CsvPath) {
        $sorted | Select-Object @{n = 'file'; e = { $_.Label }},
                                @{n = 'seed'; e = { $_.Seed }},
                                @{n = 'wns_ns'; e = { "{0:0.000}" -f $_.Wns }},
                                @{n = 'failEP'; e = { $_.FailEP }},
                                @{n = 'totalEP'; e = { $_.TotalEP }} |
            Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "  表格已落盘：$CsvPath" -ForegroundColor DarkGray
    }
    return $best
}

# ---------------------------------------------------------------------------
# -Parse：只解析
# ---------------------------------------------------------------------------
if ($Parse) {
    $p = if ([System.IO.Path]::IsPathRooted($Parse)) { $Parse } else { Join-Path $repo $Parse }
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "!! 找不到 $p" -ForegroundColor Red; exit 1 }
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $dir = Split-Path $p -Parent; $tmp = Join-Path $env:TEMP ("parse_" + [IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Copy-Item $p (Join-Path $tmp (Split-Path $p -Leaf))
        $best = Show-CpuWnsTable -Dir $tmp -CsvPath $null
        exit 0
    }
    $best = Show-CpuWnsTable -Dir $p -CsvPath $null
    exit 0
}

# ---------------------------------------------------------------------------
# 盯守模式
# ---------------------------------------------------------------------------
$outDir = if ([System.IO.Path]::IsPathRooted($OutRoot)) { Join-Path $OutRoot $Tag }
          else { Join-Path $repo (Join-Path $OutRoot $Tag) }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host ""
Write-Host "=== 逐 seed 时序取证（抢拷 $SeedRtrName）===" -ForegroundColor Cyan
Write-Host "  证据目录：$outDir"
Write-Host "  P&R 目录：$prDir"

# 提醒当前 .pds 的 seed 选项（钉了 gplace_seed 就是单 seed 模式，不会有 seed_*/）
$pdsTxt = Read-TextShared (Join-Path $repo "pds\RV32I_1\RV32I_1.pds")
if ($pdsTxt) {
    $gps = [regex]::Match($pdsTxt, '\(_option\s+gplace_seed\s+\(_integer\s+(\d+)\)\)')
    $gpt = [regex]::Match($pdsTxt, '\(_option\s+gplace_times\s+\(_integer\s+(\d+)\)\)')
    if ($gps.Success) {
        Write-Host "  [!] .pds 已钉 gplace_seed = $($gps.Groups[1].Value)（单 seed 模式）：不会有 seed_*/，" -ForegroundColor Yellow
        Write-Host "      P&R 结束只能拿 place_route\ 那一份。想看多布局分布请先换回 gplace_times。" -ForegroundColor Yellow
    } else {
        $t = if ($gpt.Success) { $gpt.Groups[1].Value } else { "默认" }
        Write-Host "  .pds：未钉 gplace_seed，gplace_times = $t（多 seed 模式，会产生 seed_*/）"
    }
} else {
    Write-Host "  [!] 读不到 .pds（没关系，继续抢拷）" -ForegroundColor DarkYellow
}
Write-Host "  轮询间隔 $IntervalSeconds s，盯守上限 $MaxMinutes min（Ctrl+C 可随时停，已拷的都在）"
Write-Host ""

# 拷一份 seed 目录里的报告（>1KB 才算写完，防拷到 0 字节的半截文件）
$script:captured = 0
function Copy-SeedRtrs {
    param([switch]$Verbose)
    if (-not (Test-Path -LiteralPath $prDir)) { return }
    foreach ($d in @(Get-ChildItem -LiteralPath $prDir -Directory -Filter 'seed_*' -ErrorAction SilentlyContinue)) {
        $src = Join-Path $d.FullName $SeedRtrName
        $fi = Get-Item -LiteralPath $src -ErrorAction SilentlyContinue
        if (-not $fi -or $fi.Length -le 1KB) { continue }   # 竞态：正在写 → 下次再来
        $seedNum = $d.Name -replace '^seed_', ''
        $dst = Join-Path $outDir ("seed_{0}_{1}" -f $seedNum, $SeedRtrName)
        try {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            if ($Verbose) { Write-Host ("  [+] 抢拷 seed_{0}  ({1:N0} KB)" -f $seedNum, ($fi.Length / 1KB)) -ForegroundColor Gray }
            $script:captured++
        } catch { }
    }
}

$t0 = Get-Date
$deadline = $t0.AddMinutes($MaxMinutes)
$sawPds = $false
$lastTick = 0

while ((Get-Date) -lt $deadline) {
    $before = $script:captured
    Copy-SeedRtrs -Verbose
    if ($script:captured -gt $before) { $lastTick = 0 } else { $lastTick++ }

    if (Get-Process -Name pds_shell -ErrorAction SilentlyContinue) {
        $sawPds = $true
        if (($lastTick % 15) -eq 0 -and $lastTick -gt 0) {
            Write-Host ("  ... 已等 {0:N1} min，手上 {1} 份（P&R 还在跑）" -f ((Get-Date) - $t0).TotalMinutes, $script:captured) -ForegroundColor DarkGray
        }
    } elseif ($sawPds) {
        Write-Host "  P&R 已结束，做收尾拷贝（被保留的 seed_*/ 那份才是最终值）..." -ForegroundColor Green
        Start-Sleep -Seconds 3
        Copy-SeedRtrs
        break
    } else {
        # 防呆：一直没等到 PDS 就说明起早了/起晚了 —— 10 min 后按现有文件收尾，别干等 90 min
        if (-not $sawPds -and (Get-Date) -gt $t0.AddMinutes(10)) {
            Write-Host "  [!] 已 10 分钟没看到 pds_shell 进程 —— 你是在 P&R 跑完之后才起的本工具？" -ForegroundColor Yellow
            Write-Host "      先按现有文件收尾。想在 P&R 结束后单独打表请用：-Parse <目录>" -ForegroundColor Yellow
            break
        }
        if (($lastTick % 15) -eq 0) { Write-Host "  ... 还没看到 pds_shell 进程，继续等（先起 build_bitstream.ps1？）" -ForegroundColor DarkGray }
    }
    Start-Sleep -Seconds $IntervalSeconds
}

# ---- 收尾：把"最终交付布局"的那份也留在证据里 ----
# [!] 2026-10-16 实测（钉 seed 的单 seed 模式）：P&R 阶段**两个地方都不出 .rtr** ——
#     `place_route\` 里只有 .prr / .adf / .netlist，`report_timing\cpu_top_board.rtr`
#     要等 PDS 把 Report Timing 跑完才写。所以单 seed 模式下本工具**只能靠这条兜底**，
#     别以为"没抢到就是没跑"。
#     多 seed 模式下这份 = **PDS 最终选中那个 seed** 的报告（正是"选种口径错"的现场证据）。
$finalCands = @(
    @{ Path = (Join-Path $prDir $SeedRtrName);                             Name = "final_place_route_$SeedRtrName" },
    @{ Path = (Join-Path $repo "pds\RV32I_1\report_timing\$SeedRtrName");  Name = "final_report_timing_$SeedRtrName" }
)
foreach ($c in $finalCands) {
    if (-not (Test-Path -LiteralPath $c.Path)) { continue }
    $fi = Get-Item -LiteralPath $c.Path -ErrorAction SilentlyContinue
    # 只认本轮（$t0）之后写的，避免把上一轮的陈旧报告当成本轮结果
    if (-not $fi -or $fi.Length -le 1KB -or $fi.LastWriteTime -lt $t0) { continue }
    Copy-Item -LiteralPath $c.Path -Destination (Join-Path $outDir $c.Name) -Force
    Write-Host "  另存 $($c.Name)（源：$($c.Path)）" -ForegroundColor Gray
}
if ($script:captured -eq 0) {
    Write-Host "  [!] 本轮一个 seed_*/ 都没抢到 —— 若 .pds 钉了 gplace_seed 就是正常的" -ForegroundColor Yellow
    Write-Host "      （单 seed 模式不产生 seed_*/，只看上面 final_* 那份）。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  本轮共拿到 $($script:captured) 份 seed 报告（用时 $([math]::Round(((Get-Date) - $t0).TotalMinutes, 1)) min）"
$null = Show-CpuWnsTable -Dir $outDir -CsvPath (Join-Path $outDir 'seed_cpu_wns_summary.csv')
Write-Host ""
Write-Host "  取证三件套（引用余量时必须一起给）：本目录的 .rtr + seed_cpu_wns_summary.csv + P&R 日志时间" -ForegroundColor DarkGray
