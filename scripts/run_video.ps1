param(
    [string]$Toolchain = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin",
    [switch]$SkipBuild,          # 跳过编译，复用已有 ELF
    [switch]$SkipSim,            # 只生成固件、不跑仿真（上板流程只需要 mem.hex）
    [switch]$NoWave              # 不弹 GTKWave
)

# 彩条固件一键：编译 video.c+start.S -> 拆 hex -> iverilog 编译 tb_video_bars -> 跑
# 验收内容（tb_video_bars.v 逐项比对）：
#   ① 串口自检：CPU→mem_bus→显存 写进去再读回来，值对不对
#   ② 一条有效行的像素：固件写好的显存被 PPU 扫出来，8 条竖条的颜色与边界对不对
# 这是 HDMI 首次上板前的功能门。板级 TMDS/OSERDES/PLL 仿真里没有，只能上板看。
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\")).Path
$env:PATH = "$Toolchain;$env:PATH"
$env:RISCV_TOOLS = $Toolchain          # 供 elf2mem.py 使用

$prog = Join-Path $repo "sim\programs"
New-Item -ItemType Directory -Force -Path $prog | Out-Null
$elf = Join-Path $prog "video.elf"
$src = Join-Path $repo "scripts\video"
$shared = Join-Path $repo "scripts\demo"   # 复用 demo 的链接脚本 / 启动代码 / 地址映射

if (-not $SkipBuild) {
    Write-Host "[1/3] 编译彩条固件 ..."
    $gccArgs = @(
        "-march=rv32im", "-mabi=ilp32", "-O2", "-mcmodel=medany", "-msmall-data-limit=0",
        "-nostartfiles",
        "-I$shared",
        "-T$shared\link.ld",
        "$src\video.c", "$shared\start.S",
        "-o", $elf
    )
    & riscv-none-elf-gcc @gccArgs
    if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }
}
else { Write-Host "[1/3] 跳过编译（-SkipBuild）" }

Write-Host "[2/3] 拆 ELF -> imem.hex / dmem.hex / mem.hex ..."
& python (Join-Path $repo "scripts\elf2mem.py") $elf $prog
if ($LASTEXITCODE -ne 0) { throw "elf2mem.py 失败" }

if ($SkipSim) {
    Write-Host "      已跳过仿真（-SkipSim）"
    Write-Host "      固件:     $prog\mem.hex"
    Write-Host "      下一步:   scripts\sync_firmware.ps1  同步到 PDS 工程目录"
    exit 0
}

Write-Host "[3/3] 编译 testbench 并仿真 ..."
$sim = Join-Path $repo "sim"
$vvp = Join-Path $sim "tb_video_bars.vvp"
$rtl = @()
foreach ($d in @("rtl\core", "rtl\periph", "rtl\bus")) {
    $rtl += Get-ChildItem (Join-Path $repo $d) -Filter "*.v" | Sort-Object Name | ForEach-Object { $_.FullName }
}
# [!] rtl\top 只收 cpu_top.v。同目录的 cpu_top_board.v 例化了 PDS 专有原语
#     （pll / video_top），而 iverilog 会把文件列表里【每一个】模块都当顶层展开
#     —— 只要它在列表里就报 Unknown module，跟本测试台有没有例化它无关。
$rtl += Join-Path $repo "rtl\top\cpu_top.v"
# [!] rtl\video 同理，只收不含原语的那几个。video_top.v 例化 pll_video，
#     rgb2tmds.v / outputserdes.v 例化 GTP_OSERDES_E2 / GTP_OUTBUFDS，都编不了。
#     本测试台直接例化 video_core —— 这正是当初把逻辑从 video_top 搬下来的原因。
foreach ($f in @("video_core.v", "ppu.v", "sync_vg.v", "vram_b32.v", "vram_dp.v", "vram_pal.v")) {
    $rtl += Join-Path $repo "rtl\video\$f"
}
& iverilog -g2012 -I (Join-Path $repo "rtl\core") -I (Join-Path $repo "rtl\periph") `
    -I (Join-Path $repo "rtl\bus") -I $sim `
    -o $vvp (Join-Path $sim "tb_video_bars.v") @rtl
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

Push-Location $sim
try {
    & vvp $vvp "+IMEM=programs/imem.hex" "+DMEM=programs/dmem.hex"
}
finally { Pop-Location }
