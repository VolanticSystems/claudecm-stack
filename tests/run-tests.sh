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

test_case "orphan quarantine and trim backup remain two distinct directories" \
    "point the orphan scan at __cm_backup_dir, unifying the two destinations" \
    's/__cm_quarantine_root/__cm_backup_dir/g' t_backup_dirs_distinct

echo ""
TOTAL=$((PASS+FAIL+HOLLOW+STALE+ERROR+INCONC))
echo "  $TOTAL test(s): $PASS pass, $FAIL fail, $ERROR error, $HOLLOW hollow, $STALE stale-sabotage, $INCONC inconclusive"
echo ""

if (( FAIL || ERROR || HOLLOW || STALE || INCONC )); then exit 1; else exit 0; fi
