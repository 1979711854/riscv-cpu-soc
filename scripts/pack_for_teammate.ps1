# One-shot packer: build the zip we hand to a teammate (includes .git so the
# round-trip works without GitHub access).
#
# [!] Windows PowerShell 5.1 reads a .ps1 WITHOUT a UTF-8 BOM as GBK; non-ASCII
#     text then swallows quote pairing and the script dies with a bogus
#     "missing )" parser error. That is the exact bug in run_own_tests.ps1 found
#     on 2026-10-06 -- reproduced here by writing this very script.
#     Rule: keep it ASCII, **or add a BOM**.
#     2026-10-10: the output path gained a Chinese directory name, so this file
#     now carries a UTF-8 BOM. **Don't strip it.**
#     (The rest of the active code below is still ASCII-only.)
#
# Three traps handled below:
#   1. `git ls-files` escapes non-ASCII paths by default ("doc/...\xxx" form);
#      Copy-Item then cannot find them. Need `-c core.quotepath=false`.
#   2. `Compress-Archive -Path "$stage\*"` may drop hidden entries -> .git lost.
#   3. Even ZipFile::CreateFromDirectory is only trustworthy if the staging dir
#      actually contains .git -- so we verify the resulting archive afterwards.
param(
    # Optional suffix to avoid a name clash when two hand-offs go out on the
    # same day (2026-10-13: the teammate's own riscv-cpu-fpga_dualissue_20261013.zip
    # already sits in the hand-off folder). Default '' keeps the old behaviour.
    #   -Tag btbras  ->  riscv-cpu-fpga_dualissue_20261013_btbras.zip
    [string]$Tag = ''
)
$repo  = 'D:\riscv-cpu-fpga_merged'
$stage = 'D:\_stage_dualissue'
# Output goes to Desktop\RV32I\交接文件 -- the hand-off folder, i.e. where the
# packages teammates send us already live. Moved there 2026-10-10 at the user's
# request; before that it sat one level up in Desktop\RV32I. (That move is also
# why this file gained a UTF-8 BOM -- the path is non-ASCII. See the note above.)
# Dated name so successive hand-offs don't silently overwrite each other; that is
# the folder's existing convention (riscv-cpu-fpga_dualissue_20261006.zip, ...).
# -Tag appends "_<tag>" before .zip, for a second hand-off on the same day.
$out   = 'C:\Users\zjn\Desktop\RV32I\交接文件\riscv-cpu-fpga_dualissue_' +
         (Get-Date -Format 'yyyyMMdd') + $(if ($Tag) { "_$Tag" } else { '' }) + '.zip'

# Trap 4: console/pipe encoding. PowerShell decodes native-command output as GBK
# on a zh-CN box, so non-ASCII file names from `git ls-files` arrive mangled
# and Copy-Item cannot find them. Force UTF-8 both ways.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $out   -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage | Out-Null

Push-Location $repo
$files = git -c core.quotepath=false ls-files
Pop-Location

$miss = 0
foreach ($f in $files) {
    $src = Join-Path $repo $f
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "MISSING SRC: $f"; $miss++; continue }
    $dst = Join-Path $stage $f
    $d = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
Copy-Item -LiteralPath (Join-Path $repo '.git') -Destination (Join-Path $stage '.git') -Recurse -Force

Write-Host ("listed={0} missing={1}" -f $files.Count, $miss)
Write-Host ("stage .git/HEAD present: " + (Test-Path -LiteralPath (Join-Path $stage '.git\HEAD')))

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stage, $out, [System.IO.Compression.CompressionLevel]::Optimal, $false)

Add-Type -AssemblyName System.IO.Compression
$z = [System.IO.Compression.ZipFile]::OpenRead($out)
$nGit = ($z.Entries | Where-Object { $_.FullName -like '.git*' }).Count   # zip uses '\', not '/'
$nAll = $z.Entries.Count
$z.Dispose()
Write-Host ("zip entries={0}  .git/*={1}" -f $nAll, $nGit)
Write-Host ("zip size MB: {0:N1}" -f ((Get-Item $out).Length / 1MB))

Remove-Item $stage -Recurse -Force
