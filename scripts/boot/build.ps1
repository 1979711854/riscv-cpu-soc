<#
============================================================================
 build.ps1 —— 编译 boot selector（scripts/boot/boot.S）
----------------------------------------------------------------------------
 用法：
   scripts\boot\build.ps1              编译 + 链接 + 出 hex，打印占用
   scripts\boot\build.ps1 -Quiet       只在失败时出声（给 build_bitstream.ps1 调）

 产物：scripts\boot\build\boot.elf
       scripts\boot\build\{imem,dmem,mem}.hex   （mem.hex 供 merge_images.py）

 [!] 4KB 是硬上限（0x0~0xFFF，0x1000 起是 CoreMark 的 .text.init）。
     链接脚本用 ASSERT 挡；这里再按 ELF 的段末地址复核一遍，双保险。
============================================================================
#>
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent (Split-Path -Parent $Here)
$Tool = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
$GCC  = Join-Path $Tool "riscv-none-elf-gcc.exe"
$SIZE = Join-Path $Tool "riscv-none-elf-size.exe"
$NM   = Join-Path $Tool "riscv-none-elf-nm.exe"

$Build = Join-Path $Here "build"
$Elf   = Join-Path $Build "boot.elf"
New-Item -ItemType Directory -Force -Path $Build | Out-Null

function Say($msg, $color = "Gray") { if (-not $Quiet) { Write-Host $msg -ForegroundColor $color } }

Say "[1/3] 编译 boot.S ..." Cyan

# [!] ld 的 "LOAD segment with RWX permissions" 警告在 PS 5.1 下会被
#     $ErrorActionPreference="Stop" 包成 NativeCommandError（同 run_coremark.ps1）。
#     调 gcc 期间临时切 Continue，真正的失败由退出码兜 —— 别用 2>$null（仍是终态）。
$eapSave = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & $GCC -march=rv32im -mabi=ilp32 -Os -nostdlib -nostartfiles `
           "-T$Here\link.ld" "$Here\boot.S" -o $Elf
} finally {
    $ErrorActionPreference = $eapSave
}
if ($LASTEXITCODE -ne 0) { throw "boot.S 编译/链接失败（多半是超过 4KB，看上面的 ASSERT）" }

Say "[2/3] 体积复核 ..." Cyan
$sizeLine = (& $SIZE $Elf | Select-Object -Last 1) -split '\s+' | Where-Object { $_ -ne '' }
$text = [int]$sizeLine[0]; $data = [int]$sizeLine[1]; $bss = [int]$sizeLine[2]
$endAddr = 0
foreach ($l in (& $NM $Elf)) {
    if ($l -match '^([0-9a-fA-F]+)\s+\S\s+_end$') { $endAddr = [Convert]::ToInt32($matches[1], 16) }
}
Say ("      .text = {0,5} B   .data = {1} B   .bss = {2} B" -f $text, $data, $bss)
Say ("      段末 _end = 0x{0:X}  （上限 0x1000）" -f $endAddr)
if ($endAddr -gt 0x1000) {
    throw ("boot selector 段末 0x{0:X} 越过 0x1000 —— 会和 CoreMark 的 .text.init 重叠。" -f $endAddr)
}

Say "[3/3] 出 hex ..." Cyan
& python (Join-Path $Repo "scripts\elf2mem.py") $Elf $Build
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

$lines = (Get-Content (Join-Path $Build "mem.hex")).Count
Say ("      -> {0}\mem.hex  {1} 行（{2} 字）" -f $Build, $lines, ($lines / 2)) Green
if (-not $Quiet) { Write-Host "完成：$Elf" -ForegroundColor Green }
