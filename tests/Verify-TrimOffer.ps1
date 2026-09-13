# Run the DEPLOYED Offer-Trim against a REAL cmv benchmark and show exactly
# what the operator will see at exit. Read-Host is replaced with a throw, so
# if it decides to ask, this fails loudly instead of hanging.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$module = "$env:USERPROFILE\.claudecm\claudecm-powershell.ps1"
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($module, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count) { throw "deployed module does not parse" }
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($fn.Name -eq 'Offer-Trim') { . ([scriptblock]::Create($fn.Extent.Text)) }
}
function Read-Host { param([string]$Prompt) throw "ASKED: $Prompt" }

$cmvExe = "$env:APPDATA\npm\cmv.cmd"
foreach ($sid in $args) {
    Write-Output ""
    Write-Output ("=== {0} ===" -f $sid.Substring(0, 8))
    $script:exitBench = (& $cmvExe benchmark -s $sid --json 2>&1 | Out-String) | ConvertFrom-Json
    try { Offer-Trim $sid } catch { Write-Output "  PROMPTED: $($_.Exception.Message)" }
}
