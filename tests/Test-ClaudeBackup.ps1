# Does the .claude backup hold what cannot be reconstructed, and leave out what
# can? Run after any change to Backup-GitHubFiles.ps1.
#
# Three separate failures on 2026-09-10 say why this exists as a test rather
# than as a glance at the file size:
#   1. the first zip was of entirely the WRONG directory, because
#      Documents\GitHub\.claude already exists and the two collided on name.
#      It looked plausible at 0.4 KB.
#   2. excluding `*.jsonl` also removed hooks\worklog\prompts.jsonl, the record
#      that lets an older authorisation still be verified.
#   3. the first version of THIS check reported a clean zero while 964 subagent
#      transcripts sat in the zip, because it only knew one filename shape.
#      A false all-clear from the instrument itself.
#
# Hence two independent measurements: named contents, and total size.
$z = 'F:\Backups\GitHubFiles\dot-claude-config.zip'
if (-not (Test-Path $z)) {
    Write-Output "SKIP: no backup at $z. Run Backup-GitHubFiles.ps1 first."
    exit 0
}
$list = & 'C:\Program Files\7-Zip\7z.exe' l $z 2>&1 | Out-String

$mustHave = @(
    'CLAUDE.md',
    'casebook.md',
    'agreement.md',
    'WORKING-AGREEMENT.md',
    'settings.json',
    'hooks\guard-worklog.py',
    'hooks\lib_agreement.py',
    'hooks\worklog\worklog.md',
    'memory\MEMORY.md',
    'hooks\worklog\prompts.jsonl'
)
$mustNotHave = @('.cmv-trim-tmp', 'file-history', 'shell-snapshots')

$bad = 0
Write-Output "must be present:"
foreach ($m in $mustHave) {
    $hit = $list -like "*$m*"
    if (-not $hit) { $bad++ }
    Write-Output ("  {0,-9} {1}" -f $(if ($hit) { 'ok' } else { '**MISSING**' }), $m)
}
Write-Output "must be absent:"
foreach ($m in $mustNotHave) {
    $hit = $list -like "*$m*"
    if ($hit) { $bad++ }
    Write-Output ("  {0,-9} {1}" -f $(if ($hit) { '**PRESENT**' } else { 'ok' }), $m)
}

# How many memory files came across? That is the irreplaceable part.
$mem = ([regex]::Matches($list, [regex]::Escape('\memory\'))).Count

# COUNT EVERY .jsonl EXCEPT THE ONE THAT BELONGS, not just GUID-shaped names.
# The first version of this check looked only for the GUID shape and reported a
# clean zero while 964 subagent transcripts named agent-*.jsonl sat in the zip,
# 630 MB of them. A false all-clear from an instrument that only knew one shape.
# Both transcript shapes, named explicitly. A GUID-named file is a session; an
# agent-named one is a subagent. Everything else ending .jsonl is small and
# wanted: prompts.jsonl is the citation history, history.jsonl is Bob's own
# typed command history, and jobs\*\timeline.jsonl is a few KB.
$guid = ([regex]::Matches($list, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl\b')).Count
$agent = ([regex]::Matches($list, 'agent-[0-9a-f]+\.jsonl\b')).Count
Write-Output ""
Write-Output ("session transcripts (must be 0): {0}" -f $guid)
Write-Output ("subagent transcripts (must be 0): {0}" -f $agent)
if ($guid -gt 0 -or $agent -gt 0) { $bad++ }

# Size is the second, independent measurement. Config plus memory is tens of MB;
# anything near a gigabyte means transcript debris got back in.
$mb = [math]::Round((Get-Item $z).Length / 1MB, 0)
Write-Output ("zip size: {0} MB" -f $mb)
if ($mb -gt 200) { Write-Output "  **TOO BIG**: debris is back"; $bad++ }

Write-Output ("memory files captured: {0}" -f $mem)
if ($mem -lt 50) { Write-Output "  **SUSPICIOUS**: expected dozens across all projects"; $bad++ }
Write-Output ("problems: {0}" -f $bad)
exit $(if ($bad) { 1 } else { 0 })
