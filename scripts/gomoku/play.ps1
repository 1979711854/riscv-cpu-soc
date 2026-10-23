<#
.SYNOPSIS
    终端里跟五子棋 AI 下棋 —— 不需要板子、不需要显示器。

.DESCRIPTION
    这是工作清单 M0「PC 上的 AI 原型跑通」的落地物。每步 AI 走完会打印
    【节点数 / 实际深度 / 耗时(ms) / 评分】—— 那四个数是 D4（时间预算）的判据，
    也是之后上板标定的基准。

    落子输入：列字母 + 行号，如 H8 = 正中天元；也接受 7 7 / 7,7（0 基）。
    命令：q 退出 / n 重开 / u 悔一手 / l <0|1|2> 换难度 / h 帮助

.EXAMPLE
    scripts\gomoku\play.ps1              # 你执黑先手，AI 用 NORMAL(4层)
    scripts\gomoku\play.ps1 -Hard        # AI 用 HARD(6层)
    scripts\gomoku\play.ps1 -Easy -White # AI 用 EASY，你执白后手
#>
param(
    [switch]$Easy,
    [switch]$Hard,
    [switch]$White,
    [string]$Gcc = ""
)

$ErrorActionPreference = "Stop"

# [!] 中文乱码的三道保险（C 程序输出的是 UTF-8 字节，而中文 Windows 的控制台
#     默认代码页是 GBK/cp936）：
#       1) chcp 65001        —— 把【控制台】的代码页切到 UTF-8
#       2) OutputEncoding    —— 让 PowerShell 按 UTF-8 解码子进程的输出
#       3) gomoku_cli.c 里的 SetConsoleOutputCP(65001) —— 直接双击 .exe 也管用
#     工程里 build_bitstream.ps1 用的也是第 2 条。
try { chcp 65001 | Out-Null } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Gcc)) {
    $cand = Join-Path $env:USERPROFILE "scoop\apps\gcc\current\bin\gcc.exe"
    if (Test-Path $cand) { $Gcc = $cand }
    else {
        $cmd = Get-Command gcc -ErrorAction SilentlyContinue
        if ($cmd) { $Gcc = $cmd.Source }
        else { Write-Host "找不到 x86 gcc。装一个： scoop install gcc" -ForegroundColor Red; exit 1 }
    }
}

$exe = Join-Path $here "gomoku.exe"
Write-Host "编译中 ..." -ForegroundColor Yellow
& $Gcc -std=c99 -O2 -Wall -Wextra `
    (Join-Path $here "board.c") (Join-Path $here "ai.c") (Join-Path $here "gomoku_cli.c") `
    -o $exe
if ($LASTEXITCODE -ne 0) { throw "gcc 编译失败" }

$cliArgs = @()
if ($Easy)  { $cliArgs += "-easy" }
if ($Hard)  { $cliArgs += "-hard" }
if ($White) { $cliArgs += "-white" }

& $exe @cliArgs
