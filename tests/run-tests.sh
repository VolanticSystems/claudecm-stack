#!/usr/bin/env bash
# run-tests.sh - first test suite for claudecm-linux.sh
#
# The bash module is easier to test than its PowerShell twin: every __cm_*
# function is defined at top level and the file ends with the standard
# BASH_SOURCE guard, so sourcing it exposes all 42 functions without running
# anything. No extraction is needed.
#
# EVERY TEST CARRIES ITS SABOTAGE. The project's rule is that if you cannot
# name the edit to the product that makes a test fail, you are not writing a
# test. Here that is executed rather than trusted: each test declares a sed
# mutation of the module, and the harness runs the test twice, once against
# the clean module (must PASS) and once against the mutated copy (must FAIL).
# A test that still passes under its own sabotage is reported HOLLOW, which
# is a failure of the suite, not of the product.
#
# Nothing here touches real state. HOME is repointed at a sandbox before the
# module is sourced, because the module computes its paths from $HOME at
# source time.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${MODULE:-$SCRIPT_DIR/../claudecm-linux.sh}"

# Git Bash ships no flock, so __cm_acquire_lock spins its full 10-second retry
# on EVERY sessions.txt write and the suite becomes unusable. Real Linux has it
# from util-linux, which the module lists as a dependency, so this shim is only
# ever reached on a box that is missing it. Announced rather than silent,
# because "no flock" is itself worth knowing about a machine.
if ! command -v flock >/dev/null 2>&1; then
    echo "  note: no flock on PATH; using tests/stubs/flock so writes do not stall 10s each."
    echo "        Real Linux has flock (util-linux). Contention is NOT covered by this suite."
    chmod +x "$SCRIPT_DIR/stubs/flock" 2>/dev/null
    PATH="$SCRIPT_DIR/stubs:$PATH"
    export PATH
fi

if [[ ! -f "$MODULE" ]]; then
    echo "  module not found: $MODULE" >&2
    exit 2
fi

PASS=0; FAIL=0; HOLLOW=0; STALE=0; ERROR=0; INCONC=0
RESULTS=()

# ------------------------------------------------------------------ sandbox

new_sandbox() {
    local root
    root="$(mktemp -d "${TMPDIR:-/tmp}/claudecm-sh-XXXXXX")"
    mkdir -p "$root/.claudecm/backup" "$root/.claude/projects"
    # spec section 4: bootstrap creates sessions.txt if missing, so every
    # function downstream may assume it exists
    : > "$root/.claudecm/sessions.txt"
    printf '%s' "$root"
}

# Runs one test body against the module, optionally sabotaged.
# $1 = body function name, $2 = sed expression ('' for clean)
# returns 0 if the body succeeded, 1 if it failed, 3 if the anchor was missing
run_in_module() {
    local body="$1" sed_expr="${2:-}"
    local sandbox mod rc
    sandbox="$(new_sandbox)"
    mod="$sandbox/module-under-test.sh"

    if [[ -n "$sed_expr" ]]; then
        sed "$sed_expr" "$MODULE" > "$mod"
        # a sabotage that changes nothing is a stale sabotage, not a passing test
        if cmp -s "$MODULE" "$mod"; then
            rm -rf "$sandbox"
            return 3
        fi
    else
        cp "$MODULE" "$mod"
    fi

    # "Deleting the file or making it unparseable does not count: an error is
    # not a red assertion." Bash hides this better than PowerShell does: if the
    # module fails to source, no __cm_* function exists, every call inside
    # $( ) degrades to an EMPTY STRING rather than an error, and the assertion
    # then goes red for entirely the wrong reason. That scored PASS until this
    # check existed, proven with a deliberately broken sabotage.
    if ! bash -n "$mod" 2>/dev/null; then
        rm -rf "$sandbox"
        return 91
    fi

    if [[ -n "$sed_expr" ]]; then
        # sabotage pass: the body is EXPECTED to fail, so its diagnostics are
        # not findings and would read as errors. Suppress them.
        (
            # SEAM FIDELITY: this harness runs under `set -uo pipefail` to catch
            # its own bugs, and a subshell inherits that. The product sets
            # neither, so without this the module executes under semantics
            # production does not have and an unset variable becomes a fatal
            # error that would never fire for Bob. Same class of defect as
            # StrictMode leaking into the PowerShell harness.
            set +u +o pipefail
            export HOME="$sandbox"
            export __CM_TEST_MODULE="$mod"
            # shellcheck disable=SC1090
            source "$mod" >/dev/null 2>&1
            declare -F __cm_get_sessions >/dev/null 2>&1 || exit 91
            "$body"
        ) >/dev/null 2>&1
    else
        (
            set +u +o pipefail   # seam fidelity; see the sabotage pass above
            export HOME="$sandbox"
            export __CM_TEST_MODULE="$mod"
            # shellcheck disable=SC1090
            source "$mod" >/dev/null 2>&1
            declare -F __cm_get_sessions >/dev/null 2>&1 || exit 91
            "$body"
        )
    fi
    rc=$?
    rm -rf "$sandbox"
    return $rc
}

