# claude-stub.ps1 - stands in for claude.exe inside the test suite.
#
# The real binary is interactive, spends subscription time, and writes a
# transcript. For a test we only care about the two things ClaudeCM actually
# observes afterwards: whether a new <GUID>.jsonl appeared in the project key
# directory, and what exit code came back.
#
# Driven entirely by environment variables so the caller does not have to
# match the real CLI's argument shape. Every real argument is accepted and
# ignored.
#
#   CLAUDECM_STUB_PROJDIR   directory to write the transcript into (required)
#   CLAUDECM_STUB_GUID      GUID to create. 'none' writes nothing, which
#                           simulates a launch that died before the transcript
#                           was created.
#   CLAUDECM_STUB_EXIT      exit code to return. Defaults to 0. Use a non-zero
#                           value to simulate Ctrl-C, a closed window, or a
#                           crash: spec 14.4 says detection must still work.
#   CLAUDECM_STUB_TAIL      'exit' appends a trailing /exit command block, so
#                           Test-CleanExitTail sees a clean exit.

$projDir = $env:CLAUDECM_STUB_PROJDIR
$guid    = $env:CLAUDECM_STUB_GUID
$exit    = $env:CLAUDECM_STUB_EXIT
$tail    = $env:CLAUDECM_STUB_TAIL

if ($projDir -and $guid -and $guid -ne 'none') {
    if (-not (Test-Path $projDir)) { New-Item -ItemType Directory -Path $projDir -Force | Out-Null }
    $path = Join-Path $projDir "$guid.jsonl"
    $lines = @(
        (@{ type = 'user';      sessionId = $guid; timestamp = '2026-08-27T10:00:00.000Z'
            message = @{ role = 'user';      content = 'hello' } } | ConvertTo-Json -Compress -Depth 6)
        (@{ type = 'assistant'; sessionId = $guid; timestamp = '2026-08-27T10:00:01.000Z'
            message = @{ role = 'assistant'; content = 'hi';   model = 'claude-opus-5' } } | ConvertTo-Json -Compress -Depth 6)
    )
    if ($tail -eq 'exit') {
        $lines += (@{ type = 'user'; sessionId = $guid; timestamp = '2026-08-27T10:00:02.000Z'
            message = @{ role = 'user'
                content = '<command-name>/exit</command-name>' } } | ConvertTo-Json -Compress -Depth 6)
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
}

if ($exit) { exit [int]$exit }
exit 0
