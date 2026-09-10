<#
.SYNOPSIS
    Install the work-agreement guards. Run -Check first. Bob runs this, not Claude.

.DESCRIPTION
    WHY BOB RUNS IT
      If this goes wrong, every tool call in every session is blocked. Claude
      cannot repair that, because repairing means editing a file and editing is
      a tool call. Whoever runs it needs to be able to see the failure and fix
      it, and that is the person at the terminal.

    ORDER MATTERS, AND THIS IS THE ORDER
      1. verify everything            (writes nothing)
      2. copy the guards into place   (still not wired to anything)
      3. SMOKE TEST the copies        (prove they run on this machine)
      4. back up settings.json        (the undo depends on this existing)
      5. write the settings block     (the only irreversible-ish step)
      6. read it back and verify
    Any failure before step 5 leaves nothing wired. The checks come before the
    write, because after the write is too late.

    IT TAKES EFFECT IMMEDIATELY, INCLUDING IN RUNNING SESSIONS. Measured
    2026-09-09. Do not run this while sessions you care about are mid-task.

.EXAMPLE
    pwsh -NoProfile -File .\install-hooks.ps1 -Check
.EXAMPLE
    pwsh -NoProfile -File .\install-hooks.ps1
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$ClaudeDir,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'

$repo      = $PSScriptRoot
$srcHooks  = Join-Path $repo 'hooks'
$claudeDir = if ($ClaudeDir) { $ClaudeDir } else { Join-Path $env:USERPROFILE '.claude' }
$dstHooks  = Join-Path $claudeDir 'hooks'
$settings  = Join-Path $claudeDir 'settings.json'
$agreement = Join-Path $claudeDir 'agreement.md'
$backup    = if ($BackupPath) { $BackupPath } else { Join-Path $env:USERPROFILE '.claudecm\backup\settings.json.pre-hooks' }

$scripts = @('lib_agreement.py', 'guard-bash.py', 'guard-write.py', 'guard-tool.py',
             'lib_worklog.py', 'record-prompt.py', 'guard-worklog.py',
             'guard-output.py')

$script:problems = @()
function Fault([string]$m) { $script:problems += $m; Write-Output "  FAIL   $m" }
function Good([string]$m)  { Write-Output "  ok     $m" }

Write-Output ''
Write-Output 'Work agreement installer'
Write-Output "  source:   $srcHooks"
Write-Output "  target:   $dstHooks"
Write-Output "  settings: $settings"
Write-Output "  backup:   $backup"
Write-Output ''
Write-Output '1. Preflight'

# --- python resolves, and is the interpreter the settings block will name
$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) {
    Fault "python is not on PATH. The settings block would name an interpreter that does not exist, and a hook that cannot start BLOCKS EVERY TOOL CALL."
} else {
    $ver = & python --version 2>&1
    Good "python found: $($py.Source) ($ver)"
}

# --- every source script exists
foreach ($s in $scripts) {
    $p = Join-Path $srcHooks $s
    if (Test-Path $p) { Good "source present: $s" } else { Fault "missing source script: $p" }
}
$srcAgreement = Join-Path $srcHooks 'agreement.md'
if (Test-Path $srcAgreement) { Good "source present: agreement.md" } else { Fault "missing: $srcAgreement" }

# --- settings.json is readable and parses
if (Test-Path $settings) {
    try {
        $null = Get-Content $settings -Raw | ConvertFrom-Json
        Good "settings.json parses"
    } catch {
        Fault "settings.json does not parse: $($_.Exception.Message). Fix it before installing."
    }
} else {
    Good "no settings.json yet, one will be created"
}

# --- somewhere to put the backup
$backupDir = Split-Path $backup
try {
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    Good "backup directory writable: $backupDir"
} catch {
    Fault "cannot create backup directory $backupDir : $($_.Exception.Message)"
}

# --- report what would change
Write-Output ''
Write-Output '2. What this would change'
Write-Output "  copy $($scripts.Count) guard scripts into $dstHooks"
if (Test-Path $agreement) {
    Write-Output "  LEAVE $agreement alone (it already exists; your rules are not overwritten)"
} else {
    Write-Output "  create $agreement with NO rules in force"
}
Write-Output "  add 3 PreToolUse entries to settings.json (Bash; Write/Edit; all tools)"
Write-Output "  existing hooks are preserved, including the cmv trimmer"

if ($script:problems.Count -gt 0) {
    Write-Output ''
    Write-Output "PREFLIGHT FAILED: $($script:problems.Count) problem(s). Nothing was changed."
    exit 1
}

