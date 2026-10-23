<#
.SYNOPSIS
    串口监视：把 FPGA 板上 CPU 的 UART 输出同时打印到屏幕并落盘。

.DESCRIPTION
    零依赖 —— 用 .NET 自带的 System.IO.Ports.SerialPort，不需要装 PuTTY /
    MobaXterm / pyserial。

    两个用途：
      1. 上板验证演示程序（按键 -> LED -> 串口）
      2. 抓 CoreMark 的 Total ticks（赛题要求运行 >=10s 的实测证据）

    默认把原始输出存到 doc/board/uart_<时间戳>.txt —— 这是赛题"实物证据"
    里需要的串口原始文本（doc/board/ 此前是空的）。

    注意：本文件必须保存为 **UTF-8 with BOM**。Windows PowerShell 5.1 读
    无 BOM 的 .ps1 会按 GBK 解码，中文字符串会被解析坏（曾因此把后面的
    逻辑一起吃掉，导致 catch 里的 return 失效）。

.PARAMETER Port
    串口号，如 COM12。不填则只列出当前系统里可用的串口。

.PARAMETER Baud
    波特率，默认 115200（uart 的分频系数按 115200 配的：板上 45MHz→390，
    仿真/远程平台 27MHz→234。两边都是 115200，所以这个默认值两边通用）。

.PARAMETER Seconds
    读取时长（秒）。0 = 一直读到 Ctrl+C。

.PARAMETER OutFile
    日志路径。留空则自动存 doc/board/uart_<yyyyMMdd_HHmmss>.txt。

.PARAMETER NoLog
    不落盘，只在屏幕上打印。

.EXAMPLE
    scripts\serial_monitor.ps1
    scripts\serial_monitor.ps1 -Port COM12
    scripts\serial_monitor.ps1 -Port COM12 -Seconds 60
    scripts\serial_monitor.ps1 -Port COM12 -OutFile doc\board\coremark_iter820.txt
#>
param(
    [string]$Port = "",
    [int]$Baud = 115200,
    [int]$Seconds = 0,
    [string]$OutFile = "",
    [switch]$NoLog
)

$ErrorActionPreference = "Stop"

# 让中文在终端正常显示。中文版 Windows 控制台默认代码页是 936(GBK)，
# 而 .ps1 的内容是 UTF-8，不显式指定输出编码就会显示成乱码。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Show-AvailablePorts {
    $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    if (-not $ports) {
        Write-Host "当前系统没有检测到任何串口。" -ForegroundColor Yellow
        Write-Host "把板子的 USB Type-C 插到 USB-UART 口后再试。"
        return
    }
    Write-Host "当前可用的串口：" -ForegroundColor Cyan
    $ports | ForEach-Object { Write-Host "  $_" }
}

# ---- 不指定串口：列出可用端口后退出 ----
if (-not $Port) {
    Show-AvailablePorts
    Write-Host ""
    Write-Host "用法：scripts\serial_monitor.ps1 -Port COM12"
    return
}

# ---- 1) 先开串口；成功之后再建日志文件 ----
# （顺序很重要：先建文件再开串口的话，串口打开失败时日志文件已经建了，
#   后续写入会撞上"无法写入已关闭的 TextWriter"）
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$sp.ReadTimeout  = 200
$sp.WriteTimeout = 200
try {
    $sp.Open()
} catch {
    Write-Host "打不开 $Port：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "常见原因：串口号选错，或串口被别的程序占用（串口助手 / PDS 终端）。" -ForegroundColor Yellow
    Write-Host "本板的双通道 FTDI 会枚举出两个串口，一个是串口、一个是 JTAG —— 两个都试一下。" -ForegroundColor Yellow
    Write-Host ""
    Show-AvailablePorts
    exit 1
}

# ---- 2) 建日志文件 ----
if (-not $NoLog -and -not $OutFile) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $boardDir = Join-Path $repoRoot "doc\board"
    if (-not (Test-Path $boardDir)) { New-Item -ItemType Directory -Path $boardDir -Force | Out-Null }
    $OutFile = Join-Path $boardDir ("uart_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
}

$writer = $null
if (-not $NoLog -and $OutFile) {
    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $writer = New-Object System.IO.StreamWriter($OutFile, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
}

$header = "# UART 抓取 $Port @ $Baud 8N1  开始于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host $header -ForegroundColor Cyan
if ($writer) {
    $writer.WriteLine($header)
    Write-Host "日志：$OutFile" -ForegroundColor Cyan
}
Write-Host ("-" * 60)
if ($Seconds -gt 0) {
    Write-Host "（读取 $Seconds 秒后自动停止）" -ForegroundColor DarkGray
} else {
    Write-Host "（Ctrl+C 停止）" -ForegroundColor DarkGray
}
Write-Host ""

# ---- 3) 读取循环 ----
$deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }
$buf = ""
$lineCount = 0

try {
    while ((Get-Date) -lt $deadline) {
        $chunk = $sp.ReadExisting()          # 立刻返回已收到的内容
        if ($chunk.Length -eq 0) {
            Start-Sleep -Milliseconds 30
            continue
        }
        $buf += $chunk
        while ($buf.Contains("`n")) {
            $idx  = $buf.IndexOf("`n")
            $line = $buf.Substring(0, $idx).TrimEnd("`r")
            $buf  = $buf.Substring($idx + 1)
            Write-Host $line
            if ($writer) { $writer.WriteLine($line) }
            $lineCount++
        }
    }
} finally {
    if ($buf.Length -gt 0) {
        Write-Host $buf
        if ($writer) { $writer.WriteLine($buf) }
        $lineCount++
    }
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
    Write-Host ("-" * 60)
    Write-Host "共收到 $lineCount 行。" -ForegroundColor Cyan
    if ($writer) {
        $writer.WriteLine("# 结束于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')，共 $lineCount 行")
        $writer.Dispose()
        Write-Host "日志已保存：$OutFile" -ForegroundColor Green
    }
}
