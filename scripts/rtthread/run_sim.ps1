<#
============================================================================
 run_sim.ps1 —— 一条命令跑完 RT-Thread 的编译 + 仿真验证
----------------------------------------------------------------------------
 用法：
   scripts\rtthread\run_sim.ps1            编 RT-Thread -> 编测试台 -> 跑仿真
   scripts\rtthread\run_sim.ps1 -NoBuild   跳过 RT-Thread 重编（只重跑仿真）
   scripts\rtthread\run_sim.ps1 -Atomic    用【硬件原子】编（rv32ima + lr/sc/AMO）

 测试台 sim\tb_rtthread.v 会检查四个自检（对应 app\main.c 的设计）：
   [1] 控制台通了        —— 出现 RT-Thread banner
   [2] gomoku 线程起来了 —— 出现 "[boot] gomoku render thread running"
   [3] AI 线程起来了      —— 出现 "[boot] gomoku ai thread running"（G3 拆线程生效）
   [4] 主线程心跳在跳     —— "[hb] alive"（调度器在跑，render 没独占 CPU）

 [!] 仿真口径与上板不同，别混（见 build.ps1 里的说明）：
     仿真时钟 100MHz（sim\ 下所有测试台都是 always #5）、短延时、出 hex

[!] RTL 配置开关（2026-10-14 补，项目约定文档 约定 55）：
     本脚本原来一个 -D 都不传，全靠 cpu_top 参数默认值 ⇒ rtthread 线的仿真
     从没覆盖过 Cache 配置（rtthread + I+D 位流上板挂死就这么漏过去）。
     现在默认【显式】传板上口径，并打印 SIM CONFIG 自证：
       默认          = 双发射 + EARLY_LD + Cache 全关（= 8894cdcb 那颗 RTL）
       -DCache       = 追加 -DDCACHE（DCACHE_EN=1）
       -ICache       = 追加 -DICACHE（ICACHE_EN=1）
       -Single       = 退回单发射（不传 -DDUAL）
       -NoEarlyLd    = 退回 EARLY_LD=0（不传 -DEARLYLD）
       -NoLanebMem   = 退回 LANEB_MEM=0（不传 -DLANEBMEM）；**默认【开】** = P3 后的板上口径
       -RxTrace      = 逐字节打 rx + pc（挂死定位用，默认关）
       -PcTrace      = PC 逐拍落盘 rtthread_pctrace.txt（对拍找第一条分叉，默认关）
       -ITrace       = IF/ID 逐拍落盘 rtthread_itrace.txt（看指令/配对/重定向，默认关）
     复现板上挂死：scripts\rtthread\run_sim.ps1 -DCache -ICache
     归因结果（2026-10-14）：-DCache / -ICache / 两者 都能打挂这条固件，
     无 Cache 是 PASS ⇒ 功能 bug、与时序无关。见
     doc\reports\2026-10-14_cache_rtthread_sim_bisect.md
