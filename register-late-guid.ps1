param(
    [string]$ProjDirClaude,
    [string]$ProjectDir,
    [string]$Desc,
    [string]$SessionsFile,
    [string]$BeforeGuids = '',
    [int]$IntervalSeconds = 30,
    [int]$TotalWindowSeconds = 300,
    # The shell ClaudeCM launched claude from. When given, the helper watches
    # until that claude session ENDS instead of for a fixed window. See below.
    [int]$WatchPid = 0,
    [int]$MaxHours = 24,
    [string]$LogFile = "$env:USERPROFILE\.claudecm\logs\register-late-guid.log"
)

# WHY IT WATCHES THE SESSION, NOT A CLOCK. Fixed 2026-10-08.
#
# The old helper gave up 300 seconds after launch. Claude Code does not create
# the conversation file until the FIRST MESSAGE is sent, so writing a careful
# opening prompt for more than five minutes meant the file appeared after the
# helper had quit. If the session then never exited cleanly through ClaudeCM,
# nothing ever registered it: a hackathon session on Scratchy ran half a day,
# 78 messages, and never appeared in the list (claudecm started 11:16, first
# message 11:23). It also gave up silently, so there was no trace of it.
#
# Now: with -WatchPid, poll until the file appears, or until the claude process
# that shell launched has come and gone, or the shell itself is gone. A final
# check runs after either, because the file can land in the last interval.
# MaxHours is a backstop against a helper outliving everything. Every exit
# path writes one log line, so "never started" and "gave up" can be told apart.
function Write-HelperLog($msg) {
    try {
        $dir = Split-Path $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ("{0}  pid {1}  {2}  {3}" -f
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, (Split-Path $ProjDirClaude -Leaf), $msg)
    } catch {}
}

$uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$before = @{}
if ($BeforeGuids) {
    foreach ($g in ($BeforeGuids -split ',')) { if ($g) { $before[$g] = $true } }
}

function Find-NewGuid {
    if (-not (Test-Path $ProjDirClaude)) { return $null }
    $newFiles = @(Get-ChildItem "$ProjDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match $uuidPattern -and -not $before.ContainsKey($_.BaseName) })
    if ($newFiles.Count -eq 0) { return $null }
    if ($newFiles.Count -eq 1) { return $newFiles[0].BaseName }
    return ($newFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).BaseName
}

function Test-ClaudeUnder($shellPid) {
    # claude is started with `& $claudeExe` inside the ClaudeCM shell, so it
    # is a direct child of that shell's process.
    return [bool](Get-CimInstance Win32_Process -Filter "Name='claude.exe' AND ParentProcessId=$shellPid" -ErrorAction SilentlyContinue)
}

$mode = if ($WatchPid) { "watching session under shell $WatchPid" } else { "fixed window ${TotalWindowSeconds}s" }
Write-HelperLog "started, $mode"
$deadline = if ($WatchPid) { (Get-Date).AddHours($MaxHours) } else { (Get-Date).AddSeconds($TotalWindowSeconds) }
$newGuid = $null
$seenClaude = $false
$why = 'deadline reached'
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $IntervalSeconds
    $newGuid = Find-NewGuid
    if ($newGuid) { break }
    if ($WatchPid) {
        if (-not (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)) { $why = 'launching shell is gone'; break }
        $alive = Test-ClaudeUnder $WatchPid
        if ($alive) { $seenClaude = $true }
        elseif ($seenClaude) { $why = 'claude session ended'; break }
    }
}
if (-not $newGuid) { $newGuid = Find-NewGuid }   # the file can land in the last interval
if (-not $newGuid) { Write-HelperLog "stopped, no conversation file ($why)"; return }

$lockPath = "$SessionsFile.lock"
$lockStream = $null
$lockDeadline = (Get-Date).AddSeconds(10)
while (-not $lockStream -and (Get-Date) -lt $lockDeadline) {
    try { $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { Start-Sleep -Milliseconds 200 }
}
if (-not $lockStream) { Write-HelperLog "found $newGuid but could not lock sessions.txt; NOT registered"; return }

$didWrite = $false
try {
    $lines = @(Get-Content $SessionsFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' })
    $alreadyThere = $lines | Where-Object { $_ -like "$newGuid|*" }
    if (-not $alreadyThere) {
        $newLine = "$newGuid|$ProjectDir|$Desc|"
        $newLines = @($newLine) + $lines
        $tmpPath = "$SessionsFile.tmp"
        $newLines | Set-Content -Path $tmpPath -Encoding UTF8
        Move-Item -Path $tmpPath -Destination $SessionsFile -Force
        $didWrite = $true
    }
} finally {
    $lockStream.Close()
    $lockStream.Dispose()
}
if ($didWrite) { Write-HelperLog "registered $newGuid"; Write-Host "registered $newGuid" }
else { Write-HelperLog "found $newGuid, already in sessions.txt" }
