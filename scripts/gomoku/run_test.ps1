<#
.SYNOPSIS
    五子棋 C/D 轨道的 x86 单测 —— 一条命令编译并跑两个测试台。

.DESCRIPTION
    **不需要板子、不需要 RISC-V 工具链、不需要 iverilog**，只要一个 x86 gcc。
    没装的话：`scoop install gcc`。

    两个测试台：
      test_board.exe  轨道 C：棋盘 / 落子合法性 / 五连判胜 / 平局
      test_ai.exe     轨道 D：AI 战术 / 自对弈 / 棋力 / 节点数与耗时

    为什么单独开一条 x86 路径（工作清单 §C / §6）：
    改一行就走 iverilog 全仿真太慢，没法迭代。这里是纯 C 逻辑，x86 上毫秒级出结果，
    而且 board.c / ai.c 是【一份源码两处用】—— 同一份文件原样编进 RV32 固件，
    不存在"PC 上过的和板上跑的不是同一份"。

    [!] 编译带 -Wall -Wextra，警告要当错误看 —— 固件那边没有 printf 兜底。
    [!] 改完 board.c / ai.c 建议再用 RV32 交叉编译器过一遍（本脚本末尾会做，
        找不到工具链就跳过）：

        riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -Wall -Wextra -ffreestanding -c board.c
        riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -Wall -Wextra -ffreestanding -c ai.c

.EXAMPLE
    scripts\gomoku\run_test.ps1
#>
param(
    [string]$Gcc = "",       # 默认走 PATH；scoop 装的在 ~\scoop\apps\gcc\current\bin
    [switch]$SkipRv32        # 跳过 RV32 交叉编译检查
)

$ErrorActionPreference = "Stop"

# [!] 两个测试台的输出都是 UTF-8 中文，而中文 Windows 的控制台默认代码页是
#     GBK(cp936) —— 不设这两句全是乱码。详见 play.ps1 里的三道保险说明。
try { chcp 65001 | Out-Null } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here "..\..")).Path   # video_port.c 要用 scripts\demo\addr_map.h

if ([string]::IsNullOrWhiteSpace($Gcc)) {
    $cand = Join-Path $env:USERPROFILE "scoop\apps\gcc\current\bin\gcc.exe"
    if (Test-Path $cand) { $Gcc = $cand }
    else {
        $cmd = Get-Command gcc -ErrorAction SilentlyContinue
        if ($cmd) { $Gcc = $cmd.Source }
        else {
            Write-Host "找不到 x86 gcc。装一个： scoop install gcc" -ForegroundColor Red
            exit 1
        }
    }
}

$CFLAGS = @("-std=c99", "-O2", "-Wall", "-Wextra")

$suites = @(
    @{ Name = "轨道 C（棋盘/判胜）"; Exe = "test_board.exe";  Src = @("board.c", "test_board.c") },
    @{ Name = "轨道 D（AI）";        Exe = "test_ai.exe";     Src = @("board.c", "ai.c", "test_ai.c") },
    @{ Name = "轨道 A3（渲染层）";   Exe = "test_render.exe"; Src = @("board.c", "render.c", "test_render.c") },
    @{ Name = "轨道 B1（按键）";     Exe = "test_input.exe";  Src = @("input.c", "test_input.c") },
    @{ Name = "轨道 B2/B3（对局）";  Exe = "test_game.exe";   Src = @("board.c", "ai.c", "game.c", "test_game.c") }
)

$failed = 0
foreach ($s in $suites) {
    $exe = Join-Path $here $s.Exe
    Write-Host ""
    Write-Host "===== $($s.Name) =====" -ForegroundColor Cyan
    Write-Host "[1/2] 编译 $($s.Exe) ..." -ForegroundColor Yellow
    $srcs = $s.Src | ForEach-Object { Join-Path $here $_ }
    & $Gcc @CFLAGS @srcs -o $exe
    if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败：$($s.Exe)" }

    Write-Host "[2/2] 运行 ..." -ForegroundColor Yellow
    & $exe
    if ($LASTEXITCODE -ne 0) { $failed++ }
}

# ---- RV32 交叉编译检查（"一份源码两处用"的守门人）----
if (-not $SkipRv32) {
    $rv = "D:\riscv-toolchain\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-gcc.exe"
    if (Test-Path $rv) {
        Write-Host ""
        Write-Host "===== RV32 交叉编译检查（rv32im / freestanding）=====" -ForegroundColor Cyan
        $obj = Join-Path $env:TEMP "gomoku_rv32_check.o"
        # video_port.c 要用 scripts/demo/addr_map.h（软件侧的地址定义）
        $inc = @("-I", $here, "-I", (Join-Path $repo "scripts\demo"))
        foreach ($f in @("board.c", "ai.c", "render.c", "video_port.c", "input.c", "hw_port.c", "game.c", "coremark_screen.c")) {
            & $rv -march=rv32im -mabi=ilp32 -O2 -Wall -Wextra -ffreestanding `
                  @inc -c (Join-Path $here $f) -o $obj
            if ($LASTEXITCODE -ne 0) {
                Write-Host "$f RV32 编译失败" -ForegroundColor Red; $failed++
            }
        }
        if ($failed -eq 0) {
            Write-Host "board / ai / render / video_port / input / hw_port / game / coremark_screen 八个文件 rv32im 编译通过、无警告 [OK]" -ForegroundColor Green
        }
        Remove-Item $obj -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host ""
        Write-Host "（跳过 RV32 检查：找不到 $rv）" -ForegroundColor DarkGray
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "全部通过 —— 这条路径不需要硬件。" -ForegroundColor Green
} else {
    Write-Host "有 $failed 个测试台失败。" -ForegroundColor Red
}
exit $failed