assert_eq() {
    # ordinal string comparison; bash == on strings is byte-exact already
    local expected="$1" actual="$2" because="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "           $because" >&2
        echo "             expected: [$expected]" >&2
        echo "             actual:   [$actual]" >&2
        return 90
    fi
    return 0
}

assert_true() {
    local cond="$1" because="$2"
    if [[ "$cond" != "0" ]]; then
        echo "           $because" >&2
        return 90
    fi
    return 0
}

test_case() {
    local name="$1" sabotage="$2" sed_expr="$3" body="$4"
    if [[ -n "${ONLY:-}" && "$name" != *"$ONLY"* ]]; then return 0; fi

    local clean_rc sab_rc verdict
    run_in_module "$body" ""; clean_rc=$?
    run_in_module "$body" "$sed_expr"; sab_rc=$?

    # 90 means an assertion evaluated and went red. Anything else non-zero is
    # the module or the harness falling over, which proves NOTHING about
    # whether this test can fail. The doctrine is explicit: an error is not a
    # red assertion, and treating one as the other is the escape hatch every
    # hollow test reaches for.
    if [[ $clean_rc -eq 90 ]]; then
        verdict="FAIL"; FAIL=$((FAIL+1))
    elif [[ $clean_rc -ne 0 ]]; then
        verdict="ERROR"; ERROR=$((ERROR+1))
    elif [[ $sab_rc -eq 3 ]]; then
        verdict="STALE"; STALE=$((STALE+1))
    elif [[ $sab_rc -eq 0 ]]; then
        verdict="HOLLOW"; HOLLOW=$((HOLLOW+1))
    elif [[ $sab_rc -eq 90 ]]; then
        verdict="PASS"; PASS=$((PASS+1))
    else
        verdict="INCONC"; INCONC=$((INCONC+1))
    fi

    printf '  %-7s %s
' "$verdict" "$name"
    case "$verdict" in
        HOLLOW) echo "           passed WITH its sabotage applied. It cannot fail. Fix the test." ;;
        STALE)  echo "           the sabotage anchor no longer matches the product. Update the mutation." ;;
        INCONC) echo "           the sabotage produced an error, not a red assertion. Move the"
                echo "           sabotage onto the path the assertion actually walks." ;;
        ERROR)  echo "           the CLEAN run fell over with a non-assertion error." ;;
    esac
}

# =============================================================================
# TIER 1 - pure transformations
# =============================================================================

t_tokens_millions() {
    assert_eq "1.2M tok" "$(__cm_format_tokens 1234567)" "spec 7 requires 1.2M tok"
}

t_tokens_thousands() {
    assert_eq "155K tok" "$(__cm_format_tokens 155000)" "spec 7 requires 155K tok"
}

t_tokens_empty() {
    assert_eq "--" "$(__cm_format_tokens '')" "spec 7: empty means never measured, not zero"
}

t_size_mb() {
    assert_eq "1.5 MB" "$(__cm_format_size 1572864)" "spec 7 requires 1.5 MB"
}

t_projkey_dots() {
    assert_eq "C--Users-alice-Documents-GitHub-WPF-Connector-Thing" \
        "$(__cm_get_proj_key 'C:\Users\alice\Documents\GitHub\WPF-Connector.Thing')" \
        "spec 6 requires dots to become hyphens too"
}

t_projkey_posix() {
    assert_eq "-home-user-projects-foo" "$(__cm_get_proj_key '/home/user/projects/foo')" \
        "spec 6 worked example"
}

# =============================================================================
# TIER 2 - state on disk
# =============================================================================

t_parse_four_fields() {
    __cm_parse_line 'abc-123|/home/u/proj|My Session|91587'
    assert_eq "My Session" "$__cm_desc" "DESC must not absorb the token field" || return 90
    assert_eq "91587" "$__cm_t" "TOKENS must be its own field"
}

t_parse_desc_with_spaces() {
    # paths on Bob's machine include 'NinjaTrader 8'; unquoted expansion here
    # would split the field
    __cm_parse_line 'g|/mnt/NinjaTrader 8/bin|NinjaTrader custom indicators|'
    assert_eq "/mnt/NinjaTrader 8/bin" "$__cm_d" "a DIR containing spaces must survive parsing" || return 90
    assert_eq "NinjaTrader custom indicators" "$__cm_desc" "a DESC containing spaces must survive parsing"
}

t_write_atomic_no_tmp() {
    printf 'g|d|desc|1\n' | __cm_write_atomic
    assert_true "$([[ -f "$__cm_sessions_file" ]] && echo 0 || echo 1)" \
        "sessions.txt must exist after write" || return 90
    assert_true "$([[ ! -f "$__cm_tmp_file" ]] && echo 0 || echo 1)" \
        "spec 5.1 step 3: the temp file must be RENAMED over the target, not copied"
}

t_get_sessions_skips_blanks() {
    printf 'a|d|One|1\n\nb|d|Two|2\n   \n' > "$__cm_sessions_file"
    local n
    n="$(__cm_get_sessions | wc -l | tr -d ' ')"
    assert_eq "2" "$n" "spec 5: empty lines are ignored on read"
}

t_get_sessions_stops_at_archived() {
    printf 'a|d|One|1\nb|d|Two|2\n[archived]\nc|d|Old|3\n' > "$__cm_sessions_file"
    local n
    n="$(__cm_get_sessions | wc -l | tr -d ' ')"
    assert_eq "2" "$n" "spec 5: the [archived] marker ends the main section"
}

