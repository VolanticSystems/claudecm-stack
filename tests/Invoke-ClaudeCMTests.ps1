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
$script:CmvStub = Join-Path $PSScriptRoot 'stubs\cmv-stub.ps1'
if (-not (Test-Path $script:CmvStub)) { throw "missing stub: $script:CmvStub" }

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
    # Bootstrap writes this file when it is missing and then reads $machineName
    # back out of it, so a lifted function can rely on both existing. Mirror
    # that order rather than just assigning the string: the product calls
    # .Trim() on the result, which throws on $null, and a prelude that skipped
    # the file would hide that.
    [void]$sb.AppendLine('if (-not (Test-Path $machineNameFile)) { Set-Content $machineNameFile "testbox" -Encoding UTF8 }')
    [void]$sb.AppendLine('$machineName = (Get-Content $machineNameFile -ErrorAction SilentlyContinue).Trim()')
    [void]$sb.AppendLine('$quarantineRoot  = Join-Path $sandbox.Root "quarantine"')
    # Deliberately a path that does not exist. Do-PostExit guards every cmv
    # call with Test-Path $cmvExe, so a missing binary means the snapshot and
    # the benchmark are skipped and the registration logic is reachable on its
    # own. That is the part worth testing; cmv is somebody else's program.
    [void]$sb.AppendLine('$cmvExe       = Join-Path $sandbox.Root "no-such-cmv.cmd"')
    # A test that NEEDS cmv present opts in with `$cmvExe = $cmvStub` as its
    # first line. Default absent, because most callers guard on Test-Path and
    # the interesting logic is what happens around cmv rather than inside it.
    [void]$sb.AppendLine("`$cmvStub      = '$script:CmvStub'")
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

Test-Case -Name 'Format-DateShort adds the year only for a previous year (spec 7)' `
    -Uses @('Format-DateShort') `
    -Sabotage 'compare against the wrong side of the year boundary so this year gets a year stamp and last year does not' `
    -Mutate @{ 'Format-DateShort' = @{ Find = '-lt (Get-Date).Year'; Replace = '-gt (Get-Date).Year' } } `
    -Body {
        $thisYear = Get-Date -Month 3 -Day 13 -Year ((Get-Date).Year)
        $lastYear = Get-Date -Month 3 -Day 13 -Year ((Get-Date).Year - 1)
        Assert-Equal 'Mar 13' (Format-DateShort $thisYear) 'spec 7: the current year is implied and omitted'
        Assert-Equal ("Mar 13, " + ((Get-Date).Year - 1)) (Format-DateShort $lastYear) `
            'spec 7: an older session must show its year, or two rows a year apart look identical'
    }

Test-Case -Name 'Get-ArchivedSessions reads only below the [archived] marker (spec 5)' `
    -Uses @('Parse-SessionLine','Get-ArchivedSessions') `
    -Sabotage 'start collecting before the marker instead of after, so live sessions are reported as archived' `
    -Mutate @{ 'Get-ArchivedSessions' = @{ Find = '$inArchived = $false'; Replace = '$inArchived = $true' } } `
    -Body {
        Set-Content $sessionsFile @(
            'aaa|C:\p|Live One|1', 'bbb|C:\p|Live Two|2', '[archived]', 'ccc|C:\p|Old One|3'
        ) -Encoding UTF8
        $arch = Get-ArchivedSessions
        Assert-Equal 1 $arch.Count 'only rows below the marker are archived'
        Assert-Equal 'Old One' $arch[0].Desc 'the archived row must be the one below the marker'
    }

Test-Case -Name 'Move-SessionToTop promotes without losing or duplicating rows (spec 5)' `
    -Uses @('Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock',
            'Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Move-SessionToTop') `
    -Sabotage 'append the promoted session instead of prepending it, so the list is no longer most-recently-used' `
    -Mutate @{ 'Move-SessionToTop' = @{
        Find = '$new = @($match) + @($rest)'; Replace = '$new = @($rest) + @($match)' } } `
    -Body {
        Set-Content $sessionsFile @(
            'aaa|C:\p|First|1', 'bbb|C:\p|Second|2', 'ccc|C:\p|Third|3'
        ) -Encoding UTF8
        Move-SessionToTop 'ccc'
        $rows = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-Equal 3 $rows.Count 'promotion must not add or drop a row'
        Assert-True ($rows[0].StartsWith('ccc')) 'the promoted session must be row 1'
        Assert-True ($rows[1].StartsWith('aaa')) 'the others must keep their relative order'
    }

# DELETED: 'Move-SessionToTop on an unknown GUID leaves the file alone'.
#
# It was written, ran green, and the hollow detector then refused it twice. The
# reason is worth keeping even though the test is not.
#
# Move-SessionToTop is safe here by construction, TWICE over. The early
# `if (-not $match) { return }` exits before anything else runs, so any
# mutation further down is unreachable. And removing that guard changes
# nothing either: with no match, @($match) is an EMPTY array, so
# @($match) + @($rest) equals $rest and the file is rewritten byte-identically.
#
# There is therefore no edit to the product that makes the assertion go red.
# Per the rule this suite is built on, that means it is not a test. Keeping it
# would have added a green line that could never catch anything, which is
# exactly the thing the project shipped thirteen of once already.

Test-Case -Name 'Get-SessionInfo marks a missing transcript and keeps its token count (spec 8)' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Get-SessionInfo') `
    -Sabotage 'report a missing transcript as ok, so a lost session looks healthy in the list' `
    -Mutate @{ 'Get-SessionInfo' = @{ Find = "Size = ""(missing)"""; Replace = "Size = ""0 B""" } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'infoproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        # nothing on disk for this GUID at all
        $r = Get-SessionInfo 'deadbeef-0000-0000-0000-000000000000' $projDir '155000'
        Assert-Equal '(missing)' $r.Size 'spec 8: a missing transcript must say so rather than showing a size'
        Assert-Equal 'missing' $r.Status 'status must report missing'
        Assert-Equal '155K tok' $r.Tokens `
            'spec 8: the historical token count stays meaningful even when the file is gone'
        Assert-Equal '--' $r.Date 'with no fallback available the date is --'
    }

Test-Case -Name 'Sync-SessionIndex drops entries whose transcript is gone (spec 10 step 6)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Sync-SessionIndex') `
    -Sabotage 'seed validEntries with every pre-existing entry before the on-disk filter runs, so stale rows survive' `
    -Mutate @{ 'Sync-SessionIndex' = @{
        Find    = '$indexedGuids = @{}'
        Replace = '$validEntries = @($existingEntries); $indexedGuids = @{}' } } `
    -Body {
        # THE ORACLE IS HAND-BUILT, deliberately. Regenerating the expected
        # index by calling the same function would bind nothing: it would agree
        # with itself no matter what it did. The expectation below is derived
        # from spec 10 and from what is on disk, by hand.
        $projDir = Join-Path $sandbox.Root 'idxproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $onDisk = 'a1a1a1a1-b2b2-c3c3-d4d4-e5e5e5e5e5e5'
        $gone   = 'f6f6f6f6-0000-1111-2222-333333333333'
        Set-Content (Join-Path $keyDir "$onDisk.jsonl") '{"type":"user"}' -Encoding UTF8
        # an index left over from before that transcript was deleted
        # The fixture carries EVERY field spec 10 step 9 writes. An index
        # missing one makes Sync-SessionIndex throw into its own swallowing
        # try/catch and do nothing at all, silently: the first version of this
        # test hit exactly that and looked like a product failure.
        $stale = @{ version = 1; originalPath = $projDir; entries = @(
            @{ sessionId = $gone;   fullPath = (Join-Path $keyDir "$gone.jsonl")
               fileMtime = 0; firstPrompt = 'Gone'; messageCount = 5
               created = '2026-01-01T00:00:00.000Z'; modified = '2026-01-01T00:00:00.000Z'
               gitBranch = ''; projectPath = $projDir; isSidechain = $false },
            @{ sessionId = $onDisk; fullPath = (Join-Path $keyDir "$onDisk.jsonl")
               fileMtime = 0; firstPrompt = 'Here'; messageCount = 5
               created = '2026-01-01T00:00:00.000Z'; modified = '2026-01-01T00:00:00.000Z'
               gitBranch = ''; projectPath = $projDir; isSidechain = $false }
        )}
        $stale | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $keyDir 'sessions-index.json') -Encoding UTF8

        Sync-SessionIndex $projDir

        $idx = Get-Content (Join-Path $keyDir 'sessions-index.json') -Raw | ConvertFrom-Json
        $ids = @($idx.entries | ForEach-Object { $_.sessionId })
        Assert-True ($ids -contains $onDisk) 'a transcript that exists must keep its entry'
        Assert-True ($ids -notcontains $gone) `
            'spec 10 step 6: an entry whose transcript is gone must be dropped, or the resume picker offers a session that cannot open'
        Assert-Equal 1 $ids.Count 'the index must contain exactly the transcripts on disk'
    }

