# ============================================================================
# 自写汇编测试（sim/tests/*.S）的汇编 + 运行脚本
# ----------------------------------------------------------------------------
# 与 run_riscv_tests.ps1 的区别：
#   * 那一份跑的是 riscv-tests 的官方测试（用随附的预编译基线 ELF）
#   * 这一份跑的是我们自己写的定向测试，现场用工具链汇编
#
# 我们的测试需要 riscv-tests 的 env 头文件（trap_vector 约定、tohost 机制、
# CSR 编号），那份 env 已入库在 third_party/riscv-tests-env/。
#
# 用法：
#   scripts\run_own_tests.ps1                  # 跑 sim/tests 下全部 .S
#   scripts\run_own_tests.ps1 -Name timer_irq  # 只跑一个
#   scripts\run_own_tests.ps1 -KeepHex         # 保留中间 hex 以便手动 vvp
# ============================================================================
param(
    [string]$Name = "",
    [switch]$KeepHex,
    [int]$MemWait = 0,  # >0 时给访存注入等待（+MEMWAIT=n，验 mem_ready 停顿逻辑）；0 = 逐位不变
    [switch]$DCache,    # 打开 D-Cache（-DDCACHE，DCACHE_EN=1）。默认关
    [switch]$ICache,    # 打开 I-Cache（-DICACHE，ICACHE_EN=1）。默认关
    [switch]$EarlyLd,   # [任务 C] load 地址提前（-DEARLYLD，EARLY_LD=1）。默认关
    [switch]$NoBtb,     # [B1-BTB] 关分支目标缓冲（-DNOBTB，BTB_EN=0）。默认【开】，与板上一致
    [switch]$LanebMem,  # [lane B 访存] lane B 放 load（-DLANEBMEM，LANEB_MEM=1）。默认关（P2 口径）
    [switch]$Single     # 切单发射（不传 -DDUAL）。默认【双发射】，与板上比特流一致
)

$ErrorActionPreference = "Stop"
$dualIssue = if ($Single) { 0 } else { 1 }
$dcacheEn  = if ($DCache) { 1 } else { 0 }
$icacheEn  = if ($ICache) { 1 } else { 0 }
$earlyLdEn = if ($EarlyLd) { 1 } else { 0 }
$btbEn     = if ($NoBtb)  { 0 } else { 1 }
# [lane B 访存] 默认 0 = P2 口径（lane B 不放 load）；-LanebMem 切 1 = P3 口径。
#   core.v 的参数默认值终将随 P3 翻 1，但仿真侧保留显式开关，便于 0/1 两档对照。
$lanebMemEn = if ($LanebMem) { 1 } else { 0 }
$repo = Split-Path -Parent $PSScriptRoot

$gcc = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-gcc.exe"
if (-not (Test-Path $gcc)) { throw "找不到工具链：$gcc" }

$envDir  = Join-Path $repo "third_party\riscv-tests-env"
$testDir = Join-Path $repo "sim\tests"
$ld      = Join-Path $repo "scripts\riscv_tests_link.ld"
$sim     = Join-Path $repo "sim"
$prog    = Join-Path $sim "programs"
$build   = Join-Path $sim "tests\build"

if (-not (Test-Path $envDir)) { throw "找不到 env 头文件：$envDir" }
if (-not (Test-Path $testDir)) { throw "找不到测试目录：$testDir" }
New-Item -ItemType Directory -Force -Path $build | Out-Null
New-Item -ItemType Directory -Force -Path $prog  | Out-Null

# [!] 这几个用【旧 done/UART 协议】汇报（写 0xFFF8 + UART 0xFFFC），不吃本脚本的
#     tohost 判分，由各自的测试台驱动 —— 别放进回归 glob（否则会误报 OTHER/FAIL）：
#       amo_int     T0 逐拍 trace 的输入程序（配 sim/tb_amo_int.v）
#       dep_probe   双发射相邻依赖对的诊断探针（非回归）
$skipThese = @('amo_int', 'dep_probe')
$srcs = @(Get-ChildItem $testDir -Filter "*.S" |
          Where-Object { $skipThese -notcontains $_.BaseName } |
          Sort-Object Name)
if ($Name -ne "") { $srcs = @($srcs | Where-Object { $_.BaseName -eq $Name }) }
if ($srcs.Count -eq 0) { throw "没有找到匹配的 .S 测试" }

