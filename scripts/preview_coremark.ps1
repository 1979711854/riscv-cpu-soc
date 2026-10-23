# ============================================================================
# preview_coremark.ps1 -- host-side CoreMark screen preview (real code path)
# ----------------------------------------------------------------------------
# Compiles the REAL scripts/coremark_port/{core_portme,ee_printf,video_text}.c
# plus third_party CoreMark sources on x86 with -DVIDEO_TEXT_HOST (fake MMIO),
# runs one real CoreMark pass (layout/console logic identical to firmware),
# then dumps the screen to:
#   <prefix>_report.{txt,bmp}  -- scrolling report (during-run screen)
#   <prefix>_result.{txt,bmp}  -- result page (final screen)
#
# Fixed invocation (single call, absolute paths, no -ExecutionPolicy):
#   powershell -NoProfile -File d:\riscv-cpu-fpga_merged\scripts\preview_coremark.ps1
#
# [!] Numbers are SYNTHETIC on host (mtime = ITER x 217088 ticks, board-scale),
#     CRCs are real x86 results. Layout is the point, not the score.
# ============================================================================
param(
    [int]$Iter = 4332,                                                      # only affects the printed ITER/score digits
    [string]$Prefix = "d:\riscv-cpu-fpga_merged\doc\board\preview_cm"       # output prefix (_report/_result .txt/.bmp)
)

$ErrorActionPreference = "Stop"
$repo    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$src     = Join-Path $repo "third_party\coremark"
$port    = Join-Path $repo "scripts\coremark_port"
$gomoku  = Join-Path $repo "scripts\gomoku"
$tools   = Join-Path $repo "sim\tools"
$exe     = Join-Path $tools "preview_coremark.exe"
$objdir  = Join-Path $tools "_cmobj"

# ---- x86 gcc (same detection as scripts\gomoku\preview.ps1) -----------------
$gcc = ""
$cand = Join-Path $env:USERPROFILE "scoop\apps\gcc\current\bin\gcc.exe"
if (Test-Path $cand) {
    $gcc = $cand
} else {
    $cmd = Get-Command gcc -ErrorAction SilentlyContinue
    if ($cmd) { $gcc = $cmd.Source }
}
if (-not $gcc) { throw "x86 gcc not found. Install: scoop install gcc" }

# ---- 1) compile core objects (-Dmain=coremark_main renames CoreMark's main) -
# [!] gcc gets forward-slash -I paths (PS 5.1 backslash quirks), and the
#     harness compile reuses the SAME $incs array that the loop proved works.
$incs = @($src, $port, $gomoku | ForEach-Object { "-I" + ($_ -replace '\\', '/') })
$defines = @("-DVIDEO_TEXT_HOST", "-DITERATIONS=$Iter", "-Dmain=coremark_main")
$coreSrcs = @("core_main.c", "core_list_join.c", "core_matrix.c", "core_state.c", "core_util.c") |
            ForEach-Object { Join-Path $src $_ }
$portSrcs = @((Join-Path $port "core_portme.c"), (Join-Path $port "ee_printf.c"), (Join-Path $port "video_text.c"))

New-Item -ItemType Directory -Force -Path $objdir | Out-Null
$objs = @()

# [!] PS 5.1 turns native stderr into a terminating error under EAP=Stop
#     (same ld/RWX-warning pitfall as run_coremark.ps1) -> relax during gcc.
$eapSave = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    foreach ($f in ($coreSrcs + $portSrcs)) {
        $o = Join-Path $objdir (([IO.Path]::GetFileNameWithoutExtension($f)) + ".o")
        & $gcc -std=c99 -O2 @defines @incs -c $f -o $o
        if ($LASTEXITCODE -ne 0) { throw "gcc -c failed: $f" }
        $objs += $o
    }
    $oHarness = Join-Path $objdir "preview_coremark_host.o"
    & $gcc -std=c99 -O2 @incs -c (Join-Path $tools "preview_coremark.c") -o $oHarness
    if ($LASTEXITCODE -ne 0) { throw "gcc -c failed: preview_coremark.c" }
    & $gcc ($objs + $oHarness) -o $exe
    if ($LASTEXITCODE -ne 0) { throw "gcc link failed" }
}
finally { $ErrorActionPreference = $eapSave }

# ---- 2) run (x86 CoreMark with ITER=4332 finishes in a few seconds) ---------
$outDir = [System.IO.Path]::GetDirectoryName($Prefix)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
& $exe "--out" $Prefix
if ($LASTEXITCODE -ne 0) { throw "preview_coremark.exe failed" }

# ---- 3) cleanup objects -----------------------------------------------------
Remove-Item -Recurse -Force $objdir -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "ASCII: $Prefix`_report.txt / $Prefix`_result.txt" -ForegroundColor Cyan
Write-Host "BMP  : $Prefix`_report.bmp / $Prefix`_result.bmp" -ForegroundColor Cyan