Test-Case -Name 'Sync-SessionIndex names a registered session from sessions.txt (spec 10 step 7)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Sync-SessionIndex') `
    -Sabotage 'always write an empty firstPrompt, so the resume picker shows an unnamed session' `
    -Mutate @{ 'Sync-SessionIndex' = @{
        Find = '$firstPrompt = $sessMatch.Desc'; Replace = '$firstPrompt = ""' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'namedproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        $guid = 'b7b7b7b7-1111-2222-3333-444444444444'
        Set-Content (Join-Path $keyDir "$guid.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$guid|$projDir|My Named Session|42" -Encoding UTF8

        Sync-SessionIndex $projDir

        $idx = Get-Content (Join-Path $keyDir 'sessions-index.json') -Raw | ConvertFrom-Json
        $e = @($idx.entries | Where-Object { $_.sessionId -eq $guid })[0]
        Assert-True ($null -ne $e) 'the transcript on disk must get an entry'
        Assert-Equal 'My Named Session' $e.firstPrompt `
            'spec 10 step 7: a registered session carries its sessions.txt name into the index'
        Assert-Equal $projDir $e.projectPath 'a registered session carries its sessions.txt directory'
    }

Test-Case -Name 'Do-OrphanScan stays silent when every transcript is accounted for' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Sync-SessionIndex','Do-OrphanScan') `
    -Sabotage 'break the directory comparison so a correctly-registered transcript always looks like it belongs elsewhere' `
    -Mutate @{ 'Do-OrphanScan' = @{
        Find    = 'if ("$($sessMatch.Dir)".TrimEnd(''\'',''/'') -ne "$scanDir".TrimEnd(''\'',''/'')) { $hasProblems = $true; break }'
        Replace = 'if ($true) { $hasProblems = $true; break }' } } `
    -Body {
        # The picker interrupting a launch when nothing is wrong is not a
        # cosmetic annoyance: it trained the operator to dismiss it, which is
        # how a real orphan gets ignored. Two files, both registered, both
        # belonging here, must produce silence.
        function Read-Host { param([string]$Prompt) throw "$script:AssertSentinel Do-OrphanScan prompted when there was nothing to report" }
        $projDir = Join-Path $sandbox.Root 'tidy'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        $a = 'aaaaaaaa-1111-1111-1111-111111111111'
        $b = 'bbbbbbbb-2222-2222-2222-222222222222'
        Set-Content (Join-Path $keyDir "$a.jsonl") '{}' -Encoding UTF8
        Set-Content (Join-Path $keyDir "$b.jsonl") '{}' -Encoding UTF8
        Set-Content $sessionsFile @("$a|$projDir|One|1", "$b|$projDir|Two|2") -Encoding UTF8

        $r = Do-OrphanScan $projDir $a
        Assert-True ($null -eq $r) 'a project whose transcripts are all registered here must not raise the picker'
    }

Test-Case -Name 'Do-OrphanScan quarantines to the quarantine root, not the trim backup (spec 3.1)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Sync-SessionIndex','Do-OrphanScan') `
    -Sabotage 'send the quarantined transcript to $backupDir, the trim/settings directory, instead of the quarantine root' `
    -Mutate @{ 'Do-OrphanScan' = @{
        Find = '$destSubdir = Join-Path $quarantineRoot (Split-Path $scanDir -Leaf)'; Replace = '$destSubdir = Join-Path $backupDir (Split-Path $scanDir -Leaf)' } } `
    -Body {
        function Read-Host { param([string]$Prompt) 'q 2' }
        $projDir = Join-Path $sandbox.Root 'messy'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        $live   = 'cccccccc-3333-3333-3333-333333333333'
        $orphan = 'dddddddd-4444-4444-4444-444444444444'
        Set-Content (Join-Path $keyDir "$live.jsonl")   '{}' -Encoding UTF8
        Set-Content (Join-Path $keyDir "$orphan.jsonl") '{}' -Encoding UTF8
        # listing is newest-first, so make the orphan older and it is row 2
        (Get-Item (Join-Path $keyDir "$orphan.jsonl")).LastWriteTime = (Get-Date).AddHours(-2)
        Set-Content $sessionsFile "$live|$projDir|Live One|1" -Encoding UTF8

        $null = Do-OrphanScan $projDir $live

        $landed = Join-Path (Join-Path $quarantineRoot (Split-Path $projDir -Leaf)) "$orphan.jsonl"
        Assert-True (Test-Path $landed) "spec 3.1: an orphan belongs in the quarantine root, expected at $landed"
        Assert-True (-not (Test-Path (Join-Path $keyDir "$orphan.jsonl"))) 'the orphan must leave the project key directory'
        Assert-True (Test-Path (Join-Path $keyDir "$live.jsonl")) 'the live session must be untouched'
    }

Test-Case -Name 'Do-OrphanScan refuses to quarantine the registered session' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Sync-SessionIndex','Do-OrphanScan') `
    -Sabotage 'remove the guard that refuses to quarantine the registered session' `
    -Mutate @{ 'Do-OrphanScan' = @{
        Find = 'if ($guid -eq $registeredGuid) {'; Replace = 'if ($false) {' } } `
    -Body {
        # The one keystroke that must never work. Quarantining the registered
        # session moves the conversation the operator is about to resume.
        function Read-Host { param([string]$Prompt) 'q 1' }
        $projDir = Join-Path $sandbox.Root 'protect'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        $live   = 'eeeeeeee-5555-5555-5555-555555555555'
        $orphan = 'ffffffff-6666-6666-6666-666666666666'
        Set-Content (Join-Path $keyDir "$live.jsonl")   '{}' -Encoding UTF8
        Set-Content (Join-Path $keyDir "$orphan.jsonl") '{}' -Encoding UTF8
        # make the LIVE one newest so 'q 1' targets exactly the protected file
        (Get-Item (Join-Path $keyDir "$orphan.jsonl")).LastWriteTime = (Get-Date).AddHours(-2)
        Set-Content $sessionsFile "$live|$projDir|Do Not Move Me|1" -Encoding UTF8

        $null = Do-OrphanScan $projDir $live

        Assert-True (Test-Path (Join-Path $keyDir "$live.jsonl")) `
            'the registered session must still be in place: quarantining it moves the conversation the operator is about to resume'
    }

Test-Case -Name 'a forked resume follows the fork and files the predecessor (spec 11.6.1)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions',
            'Sync-SessionIndex','Test-CleanExitTail','Invoke-ResumeWithForkDetection') `
    -Sabotage 'delete the Move-Item that files the fork predecessor, leaving it on disk to trip the orphan picker on the next launch' `
    -Mutate @{ 'Invoke-ResumeWithForkDetection' = @{
        Find    = 'Move-Item $predFile (Join-Path $destSubdir "$originalGuid.jsonl") -Force'
        Replace = '$null = $predFile' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'forkproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $orig = '55555555-5555-5555-5555-555555555555'
        $fork = '66666666-6666-6666-6666-666666666666'
        Set-Content (Join-Path $keyDir "$orig.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$orig|$projDir|Forked Session|900" -Encoding UTF8

        # Claude Code forks a resumed session to a new GUID; the stub reproduces
        # that by writing a different transcript than the one we asked to resume.
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        $env:CLAUDECM_STUB_GUID    = $fork
        try { Invoke-ResumeWithForkDetection $orig $projDir 'machine - Forked Session' }
        finally { Remove-Item Env:CLAUDECM_STUB_PROJDIR, Env:CLAUDECM_STUB_GUID -ErrorAction SilentlyContinue }

        $rows = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-True ($rows[0].StartsWith($fork)) 'sessions.txt must follow the fork, or the live conversation is unreachable'
        Assert-True ($rows[0] -match 'Forked Session') 'the session name must survive a fork'
        Assert-Equal $fork $script:lastResumeGuid 'the caller must be told which GUID is now live'
        Assert-True (-not (Test-Path (Join-Path $keyDir "$orig.jsonl"))) `
            'spec 11.6.1 step 4: the predecessor must be filed away, or it becomes a spurious orphan next launch'
    }

Test-Case -Name 'a resume that did NOT fork changes nothing (spec 11.6.1)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions',
            'Sync-SessionIndex','Test-CleanExitTail','Invoke-ResumeWithForkDetection') `
    -Sabotage 'treat the newest transcript as a fork unconditionally, so an ordinary resume files away the very session the user is using' `
    -Mutate @{ 'Invoke-ResumeWithForkDetection' = @{
        Find    = 'if ($newest -and $newest.BaseName -ne $originalGuid -and (-not $beforeNewest -or $newest.BaseName -ne $beforeNewest.BaseName)) {'
        Replace = 'if ($newest) {' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'plainproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $orig = '77777777-7777-7777-7777-777777777777'
        Set-Content (Join-Path $keyDir "$orig.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$orig|$projDir|Plain Resume|900" -Encoding UTF8

        # No new transcript: the ordinary case, which is almost every resume.
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        $env:CLAUDECM_STUB_GUID    = 'none'
        try { Invoke-ResumeWithForkDetection $orig $projDir 'machine - Plain Resume' }
        finally { Remove-Item Env:CLAUDECM_STUB_PROJDIR, Env:CLAUDECM_STUB_GUID -ErrorAction SilentlyContinue }

        Assert-True (Test-Path (Join-Path $keyDir "$orig.jsonl")) `
            'an ordinary resume must NOT file away the transcript the user is still using'
        $rows = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-True ($rows[0].StartsWith($orig)) 'an ordinary resume must leave the registered GUID alone'
        Assert-Equal '900' ($rows[0] -split '\|')[3] 'an ordinary resume must not reset the token count'
    }

Test-Case -Name 'Do-Trim quarantines the pre-trim transcript (spec 11.13 step 11)' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions',
            'Sync-SessionIndex','Do-Trim') `
    -Sabotage 'delete the Move-Item that files the pre-trim transcript into the backup, which is the omission that caused the April 2026 orphan accumulation' `
    -Mutate @{ 'Do-Trim' = @{
        Find    = 'Move-Item $preTrimFile (Join-Path $destSubdir "$currentGuid.jsonl") -Force -ErrorAction SilentlyContinue'
        Replace = '$null = $preTrimFile' } } `
    -Body {
        $cmvExe = $cmvStub
        $projDir = Join-Path $sandbox.Root 'myproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $oldGuid = '11111111-1111-1111-1111-111111111111'
        $newGuid = '22222222-2222-2222-2222-222222222222'
        Set-Content (Join-Path $keyDir "$oldGuid.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$oldGuid|$projDir|Trim Me|500" -Encoding UTF8

        $env:CLAUDECM_CMV_NEWGUID  = $newGuid
        $env:CLAUDECM_CMV_WRITEDIR = $keyDir
        try { Do-Trim $oldGuid }
        finally { Remove-Item Env:CLAUDECM_CMV_NEWGUID, Env:CLAUDECM_CMV_WRITEDIR -ErrorAction SilentlyContinue }

        # CMV trim creates a NEW session and leaves the original on disk
        # unreferenced. If it is not filed away it becomes an orphan and the
        # next launch greets you with the picker.
        Assert-True (-not (Test-Path (Join-Path $keyDir "$oldGuid.jsonl"))) `
            'the pre-trim transcript must not be left in the project key directory'
        $filed = Join-Path (Join-Path $backupDir (Split-Path $projDir -Leaf)) "$oldGuid.jsonl"
        Assert-True (Test-Path $filed) `
            "spec 11.13 step 11: the pre-trim transcript must be moved to the backup, expected at $filed"
    }

Test-Case -Name 'Do-Trim swaps the GUID in sessions.txt and keeps the row' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions',
            'Sync-SessionIndex','Do-Trim') `
    -Sabotage 'stop assigning the new GUID onto the matching row, so sessions.txt keeps pointing at a transcript that has been filed away' `
    -Mutate @{ 'Do-Trim' = @{
        Find = 'if ($s.Guid -eq $currentGuid) { $s.Guid = $newGuid }'; Replace = 'if ($false) { $s.Guid = $newGuid }' } } `
    -Body {
        $cmvExe = $cmvStub
        $projDir = Join-Path $sandbox.Root 'myproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $oldGuid = '33333333-3333-3333-3333-333333333333'
        $newGuid = '44444444-4444-4444-4444-444444444444'
        Set-Content (Join-Path $keyDir "$oldGuid.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$oldGuid|$projDir|Keep My Name|500" -Encoding UTF8

        $env:CLAUDECM_CMV_NEWGUID  = $newGuid
        $env:CLAUDECM_CMV_WRITEDIR = $keyDir
        try { Do-Trim $oldGuid }
        finally { Remove-Item Env:CLAUDECM_CMV_NEWGUID, Env:CLAUDECM_CMV_WRITEDIR -ErrorAction SilentlyContinue }

        $rows = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-Equal 1 $rows.Count 'trim must not add or drop a row'
        Assert-True ($rows[0].StartsWith($newGuid)) `
            'the row must now point at the trimmed transcript, or the session is unreachable'
        Assert-True ($rows[0] -match 'Keep My Name') 'the session name must survive a trim'
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

Test-Case -Name 'Get-SessionDisplayName prefixes the machine name' `
    -Uses @('Get-SessionDisplayName') `
    -Sabotage 'return the bare description, dropping the machine name that tells two boxes apart' `
    -Mutate @{ 'Get-SessionDisplayName' = @{
        Find = 'return "$machineName - $desc"'; Replace = 'return "$desc"' } } `
    -Body {
        # $machineName deliberately NOT set here. It comes from the prelude,
        # which mirrors bootstrap by writing machine-name.txt and reading it
        # back. Setting it locally would have made this test pass while the
        # harness supplied nothing, which is exactly what it did on the first
        # run until the seam-fidelity check refused it.
        Assert-Equal 'testbox - My Project' (Get-SessionDisplayName 'My Project') `
            'the display name is what distinguishes the same project on two machines'
    }

# -----------------------------------------------------------------------------
# Ensure-CleanupPeriodDays. Three outcomes, three tests, because the whole point
# of the 2026-08-27 fix is that they must be TOLD APART.
#
# The old version printed "Protected session transcripts..." unconditionally
# inside the needs-fixing branch. I watched the bash twin print that line and
# leave settings.json byte-for-byte unchanged. The user is then told their
# transcripts are safe and Claude Code deletes them a month later, which is a
# failure with no symptom until the data is gone.
# -----------------------------------------------------------------------------

Test-Case -Name 'Ensure-CleanupPeriodDays raises retention and backs up first' `
    -Uses @('Ensure-CleanupPeriodDays') `
    -Sabotage 'write 0 instead of 100000, the trap the code comments warn about: 0 disables persistence rather than extending it' `
    -Mutate @{ 'Ensure-CleanupPeriodDays' = @{
        Find    = "`$settings | Add-Member -NotePropertyName 'cleanupPeriodDays' -NotePropertyValue 100000 -Force"
        Replace = "`$settings | Add-Member -NotePropertyName 'cleanupPeriodDays' -NotePropertyValue 0 -Force" } } `
    -Body {
        $settingsPath = Join-Path $sandbox.Root '.claude\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $settingsPath) -Force | Out-Null
        # 30 is Claude Code's own default, and it is what silently deletes
        # transcripts a month old. Start from the real hostile value.
        Set-Content $settingsPath '{"cleanupPeriodDays":30,"theme":"dark"}' -Encoding UTF8

        $out = (Ensure-CleanupPeriodDays 6>&1 | Out-String)

        $after = Get-Content $settingsPath -Raw | ConvertFrom-Json
        Assert-True ($after.cleanupPeriodDays -ge 1000) `
            "retention must be raised well past 30 days or Claude Code deletes transcripts ClaudeCM still lists; found $($after.cleanupPeriodDays)"
        Assert-True ($after.cleanupPeriodDays -ne 0) `
            '0 disables persistence rather than enabling it; it is the one value that must never be written here'
        Assert-Equal 'dark' $after.theme `
            'rewriting settings.json must preserve every other key, or ClaudeCM eats the user config'
        $backups = @(Get-ChildItem (Join-Path $sandbox.Root '.claudecm\backup') -Filter 'settings.json.*' -ErrorAction SilentlyContinue)
        Assert-True ($backups.Count -ge 1) 'settings.json must be backed up before it is rewritten'
        Assert-True ($out -match 'Protected session transcripts') `
            'and having actually raised it, it should say so'
    }

Test-Case -Name 'Ensure-CleanupPeriodDays does NOT claim protection it failed to apply' `
    -Uses @('Ensure-CleanupPeriodDays') `
    -Sabotage 'announce unconditionally instead of checking what actually landed on disk, which is the bug this test was written for' `
    -Mutate @{ 'Ensure-CleanupPeriodDays' = @{
        Find = 'if ($after -and $after -ge 1000) {'; Replace = 'if ($true) {' } } `
    -Body {
        $settingsPath = Join-Path $sandbox.Root '.claude\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $settingsPath) -Force | Out-Null
        Set-Content $settingsPath '{"cleanupPeriodDays":30}' -Encoding UTF8
        # Read-only is a real condition, not a contrivance: a settings.json
        # synced by a tool, checked out of a repo, or owned by another account
        # behaves exactly like this. The write fails and the function has to
        # notice.
        Set-ItemProperty $settingsPath -Name IsReadOnly -Value $true
        try   { $out = (Ensure-CleanupPeriodDays 6>&1 | Out-String) }
        finally { Set-ItemProperty $settingsPath -Name IsReadOnly -Value $false }

        $after = Get-Content $settingsPath -Raw | ConvertFrom-Json
        Assert-Equal 30 $after.cleanupPeriodDays 'precondition: the write must genuinely have failed for this test to mean anything'
        Assert-True ($out -notmatch 'Protected session transcripts') `
            'it must not report success for a write that did not land; the user would believe their transcripts were safe and lose them a month later'
        Assert-True ($out -match 'could not raise cleanupPeriodDays') `
            'and a failure the user cannot see is not much better than a false success'
    }

Test-Case -Name 'Ensure-CleanupPeriodDays leaves an unreadable settings.json alone' `
    -Uses @('Ensure-CleanupPeriodDays') `
    -Sabotage 'reinstate the old behaviour: treat a failed read as an absent key, so a file that could not be parsed is backed up and rewritten anyway' `
    -Mutate @{ 'Ensure-CleanupPeriodDays' = @{
        Find = '} catch { return }'; Replace = '} catch { $settings = [pscustomobject]@{} }' } } `
    -Body {
        $settingsPath = Join-Path $sandbox.Root '.claude\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $settingsPath) -Force | Out-Null
        # Not JSON. Previously a failed read produced an empty $current, which
        # is indistinguishable from "the key is absent", so the function
        # proceeded to rewrite a file it had never successfully parsed.
        Set-Content $settingsPath '{not valid json at all' -Encoding UTF8
        # The sabotage above hands back an EMPTY object rather than simply
        # dropping the return, because there is a second guard on $settings
        # being null and either edit alone is a no-op the detector correctly
        # called hollow. An empty object is also the more faithful model of the
        # old code, where a failed read produced an empty $current that was
        # then read as "the key is absent, fix it".

        $out = (Ensure-CleanupPeriodDays 6>&1 | Out-String)

        Assert-True ((Get-Content $settingsPath -Raw) -match 'not valid json at all') `
            'a file that could not be parsed must be left exactly as it was'
        $backups = @(Get-ChildItem (Join-Path $sandbox.Root '.claudecm\backup') -Filter 'settings.json.*' -ErrorAction SilentlyContinue)
        Assert-Equal 0 $backups.Count `
            'and nothing should have been backed up, because nothing was going to be rewritten'
        Assert-True ($out -notmatch 'Protected session transcripts') `
            'above all it must not claim protection for a file it could not read'
    }

Test-Case -Name 'Save-ArchivedSessions writes the [archived] marker' `
    -Uses @('Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock',
            'Release-SessionsLock','Write-SessionsAtomic','Save-ArchivedSessions') `
    -Sabotage 'omit the [archived] marker line, so archived rows are written straight into the live list' `
    -Mutate @{ 'Save-ArchivedSessions' = @{
        Find = "`$lines += '[archived]'"; Replace = "`$null = 'x'" } } `
    -Body {
        $live = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $arch = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        Set-Content $sessionsFile "$live|$($sandbox.Root)|Still Working|10" -Encoding UTF8

        Save-ArchivedSessions @([pscustomobject]@{
            Guid = $arch; Dir = $sandbox.Root; Desc = 'Done With This'; Tokens = 20 })

        # The marker is the ONLY thing separating the two lists. Without it the
        # archived rows parse as ordinary sessions and reappear in the menu,
        # which is the whole point of archiving them undone.
        Assert-Equal 1 (Get-Sessions).Count `
            'an archived session must not come back as a live one'
        Assert-Equal 1 (Get-ArchivedSessions).Count `
            'the archived session must be readable back out of the archive'
        Assert-True ((Get-Content $sessionsFile -Raw) -match '\[archived\]') `
            'the marker line must be present in the file itself'
    }

Test-Case -Name 'Do-DeleteSession removes the transcript AND its sidecar directory' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions',
            'Sync-SessionIndex','Do-DeleteSession') `
    -Sabotage 'skip the recursive removal of the per-GUID sidecar directory, leaving its contents behind after a delete the user was told was complete' `
    -Mutate @{ 'Do-DeleteSession' = @{
        Find = 'if (Test-Path $guidDir) { Remove-Item $guidDir -Recurse -Force }'; Replace = '$null = $guidDir' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'delproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $guid = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        Set-Content (Join-Path $keyDir "$guid.jsonl") '{"type":"user"}' -Encoding UTF8
        # Claude Code keeps per-session sidecar state next to the transcript.
        # A delete that takes the transcript and leaves this behind is the kind
        # of half-delete that looks fine until the directory is full of them.
        $guidDir = Join-Path $keyDir $guid
        New-Item -ItemType Directory -Path $guidDir -Force | Out-Null
        Set-Content (Join-Path $guidDir 'shell-snapshot.txt') 'residue' -Encoding UTF8

        # A second, unrelated session must survive untouched.
        $keep = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        Set-Content (Join-Path $keyDir "$keep.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$keep|$projDir|Keep Me|5" -Encoding UTF8

        Do-DeleteSession $guid $projDir

        Assert-True (-not (Test-Path (Join-Path $keyDir "$guid.jsonl"))) `
            'the transcript must be gone: this is the destructive delete, not archive'
        Assert-True (-not (Test-Path $guidDir)) `
            'the per-GUID sidecar directory must go with it, or the delete is only half done'
        Assert-True (Test-Path (Join-Path $keyDir "$keep.jsonl")) `
            'deleting one session must not touch any other session in the same project'
    }

# -----------------------------------------------------------------------------
# Sync-SessionIndex. The largest single function in the module and, until now,
# untested.
#
# It repairs Claude Code's OWN sessions-index.json, which is what its /resume
# picker reads. Getting it wrong does not break ClaudeCM visibly; it breaks the
# other program quietly, which is the worst failure shape available.
#
# Every expected index below is HAND-WRITTEN. Generating the oracle with the
# same function under test would bind nothing at all: it would assert only that
# the function is deterministic, which is not in question.
# -----------------------------------------------------------------------------

function New-IndexEntry {
    param([string]$Guid, [string]$Path, [string]$Prompt = 'seeded', [string]$ProjPath = 'C:\seeded')
    @{ sessionId = $Guid; fullPath = $Path; fileMtime = 1700000000000
       firstPrompt = $Prompt; messageCount = 1
       created = '2026-01-01T00:00:00.000Z'; modified = '2026-01-01T00:00:00.000Z'
       gitBranch = ''; projectPath = $ProjPath; isSidechain = $false }
}

Test-Case -Name 'Sync-SessionIndex drops entries whose transcript is gone' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Sync-SessionIndex') `
    -Sabotage 'seed the kept-list with every existing entry, so a session deleted from disk stays in the index forever' `
    -Mutate @{ 'Sync-SessionIndex' = @{
        Find = '$validEntries = @()'; Replace = '$validEntries = @($existingEntries)' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'syncproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $alive = '11111111-2222-3333-4444-555555555555'
        $dead  = '99999999-8888-7777-6666-555555555555'
        Set-Content (Join-Path $keyDir "$alive.jsonl") '{"type":"user"}' -Encoding UTF8
        # $dead deliberately has NO file: this is the state left behind by a
        # delete, a trim, or a quarantine.

        $indexPath = Join-Path $keyDir 'sessions-index.json'
        @{ version = 1; originalPath = $projDir; entries = @(
            (New-IndexEntry $alive (Join-Path $keyDir "$alive.jsonl")),
            (New-IndexEntry $dead  (Join-Path $keyDir "$dead.jsonl"))
        ) } | ConvertTo-Json -Depth 10 | Set-Content $indexPath -Encoding UTF8

        Set-Content $sessionsFile "$alive|$projDir|Alive Session|10" -Encoding UTF8

        Sync-SessionIndex $projDir

        $after = Get-Content $indexPath -Raw | ConvertFrom-Json
        $ids = @($after.entries | ForEach-Object { $_.sessionId })
        Assert-Equal 1 $ids.Count "the index must list exactly the transcripts that exist; got $($ids -join ', ')"
        Assert-Equal $alive $ids[0] 'the surviving entry must be the one whose file is still on disk'
    }

Test-Case -Name 'Sync-SessionIndex adds an entry for a transcript it has never seen' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Sync-SessionIndex') `
    -Sabotage 'write only the surviving entries and discard the newly discovered ones, so a transcript that exists never becomes resumable' `
    -Mutate @{ 'Sync-SessionIndex' = @{
        Find = '$allEntries = @($validEntries) + @($newEntries)'; Replace = '$allEntries = @($validEntries)' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'syncproj2'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $known = 'aaaa1111-2222-3333-4444-555555555555'
        $fresh = 'bbbb1111-2222-3333-4444-555555555555'
        Set-Content (Join-Path $keyDir "$known.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content (Join-Path $keyDir "$fresh.jsonl") '{"type":"user"}' -Encoding UTF8

        $indexPath = Join-Path $keyDir 'sessions-index.json'
        @{ version = 1; originalPath = $projDir
           entries = @((New-IndexEntry $known (Join-Path $keyDir "$known.jsonl"))) } |
            ConvertTo-Json -Depth 10 | Set-Content $indexPath -Encoding UTF8

        Set-Content $sessionsFile @(
            "$known|$projDir|Known One|10", "$fresh|$projDir|Fresh One|20") -Encoding UTF8

        Sync-SessionIndex $projDir

        $after = Get-Content $indexPath -Raw | ConvertFrom-Json
        $ids = @($after.entries | ForEach-Object { $_.sessionId })
        Assert-Equal 2 $ids.Count "both transcripts on disk must be indexed; got $($ids -join ', ')"
        Assert-True ($ids -contains $fresh) 'the unindexed transcript is the whole point of the repair'
        Assert-True ($ids -contains $known) 'repairing the index must not lose what was already correct'
    }

Test-Case -Name 'Sync-SessionIndex labels a new entry with the name from sessions.txt' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Sync-SessionIndex') `
    -Sabotage 'stop copying the session description, so every repaired entry shows a blank name in the resume picker' `
    -Mutate @{ 'Sync-SessionIndex' = @{
        Find = '$firstPrompt = $sessMatch.Desc'; Replace = '$firstPrompt = ""' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'syncproj3'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        # No index at all. This is the from-scratch path, which is what a fresh
        # project and a corrupted index both land on.
        $guid = 'cccc1111-2222-3333-4444-555555555555'
        Set-Content (Join-Path $keyDir "$guid.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$guid|$projDir|Refactor The Parser|10" -Encoding UTF8

        Sync-SessionIndex $projDir

        $indexPath = Join-Path $keyDir 'sessions-index.json'
        Assert-True (Test-Path $indexPath) 'a missing index must be created, not skipped'
        $after = Get-Content $indexPath -Raw | ConvertFrom-Json
        Assert-Equal 1 @($after.entries).Count 'exactly one transcript, exactly one entry'
        Assert-Equal 'Refactor The Parser' $after.entries[0].firstPrompt `
            'the name ClaudeCM knows must be the name the resume picker shows, or the two lists disagree about what a session is'
        Assert-Equal $projDir $after.entries[0].projectPath `
            'the entry must point at the project directory sessions.txt records'
    }

Test-Case -Name 'Sync-SessionIndex preserves an existing originalPath' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Sync-SessionIndex') `
    -Sabotage 'always overwrite originalPath with the directory being synced, which silently repoints a project that has been moved' `
    -Mutate @{ 'Sync-SessionIndex' = @{
        Find = 'if ($indexData.originalPath) { $originalPath = $indexData.originalPath }'
        Replace = '$null = $indexData' } } `
    -Body {
        $projDir = Join-Path $sandbox.Root 'syncproj4'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $guid = 'dddd1111-2222-3333-4444-555555555555'
        Set-Content (Join-Path $keyDir "$guid.jsonl") '{"type":"user"}' -Encoding UTF8

        # originalPath is Claude Code's record of where the project first lived.
        # It is deliberately NOT the directory being synced here. Overwriting it
        # is the difference between "this project moved" and "this project has
        # always been here", and only the first one is true.
        $wasAt = 'C:\Users\someone\oldlocation'
        $indexPath = Join-Path $keyDir 'sessions-index.json'
        @{ version = 1; originalPath = $wasAt
           entries = @((New-IndexEntry $guid (Join-Path $keyDir "$guid.jsonl"))) } |
            ConvertTo-Json -Depth 10 | Set-Content $indexPath -Encoding UTF8

        Set-Content $sessionsFile "$guid|$projDir|Moved Project|10" -Encoding UTF8

        Sync-SessionIndex $projDir

        $after = Get-Content $indexPath -Raw | ConvertFrom-Json
        Assert-Equal $wasAt $after.originalPath `
            'a sync is a repair, not a relocation: it must not rewrite where the project came from'
    }

# -----------------------------------------------------------------------------
# Resolve-ResumeOrRecover. The gate every resume passes through.
#
# It answers one question: does this session still have a transcript, and if not
# what should happen instead. Getting the healthy case wrong is the expensive
# direction, because it diverts a working session into recovery.
# -----------------------------------------------------------------------------

Test-Case -Name 'Resolve-ResumeOrRecover resumes normally when the transcript exists' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Get-SessionInfo','Sync-SessionIndex','Build-RecoveryMetaPrompt','Resolve-ResumeOrRecover') `
    -Sabotage 'return the recovery verdict even when the transcript is present, diverting every healthy session into the lost-conversation flow' `
    -Mutate @{ 'Resolve-ResumeOrRecover' = @{
        Find    = "return [PSCustomObject]@{ Action='normal'; Guid=`$guid }"
        Replace = "return [PSCustomObject]@{ Action='fresh'; Guid=`$null }" } } `
    -Body {
        # Answers 3 (cancel) if anything asks. Nothing should: a healthy session
        # must return before the menu. Returning a value rather than throwing is
        # deliberate, so a sabotage that reaches the prompt produces a red
        # assertion instead of an error, which would only be inconclusive.
        function Read-Host { param([string]$Prompt) '3' }

        $projDir = Join-Path $sandbox.Root 'healthy'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        $guid = '0a0a0a0a-1111-2222-3333-444444444444'
        Set-Content (Join-Path $keyDir "$guid.jsonl") '{"type":"user"}' -Encoding UTF8

        $r = Resolve-ResumeOrRecover $guid $projDir 'Healthy Session' 100
        Assert-Equal 'normal' $r.Action 'a session whose transcript is on disk must resume, not recover'
        Assert-Equal $guid $r.Guid 'it must resume the GUID it was asked about'
    }

Test-Case -Name 'Resolve-ResumeOrRecover returns a null GUID when starting fresh' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Get-SessionInfo','Sync-SessionIndex','Build-RecoveryMetaPrompt','Resolve-ResumeOrRecover') `
    -Sabotage 'hand the dead GUID back with the fresh verdict, so the caller resumes a transcript that is not there' `
    -Mutate @{ 'Resolve-ResumeOrRecover' = @{
        Find    = "'1' { return [PSCustomObject]@{ Action='fresh'; Guid=`$null } }"
        Replace = "'1' { return [PSCustomObject]@{ Action='fresh'; Guid=`$guid } }" } } `
    -Body {
        function Read-Host { param([string]$Prompt) '1' }

        $projDir = Join-Path $sandbox.Root 'lost'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)) -Force | Out-Null
        # No transcript written: this is the 30-day-cleanup state.

        $r = Resolve-ResumeOrRecover 'dead0000-1111-2222-3333-444444444444' $projDir 'Lost Session' 100
        Assert-Equal 'fresh' $r.Action 'choice 1 starts a new session in that directory'
        Assert-True ($null -eq $r.Guid) `
            'the GUID must be dropped: a fresh start that carries the dead GUID resumes nothing and re-registers a session that does not exist'
    }

