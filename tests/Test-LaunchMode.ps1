<#
    Which permission mode does ClaudeCM launch Claude in?

    Standalone rather than part of Invoke-ClaudeCMTests.ps1: that suite is
    sabotage-first and every case must name a product edit inside a liftable
    function. These are bare invocations in the script body, so there is no
    function to lift, and bending the framework to fit would weaken it.

    WHY THIS MATTERS ENOUGH TO TEST

    Bypass (`--dangerously-skip-permissions`) switches OFF plan mode and the
    auto-mode classifier, which are Claude Code's own protections against an
    instance acting beyond what was asked. The docs are explicit: "Except in
    sessions with bypass permissions available, edits stay blocked until you
    approve the plan." So with bypass everywhere, the machine had no
    authorization layer at all, and hours went into building a homegrown
    replacement that measured a 13% leak against 100 hand-labelled messages.

    Changed 2026-09-11. Interactive launches use `--permission-mode auto`: no
    routine prompts, which is the whole reason bypass was there, but a
    classifier model reviews each action and blocks anything that escalates
    beyond the request.

    The two headless `-p` sites KEEP bypass deliberately. Nobody is there to
    answer if the classifier holds something, and each runs one scripted
    prompt, so the surface is small. That is a decision, not an oversight, and
    the counts below pin both halves.
#>
$ErrorActionPreference = 'Stop'

$module = Join-Path (Split-Path $PSScriptRoot -Parent) 'claudecm-powershell.ps1'
$pass = 0
$fail = 0

function Check {
    param([string]$Name, [bool]$Condition, $Detail = '')
    if ($Condition) {
        Write-Output "  PASS      $Name"
        $script:pass++
    } else {
        Write-Output "  **FAIL**  $Name"
        if ($Detail) { Write-Output "            $Detail" }
        $script:fail++
    }
}

Write-Output ''
Write-Output 'ClaudeCM launch permission mode'
Write-Output ''

Check 'the product file exists' (Test-Path $module) $module
if (-not (Test-Path $module)) {
    Write-Output ''
    Write-Output "1 check(s): 0 pass, 1 fail"
    exit 1
}

$src = Get-Content $module -Raw
# TWO FLAGS, ONE SUBSTRING. `--dangerously-skip-permissions` turns bypass ON.
# `--allow-dangerously-skip-permissions` only makes it SELECTABLE, leaving the
# session in whatever --permission-mode says. A plain match cannot tell them
# apart, so every count here uses a lookbehind. Added 2026-09-14 so bypass is
# reachable from the in-session mode cycle without relaunching.
# Count INVOCATIONS, not mentions. The first version of this counted raw
# string matches and went red on the comment that explains the flag, which is
# a test measuring the prose instead of the behaviour.
$launchLines = @($src -split "`r?`n" | Where-Object { $_ -match '&\s+\$claudeExe' })
$joined = $launchLines -join "`n"
$bypass = [regex]::Matches($joined, '(?<!allow-)dangerously-skip-permissions')

# The four interactive launches must go through the ONE decision point, so the
# answer to "what permissions does a session start with" cannot drift between
# them. A literal flag on any interactive line is the drift this catches.
$viaHelper = [regex]::Matches($joined, '@permFlags')
Check 'all four interactive launches go through Get-PermissionArgs' `
    ($viaHelper.Count -eq 4) "found $($viaHelper.Count)"

Check 'and none of them hardcodes a permission flag' `
    ($bypass.Count -eq 2) "found $($bypass.Count) bypass flag(s) on launch lines; only the two headless -p calls may carry one"

# Inside the helper: normal starts in auto with bypass merely selectable, and
# the bypass-ON branch is reachable only when the operator has chosen D.
$helper = [regex]::Match($src, '(?s)function Get-PermissionArgs \{.*?\n    \}').Value
Check 'the helper exists' ($helper.Length -gt 0) 'Get-PermissionArgs not found'
Check 'its default starts in auto and only makes bypass selectable' `
    ($helper -match 'allow-dangerously-skip-permissions' -and $helper -match 'permission-mode auto') $helper
Check 'its bypass branch is gated on the operator choosing D' `
    ($helper -match '\$script:launchBypass.*dangerously-skip-permissions') `
    'the bypass branch must be guarded by $script:launchBypass'
Check 'dangerous mode is off by default and never persisted' `
    (($src -match '\$script:launchBypass = \$false') -and ($src -notmatch 'launchBypass[^\n]*Set-Content')) `
    'launchBypass must default to false and must not be written to disk'

# Both survivors must be headless. If a bypass call ever appears without -p it
# is an interactive session with no classifier and no plan mode, which is the
# state this change exists to end.
$interactiveBypass = 0
# Launch INVOCATIONS only. The helper and its comment name the flag on purpose
# and are covered by the gating checks above; scanning the whole file here made
# this go red on an explanation, which is a test reading prose again.
foreach ($line in $launchLines) {
    if ($line -match '(?<!allow-)dangerously-skip-permissions' -and $line -notmatch '(^|\s)-p(\s|$)') {
        $interactiveBypass++
        Write-Output "            suspicious: $($line.Trim())"
    }
}
Check 'every remaining bypass call is headless (-p)' ($interactiveBypass -eq 0) `
    "$interactiveBypass bypass call(s) are not headless"

# The deployed copy is what actually runs. A repo-only change fixes nothing.
$deployed = Join-Path $env:USERPROFILE '.claudecm\claudecm-powershell.ps1'
if (Test-Path $deployed) {
    $dsrc = Get-Content $deployed -Raw
    $dlines = @($dsrc -split "`r?`n" | Where-Object { $_ -match '&\s+\$claudeExe' }) -join "`n"
    $dvia = [regex]::Matches($dlines, '@permFlags').Count
    $dhelper = $dsrc -match 'function Get-PermissionArgs'
    Check 'the DEPLOYED copy has the change too' (($dvia -eq 4) -and $dhelper) `
        "deployed has $dvia helper launches and helper-present=$dhelper; run the deploy step"
} else {
    Write-Output "  SKIP      no deployed copy at $deployed"
}

# The suggested-prompts switch. It used to live only in the deployed script,
# where a raw copy of the repo file over it (2026-09-11) silently put the
# suggestions back. It now lives in settings.json's env block, which no deploy
# touches. This pins it there so the next deploy cannot lose it again.
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $settings) {
    $val = $null
    try { $val = (Get-Content $settings -Raw | ConvertFrom-Json).env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION } catch { }
    Check 'settings.json env switches prompt suggestions OFF' ($val -eq '0') `
        "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION is '$val'; it must be '0' in the env block"
} else {
    Write-Output "  SKIP      no settings.json at $settings"
}

Write-Output ''
Write-Output "$($pass + $fail) check(s): $pass pass, $fail fail"
if ($fail) { exit 1 } else { exit 0 }
