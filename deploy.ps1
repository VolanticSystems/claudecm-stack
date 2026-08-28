# deploy.ps1 - Install/update ClaudeCM runtime files on Windows.
#
# Idempotent: safe to re-run after every `git pull`. Byte-identical files
# are skipped, changed files get a timestamped backup in ~/.claudecm/backup/
# before being overwritten.
#
# Files this script owns:
#   ~/.claudecm/claudecm-powershell.ps1
#   ~/.claudecm/extract-skeleton.mjs
#   ~/.claudecm/bgcolor.ps1
#   ~/.claudecm/register-late-guid.ps1
#   ~/bin/bgcolor.cmd  (generated shim; not in repo)
#
# Files this script does NOT touch (they belong to you):
#   $PROFILE (initial setup only, per docs/install.md)
#   ~/.claudecm/sessions.txt, machine-name.txt, notes/, backup/
#
# Usage (from the repo root):
#   .\deploy.ps1

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSCommandPath
$cmDir     = "$env:USERPROFILE\.claudecm"
$binDir    = "$env:USERPROFILE\bin"
$backupDir = "$cmDir\backup"

foreach ($d in @($cmDir, $backupDir, $binDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runtimeScript = Join-Path $cmDir 'claudecm-powershell.ps1'

# Snapshot the personal-preference tweak state BEFORE we overwrite anything.
# The commented-out line is the repo default; uncommented is a personal tweak.
$hadTweak = $false
if (Test-Path $runtimeScript) {
    $hadTweak = (Get-Content $runtimeScript -Raw) -match '(?m)^\s*\$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION\s*=\s*"0"'
}

$claudecmFiles = @(
    'claudecm-powershell.ps1',
    'extract-skeleton.mjs',
    'bgcolor.ps1',
    'register-late-guid.ps1'
)

$copied  = @()
$skipped = @()

foreach ($f in $claudecmFiles) {
    $src = Join-Path $repoRoot $f
    $dst = Join-Path $cmDir $f
    if (-not (Test-Path $src)) {
        Write-Host "  MISSING in repo: $f (skipped)" -ForegroundColor Yellow
        continue
    }
    if (Test-Path $dst) {
        if ((Get-FileHash $src -Algorithm SHA256).Hash -eq (Get-FileHash $dst -Algorithm SHA256).Hash) {
            $skipped += $f
            continue
        }
        Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir "$f.$stamp.pre-deploy") -Force
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $copied += $f
}

# bgcolor.cmd shim so plain `bgcolor` works from Command Prompt and File
# Explorer's Run dialog. Generated, not in the repo.
$shimPath = Join-Path $binDir 'bgcolor.cmd'
$shimBody = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%USERPROFILE%\.claudecm\bgcolor.ps1`" %*`r`n"
$existing = if (Test-Path $shimPath) { Get-Content $shimPath -Raw } else { '' }
if ($existing -ne $shimBody) {
    if (Test-Path $shimPath) {
        Copy-Item -LiteralPath $shimPath -Destination (Join-Path $backupDir "bgcolor.cmd.$stamp.pre-deploy") -Force
    }
    Set-Content -LiteralPath $shimPath -Value $shimBody -NoNewline
    $copied += 'bin\bgcolor.cmd'
}

Write-Host ""
if ($copied.Count -gt 0) {
    Write-Host "  Deployed:" -ForegroundColor Green
    $copied | ForEach-Object { Write-Host "    - $_" }
} else {
    Write-Host "  Nothing to do -- all files already match the repo." -ForegroundColor Green
}
if ($skipped.Count -gt 0) {
    Write-Host "  Unchanged: $($skipped -join ', ')" -ForegroundColor DarkGray
}

# If the tweak was set before and got clobbered, tell the user.
if ($hadTweak) {
    $stillHasTweak = (Get-Content $runtimeScript -Raw) -match '(?m)^\s*\$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION\s*=\s*"0"'
    if (-not $stillHasTweak) {
        Write-Host ""
        Write-Host "  NOTE: CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=`"0`" was active in your runtime" -ForegroundColor Yellow
        Write-Host "  copy and is now commented out again (repo default)." -ForegroundColor Yellow
        Write-Host "  Uncomment the line near the top of $runtimeScript" -ForegroundColor Yellow
        Write-Host "  to restore, or see REVERT-CLAUDECM.md." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "  Backups (if written): $backupDir\*.pre-deploy" -ForegroundColor DarkGray
Write-Host "  Open a new PowerShell tab to pick up changes." -ForegroundColor DarkGray
Write-Host ""