Test-Case -Name 'Resolve-ResumeOrRecover cancels on choice 3' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Get-SessionInfo','Sync-SessionIndex','Build-RecoveryMetaPrompt','Resolve-ResumeOrRecover') `
    -Sabotage 'treat cancel as a fresh start, launching a session the user just declined' `
    -Mutate @{ 'Resolve-ResumeOrRecover' = @{
        Find    = "'3' { return [PSCustomObject]@{ Action='cancel'; Guid=`$null } }"
        Replace = "'3' { return [PSCustomObject]@{ Action='fresh'; Guid=`$null } }" } } `
    -Body {
        function Read-Host { param([string]$Prompt) '3' }

        $projDir = Join-Path $sandbox.Root 'lost3'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)) -Force | Out-Null

        $r = Resolve-ResumeOrRecover 'dead0000-5555-6666-7777-888888888888' $projDir 'Lost Session' 100
        Assert-Equal 'cancel' $r.Action 'cancel must mean cancel; nothing may be launched'
    }

Test-Case -Name 'Resolve-ResumeOrRecover rotates an existing recovery-prompt.md instead of overwriting it' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Get-SessionInfo','Sync-SessionIndex','Build-RecoveryMetaPrompt','Resolve-ResumeOrRecover') `
    -Sabotage 'skip the rename, so generating a second recovery prompt destroys the first one the user may have already edited' `
    -Mutate @{ 'Resolve-ResumeOrRecover' = @{
        Find    = 'try { Rename-Item $primaryPath "recovery-prompt.md.old" -Force -ErrorAction Stop } catch {}'
        Replace = '$null = $primaryPath' } } `
    -Body {
        function Read-Host { param([string]$Prompt) '2' }
        # $claudeExe already points at the stub via the harness prelude.

        $projDir = Join-Path $sandbox.Root 'recov'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        # A recovery prompt the user has already been given, and may well have
        # edited. Losing it silently is the failure this guards.
        $primary = Join-Path $projDir 'recovery-prompt.md'
        Set-Content $primary 'ORIGINAL RECOVERY PROMPT' -Encoding UTF8

        $env:CLAUDECM_STUB_PJSON   = 'BRAND NEW RECOVERY PROMPT'
        $env:CLAUDECM_STUB_PSID    = 'ffff0000-1111-2222-3333-444444444444'
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        try {
            $null = Resolve-ResumeOrRecover 'dead1111-1111-2222-3333-444444444444' $projDir 'Recover Me' 100
        } finally {
            Remove-Item Env:CLAUDECM_STUB_PJSON, Env:CLAUDECM_STUB_PSID, Env:CLAUDECM_STUB_PROJDIR -ErrorAction SilentlyContinue
        }

        $rotated = Join-Path $projDir 'recovery-prompt.md.old'
        Assert-True (Test-Path $rotated) `
            'the previous recovery prompt must be kept as .old, not overwritten'
        Assert-True ((Get-Content $rotated -Raw) -match 'ORIGINAL RECOVERY PROMPT') `
            'the rotated file must hold the OLD content; rotating the new one over it would lose the same work'
        Assert-True ((Get-Content $primary -Raw) -match 'BRAND NEW RECOVERY PROMPT') `
            'the freshly generated prompt must land at recovery-prompt.md'
    }

Test-Case -Name 'Resolve-ResumeOrRecover deletes the throwaway transcript its own -p call created' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Get-SessionInfo','Sync-SessionIndex','Build-RecoveryMetaPrompt','Resolve-ResumeOrRecover') `
    -Sabotage 'leave the primer transcript on disk, which turns every recovery attempt into a new orphan' `
    -Mutate @{ 'Resolve-ResumeOrRecover' = @{
        Find    = 'if (Test-Path $primerJsonl) { Remove-Item $primerJsonl -Force -ErrorAction SilentlyContinue }'
        Replace = '$null = $primerJsonl' } } `
    -Body {
        function Read-Host { param([string]$Prompt) '2' }
        # $claudeExe already points at the stub via the harness prelude.

        $projDir = Join-Path $sandbox.Root 'recov2'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        # Generating a recovery prompt runs `claude -p`, and that call creates a
        # transcript of its own. It is nobody's session: it is never registered
        # in sessions.txt, so if it is left behind the next launch greets the
        # user with the orphan picker, caused by the recovery that was meant to
        # help. The stub writes one precisely so this can be checked.
        $primerSid = 'aaaa9999-1111-2222-3333-444444444444'
        $env:CLAUDECM_STUB_PJSON   = 'RECOVERY TEXT'
        $env:CLAUDECM_STUB_PSID    = $primerSid
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        try {
            $null = Resolve-ResumeOrRecover 'dead2222-1111-2222-3333-444444444444' $projDir 'Recover Me Too' 100
        } finally {
            Remove-Item Env:CLAUDECM_STUB_PJSON, Env:CLAUDECM_STUB_PSID, Env:CLAUDECM_STUB_PROJDIR -ErrorAction SilentlyContinue
        }

        Assert-True (-not (Test-Path (Join-Path $keyDir "$primerSid.jsonl"))) `
            'the primer transcript must be cleaned up, or recovery manufactures the orphans ClaudeCM exists to prevent'
        Assert-True (Test-Path (Join-Path $projDir 'recovery-prompt.md')) `
            'and the recovery prompt itself must still have been written'
    }

# -----------------------------------------------------------------------------
# Do-Refresh. Flagged as the risky one and it earns that.
#
# It builds a prompt that embeds an extracted skeleton and pipes it to a
# headless claude. The piping is not incidental. Passing the same text as an
# argument works perfectly on small inputs and fails once the command line
# passes roughly 32K, which is a size no toy fixture reaches. That combination,
# correct on every small case and broken on every real one, cost a full day in
# April 2026.
#
# So the fixture here is deliberately large: tests/stubs/extract-skeleton.mjs
# emits an 80KB skeleton by default, and the stub reports how many characters
# actually arrived on stdin.
# -----------------------------------------------------------------------------

function Install-FakeExtractor {
    # Do-Refresh searches for extract-skeleton.mjs next to the script, then
    # $env:CLAUDECM_HOME, then ~/.claudecm. Only the last one is inside the
    # sandbox, so CLAUDECM_HOME is cleared: if the real machine has it set, the
    # product would find the REAL extractor and the test would silently start
    # measuring something else.
    $env:CLAUDECM_HOME = $null
    Copy-Item (Join-Path (Split-Path $script:ClaudeStub -Parent) 'extract-skeleton.mjs') `
              (Join-Path $sandbox.CmDir 'extract-skeleton.mjs') -Force
}

Test-Case -Name 'Do-Refresh pipes the whole prompt on stdin, at a size no command line would hold' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Sync-SessionIndex','Do-Refresh') `
    -Sabotage 'pass the prompt as a command-line argument instead of piping it, the April 2026 bug: correct on every small input and truncated on every real one' `
    -Mutate @{ 'Do-Refresh' = @{
        Find    = '$refreshJson = $promptText | & $claudeExe --dangerously-skip-permissions -p --output-format json 2>&1 | Out-String'
        Replace = '$refreshJson = & $claudeExe --dangerously-skip-permissions -p $promptText --output-format json 2>&1 | Out-String' } } `
    -Body {
        # A missing node must FAIL rather than skip. Skipping would quietly
        # remove the only guard on the 32K path, which is the exact failure
        # shape this test exists to prevent.
        Assert-True ($null -ne (Get-Command node -ErrorAction SilentlyContinue)) `
            'node is required to build a realistic skeleton; without it this test cannot guard the stdin path'
        function Read-Host { param([string]$Prompt) '' }
        Install-FakeExtractor

        $projDir = Join-Path $sandbox.Root 'refreshbig'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $oldGuid = 'bbbb0000-1111-2222-3333-444444444444'
        Set-Content (Join-Path $keyDir "$oldGuid.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$oldGuid|$projDir|Big Refresh|900" -Encoding UTF8

        $record = Join-Path $sandbox.Root 'stdin-size.txt'
        $env:CLAUDECM_STUB_PJSON        = 'ok'
        $env:CLAUDECM_STUB_PSID         = 'cccc0000-1111-2222-3333-444444444444'
        $env:CLAUDECM_STUB_PROJDIR      = $keyDir
        $env:CLAUDECM_STUB_STDIN_RECORD = $record
        try { Do-Refresh $oldGuid }
        finally {
            Remove-Item Env:CLAUDECM_STUB_PJSON, Env:CLAUDECM_STUB_PSID,
                        Env:CLAUDECM_STUB_PROJDIR, Env:CLAUDECM_STUB_STDIN_RECORD -ErrorAction SilentlyContinue
        }

        Assert-True (Test-Path $record) `
            'the headless call must actually have been made; no record means claude was never reached'
        $got = [int](Get-Content $record -Raw).Trim()
        # 32768 is the number that matters. Asserting comfortably above it means
        # the test cannot pass on a prompt that a command line could have carried.
        Assert-True ($got -gt 40000) `
            "the entire prompt must reach claude on stdin; only $got characters arrived, which is the size a truncating argument path produces"
    }

Test-Case -Name 'Do-Refresh puts the new session first and the old one last, renamed' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Sync-SessionIndex','Do-Refresh') `
    -Sabotage 'drop the old session from the rewritten list, silently discarding the conversation the refresh was meant to preserve' `
    -Mutate @{ 'Do-Refresh' = @{
        Find = 'if ($oldEntry) { $newSessions += $oldEntry }'; Replace = '$null = $oldEntry' } } `
    -Body {
        function Read-Host { param([string]$Prompt) '' }
        $env:CLAUDECM_HOME = $null   # no extractor: this test is about the list

        $projDir = Join-Path $sandbox.Root 'refreshlist'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $oldGuid   = 'dddd0000-1111-2222-3333-444444444444'
        $freshGuid = 'eeee0000-1111-2222-3333-444444444444'
        Set-Content (Join-Path $keyDir "$oldGuid.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile @(
            "$oldGuid|$projDir|Main Work|900",
            "9999aaaa-1111-2222-3333-444444444444|$projDir|Unrelated|5") -Encoding UTF8

        $env:CLAUDECM_STUB_PJSON   = 'ok'
        $env:CLAUDECM_STUB_PSID    = $freshGuid
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        try { Do-Refresh $oldGuid }
        finally { Remove-Item Env:CLAUDECM_STUB_PJSON, Env:CLAUDECM_STUB_PSID, Env:CLAUDECM_STUB_PROJDIR -ErrorAction SilentlyContinue }

        $rows = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-Equal 3 $rows.Count "refresh must add one row and lose none; got $($rows.Count)"
        Assert-True ($rows[0].StartsWith($freshGuid)) 'the fresh session belongs at the top'
        Assert-True ($rows[-1] -match '\(old\)') `
            'the refreshed-from session must be kept, renamed (old), at the bottom: it still holds the conversation'
        Assert-True ($rows[-1].StartsWith($oldGuid)) 'and it must still point at the original transcript'
    }

Test-Case -Name 'Do-Refresh numbers a second (old) rather than colliding with the first' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Sync-SessionIndex','Do-Refresh') `
    -Sabotage 'always use the bare (old) suffix, producing two sessions with identical names in the same project' `
    -Mutate @{ 'Do-Refresh' = @{
        Find = 'if ($n -eq 1) { $oldDesc = "$baseDesc (old)" } else { $oldDesc = "$baseDesc (old $n)" }'
        Replace = '$oldDesc = "$baseDesc (old)"' } } `
    -Body {
        function Read-Host { param([string]$Prompt) '' }
        $env:CLAUDECM_HOME = $null

        $projDir = Join-Path $sandbox.Root 'refreshtwice'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $cur = '1111bbbb-1111-2222-3333-444444444444'
        Set-Content (Join-Path $keyDir "$cur.jsonl") '{"type":"user"}' -Encoding UTF8
        # "Main Work (old)" already exists, from a previous refresh of the same
        # project. A second refresh must not produce a duplicate name: the list
        # is chosen from by number, but a human still has to tell them apart.
        Set-Content $sessionsFile @(
            "$cur|$projDir|Main Work|900",
            "2222bbbb-1111-2222-3333-444444444444|$projDir|Main Work (old)|10") -Encoding UTF8

        $env:CLAUDECM_STUB_PJSON   = 'ok'
        $env:CLAUDECM_STUB_PSID    = '3333bbbb-1111-2222-3333-444444444444'
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        try { Do-Refresh $cur }
        finally { Remove-Item Env:CLAUDECM_STUB_PJSON, Env:CLAUDECM_STUB_PSID, Env:CLAUDECM_STUB_PROJDIR -ErrorAction SilentlyContinue }

        $text = Get-Content $sessionsFile -Raw
        Assert-True ($text -match '\(old 2\)') `
            'the second refresh must number its predecessor (old 2); two rows named the same thing are indistinguishable in the list'
        $olds = @(Get-Content $sessionsFile | Where-Object { $_ -match 'Main Work \(old\)\|' -or $_ -match 'Main Work \(old\)$' })
        Assert-Equal 1 $olds.Count 'there must still be exactly one bare (old)'
    }

Test-Case -Name 'a refresh that produced no session leaves sessions.txt untouched' `
    -Uses @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Sync-SessionIndex','Do-Refresh') `
    -Sabotage 'carry on without a new GUID, rewriting the list around a session that was never created' `
    -Mutate @{ 'Do-Refresh' = @{
        Find    = 'if (-not $freshGuid) {'
        Replace = 'if ($false) {' } } `
    -Body {
        function Read-Host { param([string]$Prompt) '' }
        $env:CLAUDECM_HOME = $null

        $projDir = Join-Path $sandbox.Root 'refreshfail'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $cur = '4444cccc-1111-2222-3333-444444444444'
        Set-Content (Join-Path $keyDir "$cur.jsonl") '{"type":"user"}' -Encoding UTF8
        $before = "$cur|$projDir|Precious Work|900"
        Set-Content $sessionsFile $before -Encoding UTF8

        # PEMPTY: claude answered, but with no session_id. That is what a failed
        # headless run looks like, and the only safe response is to change
        # nothing. Renaming the existing session (old) at that point would leave
        # the user with a list whose every entry is marked superseded by a
        # session that does not exist.
        $env:CLAUDECM_STUB_PEMPTY  = '1'
        $env:CLAUDECM_STUB_PROJDIR = $keyDir
        try { Do-Refresh $cur }
        finally { Remove-Item Env:CLAUDECM_STUB_PEMPTY, Env:CLAUDECM_STUB_PROJDIR -ErrorAction SilentlyContinue }

        $rows = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-Equal 1 $rows.Count 'a failed refresh must not add a row'
        Assert-Equal $before $rows[0] `
            'a failed refresh must leave the original session exactly as it was, name included'
    }

# -----------------------------------------------------------------------------
# The interactive surface. Left until last because it blocks on input, not
# because it matters less: two of the four functions below can destroy work.
#
# Read-Host is shadowed with a SCRIPTED SEQUENCE rather than a single answer,
# because the interesting paths are the ones that ask twice.
# -----------------------------------------------------------------------------

function Use-Answers {
    param([string[]]$Answers)
    $script:__ans = $Answers
    $script:__ansIdx = 0
}

Test-Case -Name 'Show-List numbers sessions from 1' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Get-SessionDisplayName','Move-SessionToTop','Do-DeleteSession','Do-OrphanScan','Resolve-ResumeOrRecover','Build-RecoveryMetaPrompt','Do-ViewArchived','Do-Resume','Show-List') `
    -Sabotage 'number the list from 0, so every number the user is shown is one off from the number the code accepts' `
    -Mutate @{ 'Show-List' = @{
        Find = '$num = "$($i+1).".PadRight($numWidth + 2)'; Replace = '$num = "$($i).".PadRight($numWidth + 2)' } } `
    -Body {
        $sessions = @(
            [pscustomobject]@{ Guid='1111dddd-1111-2222-3333-444444444444'; Dir=$sandbox.Root; Desc='First Thing';  Tokens='10' },
            [pscustomobject]@{ Guid='2222dddd-1111-2222-3333-444444444444'; Dir=$sandbox.Root; Desc='Second Thing'; Tokens='20' }
        )
        # 6>&1 is required: the module speaks through Write-Host, which writes to
        # the information stream, not the success pipeline. Without the redirect
        # the capture is empty and every assertion below could not fail.
        $out = (Show-List $sessions 6>&1 | Out-String)

        Assert-True ($out -match '(?m)^\s+1\.\s') `
            'the first session must be numbered 1: every selection path indexes off the number printed here'
        Assert-True ($out -notmatch '(?m)^\s+0\.\s') `
            'there is no session 0; a zero-based display makes the whole list off by one'
        Assert-True ($out -match 'Second Thing') 'every session must appear'
    }

Test-Case -Name 'Do-Resume rejects a pick of 0 instead of resuming the last session' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Get-SessionDisplayName','Move-SessionToTop','Do-DeleteSession','Do-OrphanScan','Resolve-ResumeOrRecover','Build-RecoveryMetaPrompt','Do-ViewArchived','Do-Resume','Show-List') `
    -Sabotage 'weaken the lower bound to allow 0, which in PowerShell indexes $sessions[-1] and silently resumes the LAST session instead' `
    -Mutate @{ 'Do-Resume' = @{
        Find = 'if ($pick -lt 1 -or $pick -gt $sessions.Count) {'; Replace = 'if ($pick -lt 0 -or $pick -gt $sessions.Count) {' } } `
    -Body {
        # This is not a pedantic bounds check. $sessions[0 - 1] is $sessions[-1]
        # in PowerShell, which is the LAST element rather than an error, so a
        # weakened lower bound does not crash: it quietly opens the wrong
        # conversation. Nothing in the output would tell the user.
        Use-Answers @('3','3','3')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        $projDir = $sandbox.Root
        New-Item -ItemType Directory -Path (Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)) -Force | Out-Null

        $rows = @(
            "1111eeee-1111-2222-3333-444444444444|$projDir|Alpha|1",
            "2222eeee-1111-2222-3333-444444444444|$projDir|Beta|2",
            "3333eeee-1111-2222-3333-444444444444|$projDir|Gamma|3"
        )
        Set-Content $sessionsFile $rows -Encoding UTF8
        # NOT @(Get-Sessions). Spec 14.3: the function returns ,$sessions so the
        # array survives PowerShell unrolling, which means it is ALREADY an
        # array and @() wraps it in a second one. Do-Resume would then be handed
        # a single-element list holding a list, and $sel.Dir would be $null.
        $sessions = Get-Sessions

        $null = (Do-Resume 0 $sessions 6>&1)

        # Move-SessionToTop is the first thing a real resume does, so the order
        # is the tell. No transcripts exist for these GUIDs, so even a sabotaged
        # run stops at the recovery menu and answers cancel: nothing launches
        # either way, and the only observable difference is the reordering.
        $after = @(Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' })
        Assert-Equal $rows[0] $after[0] `
            'a pick of 0 is not a selection; nothing may be resumed and the list must not be reordered'
        Assert-Equal 3 $after.Count 'and no row may be added or lost'
    }

Test-Case -Name 'a permanent delete needs the word delete, not any confirmation' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Get-SessionDisplayName','Move-SessionToTop','Do-DeleteSession','Do-OrphanScan','Resolve-ResumeOrRecover','Build-RecoveryMetaPrompt','Do-ViewArchived','Do-Resume','Show-List') `
    -Sabotage 'accept any answer as confirmation, so an absent-minded y destroys a conversation permanently' `
    -Mutate @{ 'Do-ViewArchived' = @{
        Find = "if (`$confirm -match '^delete`$') {"; Replace = 'if ($true) {' } } `
    -Body {
        # The prompt says "Type 'delete' to confirm" and this is the only guard
        # between a keystroke and an unrecoverable loss. The answer given below
        # is 'yes', which is exactly the kind of thing a person types on
        # autopilot after a day of y/N prompts.
        Use-Answers @('D1', 'yes', 'Q', 'Q')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        $projDir = Join-Path $sandbox.Root 'archproj'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        $keyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $projDir)
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null

        $guid = '5555ffff-1111-2222-3333-444444444444'
        $jsonl = Join-Path $keyDir "$guid.jsonl"
        Set-Content $jsonl '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile @(
            "6666ffff-1111-2222-3333-444444444444|$projDir|Live One|5",
            '[archived]',
            "$guid|$projDir|Old But Wanted|50") -Encoding UTF8

        $null = (Do-ViewArchived 6>&1)

        Assert-True (Test-Path $jsonl) `
            'answering anything other than the word delete must leave the conversation on disk; this is the last guard before permanent loss'
        Assert-Equal 1 (Get-ArchivedSessions).Count 'and the archive entry must remain'
    }

Test-Case -Name 'unarchiving moves a session across, it does not copy it' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Get-SessionDisplayName','Move-SessionToTop','Do-DeleteSession','Do-OrphanScan','Resolve-ResumeOrRecover','Build-RecoveryMetaPrompt','Do-ViewArchived','Do-Resume','Show-List') `
    -Sabotage 'leave the entry in the archive after adding it to the live list, so one session exists twice under two numbers' `
    -Mutate @{ 'Do-ViewArchived' = @{
        Find = '$archived = @($archived | Where-Object { $_ -ne $entry })'; Replace = '$archived = @($archived)' } } `
    -Body {
        Use-Answers @('U1', 'Q', 'Q')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        $projDir = Join-Path $sandbox.Root 'unarch'
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null

        Set-Content $sessionsFile @(
            "7777aaaa-1111-2222-3333-444444444444|$projDir|Still Live|5",
            '[archived]',
            "8888aaaa-1111-2222-3333-444444444444|$projDir|Coming Back|50") -Encoding UTF8

        $null = (Do-ViewArchived 6>&1)

        $live = Get-Sessions
        Assert-Equal 2 $live.Count 'the unarchived session must appear in the live list'
        Assert-True ($live[0].Desc -eq 'Coming Back') 'and it belongs at the top, as the most recent action'
        Assert-Equal 0 (Get-ArchivedSessions).Count `
            'it must LEAVE the archive: a session listed in both places is one session wearing two numbers, and archiving it again would not remove it'
    }

# -----------------------------------------------------------------------------
# Do-EditList. Five sub-commands, three of which can lose a session.
# -----------------------------------------------------------------------------

Test-Case -Name 'Do-EditList renames a session in place' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Do-DeleteSession','Do-EditList') `
    -Sabotage 'accept the new name and discard it, so the rename appears to work and is gone next time the list is drawn' `
    -Mutate @{ 'Do-EditList' = @{
        Find = '$sessions[$idx].Desc = $newName'; Replace = '$null = $newName' } } `
    -Body {
        Use-Answers @('R1', 'Renamed Thing', 'Q', 'Q')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        Set-Content $sessionsFile @(
            "1111bbbb-aaaa-2222-3333-444444444444|$($sandbox.Root)|Original Name|5",
            "2222bbbb-aaaa-2222-3333-444444444444|$($sandbox.Root)|Other|6") -Encoding UTF8

        $null = (Do-EditList 6>&1)

        $after = Get-Sessions
        Assert-Equal 'Renamed Thing' $after[0].Desc 'the rename must be persisted, not just echoed'
        Assert-Equal 'Other' $after[1].Desc 'and it must not touch any other session'
    }

Test-Case -Name 'archiving moves a session to the archive rather than dropping it' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Do-DeleteSession','Do-EditList') `
    -Sabotage 'remove the session from the live list without adding it to the archive, which deletes it from the tool while leaving the transcript orphaned on disk' `
    -Mutate @{ 'Do-EditList' = @{
        Find = '$archived = @($archived) + @($entry)'; Replace = '$archived = @($archived)' } } `
    -Body {
        # Archive is the non-destructive counterpart to delete, so the failure
        # that matters is not "it stayed visible", it is "it went nowhere". The
        # transcript would still be on disk, unreferenced, which is precisely
        # the orphan state the orphan scanner exists to complain about.
        Use-Answers @('A1', 'Q', 'Q')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        Set-Content $sessionsFile @(
            "3333bbbb-aaaa-2222-3333-444444444444|$($sandbox.Root)|Put Me Away|5",
            "4444bbbb-aaaa-2222-3333-444444444444|$($sandbox.Root)|Keep Me Live|6") -Encoding UTF8

        $null = (Do-EditList 6>&1)

        Assert-Equal 1 (Get-Sessions).Count 'the archived session must leave the live list'
        Assert-Equal 1 (Get-ArchivedSessions).Count `
            'and it must ARRIVE in the archive; removed from one list without reaching the other is a silent loss'
        Assert-Equal 'Put Me Away' (Get-ArchivedSessions)[0].Desc 'and it must be the one that was chosen'
    }

Test-Case -Name 'Do-EditList refuses to repoint a session at a path that does not exist' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Do-DeleteSession','Do-EditList') `
    -Sabotage 'drop the existence check, so a typo silently repoints the session at a directory that is not there' `
    -Mutate @{ 'Do-EditList' = @{
        Find = 'if (-not (Test-Path $newPath)) {'; Replace = 'if ($false) {' } } `
    -Body {
        Use-Answers @('P1', 'C:\definitely\not\a\real\directory\xyzzy', 'Q', 'Q')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        $orig = Join-Path $sandbox.Root 'origproj'
        New-Item -ItemType Directory -Path $orig -Force | Out-Null
        Set-Content $sessionsFile "5555bbbb-aaaa-2222-3333-444444444444|$orig|Path Test|5" -Encoding UTF8

        $null = (Do-EditList 6>&1)

        # The path decides the project key, which decides where the transcript
        # is looked for. Accepting one that does not exist does not fail loudly;
        # it makes the session unresumable at the next attempt instead.
        Assert-Equal $orig (Get-Sessions)[0].Dir `
            'a path that does not exist must be rejected and the session left pointing where it was'
    }

Test-Case -Name 'repointing a session copies its transcript to the new project key' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Do-DeleteSession','Do-EditList') `
    -Sabotage 'change the recorded path without copying the transcript, leaving the session pointing at a project directory that has no conversation in it' `
    -Mutate @{ 'Do-EditList' = @{
        Find = 'Copy-Item $oldFile $newFile'; Replace = '$null = $newFile' } } `
    -Body {
        $orig = Join-Path $sandbox.Root 'fromproj'
        $dest = Join-Path $sandbox.Root 'toproj'
        New-Item -ItemType Directory -Path $orig -Force | Out-Null
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        Use-Answers @('P1', $dest, 'Q', 'Q')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        $guid = '6666bbbb-aaaa-2222-3333-444444444444'
        $oldKeyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $orig)
        New-Item -ItemType Directory -Path $oldKeyDir -Force | Out-Null
        Set-Content (Join-Path $oldKeyDir "$guid.jsonl") '{"type":"user"}' -Encoding UTF8
        Set-Content $sessionsFile "$guid|$orig|Moving House|5" -Encoding UTF8

        $null = (Do-EditList 6>&1)

        # The project key is derived from the path, so changing the path alone
        # points the session at a key directory that has never held its
        # transcript. The row would look right and the resume would find nothing.
        $newKeyDir = Join-Path $sandbox.ClaudeProj (Get-ProjectKey $dest)
        Assert-True (Test-Path (Join-Path $newKeyDir "$guid.jsonl")) `
            'the transcript must be copied to the new project key, or the repointed session has no conversation to resume'
        Assert-Equal $dest (Get-Sessions)[0].Dir 'and the row must record the new path'
    }

Test-Case -Name 'Do-EditList moves a session to the requested position' `
    -Uses @('Get-ProjectKey','Format-Tokens','Format-Size','Format-DateShort','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Acquire-SessionsLock','Release-SessionsLock','Write-SessionsAtomic','Save-Sessions','Save-ArchivedSessions','Sync-SessionIndex','Get-SessionInfo','Do-DeleteSession','Do-EditList') `
    -Sabotage 'always reinsert at the top regardless of the destination, so M#,# becomes bump-to-top and cannot reorder anything' `
    -Mutate @{ 'Do-EditList' = @{
        Find = '$list.Insert($to, $item)'; Replace = '$list.Insert(0, $item)' } } `
    -Body {
        # M1,3 moves the FIRST item to third place. A sabotage that always
        # inserts at 0 puts it straight back where it started, so the list is
        # unchanged: the assertion has to compare the whole order, not just
        # check that something moved.
        Use-Answers @('M1,3', 'Q', 'Q')
        function Read-Host { param([string]$Prompt)
            $a = $script:__ans[$script:__ansIdx]; $script:__ansIdx++; $a }

        Set-Content $sessionsFile @(
            "7777bbbb-aaaa-2222-3333-444444444444|$($sandbox.Root)|Alpha|1",
            "8888bbbb-aaaa-2222-3333-444444444444|$($sandbox.Root)|Beta|2",
            "9999bbbb-aaaa-2222-3333-444444444444|$($sandbox.Root)|Gamma|3") -Encoding UTF8

        $null = (Do-EditList 6>&1)

        $after = Get-Sessions
        Assert-Equal 3 $after.Count 'reordering must not add or lose a session'
        Assert-Equal 'Beta'  $after[0].Desc 'Beta moves up to first'
        Assert-Equal 'Gamma' $after[1].Desc 'Gamma moves up to second'
        Assert-Equal 'Alpha' $after[2].Desc 'and Alpha lands in third, where it was sent'
    }

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

# ------------------------------------------------------- the suite's own trap
#
# Two assertions in this file were silently unfailable until 2026-08-27, both
# written as @(Get-Sessions).Count. Spec 14.3 exists because Get-Sessions and
# Get-ArchivedSessions return `,$sessions`, deliberately, so the array survives
# PowerShell's unrolling of a function's return value. They therefore already
# ARE arrays, and @() around one builds a NEW one-element array containing it.
# .Count is then 1 no matter what the file holds, and an assertion that reads
# `Assert-Equal 1 @(Get-Sessions).Count` can never go red.
#
# That is worse than a wrong test: it is a test that looks like coverage. No
# per-test sabotage finds it, because the sabotage is in the assertion rather
# than in the product, so it needs a check at this level.
#
# Correct idiom: (Get-Sessions).Count, no @().

Structural-Case -Name 'the suite never re-wraps a comma-returned array' `
    -Sabotage 'reintroduce the @() wrapper the spec forbids' `
    -Mutate @{ Find = 'return ,$sessions'; Replace = 'return $sessions' } `
    -Body {
        param($ModuleText)
        # Two halves, and they check different things.
        #
        # First: this FILE must not contain the nesting idiom. Read from disk
        # rather than from $ModuleText, because the fault being guarded lives in
        # the tests, not in the product.
        # Comments are stripped first. This file explains the trap by name in
        # several places, and a guard that cannot tell an explanation from an
        # occurrence is the same defect that once made a structural test bind a
        # comment instead of code.
        $suite = (Get-Content $PSCommandPath | ForEach-Object { $_ -replace '#.*$','' }) -join "`n"
        # The needles are ASSEMBLED rather than written out, because this check
        # scans the file it lives in: spelling them literally would make the
        # guard find itself and fail on a clean suite.
        $at = [char]64
        foreach ($fn in @('Get-Sessions','Get-ArchivedSessions')) {
            $bad = "$at($fn)"
            if ($suite.Contains($bad)) {
                throw "$script:AssertSentinel the suite contains $bad, which nests the comma-returned array so .Count is always 1; write ($fn).Count instead"
            }
        }
        # Second: the product must still comma-return, which is what makes the
        # idiom above correct. This is the half the sabotage moves.
        $clean = ($ModuleText -split "`n" | ForEach-Object { $_ -replace '#.*$','' }) -join "`n"
        if ($clean -notmatch 'return\s+,\$sessions') {
            throw "$script:AssertSentinel spec 14.3: Get-Sessions and Get-ArchivedSessions must return ,`$sessions or a single-element list unrolls to a bare object and the list renders empty"
        }
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
    'claudeExe','machineNameFile','quarantineRoot','cmvExe','machineName'
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
