<#
.SYNOPSIS
    Configure the claude-hud statusline so the weekly usage bar is always shown.

.DESCRIPTION
    claude-hud 0.8.0 hides the weekly (7-day) usage bar unless it is at or above
    `display.sevenDayThreshold`, which defaults to 80. Since the 5-hour bar is
    almost always present, the practical effect is that the weekly bar is
    invisible until you have burned 80% of your week, which is exactly when it
    stops being useful as a planning aid.

    From src/render/lines/usage.ts:

        const sevenDayPart = (sevenDay !== null
            && (fiveHour === null || sevenDay >= sevenDayThreshold))

    Setting the threshold to 0 shows it always.

    This script also wires up the external usage snapshot. claude-hud takes its
    figures from the `rate_limits` block that Claude Code passes on stdin, and
    there is no such block before the first API response of a session, so a
    fresh window opens with empty gauges. Pointing the read and write paths at
    the same file makes every render with real data leave a snapshot behind,
    which the next new window reads immediately.

    Those numbers are LAST KNOWN, not live. They correct themselves the moment
    the first real response lands. For a weekly window that moves slowly this is
    a better answer than a blank bar, but it is a cached figure and you should
    know that.

.NOTES
    The config path is written ABSOLUTE and VERBATIM. claude-hud does no tilde
    or environment expansion on it (validateOptionalPath in src/config.ts is a
    trim and nothing else), and a "~/..." path fails silently, writing nothing
    anywhere. That is why this has to be generated per machine rather than
    committed as a fixed file.

    Existing settings are merged, never replaced, so anything set with
    /claude-hud:configure survives. The previous file is backed up first.
#>
[CmdletBinding()]
param(
    # Report what would change and write nothing.
    [switch]$WhatIfOnly,

    # Keep the upstream threshold (80) instead of forcing 0.
    [switch]$KeepWeeklyThreshold,

    # Do not wire the snapshot; only fix the threshold.
    [switch]$NoSnapshot
)

$ErrorActionPreference = 'Stop'

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
if (-not (Test-Path $claudeDir)) {
    Write-Host "  Claude config dir not found: $claudeDir" -ForegroundColor Yellow
    Write-Host "  Is Claude Code installed for this user? Nothing written." -ForegroundColor Yellow
    return
}

$hudConfig = Join-Path $claudeDir 'claude-hud.json'
$snapshot  = Join-Path $claudeDir 'claude-hud-usage.json'

# claude-hud stores the path as given. Forward slashes work on both platforms
# under node, and avoid the backslash-escaping trap in JSON.
$snapshotJsonPath = ($snapshot -replace '\\', '/')

# ---------------------------------------------------------------- load existing
$existing = $null
if (Test-Path $hudConfig) {
    try {
        $existing = Get-Content $hudConfig -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "  Existing $hudConfig is not valid JSON." -ForegroundColor Yellow
        Write-Host "  Refusing to overwrite it. Fix or remove it, then re-run." -ForegroundColor Yellow
        return
    }
}
if ($null -eq $existing) { $existing = [pscustomobject]@{} }
if (-not $existing.PSObject.Properties.Match('display').Count) {
    $existing | Add-Member -NotePropertyName 'display' -NotePropertyValue ([pscustomobject]@{}) -Force
}
if ($null -eq $existing.display) { $existing.display = [pscustomobject]@{} }

# ------------------------------------------------------------------- decide keys
$desired = [ordered]@{}
if (-not $KeepWeeklyThreshold) { $desired['sevenDayThreshold'] = 0 }
if (-not $NoSnapshot) {
    $desired['externalUsagePath']       = $snapshotJsonPath
    $desired['externalUsageWritePath']  = $snapshotJsonPath
    # Seven days. The default is 5 minutes, which is useless here: the whole
    # point is a snapshot surviving from the last session, possibly yesterday.
    $desired['externalUsageFreshnessMs'] = 604800000
}
if ($desired.Count -eq 0) {
    Write-Host "  Nothing to do (both features opted out)." -ForegroundColor DarkGray
    return
}

$changes = @()
foreach ($k in $desired.Keys) {
    $current = $existing.display.$k
    if ($current -ne $desired[$k]) { $changes += "    $k : $(if ($null -eq $current) { '(unset)' } else { $current }) -> $($desired[$k])" }
}

if ($changes.Count -eq 0) {
    Write-Host "  claude-hud already configured; no change." -ForegroundColor DarkGray
    return
}

Write-Host "  claude-hud config: $hudConfig" -ForegroundColor Cyan
$changes | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }

if ($WhatIfOnly) {
    Write-Host "  (WhatIfOnly: nothing written)" -ForegroundColor DarkGray
    return
}

# ------------------------------------------------------------------------ write
if (Test-Path $hudConfig) {
    $backupDir = Join-Path $HOME '.claudecm\backup'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    Copy-Item $hudConfig (Join-Path $backupDir "claude-hud.json.$stamp.pre-deploy") -Force
}

foreach ($k in $desired.Keys) {
    $existing.display | Add-Member -NotePropertyName $k -NotePropertyValue $desired[$k] -Force
}

$existing | ConvertTo-Json -Depth 20 | Set-Content $hudConfig -Encoding UTF8

# Read it back rather than announcing the intention to write. Same reasoning as
# ensure_cleanup_period_days in the main module: a message the user cannot
# verify is worse than no message.
$ok = $false
try {
    $after = Get-Content $hudConfig -Raw | ConvertFrom-Json
    $ok = $true
    foreach ($k in $desired.Keys) { if ($after.display.$k -ne $desired[$k]) { $ok = $false } }
} catch { $ok = $false }

if ($ok) {
    Write-Host "  Weekly usage bar will now always show." -ForegroundColor Green
    if (-not $NoSnapshot) {
        Write-Host "  Gauges will also appear on the first turn, from the last snapshot." -ForegroundColor Green
    }
    Write-Host "  Takes effect on the next statusline render; no restart needed." -ForegroundColor DarkGray
} else {
    Write-Host "  WARNING: wrote $hudConfig but could not verify it read back correctly." -ForegroundColor Yellow
}