if ($Check) {
    Write-Output ''
    Write-Output 'PREFLIGHT PASSED. Nothing was changed (-Check).'
    Write-Output 'Re-run without -Check to install.'
    exit 0
}

# ------------------------------------------------------------------ install
Write-Output ''
Write-Output '3. Copying guards (not wired to anything yet)'
New-Item -ItemType Directory -Force $dstHooks | Out-Null
foreach ($s in $scripts) {
    Copy-Item (Join-Path $srcHooks $s) (Join-Path $dstHooks $s) -Force
    Good "copied $s"
}
if (-not (Test-Path $agreement)) {
    Copy-Item $srcAgreement $agreement -Force
    Good "created agreement.md with no rules in force"
} else {
    Good "kept your existing agreement.md"
}

Write-Output ''
Write-Output '4. Smoke testing the copies on this machine'
# Prove each guard runs and allows a benign payload BEFORE wiring it in. A guard
# that cannot start is the failure that wedges every session.
$benign = '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
foreach ($s in @('guard-bash.py', 'guard-write.py', 'guard-tool.py')) {
    $p = Join-Path $dstHooks $s
    $out = $benign | & python $p 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Fault "$s exited $rc on a benign payload. NOT WIRING ANYTHING."
    } elseif ("$out" -match '"permissionDecision"\s*:\s*"(deny|ask)"') {
        Fault "$s blocked a benign payload. NOT WIRING ANYTHING."
    } else {
        Good "$s runs and allows a benign command"
    }
}
if ($script:problems.Count -gt 0) {
    Write-Output ''
    Write-Output 'SMOKE TEST FAILED. settings.json was NOT touched, so nothing is active.'
    exit 1
}

Write-Output ''
Write-Output '5. Backing up settings.json'
if (Test-Path $settings) {
    Copy-Item $settings $backup -Force
    Good "backed up to $backup"
} else {
    '{}' | Set-Content $backup -Encoding utf8
    Good "no settings.json existed; wrote an empty backup so the undo still works"
}

