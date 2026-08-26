# Invoke-ClaudeCMTests.ps1 - first test suite for claudecm-powershell.ps1
#
# WHY THIS FILE LOOKS UNUSUAL
#
# 31 of the 34 functions in claudecm-powershell.ps1 are nested inside the
# single `claudecm` function, so dot-sourcing the module exposes only
# `claudecm`, `lst` and `grep`. None of the interesting functions are
# reachable. This harness therefore parses the module with the PowerShell
# AST, lifts each nested function's source text out, and re-defines it in an
# isolated scope alongside the enclosing-scope variables it closes over.
#
# That means ZERO changes to the product to make it testable.
#
# EVERY TEST CARRIES ITS SABOTAGE. The project's own rule is that if you
# cannot name the edit to the product that makes a test fail, you are not
# writing a test. Here that rule is executed rather than trusted: each test
# declares a textual mutation of the product source, and the harness runs the
# test twice, once clean (must PASS) and once mutated (must FAIL). A test that
# still passes under its own sabotage is reported as HOLLOW, which is a
# failure of the suite, not of the product.
#
# Nothing here touches real state. Every test runs against a sandbox
# directory and the module's path variables are repointed at it.

[CmdletBinding()]
param(
    [string]$Module = (Join-Path (Split-Path $PSScriptRoot -Parent) 'claudecm-powershell.ps1'),
    [switch]$SkipSabotage,
    [string]$Only
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- extraction

function Get-NestedFunctionSource {
    param([string]$Path)
    $errors = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count) {
        throw "module does not parse: $($errors[0].Message) at line $($errors[0].Extent.StartLineNumber)"
    }
    $all = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $map = @{}
    foreach ($fn in $all) {
        if ($fn.Name -eq 'claudecm') { continue }
        # last definition wins, which matches PowerShell's own behaviour
        $map[$fn.Name] = $fn.Extent.Text
    }
    $map
}

$script:FunctionSource = Get-NestedFunctionSource -Path $Module
$script:ClaudeStub = Join-Path $PSScriptRoot 'stubs\claude-stub.ps1'
if (-not (Test-Path $script:ClaudeStub)) { throw "missing stub: $script:ClaudeStub" }

# ------------------------------------------------------------------- sandbox

function New-Sandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("claudecm-tests-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    $null = New-Item -ItemType Directory -Path $root -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.claudecm\backup') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.claude\projects') -Force
    # Spec section 4 bootstrap creates sessions.txt if missing, so every
    # function downstream may assume it exists. The fixture matches that.
    $null = New-Item -ItemType File -Path (Join-Path $root '.claudecm\sessions.txt') -Force
    [pscustomobject]@{
        Root         = $root
        CmDir        = Join-Path $root '.claudecm'
        SessionsFile = Join-Path $root '.claudecm\sessions.txt'
        BackupDir    = Join-Path $root '.claudecm\backup'
        ClaudeProj   = Join-Path $root '.claude\projects'
    }
}

# Builds a scriptblock that defines the requested product functions plus the
# enclosing-scope variables they close over, then runs the caller's body.
function New-ProductScope {
    param([string[]]$Functions, [object]$Sandbox, [hashtable]$Mutations = @{})

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('param($sandbox)')
    # SEAM FIDELITY. This harness runs under Set-StrictMode -Version Latest to
    # catch its OWN bugs, and a created scriptblock inherits that. The product
    # never sets StrictMode, so without this line the lifted functions execute
    # under semantics production does not have.
    #
    # It is not academic: Parse-SessionLine does $parts[1] on a 1-element array
    # for a blank or malformed row. Under StrictMode that throws; in production
    # it yields $null and the tool carries on. Testing the strict version would
    # be testing a program Bob does not run.
    [void]$sb.AppendLine('Set-StrictMode -Off')
    # the enclosing-scope variables the nested functions read
    [void]$sb.AppendLine('$cmDir        = $sandbox.CmDir')
    [void]$sb.AppendLine('$sessionsFile = $sandbox.SessionsFile')
    [void]$sb.AppendLine('$backupDir    = $sandbox.BackupDir')
    [void]$sb.AppendLine('$lockFile     = "$sessionsFile.lock"')
    [void]$sb.AppendLine('$tmpFile      = "$sessionsFile.tmp"')
    # Tier 3: the launch helpers shell out to $claudeExe. Point it at the stub.
    [void]$sb.AppendLine("`$claudeExe    = '$script:ClaudeStub'")
    [void]$sb.AppendLine('$machineNameFile = "$cmDir\machine-name.txt"')
    [void]$sb.AppendLine('$quarantineRoot  = Join-Path $sandbox.Root "quarantine"')
    # Deliberately a path that does not exist. Do-PostExit guards every cmv
    # call with Test-Path $cmvExe, so a missing binary means the snapshot and
    # the benchmark are skipped and the registration logic is reachable on its
    # own. That is the part worth testing; cmv is somebody else's program.
    [void]$sb.AppendLine('$cmvExe       = Join-Path $sandbox.Root "no-such-cmv.cmd"')
    foreach ($name in $Functions) {
        if (-not $script:FunctionSource.ContainsKey($name)) { throw "no such function in module: $name" }
        $src = $script:FunctionSource[$name]
        if ($Mutations.ContainsKey($name)) {
            $m = $Mutations[$name]
            if ($src -notmatch [regex]::Escape($m.Find)) {
                throw "SABOTAGE ANCHOR MISSING in ${name}: '$($m.Find)' not found. The product changed; update the sabotage."
            }
            # .Replace, NOT -replace. In .NET replacement strings '$_' means THE
            # ENTIRE INPUT STRING, '$&' the whole match, '$1' a group. A
            # PowerShell sabotage replacement almost always contains $_, so
            # -replace silently splices the whole function into itself and the
            # mutation becomes nonsense that still parses. Two tests passed for
            # the wrong reason this way. String.Replace is literal on both sides.
            $src = $src.Replace($m.Find, $m.Replace)
        }
        [void]$sb.AppendLine($src)
    }
    $sb.ToString()
}

