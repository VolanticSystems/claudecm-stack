<#
.SYNOPSIS
    Zip each project in the GitHub tree to F:, nightly, skipping what has not changed.

.DESCRIPTION
    One zip per project in F:\Backups\GitHubFiles. On Sundays the whole set is
    also copied into a weekly folder, so there is always a snapshot roughly a
    week old to fall back to.

    WHY IT SKIPS UNCHANGED PROJECTS
      The tree is ~110 GB and four scraper projects are 89 GB of it, almost all
      static. Re-zipping that every night would take hours, hammer the disk, and
      eventually get switched off for being annoying. So each project is zipped
      only when something inside it is newer than its existing zip. Most nights
      that means a handful of small projects and nothing else.

    WHAT IS LEFT OUT, AND WHY IT IS SAFE
      Generated directories: virtual environments, node_modules, __pycache__,
      build output, and temp. About 20 GB, none of it authored. See EXCLUDE_DIRS.
      The one judgement call is youtube-processor\library: 18 MP4 files, 4.8 GB,
      re-downloadable from YouTube. Bob's call, 2026-09-10.

      NOTE the real risk in excluding environments: only 2 of 18 have a
      requirements.txt, so most cannot be rebuilt from a list. That is a gap in
      the projects, not in this script, and it is worth closing separately.

    TWO WEEKLY GENERATIONS
      weekly\ is last Sunday, weekly-previous\ is the Sunday before. Keeping two
      means a bad Sunday cannot overwrite the only good week-old copy.

.PARAMETER WhatIf
    Report what would be zipped and why. Writes nothing.

.EXAMPLE
    pwsh -NoProfile -File .\Backup-GitHubFiles.ps1 -WhatIf
.EXAMPLE
    pwsh -NoProfile -File .\Backup-GitHubFiles.ps1
#>
[CmdletBinding()]
param(
    [string]$Source      = "$env:USERPROFILE\Documents\GitHub",
    [string]$Dest        = 'F:\Backups\GitHubFiles',
    [switch]$WhatIf,
    [switch]$ForceWeekly,
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'

# Directory names skipped anywhere in any project. Names, not paths, so a new
# project gets the same treatment without anyone editing this list.
$EXCLUDE_DIRS = @(
    'venv', '.venv', 'env', 'node_modules', '__pycache__', '.pytest_cache',
    '.mypy_cache', '.ruff_cache', 'dist', 'build', 'target', '.next',
    'temp', '.gradle', '.tox', 'site-packages'
)

# Per-project extras. Keyed by project folder name.
$EXCLUDE_PER_PROJECT = @{
    'youtube-processor' = @('library')   # 4.8 GB of MP4s, re-downloadable
}

$SEVENZIP = @(
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    if (-not $WhatIf -and $script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 } catch { }
    }
}

# ---------------------------------------------------------------- preflight
if (-not $SEVENZIP) {
    Write-Output "FAILED: 7-Zip not found. Install it or adjust `$SEVENZIP."
    exit 1
}
$destRoot = Split-Path $Dest -Qualifier
if (-not (Test-Path $destRoot)) {
    # The drive is absent: log nothing, fail quietly, let the next run catch up.
    Write-Output "SKIPPED: $destRoot is not available."
    exit 0
}
if (-not (Test-Path $Source)) { Write-Output "FAILED: no source at $Source"; exit 1 }
if (-not $WhatIf) { New-Item -ItemType Directory -Force $Dest | Out-Null }
$script:LogFile = Join-Path $Dest 'backup.log'

Write-Log "=== run start ($(if ($WhatIf) { 'WHATIF' } else { 'live' })) ==="

function Get-NewestWrite {
    <# Newest LastWriteTime under a project, ignoring excluded directories.
       This is what decides whether a re-zip is needed, so it must walk the same
       set of files the zip will contain. #>
    param([string]$Path, [string[]]$Excludes)
    $newest = [datetime]::MinValue
    $stack = [System.Collections.Stack]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
        foreach ($e in $entries) {
            $name = [System.IO.Path]::GetFileName($e)
            if ([System.IO.Directory]::Exists($e)) {
                if ($Excludes -contains $name) { continue }
                $stack.Push($e)
            } else {
                try {
                    $t = [System.IO.File]::GetLastWriteTime($e)
                    if ($t -gt $newest) { $newest = $t }
                } catch { }
            }
        }
    }
    return $newest
}

