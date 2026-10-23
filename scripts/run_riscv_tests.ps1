param(
    [string]$TestsDir = "",     # riscv-tests 源码目录（含 isa/rv32ui）。默认 third_party/riscv-tests
    [string]$ElfDir = "",       # 已有 ELF 的目录：给了就跳过编译，直接跑这些 ELF
    [int]$FirstN = 0,           # >0 时只跑前 N 个测试（快速回归用）
    [int]$MemWait = 0,          # >0 时给访存注入等待（+MEMWAIT=n，验 mem_ready 停顿逻辑）；0 = 逐位不变
    [switch]$DCache,            # 打开 D-Cache（-DDCACHE，DCACHE_EN=1）。默认关
    [switch]$ICache,            # 打开 I-Cache（-DICACHE，ICACHE_EN=1）。默认关
    [switch]$EarlyLd,           # [任务 C] load 地址提前（-DEARLYLD，EARLY_LD=1）。默认关
    [switch]$NoBtb,             # [B1-BTB] 关分支目标缓冲（-DNOBTB，BTB_EN=0）。默认【开】，与板上一致
    [switch]$LanebMem,          # [lane B 访存] lane B 放 load（-DLANEBMEM，LANEB_MEM=1）。默认关（P2 口径）
    [switch]$Single,            # 切单发射（不传 -DDUAL）。默认【双发射】，与板上比特流一致
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
)

# riscv-tests (rv32ui) 一键：编译全部 .S -> 逐个跑 tb_riscv -> 汇总 PASS/FAIL
# 没有源码时可用 -ElfDir 指向一份现成的 ELF 目录，跳过编译直接回归。例如：
#   scripts\run_riscv_tests.ps1 -ElfDir riscv32-FPGA-pds\riscv-tests-run\build
#
# [重点] 配置必须显式、且与板上比特流对齐：
#   默认 = 双发射（编译传 -DDUAL）—— 与 cpu_top.v 的 DUAL_ISSUE=1（板上口径）一致。
#   -Single = 单发射（不传 -DDUAL）—— 只有为回退版比特流把关时才用。
#   两条基线不同（双发射 49/1/0 + CoreMark 229,597；单发射 49/1/0 + 303,140），别混。
#   日志首行 "SIM CONFIG: DUAL_ISSUE=?" 与 results.txt 首行会自证本次跑的是哪一种。
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
$env:RISCV_TOOLS = $Toolchain

if ([string]::IsNullOrWhiteSpace($TestsDir)) { $TestsDir = Join-Path $repo "third_party\riscv-tests" }
$isaDir = Join-Path $TestsDir "isa\rv32ui"
$macroDir = Join-Path $TestsDir "isa\macros\scalar"
# riscv-tests 的 riscv_test.h / encoding.h 在 env/ 下（常见布局是 env/p/）。
# 两个都加进 include 路径，兼容不同版本的目录结构。
$envDir = Join-Path $TestsDir "env"
$envPDir = Join-Path $envDir "p"
$linkLd = Join-Path $repo "scripts\riscv_tests_link.ld"

# 仓库里随附的基线 ELF（没有 riscv-tests 源码时的退路）
$bundledElfDir = Join-Path $repo "third_party\riscv-tests-elf"

$prog = Join-Path $repo "sim\programs"
New-Item -ItemType Directory -Force -Path $prog | Out-Null

# 没给 -ElfDir 时决定走哪条路：有源码就编译，没有就回退到随附的基线 ELF
if ([string]::IsNullOrWhiteSpace($ElfDir) -and -not (Test-Path $isaDir)) {
    if (Test-Path $bundledElfDir) {
        $ElfDir = $bundledElfDir
        Write-Host "[1/3] 未找到 riscv-tests 源码，改用随附的基线 ELF：$bundledElfDir"
        Write-Host "      （来源与再生成方式见该目录下的 README.md）"
    }
    else {
        Write-Host "找不到 riscv-tests 源码：$isaDir"
        Write-Host "也不存在随附的基线 ELF：$bundledElfDir"
        Write-Host "获取方式（任选其一）："
        Write-Host "  1) 联网 clone 源码（建议挂代理）："
        Write-Host "       git clone --depth 1 https://github.com/riscv-software-src/riscv-tests third_party/riscv-tests"
        Write-Host "     或把队友机器上的 riscv-tests 目录拷过来"
        Write-Host "  2) 直接用现成 ELF 回归："
        Write-Host "       scripts\run_riscv_tests.ps1 -ElfDir <含 *.elf 的目录>"
        exit 1
    }
}