function Invoke-InProductScope {
    param([string[]]$Functions, [object]$Sandbox, [hashtable]$Mutations = @{}, [scriptblock]$Body)
    $prelude = New-ProductScope -Functions $Functions -Sandbox $Sandbox -Mutations $Mutations
    $full = $prelude + "`n" + $Body.ToString()
    $sb = [scriptblock]::Create($full)
    # Get-ProjectKey callers build $env:USERPROFILE\.claude\projects\<key>
    # themselves, so the sandbox has to BE the user profile for the duration.
    # Restored in finally: leaking this would point the rest of the suite, and
    # anything else in this process, at a temp directory.
    $savedProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $Sandbox.Root
        # A PRECONDITION, not a test. Every path in this tool derives from
        # USERPROFILE, so if the redirect ever failed the suite would operate on
        # the real ~/.claudecm and ~/.claude. That is the one harness failure
        # that costs data rather than confidence, so it aborts rather than
        # reports. It is deliberately not a Test-Case: its sabotage would have
        # to be an edit to this harness rather than to the product, which is
        # exactly the shape the hollow detector is built to reject.
        if ($env:USERPROFILE -ne $Sandbox.Root -or $Sandbox.Root -eq $savedProfile) {
            throw "SANDBOX ISOLATION FAILED: USERPROFILE is '$env:USERPROFILE', expected '$($Sandbox.Root)'. Refusing to run a test against real state."
        }
        & $sb $Sandbox
    } finally { $env:USERPROFILE = $savedProfile }
}

# --------------------------------------------------------------- test registry

$script:Tests = New-Object System.Collections.Generic.List[object]

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Uses,
        [Parameter(Mandatory)][string]$Sabotage,   # human description
        [Parameter(Mandatory)][hashtable]$Mutate,  # @{ FuncName = @{Find=..;Replace=..} }
        [Parameter(Mandatory)][scriptblock]$Body   # throws on failure
    )
    $script:Tests.Add([pscustomobject]@{
        Name = $Name; Uses = $Uses; Sabotage = $Sabotage; Mutate = $Mutate; Body = $Body
    })
}

# THE SENTINEL, and why it exists.
#
# The doctrine says a sabotage "must leave the test running and its assertion
# evaluating. Deleting the file or making it unparseable does not count: an
# error is not a red assertion." The first version of this harness could not
# tell those apart: it treated ANY error during the sabotage pass as proof the
# test can fail. So a lazy sabotage that merely broke the module would have
# certified a hollow test as sound, which is exactly the escape hatch the rule
# names.
#
# Every assertion failure now carries this marker. Anything thrown WITHOUT it
# is the harness or the product falling over, which proves nothing, and is
# reported INCONCLUSIVE rather than counted as a pass.
$script:AssertSentinel = 'CLAUDECM-ASSERTION-FAILED'

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    # ORDINAL comparison deliberately: PowerShell's -eq on strings is culture
    # sensitive and treats control characters as ignorable, so two strings of
    # different lengths can compare equal. That defect is in this project's
    # own history.
    $ok = if ($Expected -is [string] -and $Actual -is [string]) {
        [string]::Equals($Expected, $Actual, [StringComparison]::Ordinal)
    } else { $Expected -eq $Actual }
    if (-not $ok) {
        throw "$script:AssertSentinel $Because`n    expected: [$Expected]`n    actual:   [$Actual]"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw "$script:AssertSentinel $Because" }
}

# =============================================================================
# TIER 1 - pure transformations. No filesystem.
# =============================================================================

Test-Case -Name 'Format-Tokens renders millions with one decimal (spec 7)' `
    -Uses @('Format-Tokens') `
    -Sabotage 'change the 1000000 threshold in Format-Tokens to 10000000 so 1234567 falls through to the K branch' `
    -Mutate @{ 'Format-Tokens' = @{ Find = '1000000'; Replace = '10000000' } } `
    -Body {
        Assert-Equal '1.2M tok' (Format-Tokens 1234567) 'spec 7 requires 1.2M tok'
    }

Test-Case -Name 'Format-Tokens renders thousands with no decimals (spec 7)' `
    -Uses @('Format-Tokens') `
    -Sabotage 'change the K-branch format string in Format-Tokens from {0}K to {0:N1}K' `
    -Mutate @{ 'Format-Tokens' = @{ Find = 'K tok'; Replace = '.0K tok' } } `
    -Body {
        Assert-Equal '155K tok' (Format-Tokens 155000) 'spec 7 requires 155K tok'
    }

Test-Case -Name 'Format-Tokens renders empty input as -- (spec 7)' `
    -Uses @('Format-Tokens') `
    -Sabotage 'change the empty-input return in Format-Tokens from -- to 0 tok' `
    -Mutate @{ 'Format-Tokens' = @{ Find = '"--"'; Replace = '"0 tok"' } } `
    -Body {
        Assert-Equal '--' (Format-Tokens '') 'spec 7: empty means never measured, not zero'
    }