$projects = Get-ChildItem $Source -Directory -ErrorAction SilentlyContinue
if ($Only) { $projects = $projects | Where-Object { $Only -contains $_.Name } }

$zipped = 0; $skipped = 0; $failed = 0; $bytes = 0L
foreach ($p in $projects) {
    $excludes = @($EXCLUDE_DIRS)
    if ($EXCLUDE_PER_PROJECT.ContainsKey($p.Name)) {
        $excludes += $EXCLUDE_PER_PROJECT[$p.Name]
    }

    $zipPath = Join-Path $Dest ($p.Name + '.zip')
    $newest = Get-NewestWrite -Path $p.FullName -Excludes $excludes

    if ($newest -eq [datetime]::MinValue) {
        Write-Log ("  skip   {0}  (nothing to archive after exclusions)" -f $p.Name)
        $skipped++
        continue
    }
    if ((Test-Path $zipPath) -and ((Get-Item $zipPath).LastWriteTime -ge $newest)) {
        $skipped++
        continue
    }

    if ($WhatIf) {
        Write-Log ("  WOULD ZIP {0}  (newest content {1:yyyy-MM-dd HH:mm})" -f $p.Name, $newest)
        $zipped++
        continue
    }

    # Build to a temp name and move into place, so an interrupted run cannot
    # leave a half-written zip standing where a good one used to be.
    $tmp = Join-Path $Dest ($p.Name + '.zip.partial')
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

    $args = @('a', '-tzip', '-mx1', '-bso0', '-bsp0', '-y', $tmp, (Join-Path $p.FullName '*'))
    foreach ($x in $excludes) { $args += "-xr!$x" }

    $started = Get-Date
    & $SEVENZIP @args 2>&1 | Out-Null
    $rc = $LASTEXITCODE

    # 7-Zip returns 1 for warnings (a locked file it could not read). That is a
    # partial archive, not a failure: log it and keep the result.
    if ($rc -eq 0 -or $rc -eq 1) {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
        Move-Item $tmp $zipPath -Force
        $size = (Get-Item $zipPath).Length
        $bytes += $size
        $zipped++
        $note = if ($rc -eq 1) { '  (warnings: some files were locked)' } else { '' }
        Write-Log ("  zipped {0,-32} {1,8:N0} MB  {2,5:N0}s{3}" -f `
            $p.Name, ($size / 1MB), ((Get-Date) - $started).TotalSeconds, $note)
    } else {
        $failed++
        Write-Log ("  FAILED {0}  7-Zip exit {1}  (previous zip left untouched)" -f $p.Name, $rc)
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Write-Log ("summary: {0} zipped ({1:N1} GB), {2} unchanged, {3} failed" -f `
    $zipped, ($bytes / 1GB), $skipped, $failed)

# ------------------------------------------------------------------ weekly
$isSunday = (Get-Date).DayOfWeek -eq 'Sunday'
if (($isSunday -or $ForceWeekly) -and -not $WhatIf) {
    $weekly = Join-Path $Dest 'weekly'
    $prev   = Join-Path $Dest 'weekly-previous'
    Write-Log "weekly rotation"
    try {
        if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
        if (Test-Path $weekly) { Move-Item $weekly $prev }
        New-Item -ItemType Directory -Force $weekly | Out-Null
        $n = 0
        foreach ($z in Get-ChildItem $Dest -Filter '*.zip') {
            Copy-Item $z.FullName (Join-Path $weekly $z.Name) -Force
            $n++
        }
        Write-Log ("  weekly: {0} zip(s) copied; last week moved to weekly-previous" -f $n)
    } catch {
        Write-Log ("  WEEKLY FAILED: {0}" -f $_.Exception.Message)
    }
}

Write-Log "=== run end ==="
exit $(if ($failed -gt 0) { 1 } else { 0 })
