<#
    Proves undo-hooks.ps1 actually turns the guards off without collateral damage.

    This script is the safety net for a change that can block every tool call in
    every running session. A safety net that has not been proved to catch is not
    a safety net, so each check below states what it proves and the suite fails
    loudly rather than reporting a count nobody reads.

    Runs entirely against fixtures under temp/. Never touches ~/.claude.
#>
$ErrorActionPreference = 'Stop'

$repo   = Split-Path -Parent $PSScriptRoot
$undo   = Join-Path $repo 'undo-hooks.ps1'
$scratch = Join-Path $repo 'temp\undo-hooks-tests'

$script:pass = 0
$script:fail = 0

function Check {
    param([string]$Name, [bool]$Condition, $Detail = '')
    if ($Condition) {
        Write-Output "  PASS   $Name"
        $script:pass++
    } else {
        Write-Output "  **FAIL** $Name"
        if ($Detail) { Write-Output "           $Detail" }
        $script:fail++
    }
}

function New-Scratch {
    if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch }
    New-Item -ItemType Directory -Force $scratch | Out-Null
}

# A settings file shaped like Bob's real one: cmv hooks that MUST survive, guard
# hooks that must not, and unrelated keys that must come through untouched.
$realistic = @'
{
  "model": "opus[1m]",
  "env": { "ANTHROPIC_MODEL": "opus[1m]" },
  "hooks": {
    "PreCompact": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmv auto-trim", "timeout": 30 } ] }
    ],
    "PostToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmv auto-trim --check-size", "timeout": 10 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "python \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard-bash.py\"", "timeout": 10 } ] },
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "python \"~/.claude/hooks/guard-write.py\"", "timeout": 10 } ] },
      { "hooks": [ { "type": "command", "command": "python \"~/.claude/hooks/guard-tool.py\"", "timeout": 10 } ] },
      { "hooks": [ { "type": "command", "command": "python \"~/.claude/hooks/guard-authorization.py\"", "timeout": 10 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "python \"~/.claude/hooks/classify-prompt.py\"", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "python \"~/.claude/hooks/check-output.py\"", "timeout": 10 } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "node hud.js" }
}
'@

Write-Output ''
Write-Output 'undo-hooks.ps1'
Write-Output ''

# ---------------------------------------------------------------- StripOnly
New-Scratch
$s = Join-Path $scratch 'settings.json'
$b = Join-Path $scratch 'backup\settings.json.pre-hooks'
Set-Content -Path $s -Value $realistic -Encoding utf8

$out = & pwsh -NoProfile -File $undo -StripOnly -SettingsPath $s -BackupPath $b 2>&1 | Out-String
$rc = $LASTEXITCODE
$after = Get-Content $s -Raw
$json = $after | ConvertFrom-Json

Check 'strip: exits 0' ($rc -eq 0) $out
Check 'strip: says it is verified' ($out -match 'VERIFIED') $out
Check 'strip: guard-bash is gone' ($after -notmatch 'guard-bash')
Check 'strip: guard-write is gone' ($after -notmatch 'guard-write')
Check 'strip: check-output is gone' ($after -notmatch 'check-output')
Check 'strip: guard-tool is gone' ($after -notmatch 'guard-tool')
# The rule-1 pair matters most here: if the undo cannot remove them, Bob's
# escape hatch does not cover the guard most likely to be in his way.
Check 'strip: guard-authorization is gone' ($after -notmatch 'guard-authorization')
Check 'strip: classify-prompt is gone (a UserPromptSubmit hook, not PreToolUse)' ($after -notmatch 'classify-prompt')
Check 'strip: the cmv PreCompact hook SURVIVES' ($after -match 'cmv auto-trim')
Check 'strip: the cmv PostToolUse hook SURVIVES' ($after -match 'check-size')
Check 'strip: unrelated keys survive (statusLine)' ($null -ne $json.statusLine)
Check 'strip: unrelated keys survive (env)' ($json.env.ANTHROPIC_MODEL -eq 'opus[1m]')

# The ConvertTo-Json depth trap: at the default depth of 2 the nested hooks
# arrays flatten into literal strings and the file is silently ruined.
$cmvCmd = $null
try { $cmvCmd = $json.hooks.PreCompact[0].hooks[0].command } catch { }
Check 'strip: nested hook structure survives the JSON round trip (depth trap)' ($cmvCmd -eq 'cmv auto-trim') "got: $cmvCmd"