# =============================================================================
# TIER 2b - whole-module integration, through the claudecm entry point.
# =============================================================================

_seed_sessions() {
    printf 'desktop\n' > "$__cm_machine_name_file"
    cat > "$__cm_sessions_file" <<'ROWS'
aaa|/tmp/p1|Claude Context Manager|441961
bbb|/tmp/p2|Router|195046
ccc|/tmp/p3|Mozz AI|216263
ddd|/tmp/p4|context switching notes|1000
eee|/tmp/p5|Zoom Dom|300943
ROWS
}

t_search_filters() {
    _seed_sessions
    local out
    out="$(printf 'q\n' | claudecm -s context 2>&1)"
    [[ "$out" == *"Claude Context Manager"* ]]  || { echo "           a mid-name match must be found" >&2; return 90; }
    [[ "$out" == *"context switching notes"* ]] || { echo "           a start-of-name match must be found" >&2; return 90; }
    [[ "$out" != *"Zoom Dom"* ]]                || { echo "           a non-matching session must not be listed" >&2; return 90; }
    [[ "$out" == *"2 of 5"* ]]                  || { echo "           the count line must report matches out of total" >&2; return 90; }
    return 0
}

t_search_no_new_project() {
    _seed_sessions
    local out
    out="$(claudecm -s zzzznotarealproject 2>&1)"
    [[ "$out" == *"No sessions matching"* ]]   || { echo "           a search with no hits must say so" >&2; return 90; }
    [[ "$out" != *"Create a NEW project"* ]]   || { echo "           search mode must never offer to create a project" >&2; return 90; }
    return 0
}

t_search_leaves_sessions_intact() {
    _seed_sessions
    local before after
    before="$(cat "$__cm_sessions_file")"
    printf 'q\n' | claudecm -s context >/dev/null 2>&1
    after="$(cat "$__cm_sessions_file")"
    [[ "$before" == "$after" ]] || { echo "           search must not rewrite sessions.txt" >&2; return 90; }
    return 0
}

# =============================================================================
# TIER 3 - behaviours that spawn a child process.
#
# __cm_resolve_claude is OVERRIDDEN rather than relying on PATH order. Its real
# implementation looks for `claude` on PATH first, which on this machine finds
# the genuine binary. A test that launched that would spend subscription time
# and write into the real project tree.
# =============================================================================

_use_claude_stub() {
    # NOT `local stub=...`. bash scopes a local to the CALL, and this override
    # runs later, from inside __cm_invoke_claude_launch, by which time the
    # local is gone and $claude_exe resolves to the empty string. That failure
    # is near-invisible: the launch silently does nothing, which for a test
    # asserting "no transcript was produced" looks exactly like success.
    __CM_TEST_STUB="$SCRIPT_DIR/stubs/claude-stub.sh"
    chmod +x "$__CM_TEST_STUB" 2>/dev/null
    __cm_resolve_claude() { printf '%s\n' "$__CM_TEST_STUB"; }
    # Prove the override actually resolves, so a broken stub can never be
    # mistaken for a launch that legitimately produced nothing.
    [[ -x "$(__cm_resolve_claude)" ]] || { echo "           stub not executable" >&2; return 90; }
}

t_launch_bail_adopts_nothing() {
    # The user starts a new session and quits at the splash screen, so no
    # transcript is ever written. An unrelated conversation already exists in
    # the same project key directory.
    local projdir="$HOME/proj"; mkdir -p "$projdir"
    local pk pd; pk=$(__cm_get_proj_key "$projdir"); pd="$HOME/.claude/projects/$pk"
    mkdir -p "$pd"
    local victim="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    printf '{"type":"user"}\n' > "$pd/$victim.jsonl"

    _use_claude_stub || return 90
    export CLAUDECM_STUB_PROJDIR="$pd"
    export CLAUDECM_STUB_GUID="none"     # launch produces no transcript
    __cm_invoke_claude_launch "$projdir" -- --dangerously-skip-permissions
    unset CLAUDECM_STUB_PROJDIR CLAUDECM_STUB_GUID

    # spec 11.6.2 single-source rule: with nothing new on disk the answer is
    # "no session", never "the newest file that happens to be lying there".
    assert_eq "" "${__cm_launch_sid:-}" \
        "a launch that produced no transcript must adopt NOTHING; adopting the newest existing file registers somebody else's conversation under this session's name"
}

t_launch_detects_after_nonzero_exit() {
    local projdir="$HOME/proj2"; mkdir -p "$projdir"
    local pk pd; pk=$(__cm_get_proj_key "$projdir"); pd="$HOME/.claude/projects/$pk"
    mkdir -p "$pd"
    local newguid="99999999-8888-7777-6666-555555555555"

    _use_claude_stub || return 90
    export CLAUDECM_STUB_PROJDIR="$pd"
    export CLAUDECM_STUB_GUID="$newguid"
    export CLAUDECM_STUB_EXIT="130"      # Ctrl-C
    __cm_invoke_claude_launch "$projdir" -- --dangerously-skip-permissions
    unset CLAUDECM_STUB_PROJDIR CLAUDECM_STUB_GUID CLAUDECM_STUB_EXIT

    assert_eq "$newguid" "${__cm_launch_sid:-}" \
        "spec 14.4: detection must run regardless of the child exit code" || return 90
    assert_eq "130" "${__cm_launch_exit:-}" "the exit code itself must still be reported"
}

