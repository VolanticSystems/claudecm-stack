# cmv-stub.ps1 - stands in for the cmv binary inside the test suite.
#
# Do-Trim shells out to `cmv trim -s <guid> --skip-launch` and parses one thing
# out of the output: a line matching `Session ID: <guid>`. Everything after
# that is ClaudeCM's own work, which is the part worth testing. cmv itself is
# somebody else's program.
#
# Do-PostExit also calls `cmv snapshot` and `cmv benchmark -s <guid> --json`,
# so those verbs are handled too.
#
# Driven by environment variables:
#
#   CLAUDECM_CMV_NEWGUID    the GUID `trim` should claim it created. Required
#                           for the trim path; if unset, trim prints no
#                           Session ID line, which is how a failed trim looks.
#   CLAUDECM_CMV_WRITEDIR   directory to write <newguid>.jsonl into. Omit to
#                           simulate cmv claiming success without producing a
#                           file, which Do-Trim is supposed to report loudly.
#   CLAUDECM_CMV_TOKENS     preTrimTokens value for `benchmark --json`.
#   CLAUDECM_CMV_LEAVETMP   if set, drop a <name>.cmv-trim-tmp file in
#                           WRITEDIR, so the post-trim cleanup has something
#                           real to clean.

$verb = if ($args.Count -gt 0) { [string]$args[0] } else { '' }

switch ($verb) {
    'trim' {
        $new = $env:CLAUDECM_CMV_NEWGUID
        $dir = $env:CLAUDECM_CMV_WRITEDIR
        if ($env:CLAUDECM_CMV_LEAVETMP -and $dir) {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -LiteralPath (Join-Path $dir 'leftover.cmv-trim-tmp') -Value 'x' -Encoding UTF8
        }
        if (-not $new) {
            Write-Output 'trim failed: nothing to do'
            exit 0
        }
        if ($dir) {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -LiteralPath (Join-Path $dir "$new.jsonl") `
                -Value '{"type":"user","message":{"role":"user","content":"trimmed"}}' -Encoding UTF8
        }
        Write-Output "Trim complete."
        Write-Output "Session ID: $new"
        exit 0
    }
    'benchmark' {
        $tok = if ($env:CLAUDECM_CMV_TOKENS) { $env:CLAUDECM_CMV_TOKENS } else { '12345' }
        Write-Output ('{"preTrimTokens": ' + $tok + '}')
        exit 0
    }
    'snapshot' { Write-Output 'snapshot ok'; exit 0 }
    default    { Write-Output "cmv-stub: unhandled verb '$verb'"; exit 0 }
}
