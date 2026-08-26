#!/usr/bin/env bash
# claude-stub.sh - stands in for the claude binary inside the bash test suite.
#
# Same contract as stubs/claude-stub.ps1. The real binary is interactive and
# spends subscription time; for a test only two observable things matter:
# whether a new <GUID>.jsonl appeared in the project key directory, and what
# exit code came back.
#
# Every real argument is accepted and ignored. Behaviour comes from the
# environment:
#
#   CLAUDECM_STUB_PROJDIR   directory to write the transcript into
#   CLAUDECM_STUB_GUID      GUID to create. 'none', or unset, writes nothing,
#                           which is what a launch looks like when the user
#                           bails at the splash screen.
#   CLAUDECM_STUB_EXIT      exit code to return, default 0. Non-zero simulates
#                           Ctrl-C, a closed window, or a crash; spec 14.4 says
#                           detection must still work.

projdir="${CLAUDECM_STUB_PROJDIR:-}"
guid="${CLAUDECM_STUB_GUID:-none}"
code="${CLAUDECM_STUB_EXIT:-0}"

if [[ -n "$projdir" && "$guid" != "none" ]]; then
    mkdir -p "$projdir"
    {
        printf '{"type":"user","sessionId":"%s","message":{"role":"user","content":"hello"}}\n' "$guid"
        printf '{"type":"assistant","sessionId":"%s","message":{"role":"assistant","content":"hi"}}\n' "$guid"
    } > "$projdir/$guid.jsonl"
fi

exit "$code"