_use_cmv_stub() {
    __CM_TEST_CMV="$SCRIPT_DIR/stubs/cmv-stub.sh"
    chmod +x "$__CM_TEST_CMV" 2>/dev/null
    __cm_resolve_cmv() { printf '%s\n' "$__CM_TEST_CMV"; }
    [[ -x "$(__cm_resolve_cmv)" ]] || { echo "           cmv stub not executable" >&2; return 90; }
}

# Builds a project dir plus its key dir, and echoes the key dir.
_mk_project() {
    local name="$1" projdir="$HOME/$1" pk pd
    mkdir -p "$projdir"
    pk=$(__cm_get_proj_key "$projdir"); pd="$HOME/.claude/projects/$pk"
    mkdir -p "$pd"
    printf '%s\n' "$pd"
}

t_trim_files_pretrim() {
    _use_cmv_stub || return 90
    local pd; pd=$(_mk_project trimproj)
    local old="11111111-1111-1111-1111-111111111111"
    local new="22222222-2222-2222-2222-222222222222"
    printf '{}\n' > "$pd/$old.jsonl"
    printf '%s|%s|Trim Me|500\n' "$old" "$HOME/trimproj" > "$__cm_sessions_file"

    export CLAUDECM_CMV_NEWGUID="$new" CLAUDECM_CMV_WRITEDIR="$pd"
    __cm_do_trim "$old" >/dev/null 2>&1
    unset CLAUDECM_CMV_NEWGUID CLAUDECM_CMV_WRITEDIR

    # cmv trim creates a NEW session and leaves the original unreferenced. Not
    # filing it away is what caused the April 2026 orphan accumulation.
    assert_true "$([[ ! -f "$pd/$old.jsonl" ]] && echo 0 || echo 1)" \
        "the pre-trim transcript must not be left in the project key directory" || return 90
    assert_true "$([[ -f "$__cm_backup_dir/trimproj/$old.jsonl" ]] && echo 0 || echo 1)" \
        "spec 11.13 step 11: the pre-trim transcript must be moved to the backup"
}

t_trim_swaps_guid() {
    _use_cmv_stub || return 90
    local pd; pd=$(_mk_project trimproj2)
    local old="33333333-3333-3333-3333-333333333333"
    local new="44444444-4444-4444-4444-444444444444"
    printf '{}\n' > "$pd/$old.jsonl"
    printf '%s|%s|Keep My Name|500\n' "$old" "$HOME/trimproj2" > "$__cm_sessions_file"

    export CLAUDECM_CMV_NEWGUID="$new" CLAUDECM_CMV_WRITEDIR="$pd"
    __cm_do_trim "$old" >/dev/null 2>&1
    unset CLAUDECM_CMV_NEWGUID CLAUDECM_CMV_WRITEDIR

    local rows; rows=$(__cm_get_sessions | wc -l | tr -d ' ')
    assert_eq "1" "$rows" "trim must not add or drop a row" || return 90
    local first; first=$(__cm_get_sessions | head -1)
    assert_true "$([[ "$first" == "$new|"* ]] && echo 0 || echo 1)" \
        "the row must point at the trimmed transcript, or the session is unreachable" || return 90
    assert_true "$([[ "$first" == *"Keep My Name"* ]] && echo 0 || echo 1)" \
        "the session name must survive a trim"
}

t_fork_followed_and_predecessor_filed() {
    _use_claude_stub || return 90
    local pd; pd=$(_mk_project forkproj)
    local orig="55555555-5555-5555-5555-555555555555"
    local fork="66666666-6666-6666-6666-666666666666"
    printf '{}\n' > "$pd/$orig.jsonl"
    printf '%s|%s|Forked Session|900\n' "$orig" "$HOME/forkproj" > "$__cm_sessions_file"

    export CLAUDECM_STUB_PROJDIR="$pd" CLAUDECM_STUB_GUID="$fork"
    __cm_invoke_resume_with_fork_detection "$orig" "$HOME/forkproj" "machine - Forked Session" >/dev/null 2>&1
    unset CLAUDECM_STUB_PROJDIR CLAUDECM_STUB_GUID

    local first; first=$(__cm_get_sessions | head -1)
    assert_true "$([[ "$first" == "$fork|"* ]] && echo 0 || echo 1)" \
        "sessions.txt must follow the fork, or the live conversation is unreachable" || return 90
    assert_eq "$fork" "${__cm_resume_effective_guid:-}" "the caller must be told which GUID is now live" || return 90
    assert_true "$([[ ! -f "$pd/$orig.jsonl" ]] && echo 0 || echo 1)" \
        "spec 11.6.1 step 4: the predecessor must be filed away or it becomes a spurious orphan"
}

