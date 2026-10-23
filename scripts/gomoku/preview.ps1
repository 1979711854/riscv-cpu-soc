# ============================================================================
# preview.ps1 -- host-side UI preview (no board, no iverilog, no RISC-V toolchain)
# ----------------------------------------------------------------------------
# Compiles the REAL scripts/gomoku/main.c + render.c + game.c on x86 with a fake
# video port, then prints a 40x30 tile grid and optionally writes a 640x480 BMP.
#
#   scripts\gomoku\preview.ps1                         # title screen, ASCII
#   scripts\gomoku\preview.ps1 -Scene game             # in-game screen
#   scripts\gomoku\preview.ps1 -Scene game -Bmp doc\board\preview_game.bmp
#   scripts\gomoku\preview.ps1 -Scene game -Check      # compare golden_game.txt
#   scripts\gomoku\preview.ps1 -Scene game -SaveGolden # freeze current layout
#
# Scenes: title / submenu / game / over / all
# ============================================================================
param(
    [ValidateSet("title", "submenu", "human", "game", "over", "all")]
    [string]$Scene = "title",
    [string]$Bmp = "",
    [string]$Out = "",
    [string]$Golden = "",
    [switch]$Check,
    [switch]$SaveGolden
)

$ErrorActionPreference = "Stop"
$repo   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$gomoku = Join-Path $repo "scripts\gomoku"
$tools  = Join-Path $repo "sim\tools"
$outDir = Join-Path $repo "doc\board"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ---- x86 gcc ----------------------------------------------------------------
$gcc = ""
$cand = Join-Path $env:USERPROFILE "scoop\apps\gcc\current\bin\gcc.exe"
if (Test-Path $cand) {
    $gcc = $cand
} else {
    $cmd = Get-Command gcc -ErrorAction SilentlyContinue
    if ($cmd) { $gcc = $cmd.Source }
}
if (-not $gcc) { throw "x86 gcc not found. Install: scoop install gcc" }

# ---- 1) generate _main_preview.c from the real main.c -----------------------
& python -I (Join-Path $tools "_mk_preview.py")
if ($LASTEXITCODE -ne 0) { throw "generate _main_preview.c failed" }

# ---- 2) compile -------------------------------------------------------------
$exe = Join-Path $tools "preview_gomoku.exe"
$srcs = @(
    (Join-Path $tools  "preview_gomoku.c"),
    (Join-Path $gomoku "board.c"),
    (Join-Path $gomoku "ai.c"),
    (Join-Path $gomoku "render.c"),
    (Join-Path $gomoku "input.c"),
    (Join-Path $gomoku "game.c"),
    (Join-Path $gomoku "coremark_screen.c"),
    (Join-Path $tools  "_main_preview.c")
)
& $gcc -std=c99 -O2 -I $gomoku -o $exe @srcs
if ($LASTEXITCODE -ne 0) { throw "gcc compile failed" }

# ---- 3) run -----------------------------------------------------------------
$map  = @{ title = 0; submenu = 1; human = 4; game = 2; over = 3 }
$list = if ($Scene -eq "all") { @("title", "submenu", "human", "game", "over") } else { @($Scene) }

foreach ($s in $list) {
    $num = $map[$s]

    if ($Out -and $list.Count -eq 1) {
        $txt = $Out
    } elseif ($Out) {
        $dir = [System.IO.Path]::GetDirectoryName($Out)
        if (-not $dir) { $dir = "." }
        $txt = Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($Out) + "_$s.txt")
    } else {
        $txt = Join-Path $outDir "preview_$s.txt"
    }

    $args = @("--scene", "$num", "--txt", $txt)
    $bmpPath = $null
    if ($Bmp) {
        if ($list.Count -eq 1) {
            $bmpPath = $Bmp
        } else {
            $dir = [System.IO.Path]::GetDirectoryName($Bmp)
            if (-not $dir) { $dir = "." }
            $bmpPath = Join-Path $dir ([System.IO.Path]::GetFileNameWithoutExtension($Bmp) + "_$s.bmp")
        }
        $args += @("--bmp", $bmpPath)
    }

    & $exe @args
    if ($LASTEXITCODE -ne 0) { throw "preview failed: $s" }

    Write-Host ""
    Write-Host "=== scene: $s ===" -ForegroundColor Cyan
    Write-Host "ASCII: $txt"
    if ($bmpPath) { Write-Host "BMP  : $bmpPath" }

    $goldenPath = $Golden
    if (-not $goldenPath) { $goldenPath = Join-Path $outDir "golden_$s.txt" }

    if ($SaveGolden) {
        Copy-Item -LiteralPath $txt -Destination $goldenPath -Force
        Write-Host "GOLDEN SAVED: $goldenPath" -ForegroundColor Green
    } elseif ($Check) {
        if (-not (Test-Path $goldenPath)) {
            throw "golden not found: $goldenPath  (run with -SaveGolden after approval)"
        }
        $a = Get-Content -LiteralPath $goldenPath
        $b = Get-Content -LiteralPath $txt
        $d = Compare-Object -ReferenceObject $a -DifferenceObject $b
        if ($d) {
            $d | Format-Table -AutoSize | Out-Host
            throw "GOLDEN DIFF: $s"
        }
        Write-Host "GOLDEN OK: $s" -ForegroundColor Green
    }
}