Test-Case -Name 'Format-Size renders megabytes with one decimal (spec 7)' `
    -Uses @('Format-Size') `
    -Sabotage 'change the 1MB threshold in Format-Size to 1GB so 1572864 falls to the KB branch' `
    -Mutate @{ 'Format-Size' = @{ Find = '1MB'; Replace = '1GB' } } `
    -Body {
        Assert-Equal '1.5 MB' (Format-Size 1572864) 'spec 7 requires 1.5 MB'
    }

Test-Case -Name 'Get-ProjectKey replaces EVERY non-alphanumeric (spec 6)' `
    -Uses @('Get-ProjectKey') `
    -Sabotage 'narrow the character class in Get-ProjectKey to [:\\ ] so dots and slashes survive' `
    -Mutate @{ 'Get-ProjectKey' = @{ Find = '[^a-zA-Z0-9]'; Replace = '[:\\ ]' } } `
    -Body {
        # the spec calls out dots specifically: inline regexes that miss them
        # produce keys that do not match disk
        Assert-Equal 'C--Users-alice-Documents-GitHub-WPF-Connector-Thing' `
            (Get-ProjectKey 'C:\Users\alice\Documents\GitHub\WPF-Connector.Thing') `
            'spec 6 requires dots to become hyphens too'
    }

Test-Case -Name 'Get-ProjectKey handles POSIX paths (spec 6)' `
    -Uses @('Get-ProjectKey') `
    -Sabotage 'anchor Get-ProjectKey to backslash only, leaving forward slashes intact' `
    -Mutate @{ 'Get-ProjectKey' = @{ Find = '[^a-zA-Z0-9]'; Replace = '[\\]' } } `
    -Body {
        Assert-Equal '-home-user-projects-foo' (Get-ProjectKey '/home/user/projects/foo') `
            'spec 6 worked example'
    }

# =============================================================================
# TIER 2 - state on disk, in a sandbox.
# =============================================================================

Test-Case -Name 'Parse-SessionLine round-trips a 4-field row (spec 5)' `
    -Uses @('Parse-SessionLine') `
    -Sabotage 'change the split limit in Parse-SessionLine from 4 to 3 so tokens are folded into desc' `
    -Mutate @{ 'Parse-SessionLine' = @{ Find = "'\|', 4"; Replace = "'\|', 3" } } `
    -Body {
        $r = Parse-SessionLine 'abc-123|C:\proj\x|My Session|91587'
        Assert-Equal 'My Session' $r.Desc  'DESC must not absorb the token field'
        Assert-Equal '91587'      $r.Tokens 'TOKENS must be its own field'
    }

Test-Case -Name 'Write-SessionsAtomic leaves no .tmp behind (spec 5.1)' `
    -Uses @('Write-SessionsAtomic') `
    -Sabotage 'replace the Move-Item rename in Write-SessionsAtomic with Copy-Item so the temp file survives' `
    -Mutate @{ 'Write-SessionsAtomic' = @{ Find = 'Move-Item'; Replace = 'Copy-Item' } } `
    -Body {
        Write-SessionsAtomic @('g|d|desc|1')
        Assert-True (Test-Path $sessionsFile) 'sessions.txt must exist after write'
        Assert-True (-not (Test-Path "$sessionsFile.tmp")) `
            'spec 5.1 step 3: the temp file must be RENAMED over the target, not copied'
    }

Test-Case -Name 'Save-Sessions preserves row order, which is MRU meaning (spec 5)' `
    -Uses @('Write-SessionsAtomic','Acquire-SessionsLock','Release-SessionsLock','Get-ArchivedSessions','Save-Sessions','Parse-SessionLine','Get-Sessions') `
    -Sabotage 'add a Sort-Object Desc to the projection inside Save-Sessions, so the file is written alphabetically instead of in MRU order' `
    -Mutate @{ 'Save-Sessions' = @{ Find = '$lines = @($sessions | ForEach-Object'; Replace = '$lines = @($sessions | Sort-Object Desc | ForEach-Object' } } `
    -Body {
        # Save-Sessions takes session OBJECTS, not raw lines.
        $rows = @(
            (Parse-SessionLine 'zzz|C:\proj|Zebra|1'),
            (Parse-SessionLine 'aaa|C:\proj|Apple|2')
        )
        Save-Sessions $rows
        $back = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-Equal 'zzz|C:\proj|Zebra|1' $back[0] `
            'spec 5: order in the file is order in the menu. Sorting destroys MRU meaning.'
    }

Test-Case -Name 'Get-Sessions returns an ARRAY even for one row (spec 14.3)' `
    -Uses @('Write-SessionsAtomic','Parse-SessionLine','Get-Sessions') `
    -Sabotage 'drop the comma from "return ,$sessions" in Get-Sessions, so a single-element array unwraps to a bare PSCustomObject' `
    -Mutate @{ 'Get-Sessions' = @{ Find = 'return ,$sessions'; Replace = 'return $sessions' } } `
    -Body {
        Write-SessionsAtomic @('only-one|C:\proj|Solo|5')
        $s = Get-Sessions
        # Assert the TYPE, not .Count: a bare PSCustomObject also reports
        # .Count of 1 in PowerShell 7, so a count assertion here would be a
        # test that cannot fail. Spec 14.3 is about the wrapper surviving.
        Assert-True ($s -is [array]) `
            'spec 14.3: the comma must keep the array wrapper, or a 1-session project falsely trips the orphan picker'
    }