# ---------------------------------------------------------------------------
# [1/3] 汇编 + 链接
# ---------------------------------------------------------------------------
Write-Host "[1/3] 编译并链接 $($srcs.Count) 个测试 ..."
foreach ($s in $srcs) {
    $elf = Join-Path $build "$($s.BaseName).elf"
    # [!] 2026-10-16：ld 的 RWX 警告走 stderr，而本脚本 $ErrorActionPreference="Stop"
    #    会让它变成终态错误（构建阶段当场死，ELF 其实已生成）。
    #    修法：汇编期间临时把 EAP 切到 Continue，退出码兜真正的失败。
    #    **别用 2>$null** —— 实测 PS 5.1 下仍然终态。
    $eapSave = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 `
            -nostdlib -nostartfiles -static -mcmodel=medany `
            -I $envDir -I (Join-Path $envDir "p") -I $testDir `
            -T $ld -o $elf $s.FullName
    } finally {
        $ErrorActionPreference = $eapSave
    }
    if ($LASTEXITCODE -ne 0) { throw "$($s.Name) 汇编/链接失败" }
}

# ---------------------------------------------------------------------------
# [2/3] 编译测试台（只编 core/bus/periph，SoC 级顶层不参与）
# ---------------------------------------------------------------------------
# vvp 文件名带配置后缀（与 run_riscv_tests.ps1 同名同配置可复用），避免配置混用。
$vvpName = if ($dualIssue -eq 1) { "tb_riscv_dual.vvp" } else { "tb_riscv_single.vvp" }
if ($dcacheEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_dcache.vvp" }
if ($icacheEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_icache.vvp" }
if ($earlyLdEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_earlyld.vvp" }
if ($btbEn     -eq 0) { $vvpName = $vvpName -replace "\.vvp$", "_nobtb.vvp" }
if ($lanebMemEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_lanebmem.vvp" }
Write-Host "[2/3] 编译测试台 ... DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn LANEB_MEM=$lanebMemEn（$vvpName）"
$vvp  = Join-Path $sim $vvpName
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
# [lane B 访存] -LanebMem → -DLANEBMEM（LANEB_MEM=1）。不传 = 0（P2 口径，与板上默认一致）。
if ($lanebMemEn -eq 1) { $defs += "-DLANEBMEM" }
# [面积优化] A 扩展：**本脚本必须传** —— 套件里有 `tb_amo_cpu`（A 扩展整核测试）。
#   core 的 A_EXT 默认 0（生产档砍掉省面积），不传的话它会以 testnum 668 FAIL。
#   `run_riscv_tests.ps1` 则相反：回归集里没有 rv32ua，A_EXT=0 才是板上口径。
$defs += "-DAEXT"
$iverilogArgs = @("-g2012") + $defs + @(
    "-I", (Join-Path $repo "rtl\core"), "-I", (Join-Path $repo "rtl\periph"),
    "-I", (Join-Path $repo "rtl\bus"), "-I", $sim,
    "-o", $vvp, (Join-Path $sim "tb_riscv.v")
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

# ---------------------------------------------------------------------------
# [3/3] 逐个跑
# ---------------------------------------------------------------------------
Write-Host "[3/3] 运行 ...（SIM CONFIG: DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn LANEB_MEM=$lanebMemEn MEMWAIT=$MemWait）"
$pass = 0; $fail = 0; $other = 0
$results = @()
foreach ($s in $srcs) {
    $elf = Join-Path $build "$($s.BaseName).elf"
    & python (Join-Path $repo "scripts\elf2mem.py") $elf $prog | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$($s.Name) 转 hex 失败" }

    Push-Location $sim
    try {
        $out = & vvp $vvp "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" `
                      "+TOHOST=programs/tohost_addr.hex" "+MEMWAIT=$MemWait" 2>&1
    } finally { Pop-Location }

    $line = ($out | Where-Object { $_ -match "=== (PASS|FAIL|TIMEOUT|UNEXPECTED)" } |
             Select-Object -First 1)
    if     ($line -match "=== PASS")       { $pass++;  $tag = "PASS" }
    # 注意用非贪婪的 [^=]* —— `.*===` 会贪婪地吃到【最后一个】"==="，把 tag 吃空
    elseif ($line -match "=== FAIL")       { $fail++;  $tag = ($line -replace '^[^=]*=== ','') -replace ' ===$','' }
    elseif ($line -match "=== TIMEOUT")    { $other++; $tag = "TIMEOUT" }
    else                                   { $other++; $tag = "OTHER" }
    $results += [pscustomobject]@{ Name = $s.BaseName; Result = $tag }
    Write-Host ("  {0,-16} === {1} ===" -f $s.BaseName, $tag)
}

Write-Host ""
Write-Host "======== 汇总 ========"
Write-Host "SIM CONFIG: DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn LANEB_MEM=$lanebMemEn MEMWAIT=$MemWait" -ForegroundColor Cyan
Write-Host "PASS=$pass  FAIL=$fail  OTHER=$other"
$results | Format-Table -AutoSize | Out-String | Write-Host

if ($fail -gt 0 -or $other -gt 0) { exit 1 }

# 默认清掉中间产物；-KeepHex 时保留，方便手动 vvp 复盘
if (-not $KeepHex) {
    Remove-Item -Recurse -Force $build -ErrorAction SilentlyContinue
}
