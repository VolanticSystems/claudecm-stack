param(
    [string]$ProjDirClaude,
    [string]$ProjectDir,
    [string]$Desc,
    [string]$SessionsFile,
    [string]$BeforeGuids = '',
    [int]$IntervalSeconds = 30,
    [int]$TotalWindowSeconds = 300
)

$uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$before = @{}
if ($BeforeGuids) {
    foreach ($g in ($BeforeGuids -split ',')) { if ($g) { $before[$g] = $true } }
}

$deadline = (Get-Date).AddSeconds($TotalWindowSeconds)
$newGuid = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $IntervalSeconds
    if (-not (Test-Path $ProjDirClaude)) { continue }
    $newFiles = @(Get-ChildItem "$ProjDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match $uuidPattern -and -not $before.ContainsKey($_.BaseName) })
    if ($newFiles.Count -gt 0) {
        $newGuid = if ($newFiles.Count -eq 1) {
            $newFiles[0].BaseName
        } else {
            ($newFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).BaseName
        }
        break
    }
}
if (-not $newGuid) { return }

$lockPath = "$SessionsFile.lock"
$lockStream = $null
$lockDeadline = (Get-Date).AddSeconds(10)
while (-not $lockStream -and (Get-Date) -lt $lockDeadline) {
    try { $lockStream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { Start-Sleep -Milliseconds 200 }
}
if (-not $lockStream) { return }

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
if ($didWrite) { Write-Host "registered $newGuid" }