Test-Case -Name 'sessions.txt ignores blank lines on read (spec 5)' `
    -Uses @('Write-SessionsAtomic','Parse-SessionLine','Get-Sessions') `
    -Body {
        Set-Content $sessionsFile @('a|d|One|1','','b|d|Two|2','   ') -Encoding UTF8
        # NOTE, and this cost a real debugging round: do NOT write
        # @(Get-Sessions). Get-Sessions returns ,$sessions and re-wrapping a
        # comma-returned array NESTS it, giving one element that is itself the
        # array. That is spec 14.3 and commit 49b3c45, reproduced accidentally
        # while writing this very test.
        $s = Get-Sessions
        Assert-Equal 2 $s.Count 'spec 5: empty lines are ignored on read'
    } `
    -Sabotage 'weaken the blank-line filter in Get-Sessions from -ne to -eq so only blank rows survive' `
    -Mutate @{ 'Get-Sessions' = @{ Find = "Where-Object { `$_.Trim() -ne '' }"; Replace = "Where-Object { `$_ -ne `$null }" } }

# =============================================================================
# TIER 3 - behaviours that spawn a child process.
#
# These call the real launch helpers with $claudeExe pointed at
# stubs\claude-stub.ps1, which writes a transcript and returns a chosen exit
# code. This is where every historical data-loss incident lives, so it is the
# tier worth the setup cost.
# =============================================================================

Test-Case -Name 'new-session detection survives a non-zero exit (spec 14.4)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Invoke-FreshLaunchWithDetection') `
    -Sabotage 'gate the GUID assignment in Invoke-FreshLaunchWithDetection on $exitCode -eq 0, reintroducing the defect that made sessions vanish unless the user typed /exit' `
    -Mutate @{ 'Invoke-FreshLaunchWithDetection' = @{
        Find    = '$script:lastFreshNewGuid = $newGuid'
        Replace = '$script:lastFreshNewGuid = $(if ($exitCode -eq 0) { $newGuid } else { $null })' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'proj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $key = Get-ProjectKey $projDir
        $keyDir = Join-Path $sandbox.ClaudeProj $key
        $guid = '11111111-2222-3333-4444-555555555555'
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        $env:CLAUDECM_STUB_GUID    = $guid
        # 130 is Ctrl-C. The user closing the window or the process crashing
        # look the same to us, and spec 14.4 says all of them must still
        # register the session.
        $env:CLAUDECM_STUB_EXIT    = '130'
        try {
            Invoke-FreshLaunchWithDetection $projDir 'machine - Test' @() $null
            Assert-Equal $guid $script:lastFreshNewGuid `
                'spec 14.4: registration must NOT depend on the child exit code'
            Assert-Equal 130 $script:lastFreshExit 'the exit code itself must still be reported'
        } finally {
            Remove-Item Env:CLAUDECM_STUB_PROJDIR, Env:CLAUDECM_STUB_GUID, Env:CLAUDECM_STUB_EXIT -ErrorAction SilentlyContinue
        }
    }

Test-Case -Name 'new-session detection uses set-diff, not newest-mtime (spec 11.6.2)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Invoke-FreshLaunchWithDetection') `
    -Sabotage 'drop the "-not $before.ContainsKey" clause so every JSONL is a candidate and the newest wins, which is the newest-mtime strategy 11.6.2 exists to replace' `
    -Mutate @{ 'Invoke-FreshLaunchWithDetection' = @{
        Find    = 'Where-Object { $_.BaseName -match $uuidPattern -and -not $before.ContainsKey($_.BaseName) })'
        Replace = 'Where-Object { $_.BaseName -match $uuidPattern })' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'proj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $key = Get-ProjectKey $projDir
        $keyDir = Join-Path $sandbox.ClaudeProj $key
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        # a session that already existed before this launch
        $oldGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $oldPath = Join-Path $keyDir "$oldGuid.jsonl"
        Set-Content $oldPath '{"type":"user"}' -Encoding UTF8
        # Make the PRE-EXISTING file the newest on disk BEFORE the launch, so it
        # is still the newest at the moment detection runs. Setting it afterwards
        # changes nothing the code ever looks at, which made this test hollow on
        # its first outing. Under set-diff the mtime is irrelevant; under
        # newest-mtime this file wins and the tool adopts the wrong GUID, which
        # is exactly the failure 11.6.2 was written to prevent.
        (Get-Item $oldPath).LastWriteTime = (Get-Date).AddMinutes(5)

        $newGuid = '99999999-8888-7777-6666-555555555555'
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        $env:CLAUDECM_STUB_GUID    = $newGuid
        try {
            Invoke-FreshLaunchWithDetection $projDir 'machine - Test' @() $null
            Assert-Equal $newGuid $script:lastFreshNewGuid `
                'spec 11.6.2: identification is by set-diff, so a concurrent writer touching an older transcript cannot steal the result'
        } finally {
            Remove-Item Env:CLAUDECM_STUB_PROJDIR, Env:CLAUDECM_STUB_GUID -ErrorAction SilentlyContinue
        }
    }

Test-Case -Name 'Do-PostExit bumps the exited session to the top (MRU)' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine',
            'Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock',
            'Write-SessionsAtomic','Save-Sessions','Sync-SessionIndex','Get-SessionInfo','Do-PostExit') `
    -Sabotage 'stop reordering in Do-PostExit and write the list back untouched, so the exited session keeps its old position and sessions.txt is no longer MRU' `
    -Mutate @{ 'Do-PostExit' = @{
        Find    = '$sessions = @($existing) + @($sessions | Where-Object { $_.Guid -ne $guid })'
        Replace = '$sessions = $sessions' } } `
    -Body {
        # Do-PostExit prompts twice at the end (trim, refresh). Shadow Read-Host
        # so both answer no and the function returns without reaching Do-Trim or
        # Do-Refresh, neither of which is loaded here.
        function Read-Host { param([string]$Prompt) 'N' }
        $target = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        Set-Content $sessionsFile @(
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|$($sandbox.Root)|First|1",
            "$target|$($sandbox.Root)|Second|2",
            "cccccccc-cccc-cccc-cccc-cccccccccccc|$($sandbox.Root)|Third|3"
        ) -Encoding UTF8

        Do-PostExit $target

        $rows = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-True ($rows[0].StartsWith($target)) `
            'the session that just exited must be row 1: sessions.txt is most-recently-used order'
        Assert-Equal 3 $rows.Count 'no session may be lost or duplicated by the reorder'
    }

