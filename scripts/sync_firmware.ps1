param(
    [string]$Prog = "",     # 默认 sim/programs
    [string]$PdsProject = "" # 默认 pds/RV32I_1
)

# 把仿真用的固件镜像同步到 PDS 工程目录，供 rtl/mem/unified_mem.v 的
# $readmemh 在综合时初始化 BRAM。
#
# 统一存储器只用【一份】mem.hex（指令+数据的并集，由 elf2mem.py 生成）。
# 旧设计的 imem.hex / dmem.hex 已无人读取，本脚本会顺手清掉，避免工程里
# 留着一份看起来有效、实际是上一次构建残留的镜像。
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
if ([string]::IsNullOrWhiteSpace($Prog)) { $Prog = Join-Path $repo "sim\programs" }
if ([string]::IsNullOrWhiteSpace($PdsProject)) { $PdsProject = Join-Path $repo "pds\RV32I_1" }

if (-not (Test-Path $Prog)) { throw "找不到固件目录：$Prog（先运行 scripts\run_coremark.ps1）" }
if (-not (Test-Path $PdsProject)) { throw "找不到 PDS 工程目录：$PdsProject" }

$src = Join-Path $Prog "mem.hex"
if (-not (Test-Path $src)) {
    throw "缺少 $src（由 scripts\elf2mem.py 生成，先运行 scripts\run_coremark.ps1）"
}
Copy-Item $src (Join-Path $PdsProject "mem.hex") -Force
Write-Host "已同步 mem.hex -> $PdsProject"

foreach ($stale in @("imem.hex", "dmem.hex")) {
    $old = Join-Path $PdsProject $stale
    if (Test-Path $old) {
        Remove-Item $old -Force
        Write-Host "已删除过期的 $stale（统一存储器不再读取，留着会误导）"
    }
}

Write-Host "完成。在 PDS 里重新 compile / synthesize / P&R 即可。"