t_plain_resume_changes_nothing() {
    _use_claude_stub || return 90
    local pd; pd=$(_mk_project plainproj)
    local orig="77777777-7777-7777-7777-777777777777"
    printf '{}\n' > "$pd/$orig.jsonl"
    printf '%s|%s|Plain Resume|900\n' "$orig" "$HOME/plainproj" > "$__cm_sessions_file"

    export CLAUDECM_STUB_PROJDIR="$pd" CLAUDECM_STUB_GUID="none"
    __cm_invoke_resume_with_fork_detection "$orig" "$HOME/plainproj" "machine - Plain Resume" >/dev/null 2>&1
    unset CLAUDECM_STUB_PROJDIR CLAUDECM_STUB_GUID

    # The ordinary case, which is almost every resume. Getting this wrong files
    # away the very session the operator is sitting in.
    assert_true "$([[ -f "$pd/$orig.jsonl" ]] && echo 0 || echo 1)" \
        "an ordinary resume must NOT file away the transcript still in use" || return 90
    local first; first=$(__cm_get_sessions | head -1)
    assert_true "$([[ "$first" == "$orig|"* ]] && echo 0 || echo 1)" \
        "an ordinary resume must leave the registered GUID alone" || return 90
    assert_true "$([[ "$first" == *"|900" ]] && echo 0 || echo 1)" \
        "an ordinary resume must not reset the token count"
}

t_sync_index_drops_missing() {
    # __cm_sync_session_index shells out to node. Without it the function
    # returns silently and this project has no index sync at all, which is
    # worth failing loudly about rather than passing quietly.
    command -v node >/dev/null 2>&1 || {
        echo "           node not found: __cm_sync_session_index cannot run on this box at all" >&2
        return 90
    }
    local pd; pd=$(_mk_project idxproj)
    local ondisk="a1a1a1a1-b2b2-c3c3-d4d4-e5e5e5e5e5e5"
    local gone="f6f6f6f6-0000-1111-2222-333333333333"
    printf '{"type":"user"}\n' > "$pd/$ondisk.jsonl"
    # THE ORACLE IS HAND-BUILT. Regenerating it by calling the same function
    # would agree with itself no matter what it did.
    cat > "$pd/sessions-index.json" <<JSON
{"version":1,"originalPath":"$HOME/idxproj","entries":[
 {"sessionId":"$gone","fullPath":"$pd/$gone.jsonl","fileMtime":0,"firstPrompt":"Gone","messageCount":5,
  "created":"2026-01-01T00:00:00.000Z","modified":"2026-01-01T00:00:00.000Z","gitBranch":"","projectPath":"$HOME/idxproj","isSidechain":false},
 {"sessionId":"$ondisk","fullPath":"$pd/$ondisk.jsonl","fileMtime":0,"firstPrompt":"Here","messageCount":5,
  "created":"2026-01-01T00:00:00.000Z","modified":"2026-01-01T00:00:00.000Z","gitBranch":"","projectPath":"$HOME/idxproj","isSidechain":false}
]}
JSON
    __cm_sync_session_index "$HOME/idxproj" >/dev/null 2>&1

    local body; body=$(cat "$pd/sessions-index.json")
    assert_true "$([[ "$body" == *"$ondisk"* ]] && echo 0 || echo 1)" \
        "a transcript that exists must keep its entry" || return 90
    assert_true "$([[ "$body" != *"$gone"* ]] && echo 0 || echo 1)" \
        "spec 10 step 6: an entry whose transcript is gone must be dropped, or the resume picker offers a session that cannot open"
}

t_sync_index_names_registered() {
    command -v node >/dev/null 2>&1 || {
        echo "           node not found: __cm_sync_session_index cannot run on this box at all" >&2
        return 90
    }
    local pd; pd=$(_mk_project namedproj)
    local guid="b7b7b7b7-1111-2222-3333-444444444444"
    printf '{"type":"user"}\n' > "$pd/$guid.jsonl"
    printf '%s|%s|My Named Session|42\n' "$guid" "$HOME/namedproj" > "$__cm_sessions_file"

    __cm_sync_session_index "$HOME/namedproj" >/dev/null 2>&1

    local body; body=$(cat "$pd/sessions-index.json")
    assert_true "$([[ "$body" == *"My Named Session"* ]] && echo 0 || echo 1)" \
        "spec 10 step 7: a registered session carries its sessions.txt name into the index"
}

t_format_date_short_year() {
    local this_yr last_yr
    this_yr=$(date +%Y)
    last_yr=$(( this_yr - 1 ))
    assert_eq "Mar 13" "$(__cm_format_date_short "$(date -d "$this_yr-03-13" +%s 2>/dev/null || date -j -f %Y-%m-%d "$this_yr-03-13" +%s)")" \
        "spec 7: the current year is implied and omitted" || return 90
    assert_eq "Mar 13, $last_yr" "$(__cm_format_date_short "$(date -d "$last_yr-03-13" +%s 2>/dev/null || date -j -f %Y-%m-%d "$last_yr-03-13" +%s)")" \
        "spec 7: an older session must show its year, or two rows a year apart look identical"
}

