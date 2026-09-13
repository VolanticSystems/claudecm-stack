# Run the DEPLOYED Do-OrphanScan against the REAL project directories and
# assert it stays silent. This is the failure the operator reported after the reboot:
# the "Multiple conversation files found" picker interrupting a launch. The
# sandbox test in Invoke-ClaudeCMTests.ps1 proves the logic; this proves the
# live state on this machine, which is the thing he actually sees.
#
# Read-only: Read-Host is replaced with a throw, so nothing can be selected or
# quarantined even if the picker were to fire.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$module = "$env:USERPROFILE\.claudecm\claudecm-powershell.ps1"
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count) { throw "deployed module does not parse: $($errors[0].Message)" }
$src = @{}
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($fn.Name -ne 'claudecm') { $src[$fn.Name] = $fn.Extent.Text }
}

$cmDir = "$env:USERPROFILE\.claudecm"
$sessionsFile = "$cmDir\sessions.txt"
$quarantineRoot = "$env:USERPROFILE\documents\github\claude-conversation-backup"
foreach ($n in @('Get-ProjectKey','Parse-SessionLine','Get-Sessions','Get-ArchivedSessions','Sync-SessionIndex','Do-OrphanScan')) {
    if (-not $src.ContainsKey($n)) { throw "deployed module has no $n" }
    . ([scriptblock]::Create($src[$n]))
}
function Read-Host { param([string]$Prompt) throw 'PICKER FIRED: Do-OrphanScan prompted' }

$fail = 0
foreach ($row in (Get-Sessions)) {
    $key = Get-ProjectKey $row.Dir
    $keyDir = "$env:USERPROFILE\.claude\projects\$key"
    if (-not (Test-Path $keyDir)) { continue }
    $n = @(Get-ChildItem "$keyDir\*.jsonl" -ErrorAction SilentlyContinue).Count
    if ($n -le 1) { continue }
    try {
        $r = Do-OrphanScan $row.Dir $row.Guid
        if ($null -ne $r) { Write-Output ("UNEXPECTED  {0}: returned a result" -f $row.Desc); $fail++ }
        else { Write-Output ("silent      {0}  ({1} transcripts)" -f $row.Desc, $n) }
    } catch {
        Write-Output ("PICKER      {0}  ({1} transcripts) <-- would interrupt the launch" -f $row.Desc, $n)
        $fail++
    }
}
Write-Output ''
if ($fail -eq 0) { Write-Output 'PASS: no registered project raises the orphan picker.' }
else { Write-Output "FAIL: $fail project(s) would raise the picker." }
