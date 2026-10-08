# Tests for register-late-guid.ps1, the helper that registers a new session
# in sessions.txt even if ClaudeCM never gets to exit cleanly.
#
# Case 1 REPRODUCES THE 2026-10-07 FAILURE on purpose, using the old fixed
# window: the conversation file appears after the window and is never
# registered. If case 1 stops failing, the test has stopped measuring anything.
#
# A fake "claude" is a copy of PING.EXE renamed claude.exe, started as a child
# of a fake ClaudeCM shell, because the helper identifies the session as
# claude.exe whose parent is the watched shell. Timings are seconds, not
# minutes; the logic is the same.
#
#   pwsh -NoProfile -File tests\Test-LateGuidHelper.ps1
$ErrorActionPreference = 'Stop'
$repo   = Split-Path $PSScriptRoot
$helper = Join-Path $repo 'register-late-guid.ps1'
$root   = Join-Path $repo 'temp\lateguid-test'
$fakeClaude = Join-Path $root 'claude.exe'
$guid = '11111111-2222-3333-4444-555555555555'
$pass = 0; $fail = 0

function Stop-FakeClaudes {
    # Killing a fake shell does NOT kill its claude.exe child; it lingers and
    # holds the exe open, so the next reset cannot delete the sandbox.
    Get-Process claude -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $fakeClaude } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Reset-Sandbox {
    Stop-FakeClaudes
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
    New-Item -ItemType Directory -Force "$root\proj" | Out-Null
    Copy-Item "$env:SystemRoot\System32\PING.EXE" $fakeClaude
    Set-Content "$root\sessions.txt" 'aaaaaaaa-0000-0000-0000-000000000000|C:\other|Other|' -Encoding UTF8
}

function Start-FakeSession([int]$seconds) {
    # A shell whose child is claude.exe for roughly $seconds. Returns the shell.
    $cmd = "& '$fakeClaude' -n $($seconds + 1) 127.0.0.1 | Out-Null"
    return Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $cmd -WindowStyle Hidden -PassThru
}

function Start-Helper([hashtable]$extra) {
    $a = @('-NoProfile', '-File', "`"$helper`"", '-ProjDirClaude', "`"$root\proj`"",
           '-ProjectDir', '"C:\x\durable"', '-Desc', '"Durable"',
           '-SessionsFile', "`"$root\sessions.txt`"", '-IntervalSeconds', '1',
           '-LogFile', "`"$root\helper.log`"")
    foreach ($k in $extra.Keys) { $a += @("-$k", "$($extra[$k])") }
    return Start-Process pwsh -ArgumentList $a -WindowStyle Hidden -PassThru
}

function Assert($name, [bool]$ok, $detail) {
    if ($ok) { $script:pass++; "  PASS  $name" } else { $script:fail++; "  FAIL  $name"; "        $detail" }
}

function Registered { [bool](Select-String -Path "$root\sessions.txt" -Pattern "^$guid\|" -Quiet) }
function LogText { if (Test-Path "$root\helper.log") { Get-Content "$root\helper.log" -Raw } else { '' } }

# --- 1. control: old fixed window, file arrives late -> NOT registered -------
Reset-Sandbox
$h = Start-Helper @{ TotalWindowSeconds = 3 }
Start-Sleep 6
Set-Content "$root\proj\$guid.jsonl" '{}'
$h.WaitForExit(15000) | Out-Null
Assert 'control: old 3s window misses a file that arrives at 6s (the original bug)' (-not (Registered)) (LogText)

# --- 2. the fix: watching the session, file arrives late -> registered -------
Reset-Sandbox
$shell = Start-FakeSession 20
Start-Sleep 2
$h = Start-Helper @{ WatchPid = $shell.Id; TotalWindowSeconds = 3 }
Start-Sleep 7
Set-Content "$root\proj\$guid.jsonl" '{}'
$h.WaitForExit(15000) | Out-Null
Assert 'fix: a file arriving long after the old window is registered' (Registered) (LogText)
Assert 'fix: the registration is logged' ((LogText) -match "registered $guid") (LogText)
Stop-Process -Id $shell.Id -Force -ErrorAction SilentlyContinue

# --- 3. session ends with no message sent -> helper stops, says why ----------
Reset-Sandbox
$shell = Start-FakeSession 4
Start-Sleep 1
$h = Start-Helper @{ WatchPid = $shell.Id }
$exited = $h.WaitForExit(20000)
Assert 'no file: helper stops once the claude session ends' $exited 'helper still running after 20s'
Assert 'no file: it logs why it stopped' ((LogText) -match 'stopped, no conversation file') (LogText)
Assert 'no file: sessions.txt untouched' (-not (Registered)) ''

# --- 4. the window is closed (shell killed) -> helper stops ------------------
Reset-Sandbox
$shell = Start-FakeSession 60
Start-Sleep 1
$h = Start-Helper @{ WatchPid = $shell.Id }
Start-Sleep 2
Stop-Process -Id $shell.Id -Force
$exited = $h.WaitForExit(20000)
Assert 'closed window: helper stops when the shell is gone' $exited 'helper still running after 20s'
Assert 'closed window: it logs that reason' ((LogText) -match 'launching shell is gone|claude session ended') (LogText)
Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $fakeClaude } | Stop-Process -Force

# --- 5. ClaudeCM already registered it on a clean exit -> no duplicate --------
Reset-Sandbox
Add-Content "$root\sessions.txt" "$guid|C:\x\durable|Durable|"
$shell = Start-FakeSession 20
Start-Sleep 1
$h = Start-Helper @{ WatchPid = $shell.Id }
Start-Sleep 2
Set-Content "$root\proj\$guid.jsonl" '{}'
$h.WaitForExit(15000) | Out-Null
$rows = @(Select-String -Path "$root\sessions.txt" -Pattern "^$guid\|").Count
Assert 'clean exit already wrote the row: still exactly one row' ($rows -eq 1) "$rows rows"
Stop-Process -Id $shell.Id -Force -ErrorAction SilentlyContinue

Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $fakeClaude } | Stop-Process -Force
Start-Sleep 1
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
""
"  $($pass + $fail) test(s): $pass pass, $fail fail"
if ($fail) { exit 1 }