t_get_archived_below_marker() {
    printf 'aaa|/p|Live One|1\nbbb|/p|Live Two|2\n[archived]\nccc|/p|Old One|3\n' > "$__cm_sessions_file"
    local n; n=$(__cm_get_archived | wc -l | tr -d ' ')
    assert_eq "1" "$n" "only rows below the marker are archived" || return 90
    local first; first=$(__cm_get_archived | head -1)
    assert_true "$([[ "$first" == *"Old One"* ]] && echo 0 || echo 1)" \
        "the archived row must be the one below the marker"
}

t_move_to_top_promotes() {
    printf 'aaa|/p|First|1\nbbb|/p|Second|2\nccc|/p|Third|3\n' > "$__cm_sessions_file"
    __cm_move_session_to_top "ccc" >/dev/null 2>&1
    local rows; rows=$(__cm_get_sessions | wc -l | tr -d ' ')
    assert_eq "3" "$rows" "promotion must not add or drop a row" || return 90
    local first; first=$(__cm_get_sessions | head -1)
    assert_true "$([[ "$first" == "ccc|"* ]] && echo 0 || echo 1)" "the promoted session must be row 1"
}

t_session_info_missing() {
    mkdir -p "$HOME/infoproj"
    __cm_get_session_info "deadbeef-0000-0000-0000-000000000000" "$HOME/infoproj" "155000"
    assert_eq "(missing)" "${__cm_info_size:-}" \
        "spec 8: a missing transcript must say so rather than showing a size" || return 90
    assert_eq "155K tok" "${__cm_info_tokens:-}" \
        "spec 8: the historical token count stays meaningful even when the file is gone"
}

t_orphan_scan_silent_when_tidy() {
    local pd; pd=$(_mk_project tidyproj)
    local a="aaaaaaaa-1111-1111-1111-111111111111"
    local b="bbbbbbbb-2222-2222-2222-222222222222"
    printf '{}\n' > "$pd/$a.jsonl"; printf '{}\n' > "$pd/$b.jsonl"
    printf '%s|%s|One|1\n%s|%s|Two|2\n' "$a" "$HOME/tidyproj" "$b" "$HOME/tidyproj" > "$__cm_sessions_file"

    # The picker firing when nothing is wrong trains the operator to dismiss it,
    # which is how a real orphan gets ignored.
    local out; out=$(__cm_do_orphan_scan "$HOME/tidyproj" "$a" 2>&1 </dev/null)
    assert_true "$([[ "$out" != *"Multiple conversation files"* ]] && echo 0 || echo 1)" \
        "a project whose transcripts are all registered here must not raise the picker"
}

t_orphan_scan_quarantines_to_quarantine_root() {
    local pd; pd=$(_mk_project messyproj)
    local live="cccccccc-3333-3333-3333-333333333333"
    local orph="dddddddd-4444-4444-4444-444444444444"
    printf '{}\n' > "$pd/$live.jsonl"
    printf '{}\n' > "$pd/$orph.jsonl"
    touch -d "-2 hours" "$pd/$orph.jsonl" 2>/dev/null || touch -A -020000 "$pd/$orph.jsonl" 2>/dev/null
    printf '%s|%s|Live One|1\n' "$live" "$HOME/messyproj" > "$__cm_sessions_file"

    printf 'q 2\n' | __cm_do_orphan_scan "$HOME/messyproj" "$live" >/dev/null 2>&1

    assert_true "$([[ -f "$__cm_quarantine_root/messyproj/$orph.jsonl" ]] && echo 0 || echo 1)" \
        "spec 3.1: an orphan belongs in the quarantine root, not the trim backup" || return 90
    assert_true "$([[ ! -f "$pd/$orph.jsonl" ]] && echo 0 || echo 1)" \
        "the orphan must leave the project key directory" || return 90
    assert_true "$([[ -f "$pd/$live.jsonl" ]] && echo 0 || echo 1)" \
        "the live session must be untouched"
}

t_orphan_scan_protects_registered() {
    local pd; pd=$(_mk_project protectproj)
    local live="eeeeeeee-5555-5555-5555-555555555555"
    local orph="ffffffff-6666-6666-6666-666666666666"
    printf '{}\n' > "$pd/$live.jsonl"
    printf '{}\n' > "$pd/$orph.jsonl"
    # make the LIVE one newest so 'q 1' targets exactly the protected file
    touch -d "-2 hours" "$pd/$orph.jsonl" 2>/dev/null || touch -A -020000 "$pd/$orph.jsonl" 2>/dev/null
    printf '%s|%s|Do Not Move Me|1\n' "$live" "$HOME/protectproj" > "$__cm_sessions_file"

    printf 'q 1\n' | __cm_do_orphan_scan "$HOME/protectproj" "$live" >/dev/null 2>&1

    # The one keystroke that must never work.
    assert_true "$([[ -f "$pd/$live.jsonl" ]] && echo 0 || echo 1)" \
        "the registered session must still be in place: quarantining it moves the conversation about to be resumed"
}

# =============================================================================
# TIER 0 - structural. Asserts on the module SOURCE, not its behaviour.
# Guards that the two backup destinations stay distinct. See the PowerShell
# suite for why this is a structural test and not a behavioural one.
# =============================================================================

