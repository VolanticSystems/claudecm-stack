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
$bypass = [regex]::Matches($src, 'dangerously-skip-permissions')
$auto = [regex]::Matches($src, 'permission-mode auto')

Check 'the four interactive launches pass --permission-mode auto' `
    ($auto.Count -eq 4) "found $($auto.Count)"

Check 'exactly two launches keep bypass (the headless -p pair)' `
    ($bypass.Count -eq 2) "found $($bypass.Count)"

# Both survivors must be headless. If a bypass call ever appears without -p it
# is an interactive session with no classifier and no plan mode, which is the
# state this change exists to end.
$interactiveBypass = 0
foreach ($line in ($src -split "`r?`n")) {
    if ($line -match 'dangerously-skip-permissions' -and $line -notmatch '(^|\s)-p(\s|$)') {
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
    $dauto = [regex]::Matches($dsrc, 'permission-mode auto').Count
    Check 'the DEPLOYED copy has the change too' ($dauto -eq 4) `
        "deployed has $dauto auto launches; run the deploy step"
} else {
    Write-Output "  SKIP      no deployed copy at $deployed"
}

Write-Output ''
Write-Output "$($pass + $fail) check(s): $pass pass, $fail fail"
if ($fail) { exit 1 } else { exit 0 }