if (-not [string]::IsNullOrWhiteSpace($ElfDir)) {
    # ---- 1) 直接用现成 ELF，跳过编译 ----
    if (-not (Test-Path $ElfDir)) { throw "找不到 ELF 目录：$ElfDir" }
    $elfs = @(Get-ChildItem $ElfDir -Filter "*.elf" | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($elfs.Count -eq 0) { throw "$ElfDir 下没有 .elf 文件" }
    Write-Host "      使用现成 ELF：$($elfs.Count) 个"
}
else {
    # ---- 1) 编译全部测试 ELF ----
    Write-Host "[1/3] 编译 rv32ui 测试 ..."
    $elfs = @()
    foreach ($f in Get-ChildItem (Join-Path $isaDir "*.S") | Sort-Object Name) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $elf = Join-Path $prog "$name.elf"
        & riscv-none-elf-gcc -march=rv32i_zicsr_zifencei -mabi=ilp32 -static -mcmodel=medany `
            -nostdlib -nostartfiles -I"$isaDir" -I"$macroDir" -I"$envPDir" -I"$envDir" `
            -T"$linkLd" $f.FullName -o $elf
        if ($LASTEXITCODE -eq 0) { $elfs += $elf }
    }
    Write-Host "      编译出 $($elfs.Count) 个 ELF"
}
if ($FirstN -gt 0) { $elfs = $elfs[0..([Math]::Min($FirstN, $elfs.Count) - 1)] }

# ---- 2) 编译 testbench（只编一次）----
# vvp 文件名带配置后缀，避免"单发射产物"被误当成双发射的构建结果。
$vvpName = if ($dualIssue -eq 1) { "tb_riscv_dual.vvp" } else { "tb_riscv_single.vvp" }
if ($dcacheEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_dcache.vvp" }
if ($icacheEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_icache.vvp" }
if ($earlyLdEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_earlyld.vvp" }
if ($btbEn     -eq 0) { $vvpName = $vvpName -replace "\.vvp$", "_nobtb.vvp" }
if ($lanebMemEn -eq 1) { $vvpName = $vvpName -replace "\.vvp$", "_lanebmem.vvp" }
Write-Host "[2/3] 编译 testbench ... DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn（$vvpName）"
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
    "-o", $vvp, (Join-Path $sim "tb_riscv.v")
) + $rtl
$ivOut = & iverilog @iverilogArgs 2>&1
$ivOut | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }
# [!] **端口宽度不一致 = 静默截位，必须当错误处理**（2026-10-10 实踩）。
#     64KB 扩容时 `imem_addr2` 漏改成 14 位，iverilog 每次都报
#       "Port 5 (a2_addr) of module unified_mem expects 14 bit(s), given 13"
#     但没人看这行警告，于是"取指地址 ≥ 0x8000 时 lane B 取错指令"的 bug
#     躲过了全部四条基线。这类警告没有一条是良性的 —— 现在它们是硬错误。
$widthWarn = @($ivOut | Where-Object { $_ -match 'expects \d+ bit\(s\), given' })
if ($widthWarn.Count -gt 0) {
    $widthWarn | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "iverilog 报了 $($widthWarn.Count) 条端口宽度不一致 —— 那是静默截位，先把宽度对齐再跑回归"
}

# ---- 3) 逐个跑 ----
Write-Host "[3/3] 逐个仿真 ...（SIM CONFIG: DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn MEMWAIT=$MemWait）"
$pass = 0; $fail = 0; $timeout = 0; $other = 0
$lines = @()
foreach ($elf in $elfs) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($elf)
    & python (Join-Path $repo "scripts\elf2mem.py") $elf $prog | Out-Null
    Push-Location $sim
    try {
        $out = & vvp $vvp "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex" "+TOHOST=programs/tohost_addr.hex" "+MEMWAIT=$MemWait" 2>&1
    }
    finally { Pop-Location }
    $hit = ($out | Select-String -Pattern "PASS|FAIL|TIMEOUT|UNEXPECTED" | Select-Object -First 1)
    $txt = if ($hit) { $hit.Line } else { "???" }
    if     ($txt -match "PASS")     { $pass++;    $lines += "PASS     $name" }
    elseif ($txt -match "FAIL")     { $fail++;    $lines += "FAIL     $name   $txt" }
    elseif ($txt -match "TIMEOUT")  { $timeout++; $lines += "TIMEOUT  $name" }
    else                            { $other++;   $lines += "???      $name   $txt" }
    Write-Host ("  {0,-10} {1}" -f $name, $txt)
}

@("SIM CONFIG: DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn MEMWAIT=$MemWait") + $lines | Set-Content (Join-Path $prog "results.txt")
Write-Host ""
Write-Host "======== 汇总 ========"
Write-Host "SIM CONFIG: DUAL_ISSUE=$dualIssue DCACHE_EN=$dcacheEn ICACHE_EN=$icacheEn EARLY_LD=$earlyLdEn BTB_EN=$btbEn MEMWAIT=$MemWait" -ForegroundColor Cyan
Write-Host "PASS=$pass  FAIL=$fail  TIMEOUT=$timeout  OTHER=$other"
Write-Host "明细: sim/programs/results.txt（首行即本次配置）"