_fn_body() {
    # $1 = function name; prints that function's CODE from the module copy.
    #
    # Comments are stripped. The first version of this did not strip them and
    # immediately bound a comment: an explanatory line in __cm_do_trim reading
    # "NOT to $__cm_quarantine_root, which is for orphans" made the test fail
    # against correct code. A test that a comment can turn red is not testing
    # behaviour, which is the whole point of this suite.
    local header="$1() {"
    awk -v f="$header" 'index($0,f)==1 {p=1} p {print} p && /^}$/ {exit}' "$__CM_TEST_MODULE" \
        | sed 's/#.*$//'
}

t_backup_dirs_distinct() {
    local orphan trim
    orphan="$(_fn_body __cm_do_orphan_scan)"
    trim="$(_fn_body __cm_do_trim)"
    [[ "$orphan" == *'__cm_quarantine_root'* ]] || { echo "           orphan scan must quarantine to \$__cm_quarantine_root" >&2; return 90; }
    [[ "$orphan" != *'__cm_backup_dir'* ]]      || { echo "           orphan scan must NOT use \$__cm_backup_dir" >&2; return 90; }
    [[ "$trim"   == *'__cm_backup_dir'* ]]      || { echo "           trim must move the pre-trim file to \$__cm_backup_dir (spec 11.13 step 11)" >&2; return 90; }
    [[ "$trim"   != *'__cm_quarantine_root'* ]] || { echo "           trim must NOT use the orphan quarantine root" >&2; return 90; }
    return 0
}

# ================================================================== the runner

echo ""
echo "  ClaudeCM bash suite"
echo "  module: $MODULE"
echo ""

test_case "format_tokens renders millions with one decimal (spec 7)" \
    "change the 1000000 threshold so 1234567 falls through to the K branch" \
    's/t >= 1000000/t >= 10000000/' t_tokens_millions

test_case "format_tokens renders thousands with no decimals (spec 7)" \
    "change the K-branch format from %d to %.1f" \
    's/%dK tok/%.1fK tok/' t_tokens_thousands

test_case "format_tokens renders empty input as -- (spec 7)" \
    "change the empty-input return from -- to 0" \
    "s/printf '%s' \"--\"/printf '%s' \"0 tok\"/" t_tokens_empty

test_case "format_size renders megabytes with one decimal (spec 7)" \
    "raise the 1MB threshold to 1GB so 1572864 falls to the KB branch" \
    's/b >= 1048576/b >= 1073741824/' t_size_mb

test_case "get_proj_key replaces EVERY non-alphanumeric (spec 6)" \
    "narrow the sed character class so dots survive" \
    's|\[^a-zA-Z0-9\]|[^a-zA-Z0-9.]|' t_projkey_dots

test_case "get_proj_key handles POSIX paths (spec 6)" \
    "narrow the sed class to backslash only, leaving forward slashes intact" \
    's|s/\[^a-zA-Z0-9\]/-/g|s/[\\\\]/-/g|' t_projkey_posix

test_case "parse_line round-trips a 4-field row (spec 5)" \
    "drop __cm_t from the read target list so TOKENS is never bound" \
    's/read -r __cm_g __cm_d __cm_desc __cm_t/read -r __cm_g __cm_d __cm_desc/' t_parse_four_fields

test_case "parse_line preserves spaces in DIR and DESC (spec 5)" \
    "remove IFS=| from the read so the default IFS splits fields on whitespace" \
    "s/IFS='|' read -r __cm_g/read -r __cm_g/" t_parse_desc_with_spaces

test_case "write_atomic leaves no .tmp behind (spec 5.1)" \
    "replace the mv rename with cp so the temp file survives" \
    's/mv -f "\$__cm_tmp_file"/cp -f "$__cm_tmp_file"/' t_write_atomic_no_tmp

test_case "get_sessions ignores blank lines (spec 5)" \
    "remove the blank-line continue so empty rows are emitted" \
    's/\[\[ -z "\${line\/\/ }" \]\] && continue/:/' t_get_sessions_skips_blanks

test_case "get_sessions stops at the [archived] marker (spec 5)" \
    "change the break at the archived marker to a continue, so archived rows leak into the main list" \
    's/== "\[archived\]" \]\] && break/== "[archived]" ]] \&\& continue/' t_get_sessions_stops_at_archived

test_case "claudecm -s filters the list by name, case-insensitively" \
    "change the substring test to an exact-equality test so a partial name stops matching" \
    's/== \*"\$term_lc"\* \]\]/== "$term_lc" ]]/' t_search_filters

test_case "claudecm -s never offers the new-project fallback" \
    "change the no-match message so the branch no longer reports the miss" \
    "s/No sessions matching/MATCHED NOTHING/" t_search_no_new_project

# NOTE: the sabotage must sit on the path the test actually walks. An earlier
# version mutated the number-pick branch while the test answers 'q', so the
# mutation never executed and the harness correctly reported the test HOLLOW.
# This one truncates the file while rendering the header, which the 'q' path
# does reach.
test_case "claudecm -s leaves sessions.txt byte-identical" \
    "truncate sessions.txt while rendering the search header, on the path a quitting user walks" \
    's|__cm_say "=== Sessions matching|: > "$__cm_sessions_file"; __cm_say "=== Sessions matching|' \
    t_search_leaves_sessions_intact

test_case "a launch that produced no transcript adopts nothing (spec 11.6.2)" \
    "make comm treat files that existed BEFORE the launch as if they were new" \
    's/comm -13/comm -12/' t_launch_bail_adopts_nothing