Test-Case -Name 'Test-CleanExitTail recognises a trailing /exit' `
    -Uses @('Test-CleanExitTail') `
    -Sabotage 'narrow the tail pattern so the /exit command block no longer matches' `
    -Mutate @{ 'Test-CleanExitTail' = @{
        Find = "'/exit</command-name>'"; Replace = "'/quit</command-name>'" } } `
    -Body {
        $clean = Join-Path $sandbox.Root 'clean.jsonl'
        $dirty = Join-Path $sandbox.Root 'dirty.jsonl'
        Set-Content $clean @('{"a":1}','{"m":"<command-name>/exit</command-name>"}') -Encoding UTF8
        Set-Content $dirty @('{"a":1}','{"m":"still talking"}') -Encoding UTF8
        Assert-True (Test-CleanExitTail $clean) 'a trailing /exit must be recognised'
        Assert-True (-not (Test-CleanExitTail $dirty)) 'an interrupted session must NOT look like a clean exit'
    }

# =============================================================================
# TIER 2b - whole-module integration.
#
# The search dispatch lives inside `claudecm` itself rather than in a nested
# function, so the AST-lift seam cannot reach it. These tests instead copy the
# whole module, optionally mutate the copy, dot-source it in a CHILD pwsh with
# USERPROFILE repointed at a sandbox, and shadow Read-Host so the interactive
# pick returns immediately.
# =============================================================================

$script:IntegrationTests = New-Object System.Collections.Generic.List[object]

function Integration-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Sabotage,
        [Parameter(Mandatory)][hashtable]$Mutate,   # @{Find=..;Replace=..} against the whole file
        [Parameter(Mandatory)][string]$Assertions   # pwsh code; throw to fail
    )
    $script:IntegrationTests.Add([pscustomobject]@{
        Name = $Name; Sabotage = $Sabotage; Mutate = $Mutate; Assertions = $Assertions
    })
}