Write-Output ''
Write-Output '6. Wiring the hooks'
$json = if (Test-Path $settings) { Get-Content $settings -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $json.PSObject.Properties.Name.Contains('hooks')) {
    $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
if (-not $json.hooks.PSObject.Properties.Name.Contains('PreToolUse')) {
    $json.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @()
}

$bashCmd  = 'python "' + ($dstHooks -replace '\\', '/') + '/guard-bash.py"'
$writeCmd = 'python "' + ($dstHooks -replace '\\', '/') + '/guard-write.py"'
$toolCmd  = 'python "' + ($dstHooks -replace '\\', '/') + '/guard-tool.py"'
$workCmd  = 'python "' + ($dstHooks -replace '\\', '/') + '/guard-worklog.py"'
$recCmd   = 'python "' + ($dstHooks -replace '\\', '/') + '/record-prompt.py"'
$outCmd   = 'python "' + ($dstHooks -replace '\\', '/') + '/guard-output.py"'

# Drop any previous copy of ours first, so re-running does not duplicate.
$kept = @($json.hooks.PreToolUse | Where-Object {
    $entry = $_
    -not (@($entry.hooks) | Where-Object { $_.command -match 'guard-bash\.py|guard-write\.py|guard-tool\.py' })
})

$kept += [pscustomobject]@{
    matcher = 'Bash'
    hooks   = @([pscustomobject]@{ type = 'command'; command = $bashCmd; timeout = 15 })
}
$kept += [pscustomobject]@{
    matcher = 'Write|Edit|MultiEdit|NotebookEdit'
    hooks   = @([pscustomobject]@{ type = 'command'; command = $writeCmd; timeout = 15 })
}
# No matcher: the tool guard has to see EVERY tool, because its whole job is
# matching on the name of a tool that must not run at all.
$kept += [pscustomobject]@{
    hooks   = @([pscustomobject]@{ type = 'command'; command = $toolCmd; timeout = 15 })
}
# Also unmatched: the work-record guard has to see every tool, because it
# decides per call whether that call changes anything on Bob's machine.
$kept += [pscustomobject]@{
    hooks   = @([pscustomobject]@{ type = 'command'; command = $workCmd; timeout = 15 })
}
$json.hooks.PreToolUse = $kept

# UserPromptSubmit: classify Bob's message before any tool runs. This hook
# decides nothing and never blocks a prompt; it only writes the verdict the
# rule-1 guard reads.
if (-not $json.hooks.PSObject.Properties.Name.Contains('UserPromptSubmit')) {
    $json.hooks | Add-Member -NotePropertyName UserPromptSubmit -NotePropertyValue @()
}
$keptPrompt = @($json.hooks.UserPromptSubmit | Where-Object {
    $entry = $_
    -not (@($entry.hooks) | Where-Object { $_.command -match 'record-prompt\.py|classify-prompt\.py' })
})
$keptPrompt += [pscustomobject]@{
    hooks = @([pscustomobject]@{ type = 'command'; command = $recCmd; timeout = 15 })
}
$json.hooks.UserPromptSubmit = $keptPrompt

# Stop: check the message just written against the `output` rules. This is the
# only hook that can see Claude's own prose, via last_assistant_message in the
# payload. It refuses to block twice in one turn, so it cannot spin a session.
if (-not $json.hooks.PSObject.Properties.Name.Contains('Stop')) {
    $json.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @()
}
$keptStop = @($json.hooks.Stop | Where-Object {
    $entry = $_
    -not (@($entry.hooks) | Where-Object { $_.command -match 'guard-output\.py|check-output\.py' })
})
$keptStop += [pscustomobject]@{
    hooks = @([pscustomobject]@{ type = 'command'; command = $outCmd; timeout = 15 })
}
$json.hooks.Stop = $keptStop

# -Depth 20 is load-bearing: the default of 2 flattens nested arrays to strings.
$json | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding utf8
Good "wrote settings.json"

Write-Output ''
Write-Output '7. Verifying from disk'
$after = Get-Content $settings -Raw
$reparsed = $null
try { $reparsed = $after | ConvertFrom-Json } catch { }
if (-not $reparsed) {
    Fault "settings.json no longer parses. RESTORE NOW: pwsh -NoProfile -File `"$repo\undo-hooks.ps1`""
} else {
    if ($after -match 'guard-bash\.py') { Good "guard-bash is wired" } else { Fault "guard-bash is not in the file" }
    if ($after -match 'guard-write\.py') { Good "guard-write is wired" } else { Fault "guard-write is not in the file" }
    if ($after -match 'guard-tool\.py') { Good "guard-tool is wired" } else { Fault "guard-tool is not in the file" }
    # These two were added later and were NOT checked here at first, so the
    # installer reported success having verified three of five guards. Verify
    # what you are claiming, not that the write returned.
    if ($after -match 'guard-worklog\.py') { Good "guard-worklog is wired" } else { Fault "guard-worklog is not in the file" }
    if ($after -match 'record-prompt\.py') { Good "record-prompt is wired (UserPromptSubmit)" } else { Fault "record-prompt is not in the file" }
    if ($after -match 'guard-output\.py') { Good "guard-output is wired (Stop)" } else { Fault "guard-output is not in the file" }
    # Nothing may reference a script that is not on disk. That is the exact
    # shape of the 2026-09-10 wedge: settings pointed at a deleted file, Python
    # exited non-zero, and every tool call in every session was refused.
    foreach ($m in [regex]::Matches($after, '[A-Za-z0-9_-]+\.py')) {
        $p = Join-Path $dstHooks $m.Value
        if (-not (Test-Path $p)) { Fault "settings.json names $($m.Value) but it is not in $dstHooks" }
    }
    $cmv = ($after -match 'cmv auto-trim')
    if ($cmv) { Good "the cmv trimmer survived" }
}

Write-Output ''
if ($script:problems.Count -gt 0) {
    Write-Output "INSTALL INCOMPLETE. Undo with:"
    Write-Output "  pwsh -NoProfile -File `"$repo\undo-hooks.ps1`""
    exit 1
}

# Report the ACTUAL rule count rather than assuming a first install. This line
# used to say "inert: no rules are in force yet" unconditionally, which was a
# lie on every reinstall after the first.
$ruleCount = '(could not read)'
try {
    $listing = & python (Join-Path $dstHooks 'lib_agreement.py') --list 2>&1 | Out-String
    if ($listing -match '(\d+)\s+rule\(s\) in force') { $ruleCount = $Matches[1] }
} catch { }

if ($ruleCount -eq '0') {
    Write-Output 'INSTALLED, and inert: no rules are in force yet.'
} else {
    Write-Output "INSTALLED. $ruleCount rule(s) are in force."
    Write-Output "  Reads are never gated. A state change needs an open task in"
    Write-Output "  hooks\state\current-task.json citing something you actually said."
}
Write-Output ''
Write-Output "Edit your rules here:  $agreement"
Write-Output "Test a rule first:     python `"$dstHooks\lib_agreement.py`" --list"
Write-Output ''
Write-Output 'If anything goes wrong, from any terminal:'
Write-Output "  pwsh -NoProfile -File `"$repo\undo-hooks.ps1`""
Write-Output ''
Write-Output 'Running sessions pick this up on their next tool call. No restart needed.'
exit 0
