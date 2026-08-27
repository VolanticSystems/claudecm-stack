#!/usr/bin/env bash
# cmv-stub.sh - stands in for the cmv binary inside the bash test suite.
# Same contract as stubs/cmv-stub.ps1.
#
#   CLAUDECM_CMV_NEWGUID    GUID that `trim` claims it created. Unset means the
#                           trim printed no Session ID line, i.e. it failed.
#   CLAUDECM_CMV_WRITEDIR   where to write <newguid>.jsonl. Omit to simulate cmv
#                           claiming success without producing a file.
#   CLAUDECM_CMV_TOKENS     preTrimTokens for `benchmark --json`.

verb="${1:-}"

case "$verb" in
    trim)
        new="${CLAUDECM_CMV_NEWGUID:-}"
        dir="${CLAUDECM_CMV_WRITEDIR:-}"
        if [[ -z "$new" ]]; then
            echo "trim failed: nothing to do"
            exit 0
        fi
        if [[ -n "$dir" ]]; then
            mkdir -p "$dir"
            printf '{"type":"user","message":{"role":"user","content":"trimmed"}}\n' > "$dir/$new.jsonl"
        fi
        echo "Trim complete."
        echo "Session ID: $new"
        ;;
    benchmark)
        printf '{"preTrimTokens": %s}\n' "${CLAUDECM_CMV_TOKENS:-12345}"
        ;;
    snapshot)
        echo "snapshot ok"
        ;;
    *)
        echo "cmv-stub: unhandled verb '$verb'"
        ;;
esac
exit 0