function Invoke-Integration {
    param([object]$Case, [bool]$Sabotaged)
    $sb = New-Sandbox
    $modCopy = Join-Path $sb.Root 'module-under-test.ps1'
    $src = Get-Content $Module -Raw
    if ($Sabotaged) {
        if ($src -notmatch [regex]::Escape($Case.Mutate.Find)) { Remove-Item $sb.Root -Recurse -Force; return 3 }
        $src = $src.Replace($Case.Mutate.Find, $Case.Mutate.Replace)   # literal; see New-ProductScope
    }
    Set-Content -LiteralPath $modCopy -Value $src -Encoding UTF8

    'desktop' | Set-Content (Join-Path $sb.CmDir 'machine-name.txt')
    @(
        'aaa|C:\tmp\p1|Claude Context Manager|441961'
        'bbb|C:\tmp\p2|Router|195046'
        'ccc|C:\tmp\p3|Mozz AI|216263'
        'ddd|C:\tmp\p4|context switching notes|1000'
        'eee|C:\tmp\p5|Zoom Dom|300943'
    ) | Set-Content $sb.SessionsFile -Encoding UTF8

    $driver = Join-Path $sb.Root 'driver.ps1'
    $body = @"
`$env:USERPROFILE = '$($sb.Root)'
. '$modCopy'
function Read-Host { param([string]`$Prompt) 'q' }
`$SENT = '$script:AssertSentinel'
function Assert-Contains { param(`$Text,`$Needle,`$Because) if (`$Text -notmatch [regex]::Escape(`$Needle)) { throw "`$SENT `$Because" } }
function Assert-NotContains { param(`$Text,`$Needle,`$Because) if (`$Text -match [regex]::Escape(`$Needle)) { throw "`$SENT `$Because" } }
try {
$($Case.Assertions)
    exit 0
} catch {
    Write-Host `$_.Exception.Message
    # 90 = an assertion evaluated and went red. 91 = something else fell over,
    # which proves nothing about whether this test can fail.
    if (`$_.Exception.Message -like "*`$SENT*") { exit 90 } else { exit 91 }
}
"@
    Set-Content -LiteralPath $driver -Value $body -Encoding UTF8
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $driver *> $null
    $rc = $LASTEXITCODE
    Remove-Item $sb.Root -Recurse -Force -ErrorAction SilentlyContinue
    return $rc
}

Integration-Case -Name 'claudecm -s filters the list by name, case-insensitively' `
    -Sabotage 'change the search predicate from .Contains to .StartsWith, so a term in the middle of a name stops matching' `
    -Mutate @{ Find = '$_.Desc.ToLower().Contains($term.ToLower())'; Replace = '$_.Desc.ToLower().StartsWith($term.ToLower())' } `
    -Assertions @'
    # 6>&1 is REQUIRED: the module speaks only through Write-Host, which
    # writes to the information stream (6), not the success pipeline. Without
    # this redirect the capture is empty and every assertion below would be
    # asserting against an empty string, which is a test that cannot fail.
    $out = (claudecm -s context 6>&1 | Out-String)
    Assert-Contains $out 'Claude Context Manager' 'a mid-name match must be found'
    Assert-Contains $out 'context switching notes' 'a start-of-name match must be found'
    Assert-NotContains $out 'Zoom Dom' 'a non-matching session must not be listed'
    Assert-Contains $out '2 of 5' 'the count line must report matches out of total'
'@

Integration-Case -Name 'claudecm -s never offers the new-project fallback' `
    -Sabotage 'make the no-match branch fall through instead of returning, so search reaches list-mode behaviour' `
    -Mutate @{ Find = "Write-Host `"  No sessions matching '`$term'.`""; Replace = "Write-Host `"  MATCHED NOTHING`"" } `
    -Assertions @'
    # 6>&1 is REQUIRED: the module speaks only through Write-Host, which
    # writes to the information stream (6), not the success pipeline. Without
    # this redirect the capture is empty and every assertion below would be
    # asserting against an empty string, which is a test that cannot fail.
    $out = (claudecm -s zzzznotarealproject 6>&1 | Out-String)
    Assert-Contains $out 'No sessions matching' 'a search with no hits must say so'
    Assert-NotContains $out 'Create a NEW project' 'search mode must never offer to create a project'
'@

# =============================================================================
# TIER 0 - structural. Asserts on the module SOURCE, not its behaviour.
#
# Honest about what this is: it cannot prove that a quarantined file lands in
# the right directory, only that the two directories have not been silently
# unified. That is worth guarding because the two used to share the name
# $backupDir, and "simplify this to one variable" is exactly the change that
# would move every orphan into the trim backup without any test noticing.
# The behavioural version needs a cmv stub and belongs in Tier 3.
# =============================================================================

$script:StructuralTests = New-Object System.Collections.Generic.List[object]

function Structural-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Sabotage,
        [Parameter(Mandatory)][hashtable]$Mutate,
        [Parameter(Mandatory)][scriptblock]$Body   # receives the module text
    )
    $script:StructuralTests.Add([pscustomobject]@{ Name=$Name; Sabotage=$Sabotage; Mutate=$Mutate; Body=$Body })
}

function Get-FunctionBody {
    param([string]$Text, [string]$Name)
    $errs=$null; $toks=$null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$toks, [ref]$errs)
    $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
          Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $fn) { throw "function not found in source: $Name" }
    # Strip comments. Without this the test binds prose: the bash twin of this
    # test failed against correct code because an explanatory comment named the
    # other variable. A test a comment can turn red is not testing behaviour.
    ($fn.Extent.Text -split "`n" | ForEach-Object { $_ -replace '#.*$','' }) -join "`n"
}

# --------------------------------------------------------------- seam fidelity
#
# The whole PowerShell suite rests on one unproven claim: that a function
# lifted out of `claudecm` and re-defined in a synthetic scope behaves the way
# it does in place. One infidelity has already been found and fixed (the
# harness imposed StrictMode, which the product never sets). This checks the
# other realistic failure mode.
#
# A lifted function reads variables it never declares: $cmDir, $sessionsFile,
# $claudeExe and so on come from the enclosing `claudecm` scope. The harness
# prelude re-creates them by hand. If the product ever reads one the prelude
# does NOT supply, the lifted function silently sees $null where production
# sees a real value, every assertion still runs, and the suite goes green while
# testing something that cannot happen. That is a hollow SUITE rather than a
# hollow test, and no individual sabotage would catch it.

function Get-FreeVariables {
    param([string]$FunctionName)
    $src = $script:FunctionSource[$FunctionName]
    $errs = $null; $toks = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$toks, [ref]$errs)

    $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            [void]$assigned.Add($a.Left.VariablePath.UserPath)
        }
    }
    # parameters, both param() blocks and the function($a,$b) shorthand
    foreach ($p in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        [void]$assigned.Add($p.Name.VariablePath.UserPath)
    }
    # foreach induction variables
    foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        [void]$assigned.Add($f.Variable.VariablePath.UserPath)
    }

    $free = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $name = $v.VariablePath.UserPath
        if ($v.VariablePath.IsGlobal -or $v.VariablePath.IsScript) { continue }  # $script: is state, not closure
        # $env:X is PROCESS state, inherited rather than closed over, so the
        # prelude is not the thing that should supply it. What matters instead
        # is that the sandbox redirects the one that decides where state lives;
        # a separate test asserts $env:USERPROFILE points at the sandbox.
        if ($name -like 'env:*') { continue }
        if ($assigned.Contains($name)) { continue }
        [void]$free.Add($name)
    }
    $free
}

# What the prelude actually defines, plus PowerShell's own automatics.
$script:PreludeSupplies = @(
    'sandbox','cmDir','sessionsFile','backupDir','lockFile','tmpFile',
    'claudeExe','machineNameFile','quarantineRoot','cmvExe'
)
$script:PSAutomatics = @(
    '_','args','PSItem','true','false','null','LASTEXITCODE','?','PSScriptRoot',
    'PSCommandPath','Host','Error','MyInvocation','PWD','HOME','input','PID',
    'ErrorActionPreference','ProgressPreference','matches','Matches','foreach','switch'
)

Structural-Case -Name 'the harness supplies every enclosing-scope variable the lifted functions read' `
    -Sabotage 'have the product read an enclosing variable the harness prelude does not define, which is the shape that makes the whole suite hollow' `
    -Mutate @{ Find = '$lines = Get-Content $sessionsFile'; Replace = '$lines = Get-Content $sessionsFileTypoNobodyDefines' } `
    -Body {
        param($text)
        # Re-lift from the (possibly mutated) text rather than the cached map,
        # so the sabotage is actually visible to this check.
        $errs = $null; $toks = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$toks, [ref]$errs)
        $all = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $saved = $script:FunctionSource
        $script:FunctionSource = @{}
        foreach ($fn in $all) { if ($fn.Name -ne 'claudecm') { $script:FunctionSource[$fn.Name] = $fn.Extent.Text } }

        try {
            # every function any test actually lifts
            $lifted = $script:Tests | ForEach-Object { $_.Uses } | Sort-Object -Unique
            $known = @($script:PreludeSupplies) + @($script:PSAutomatics) +
                     @($script:FunctionSource.Keys)   # sibling functions are defined alongside
            $unsupplied = @()
            foreach ($name in $lifted) {
                if (-not $script:FunctionSource.ContainsKey($name)) { continue }
                foreach ($v in (Get-FreeVariables $name)) {
                    if ($known -notcontains $v) { $unsupplied += "$name reads `$$v" }
                }
            }
            Assert-True ($unsupplied.Count -eq 0) `
                ("the harness does not supply: " + ($unsupplied -join '; ') +
                 ". A lifted function reading an undefined enclosing variable sees `$null where production sees a value, and the suite goes green testing something that cannot happen.")
        } finally { $script:FunctionSource = $saved }
    }

