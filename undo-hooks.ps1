<#
.SYNOPSIS
    Turn off the work-agreement hooks. Run this from a normal terminal.

.DESCRIPTION
    A PreToolUse hook that fails blocks EVERY tool call. When that happens Claude
    cannot repair itself, because repairing means editing a file, and editing is a
    tool call. So this script exists to be run by Bob, in pwsh, with no Claude
    involved and no Python involved (Python being broken is one of the ways the
    hooks fail in the first place).

    The fix takes effect IMMEDIATELY in sessions that are already running. Measured
    2026-09-09: adding a hook mid-session fired on the very next tool call, and
    removing it stopped firing on the next call after that. No restart needed.

    Two modes:

      (default)   Restore ~/.claude/settings.json from the backup the installer
                  made. Blunt, cannot fail on malformed JSON, and brings back the
                  cmv hooks and everything else exactly as it was. Loses any
                  settings edits made after the install.

      -StripOnly  Parse settings.json and remove only the guard entries, leaving
                  the cmv PreCompact/PostToolUse hooks, statusline, env and the
                  rest untouched. Use when settings have changed since install.

.EXAMPLE
    pwsh -NoProfile -File .\undo-hooks.ps1
.EXAMPLE
    pwsh -NoProfile -File .\undo-hooks.ps1 -StripOnly
#>
[CmdletBinding()]
param(
    [switch]$StripOnly,
    # Overridable so the test suite can prove this works against fixtures rather
    # than against Bob's live settings. Defaults are the real paths.
    [string]$SettingsPath,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'

$settings = if ($SettingsPath) { $SettingsPath } else { Join-Path $env:USERPROFILE '.claude\settings.json' }
$backup   = if ($BackupPath)   { $BackupPath }   else { Join-Path $env:USERPROFILE '.claudecm\backup\settings.json.pre-hooks' }
$backupDir = Split-Path $backup

# Every script the work agreement installs. An entry whose command mentions any
# of these is ours and is removed; anything else is left alone.
$guardScripts = @('guard-bash.py', 'guard-write.py', 'guard-tool.py', 'check-output.py', 'rule-check.py', 'guard-scope.py')

function Test-GuardFree {
    <# Read the file back off disk and prove the guards are gone. Verifying the
       CLAIM, not that the write returned. #>
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $text = Get-Content $Path -Raw
    foreach ($s in $guardScripts) {
        if ($text -match [regex]::Escape($s)) { return $false }
    }
    return $true
}

Write-Output "settings: $settings"

if ($StripOnly) {
    if (-not (Test-Path $settings)) {
        Write-Output "NOTHING TO DO: $settings does not exist."
        exit 0
    }

    # Keep a copy of whatever is there now, in case this strip is the mistake.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $preStrip = Join-Path $backupDir "settings.json.pre-strip-$stamp"
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    Copy-Item $settings $preStrip -Force
    Write-Output "saved current file to: $preStrip"

    try {
        $json = Get-Content $settings -Raw | ConvertFrom-Json
    } catch {
        Write-Output "FAILED: settings.json does not parse, so it cannot be edited surgically."
        Write-Output "Run without -StripOnly to restore the backup instead."
        exit 1
    }

    if (-not $json.hooks) {
        Write-Output "No hooks block present. Nothing to strip."
        exit 0
    }

    $removed = 0
    foreach ($eventName in @($json.hooks.PSObject.Properties.Name)) {
        $entries = @($json.hooks.$eventName)
        $keep = @()
        foreach ($entry in $entries) {
            $isGuard = $false
            foreach ($h in @($entry.hooks)) {
                foreach ($s in $guardScripts) {
                    if ($h.command -and $h.command -match [regex]::Escape($s)) { $isGuard = $true }
                }
            }
            if ($isGuard) { $removed++ } else { $keep += $entry }
        }
        # An event left with no entries is removed entirely rather than left as [].
        if ($keep.Count -eq 0) {
            $json.hooks.PSObject.Properties.Remove($eventName)
        } else {
            $json.hooks.$eventName = $keep
        }
    }

    # -Depth 20 is load-bearing: ConvertTo-Json defaults to depth 2 and would
    # silently flatten the nested hooks arrays into strings.
    $json | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding utf8
    Write-Output "removed $removed guard entr$(if ($removed -eq 1) {'y'} else {'ies'})."
}
else {
    if (-not (Test-Path $backup)) {
        Write-Output "FAILED: no backup at $backup"
        Write-Output "The installer should have written it. Use -StripOnly instead, or"
        Write-Output "edit $settings by hand and delete the entries naming the guard scripts."
        exit 1
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $preRestore = Join-Path $backupDir "settings.json.pre-restore-$stamp"
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    if (Test-Path $settings) { Copy-Item $settings $preRestore -Force; Write-Output "saved current file to: $preRestore" }
    Copy-Item $backup $settings -Force
    Write-Output "restored from: $backup"
}

# Verify the claim, from disk, before saying it worked.
if (Test-GuardFree -Path $settings) {
    Write-Output ""
    Write-Output "VERIFIED: no guard script is referenced in settings.json."
    Write-Output "Running sessions recover on their NEXT tool call. No restart needed."
    exit 0
} else {
    Write-Output ""
    Write-Output "NOT CLEAN: a guard script is still referenced in $settings."
    Write-Output "Open the file and delete the entries naming: $($guardScripts -join ', ')"
    exit 1
}