test_case "new-session detection survives a non-zero exit (spec 14.4)" \
    "bail out of __cm_invoke_claude_launch as soon as the child exits non-zero, which is the defect that made sessions vanish unless the user typed /exit" \
    's/__cm_launch_exit=\$?/__cm_launch_exit=$?; if [[ $__cm_launch_exit -ne 0 ]]; then return 0; fi/' \
    t_launch_detects_after_nonzero_exit

test_case "do_trim files the pre-trim transcript to the backup (spec 11.13 step 11)" \
    "delete the mv that files the pre-trim transcript, the omission that caused the April 2026 orphan accumulation" \
    's|mv -f "\$pre_trim_file" "\$backup_sub/\$current_guid.jsonl"|: "$pre_trim_file"|' t_trim_files_pretrim

test_case "do_trim swaps the GUID in sessions.txt and keeps the row" \
    "keep the old GUID on the row, so sessions.txt points at a transcript that has just been filed away" \
    's|updated+=("\$new_guid\|\$d\|\$desc\|\$t")|updated+=("$g\|$d\|$desc\|$t")|' t_trim_swaps_guid

test_case "a forked resume follows the fork and files the predecessor (spec 11.6.1)" \
    "delete the mv that files the fork predecessor, leaving it to trip the orphan picker next launch" \
    's|mv -f "\$pred" "\$dest/\$original_guid.jsonl"|: "$pred"|' t_fork_followed_and_predecessor_filed

test_case "a resume that did NOT fork changes nothing (spec 11.6.1)" \
    "treat the newest transcript as a fork unconditionally, filing away the session the operator is sitting in" \
    's|if \[\[ "\$newest_bn" != "\$original_guid" \]\] \&\& \[\[ -z "\$before_newest" \|\| "\$newest_bn" != "\$before_newest" \]\]; then|if true; then|' \
    t_plain_resume_changes_nothing

test_case "sync_session_index drops entries whose transcript is gone (spec 10 step 6)" \
    "keep every pre-existing entry regardless of what is on disk" \
    's|if (e && e.sessionId && onDisk\[e.sessionId\]) {|if (e && e.sessionId) {|' t_sync_index_drops_missing

test_case "sync_session_index names a registered session from sessions.txt (spec 10 step 7)" \
    "always write an empty firstPrompt, so the resume picker shows an unnamed session" \
    "s@firstPrompt: r.desc || '',@firstPrompt: '',@" t_sync_index_names_registered

test_case "format_date_short adds the year only for a previous year (spec 7)" \
    "compare the wrong way round so this year gets a year stamp and last year does not" \
    's|"\$file_year" -lt "\$now_year"|"$file_year" -gt "$now_year"|' t_format_date_short_year

test_case "get_archived reads only below the [archived] marker (spec 5)" \
    "emit every line rather than only those after the marker, so live sessions read as archived" \
    's|(( in_arch )) \&\& printf|printf|' t_get_archived_below_marker

test_case "move_session_to_top promotes without losing rows (spec 5)" \
    "append the promoted session instead of prepending it, so the list is no longer most-recently-used" \
    's|__cm_save_sessions "\$match" "\${rest\[@\]}"|__cm_save_sessions "${rest[@]}" "$match"|' t_move_to_top_promotes

test_case "get_session_info marks a missing transcript and keeps its tokens (spec 8)" \
    "report a missing transcript as a real size, so a lost session looks healthy in the list" \
    's|__cm_info_size="(missing)"|__cm_info_size="0 B"|' t_session_info_missing

test_case "do_orphan_scan stays silent when every transcript is accounted for" \
    "break the directory comparison so a correctly-registered transcript always looks foreign" \
    's|if \[\[ "\$match_dir" != "\$scan_dir" \]\]; then has_problem=1; break; fi|if true; then has_problem=1; break; fi|' \
    t_orphan_scan_silent_when_tidy

test_case "do_orphan_scan quarantines to the quarantine root, not the trim backup (spec 3.1)" \
    "send the quarantined transcript to the trim/settings backup instead of the quarantine root" \
    's|__cm_quarantine_root/\$leaf|__cm_backup_dir/$leaf|' t_orphan_scan_quarantines_to_quarantine_root

test_case "do_orphan_scan refuses to quarantine the registered session" \
    "remove the guard that refuses to quarantine the registered session" \
    's|if \[\[ "\$g" == "\$registered_guid" \]\]; then|if false; then|' t_orphan_scan_protects_registered

test_case "orphan quarantine and trim backup remain two distinct directories" \
    "point the orphan scan at __cm_backup_dir, unifying the two destinations" \
    's/__cm_quarantine_root/__cm_backup_dir/g' t_backup_dirs_distinct

echo ""
TOTAL=$((PASS+FAIL+HOLLOW+STALE+ERROR+INCONC))
echo "  $TOTAL test(s): $PASS pass, $FAIL fail, $ERROR error, $HOLLOW hollow, $STALE stale-sabotage, $INCONC inconclusive"
echo ""

if (( FAIL || ERROR || HOLLOW || STALE || INCONC )); then exit 1; else exit 0; fi