# An event emptied of entries should be removed, not left as a dangling []
Check 'strip: an emptied event is removed, not left empty' ($null -eq $json.hooks.PreToolUse)
Check 'strip: it kept a pre-strip backup' (Test-Path (Join-Path $scratch 'backup'))

# ------------------------------------------------------------ idempotence
$out2 = & pwsh -NoProfile -File $undo -StripOnly -SettingsPath $s -BackupPath $b 2>&1 | Out-String
Check 'strip: running twice is safe' ($LASTEXITCODE -eq 0) $out2

# ------------------------------------------------------------ restore mode
New-Scratch
$s = Join-Path $scratch 'settings.json'
$b = Join-Path $scratch 'backup\settings.json.pre-hooks'
New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
# Backup is the clean pre-install file; settings.json is the guarded one.
# Written out in full rather than regex-stripped from $realistic: an earlier
# version of this test built it with a regex, silently left the Stop guard in,
# and reported a script bug that did not exist.
$cleanPreInstall = @'
{
  "model": "opus[1m]",
  "env": { "ANTHROPIC_MODEL": "opus[1m]" },
  "hooks": {
    "PreCompact": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmv auto-trim", "timeout": 30 } ] }
    ],
    "PostToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmv auto-trim --check-size", "timeout": 10 } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "node hud.js" }
}
'@
Set-Content -Path $b -Value $cleanPreInstall -Encoding utf8
Set-Content -Path $s -Value $realistic -Encoding utf8

$out = & pwsh -NoProfile -File $undo -SettingsPath $s -BackupPath $b 2>&1 | Out-String
$rc = $LASTEXITCODE
$after = Get-Content $s -Raw
Check 'restore: exits 0' ($rc -eq 0) $out
Check 'restore: guards are gone' ($after -notmatch 'guard-bash' -and $after -notmatch 'check-output') $after
Check 'restore: cmv survives' ($after -match 'cmv auto-trim')

# ------------------------------------------- FAIL DIRECTIONS (the sabotage)
New-Scratch
$s = Join-Path $scratch 'settings.json'
$b = Join-Path $scratch 'backup\settings.json.pre-hooks'
Set-Content -Path $s -Value $realistic -Encoding utf8
$out = & pwsh -NoProfile -File $undo -SettingsPath $s -BackupPath $b 2>&1 | Out-String
Check 'restore with NO backup: exits non-zero rather than claiming success' ($LASTEXITCODE -ne 0) $out
Check 'restore with NO backup: says where the backup should have been' ($out -match 'no backup at') $out
Check 'restore with NO backup: leaves settings.json untouched' ((Get-Content $s -Raw) -match 'guard-bash')

New-Scratch
$s = Join-Path $scratch 'settings.json'
$b = Join-Path $scratch 'backup\settings.json.pre-hooks'
Set-Content -Path $s -Value '{ this is not json' -Encoding utf8
$out = & pwsh -NoProfile -File $undo -StripOnly -SettingsPath $s -BackupPath $b 2>&1 | Out-String
Check 'strip on malformed JSON: refuses rather than destroying the file' ($LASTEXITCODE -ne 0) $out
Check 'strip on malformed JSON: points at the restore path instead' ($out -match 'without -StripOnly') $out
Check 'strip on malformed JSON: the original file is still there' ((Get-Content $s -Raw) -match 'this is not json')

# Prove the verifier can actually go red: hand back a file that still has a guard.
New-Scratch
$s = Join-Path $scratch 'settings.json'
$b = Join-Path $scratch 'backup\settings.json.pre-hooks'
New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
Set-Content -Path $b -Value $realistic -Encoding utf8   # backup ITSELF contains a guard
Set-Content -Path $s -Value $realistic -Encoding utf8
$out = & pwsh -NoProfile -File $undo -SettingsPath $s -BackupPath $b 2>&1 | Out-String
Check 'a restore that does not actually clean it reports NOT CLEAN' ($out -match 'NOT CLEAN') $out
Check 'and exits non-zero' ($LASTEXITCODE -ne 0)

if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch }

Write-Output ''
Write-Output "$($script:pass + $script:fail) check(s): $($script:pass) pass, $($script:fail) fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