============================================================================
#>
param(
    [switch]$NoBuild,
    [switch]$Atomic,     # 透传给 build.ps1：rv32ima + atomic_riscv.c + RT_USING_STDC_ATOMIC
    [switch]$DCache,     # DCACHE_EN=1（追加 -DDCACHE）
    [switch]$ICache,     # ICACHE_EN=1（追加 -DICACHE）
    [switch]$Single,     # 退回单发射（不传 -DDUAL）
    [switch]$NoEarlyLd,  # 退回 EARLY_LD=0（不传 -DEARLYLD）
    [switch]$NoLanebMem, # 退回 LANEB_MEM=0（不传 -DLANEBMEM）；默认【开】= cpu_top/core 的板上默认
    [switch]$RxTrace,    # 逐字节打 rx + pc（挂死定位用；默认关，开了会刷 168 行）
    [switch]$PcTrace,    # PC 逐拍落盘（对拍定位用；默认关，一份约 40MB）
    [switch]$ITrace,     # IF/ID 逐拍落盘（看指令进 ID / 配对 / 重定向；默认关）
    [switch]$TrapTrace,  # trap 事件落盘（cause + 肇事 pc；默认关）
    [switch]$LTrace,     # 访存事件落盘（pc/addr/wdata/rdata/ready；默认关）
    [switch]$LdChk       # load 数据自检 + 规范化访存事件流落盘（默认关）
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent (Split-Path -Parent $Here)
$Sim  = Join-Path $Repo "sim"
$Bld  = Join-Path $Here "build"

# ---- 1) 按仿真口径编 RT-Thread（27/49MHz 那套口径跑仿真会算错 tick）----
if (-not $NoBuild) {
    # [!] 必须用哈希表 splat：数组 splat @("-Sim","-Atomic") 传的是位置字符串，
    #     PowerShell 不会把它当开关名解析，实测两个开关全被丢掉（静默按默认口径编）。
    $bargs = @{ Sim = $true }
    if ($Atomic) { $bargs.Atomic = $true }
    & (Join-Path $Here "build.ps1") @bargs
    if ($LASTEXITCODE -ne 0) { throw "RT-Thread 编译失败" }
}

foreach ($f in @("imem.hex", "dmem.hex")) {
    if (-not (Test-Path (Join-Path $Bld $f))) { throw "缺少 $f —— 先不带 -NoBuild 跑一次" }
}

# ---- 1a) -NoBuild 守卫：build/ 里的固件必须是【-Sim 口径】编的 ----
# [!] 2026-10-14 实踩：板级集成用【板载口径】编过一次（76.5MHz / HB_DELAY_MS=5000）后，
#     build/ 的 hex 被覆盖；-NoBuild 拿它跑 100MHz 仿真 ⇒ 心跳 3.8 秒 wall time 才出现，
#     30ms 扫描窗等不到 ⇒ [FAIL] 没看到主线程心跳（与 RTL 无关，纯口径错配，白查一轮）。
#     build.ps1 在 -Sim 时写 .sim_build_ok 标记、板载构建时删它 —— 见到没标记就别跑。
if ($NoBuild -and -not (Test-Path (Join-Path $Bld ".sim_build_ok"))) {
    throw ("build/ 里的固件不是 -Sim 口径编的（缺 .sim_build_ok 标记，上次很可能是板级构建）。" +
           "板载口径（76.5MHz / HB_DELAY_MS=5000）在 100MHz 仿真里会整体变慢、心跳永远超窗，" +
           "判 FAIL 但与 RTL 无关。请去掉 -NoBuild 重跑（会按仿真口径重编固件）。")
}

# ---- 2) 编测试台 ----
# [!] 不要编 rtl\mem\unified_mem.v —— 测试台用 sim\mem_model.vh 里的行为模型，
#     重复定义会冲突（项目约定文档 关键约定 2）。
# [!] **必须带 rtl\video 那六个文件** —— 五子棋会访问显存区，测试台把
#     cpu_top 的 vid_* 口接到 video_core（见 tb_rtthread.v 文件头的 [!]）。
#     少编它们会报 "Unknown module type: video_core"。
#     清单与 scripts\gomoku\run_sim.ps1 一致：**不含 video_top.v**
#     （它例化 PDS 专有原语 pll_video / OSERDES，iverilog 里不存在）。
Write-Host "[1/2] 编译测试台 ..." -ForegroundColor Cyan
$vvp = Join-Path $Bld "tb_rtthread.vvp"
$vidSrcs = @("video_core.v", "ppu.v", "sync_vg.v", "vram_b32.v", "vram_dp.v", "vram_pal.v") |
           ForEach-Object { Join-Path $Repo "rtl\video\$_" }
$srcs = @(
    (Join-Path $Sim "tb_rtthread.v")
) + (Get-ChildItem (Join-Path $Repo "rtl\core") -Filter *.v -File | ForEach-Object { $_.FullName }) `
  + (Get-ChildItem (Join-Path $Repo "rtl\bus") -Filter *.v -File | ForEach-Object { $_.FullName }) `
  + (Get-ChildItem (Join-Path $Repo "rtl\periph") -Filter *.v -File | ForEach-Object { $_.FullName }) `
  + @((Join-Path $Repo "rtl\top\cpu_top.v")) `
  + $vidSrcs

$inc = @("-I", (Join-Path $Repo "rtl\core"), "-I", (Join-Path $Repo "rtl\periph"),
         "-I", (Join-Path $Repo "rtl\bus"),  "-I", (Join-Path $Repo "rtl\video"), "-I", $Sim)
# ---- 2b) 组装 RTL 配置的 -D 旗标 —— 必须【显式】传，不靠 cpu_top 参数默认值 ----
# [!] 2026-10-14（约定 55）：本脚本原来一个 -D 都不传，tb_rtthread 靠 cpu_top 默认值
#     （双发射 + EARLY_LD + Cache 关）跑，于是 rtthread 固件 + Cache 的组合从没被仿真过。
#     现在默认显式传板上口径（-DDUAL -DEARLYLD），-DCache/-ICache 追加；
#     vvp 首行会打 SIM CONFIG 自证，与 tb_riscv/tb_coremark 同一格式。
$defs = @()
if (-not $Single)    { $defs += "-DDUAL" }
if (-not $NoEarlyLd) { $defs += "-DEARLYLD" }
# [lane B 访存] 默认开（-DLANEBMEM）—— 与 cpu_top/core 的 LANEB_MEM 默认值一致（P3）。
if (-not $NoLanebMem) { $defs += "-DLANEBMEM" }
if ($DCache)         { $defs += "-DDCACHE" }
if ($ICache)         { $defs += "-DICACHE" }
# [面积优化] A_EXT 默认关（= 生产档）。只有 -Atomic（rv32ima 硬件原子固件）才开 ——
#   不开的话那份固件里的 lr/sc/AMO 会被判非法指令而挂死，那是预期行为，不是 RTL bug。
if ($Atomic)         { $defs += "-DAEXT" }
if ($RxTrace)        { $defs += "-DRXTRACE" }
if ($PcTrace)        { $defs += "-DPCTRACE" }
if ($ITrace)         { $defs += "-DITRACE" }
if ($TrapTrace)      { $defs += "-DTRAPTRACE" }
if ($LTrace)         { $defs += "-DLTRACE" }
if ($LdChk)          { $defs += "-DLDCHK" }
$cfgDual   = if ($Single)    { 0 } else { 1 }
$cfgDCache = if ($DCache)    { 1 } else { 0 }
$cfgICache = if ($ICache)    { 1 } else { 0 }
$cfgEarly  = if ($NoEarlyLd) { 0 } else { 1 }
$cfgAext   = if ($Atomic)    { 1 } else { 0 }
$cfgLaneb  = if ($NoLanebMem){ 0 } else { 1 }
Write-Host "    RTL 配置：SIM CONFIG: DUAL_ISSUE=$cfgDual DCACHE_EN=$cfgDCache ICACHE_EN=$cfgICache EARLY_LD=$cfgEarly A_EXT=$cfgAext LANEB_MEM=$cfgLaneb" -ForegroundColor Cyan

$ivOut = & iverilog -g2012 @defs @inc -s tb_rtthread -o $vvp @srcs 2>&1
$ivOut | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }
# [!] **端口宽度不一致 = 静默截位，必须当错误处理**（2026-10-10 实踩，同 run_riscv_tests.ps1）。
$widthWarn = @($ivOut | Where-Object { $_ -match 'expects \d+ bit\(s\), given' })
if ($widthWarn.Count -gt 0) {
    $widthWarn | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "iverilog 报了 $($widthWarn.Count) 条端口宽度不一致 —— 那是静默截位，先把宽度对齐再跑回归"
}

# ---- 3) 跑 ----
Write-Host "[2/2] 跑仿真 ..." -ForegroundColor Cyan
& vvp $vvp "+IMEM=$Bld\imem.hex" "+DMEM=$Bld\dmem.hex"
exit $LASTEXITCODE
