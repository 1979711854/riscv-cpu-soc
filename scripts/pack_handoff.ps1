# One-shot packer: build the zip we hand to a teammate.
#
# [!] This file is deliberately ASCII-only. Windows PowerShell 5.1 reads a .ps1
#     WITHOUT a UTF-8 BOM as GBK; non-ASCII text then swallows quote pairing and
#     the script dies with a bogus "missing )" parser error. That is the exact
#     bug in run_own_tests.ps1 found on 2026-10-06. Keep it ASCII, or add a BOM.
#
# Two repos, two packages:
#   riscv-cpu-fpga_ac     -> RV32A atomic-instruction fix task
#   riscv-cpu-fpga_merged -> gomoku G1+G2 task
#
# Both include .git so the round-trip works without GitHub access.
#
# Traps handled (all four have bitten us before):
#   1. `git ls-files` escapes non-ASCII paths ("doc/...\xxx" form) unless
#      -c core.quotepath=false; Copy-Item then cannot find them.
#   2. Compress-Archive -Path "$stage\*" may drop hidden entries -> .git lost.
#   3. ZipFile::CreateFromDirectory is only trustworthy if the staging dir
#      actually contains .git -- so we verify the archive afterwards.
#   4. Console/pipe encoding: PowerShell decodes native-command output as GBK
#      on a zh-CN box, mangling non-ASCII names from `git ls-files`.
$repoA = 'D:\riscv-cpu-fpga_ac'
$stageRoot = 'D:\_stage_handoff'
$outDir   = 'C:\Users\zjn\Desktop\RV32I'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Pack-Repo($repo, $stage, $zipName, $label) {
    Write-Host ""
    Write-Host "=== $label ==="
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipName -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    Push-Location $repo
    $files = git -c core.quotepath=false ls-files
    Pop-Location

    $miss = 0
    foreach ($f in $files) {
        $src = Join-Path $repo $f
        if (-not (Test-Path -LiteralPath $src)) { Write-Host "MISSING: $f"; $miss++; continue }
        $dst = Join-Path $stage $f
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    if ($miss -gt 0) { throw "$label : $miss source files missing, aborting." }

    # .git must travel too, otherwise the teammate cannot commit/push.
    Copy-Item -LiteralPath (Join-Path $repo '.git') -Destination (Join-Path $stage '.git') -Recurse -Force

    # Build the zip from the STAGING dir (not the repo) so build artifacts and
    # untracked junk stay out. CreateFromDirectory keeps hidden entries.
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipName,
        [System.IO.Compression.CompressionLevel]::Optimal, $false)

    # Verify .git really made it into the archive.
    $za = [System.IO.Compression.ZipFile]::OpenRead($zipName)
    $hasGit = @($za.Entries | Where-Object { $_.FullName -like '.git*' }).Count
    $entryCount = $za.Entries.Count
    $za.Dispose()

    $mb = [math]::Round((Get-Item $zipName).Length / 1MB, 2)
    Write-Host ("  files staged : {0}" -f $files.Count)
    Write-Host ("  zip entries  : {0}" -f $entryCount)
    Write-Host ("  .git entries : {0}" -f $hasGit)
    Write-Host ("  zip size     : {0} MB" -f $mb)
    Write-Host ("  -> {0}" -f $zipName)
    if ($hasGit -eq 0) { throw "$label : .git missing from archive!" }
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# Single package since 2026-08: everything (RV32A fix + gomoku port + G1/G2)
# lives in riscv-cpu-fpga_ac. The teammate should only ever need one zip.
# The old two-package layout is gone; see doc/reports/2026-10-08_handoff_message.md.
Pack-Repo $repoA (Join-Path $stageRoot 'riscv-cpu-fpga_ac') `
    (Join-Path $outDir 'riscv-cpu-fpga_handoff.zip') 'Single handoff package'

Write-Host ""
Write-Host "=== package ready in $outDir ==="
Get-ChildItem $outDir -Filter 'riscv-cpu-fpga_handoff.zip' | ForEach-Object {
    Write-Host ("  {0,-42} {1,8:N2} MB" -f $_.Name, ($_.Length / 1MB))
}