Structural-Case -Name 'the module never spawns powershell.exe' `
    -Sabotage 'point the late-registration Start-Process back at powershell.exe' `
    -Mutate @{ Find = "Start-Process -FilePath 'pwsh'"; Replace = "Start-Process -FilePath 'powershell.exe'" } `
    -Body {
        param($text)
        # Spawning powershell.exe flips the console to a raster font and resizes
        # the window (microsoft/terminal#367, unfixed). Measured 2026-08-26:
        # powershell.exe 2 flips out of 2, pwsh 0 out of 3. Comments are stripped
        # before matching, so the explanation beside the call site cannot satisfy
        # or trip this test.
        $code = ($text -split "`n" | ForEach-Object { $_ -replace '#.*$','' }) -join "`n"
        Assert-True ($code -notmatch 'powershell\.exe') `
            'this module must spawn pwsh, never powershell.exe: powershell.exe corrupts the console font'
    }

Structural-Case -Name 'orphan quarantine and trim backup remain two distinct directories' `
    -Sabotage 'point Do-OrphanScan back at $backupDir, unifying the two destinations' `
    -Mutate @{ Find = '$quarantineRoot'; Replace = '$backupDir' } `
    -Body {
        param($text)
        $orphan = Get-FunctionBody $text 'Do-OrphanScan'
        $trim   = Get-FunctionBody $text 'Do-Trim'
        Assert-True ($orphan -match [regex]::Escape('$quarantineRoot')) `
            'Do-OrphanScan must quarantine to $quarantineRoot (spec section 3 storage layout)'
        Assert-True ($orphan -notmatch [regex]::Escape('$backupDir')) `
            'Do-OrphanScan must NOT use $backupDir: that is the trim/settings destination'
        Assert-True ($trim -match [regex]::Escape('$backupDir')) `
            'Do-Trim must move the pre-trim file to $backupDir (spec 11.13 step 11)'
        Assert-True ($trim -notmatch [regex]::Escape('$quarantineRoot')) `
            'Do-Trim must NOT use the orphan quarantine root'
    }

# ================================================================== the runner

$sandboxes = @()
function Invoke-Suite {
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in $script:Tests) {
        if ($Only -and $t.Name -notlike "*$Only*") { continue }

        # --- clean run: must pass
        $sb = New-Sandbox; $script:sandboxes += $sb
        $cleanErr = $null
        try { Invoke-InProductScope -Functions $t.Uses -Sandbox $sb -Body $t.Body | Out-Null }
        catch { $cleanErr = $_.Exception.Message }

        # --- sabotaged run: must FAIL, or the test is hollow
        $sabotageResult = 'skipped'
        if (-not $SkipSabotage) {
            $sb2 = New-Sandbox; $script:sandboxes += $sb2
            $sabErr = $null
            try { Invoke-InProductScope -Functions $t.Uses -Sandbox $sb2 -Mutations $t.Mutate -Body $t.Body | Out-Null }
            catch { $sabErr = $_.Exception.Message }
            if ($sabErr -and $sabErr -like '*SABOTAGE ANCHOR MISSING*') { $sabotageResult = 'ANCHOR-LOST' }
            elseif ($sabErr -and $sabErr -like "*$script:AssertSentinel*") { $sabotageResult = 'went-red' }
            elseif ($sabErr) { $sabotageResult = 'BLEW-UP' }   # an error is not a red assertion
            else { $sabotageResult = 'STILL-GREEN' }
        }

        $verdict =
            if ($cleanErr -and $cleanErr -notlike "*$script:AssertSentinel*") { 'ERROR' }
            elseif ($cleanErr) { 'FAIL' }
            elseif ($sabotageResult -eq 'STILL-GREEN') { 'HOLLOW' }
            elseif ($sabotageResult -eq 'ANCHOR-LOST') { 'STALE-SABOTAGE' }
            elseif ($sabotageResult -eq 'BLEW-UP') { 'INCONCLUSIVE' }
            else { 'PASS' }

        $results.Add([pscustomobject]@{
            Name = $t.Name; Verdict = $verdict; Error = $cleanErr; Sabotage = $sabotageResult
        })
    }
    $results
}

Write-Host ''
Write-Host '  ClaudeCM PowerShell suite'
Write-Host ("  module: {0}" -f $Module)
Write-Host ("  {0} nested function(s) lifted from the module by AST" -f $script:FunctionSource.Count)
Write-Host ''

$res = New-Object System.Collections.Generic.List[object]
foreach ($r in (Invoke-Suite)) { $res.Add($r) }

function Write-Verdict {
    param([string]$Verdict, [string]$Name, [string]$ErrText)
    $tag = switch ($Verdict) {
        'PASS'           { '  PASS  ' }
        'FAIL'           { '  FAIL  ' }
        'ERROR'          { ' ERROR  ' }
        'HOLLOW'         { ' HOLLOW ' }
        'STALE-SABOTAGE' { ' STALE  ' }
        'INCONCLUSIVE'   { ' INCONC ' }
        default          { '  ????  ' }
    }
    Write-Host ("{0} {1}" -f $tag, $Name)
    if ($ErrText) {
        $clean = ($ErrText -replace [regex]::Escape($script:AssertSentinel), '').Trim()
        Write-Host ("           {0}" -f ($clean -replace "`n", "`n           "))
    }
    switch ($Verdict) {
        'HOLLOW'         { Write-Host '           passed WITH its sabotage applied. It cannot fail. Fix the test.' }
        'STALE-SABOTAGE' { Write-Host '           the sabotage anchor no longer exists in the product. Update the mutation.' }
        'INCONCLUSIVE'   { Write-Host '           the sabotage did not produce a red ASSERTION, it produced an error.' 
                           Write-Host '           An error is not a failing test. Move the sabotage onto the path the' 
                           Write-Host '           assertion actually walks, and keep the module parseable.' }
        'ERROR'          { Write-Host '           the CLEAN run threw a non-assertion error. Harness or product fault.' }
    }
}

foreach ($r in $res) { Write-Verdict $r.Verdict $r.Name $r.Error }

foreach ($ic in $script:IntegrationTests) {
    if ($Only -and $ic.Name -notlike "*$Only*") { continue }
    $clean = Invoke-Integration -Case $ic -Sabotaged $false
    $sab   = if ($SkipSabotage) { 1 } else { Invoke-Integration -Case $ic -Sabotaged $true }
    $verdict =
        if ($clean -eq 91)   { 'ERROR' }          # clean run fell over, not an assertion
        elseif ($clean -ne 0){ 'FAIL' }
        elseif ($sab -eq 3)  { 'STALE-SABOTAGE' }
        elseif ($sab -eq 0)  { 'HOLLOW' }
        elseif ($sab -eq 90) { 'PASS' }           # a real assertion went red
        else                 { 'INCONCLUSIVE' }   # 91 or anything else: an error, not a red assertion
    Write-Verdict $verdict $ic.Name $null
    $res.Add([pscustomobject]@{ Name = $ic.Name; Verdict = $verdict; Error = $null; Sabotage = $sab })
}

foreach ($sc in $script:StructuralTests) {
    if ($Only -and $sc.Name -notlike "*$Only*") { continue }
    $srcText = Get-Content $Module -Raw
    $cleanErr = $null
    try { & $sc.Body $srcText } catch { $cleanErr = $_.Exception.Message }

    $sabState = 'skipped'
    if (-not $SkipSabotage) {
        if ($srcText -notmatch [regex]::Escape($sc.Mutate.Find)) { $sabState = 'ANCHOR-LOST' }
        else {
            $mutated = $srcText.Replace($sc.Mutate.Find, $sc.Mutate.Replace)   # literal; see New-ProductScope
            try { & $sc.Body $mutated; $sabState = 'STILL-GREEN' }
            catch {
                $sabState = if ($_.Exception.Message -like "*$script:AssertSentinel*") { 'went-red' } else { 'BLEW-UP' }
            }
        }
    }
    $verdict =
        if ($cleanErr -and $cleanErr -notlike "*$script:AssertSentinel*") { 'ERROR' }
        elseif ($cleanErr) { 'FAIL' }
        elseif ($sabState -eq 'STILL-GREEN') { 'HOLLOW' }
        elseif ($sabState -eq 'ANCHOR-LOST') { 'STALE-SABOTAGE' }
        elseif ($sabState -eq 'BLEW-UP') { 'INCONCLUSIVE' }
        else { 'PASS' }
    Write-Verdict $verdict $sc.Name $cleanErr
    $res.Add([pscustomobject]@{ Name=$sc.Name; Verdict=$verdict; Error=$cleanErr; Sabotage=$sabState })
}

$pass   = @($res | Where-Object Verdict -eq 'PASS').Count
$fail   = @($res | Where-Object Verdict -eq 'FAIL').Count
$err    = @($res | Where-Object Verdict -eq 'ERROR').Count
$hollow = @($res | Where-Object Verdict -eq 'HOLLOW').Count
$stale  = @($res | Where-Object Verdict -eq 'STALE-SABOTAGE').Count
$inconc = @($res | Where-Object Verdict -eq 'INCONCLUSIVE').Count

Write-Host ''
Write-Host ("  {0} test(s): {1} pass, {2} fail, {3} error, {4} hollow, {5} stale-sabotage, {6} inconclusive" -f `
    $res.Count, $pass, $fail, $err, $hollow, $stale, $inconc)
Write-Host ''

foreach ($s in $script:sandboxes) {
    if ($s -and (Test-Path $s.Root)) { Remove-Item $s.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($fail -or $err -or $hollow -or $stale -or $inconc) { exit 1 } else { exit 0 }
