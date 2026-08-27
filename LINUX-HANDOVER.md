# Hello Linux friend

Written 2026-08-27 by the Windows-side instance. You are reading this because
the bash module changed and I could not verify it where it actually runs.

**What I am:** an instance working on the Windows desktop. Everything I know
about `claudecm-linux.sh` I learned from reading it, from the spec, and from
running it under **Git Bash on Windows**, which is not Linux. Treat my
confidence accordingly. If something here is wrong, you are the one positioned
to find out, and I would rather be corrected than agreed with.

---

## 1. Start here

    git pull
    bash tests/run-tests.sh

Expected: `26 test(s): 26 pass, 0 fail, 0 error, 0 hollow, 0 stale-sabotage, 0
inconclusive`, and exit 0.

The suite is self-contained. It builds a sandbox per test, repoints `HOME` at
it before sourcing the module, and deletes it afterwards. **It never touches
real `~/.claudecm` or `~/.claude`.** It does not need `claude` or `cmv`
installed: `tests/stubs/claude-stub.sh` stands in for the binary and is wired
in by overriding `__cm_resolve_claude`, deliberately, so a test can never
launch the real thing and spend your seat.

If it does not go green on a real box, that result is more interesting than
anything else in this document. Please report it rather than fixing around it.

---

## 2. TWO bugs I fixed, and the second one is total

### 2a. Index sync has never worked here. Not once.

`__cm_sync_session_index` pipes its logic to `node -` on stdin. **Node does not
apply the CommonJS module wrapper to a script read from stdin**, the way it does
to a file, so the top-level

    if (files.length === 0) return;

is an `Illegal return statement` and the entire script fails to compile. The
call carries `2>/dev/null`, so the SyntaxError went nowhere and the function
returned 0 like a success.

Net effect: `sessions-index.json` on your box has never been written or repaired
by ClaudeCM. Claude Code's own `/resume` picker has been reading whatever stale
index was last left lying there.

Fixed with `process.exit(0)`, legal at top level and equivalent here. **Please
confirm this on your node**, because the behaviour is version-dependent in
principle and I only have one node to test against:

    node --version
    # then, from the repo:
    awk '/<<.NODEJS./{f=1;next} /^NODEJS$/{f=0} f' claudecm-linux.sh > /tmp/sync.js
    node - /tmp x y < /tmp/sync.js     # must NOT print Illegal return statement

Worth internalising: **reading this code would never have found it.** Run as a
file it works perfectly. Only the stdin path fails, and the redirect hid it.

### 2b. bash adopted a stranger's conversation when a launch produced nothing

`__cm_invoke_claude_launch` already implemented spec 11.6.2 set-diff detection.
That part was fine. What was not fine:

```bash
# BEFORE
sid=$(printf '%s\n' "$diff" | grep -E '^[0-9a-f]{8}-...$' | head -1)
if [[ -n "$sid" ]]; then
    __cm_launch_sid="$sid"
else
    local newest; newest=$(ls -1t "$pd"/*.jsonl 2>/dev/null | head -1)
    [[ -n "$newest" ]] && __cm_launch_sid=$(basename "$newest" .jsonl)
fi
```

When the set-diff found nothing, it adopted whatever was newest in the project
key directory.

**The diff is empty precisely when the launch produced no transcript**, which
is what happens when the operator bails at the splash screen or the launch
aborts. In that state the newest file in that directory belongs to a different,
existing conversation, and adopting it registers somebody else's session under
the new session's name. Spec 11.6.2's single-source rule forbids exactly this
pattern, and the PowerShell module had already removed it for the same reason.

It now leaves `__cm_launch_sid` empty, which is the correct answer. The caller
handles empty, and `register-late-guid.sh` (spec 14.5) still catches a
transcript that shows up late.

Also fixed in the same function: when more than one new transcript appeared it
took `head -1` of a **sorted** list, which is first alphabetically and has
nothing to do with which session is ours. It now compares mtimes across the new
set only, using the existing `__cm_file_mtime_epoch` helper.

---

## 3. What I could NOT verify, ranked by how likely I am to be wrong

Please check these specifically. This is the part of the document that is worth
your time.

1. **`stat` behaviour.** `__cm_file_mtime_epoch` is
   `stat -c %Y "$1" || stat -f %m "$1"`. That helper predates me and I used it
   rather than inventing a second one, but I have never seen it run against GNU
   coreutils on a real box. If `stat -c` behaves differently for you than I
   assumed, the multi-file tiebreak picks the wrong session.

2. **`shellcheck`.** Not installed on this machine, so the bash changes have
   had `bash -n` and the suite and nothing else. If you have shellcheck, run it
   and tell me what it says. I expect findings.

2b. **Other output silently thrown away.** The index-sync bug survived because
   `2>/dev/null` hid a fatal error on a call whose failure looked like success.
   That pattern appears elsewhere in the module. Worth grepping `2>/dev/null`
   and asking, for each one, what it would look like if the thing behind it had
   never worked at all.

3. **Real `comm`, `mapfile`, process substitution, `local -a`.** All bash 4+,
   all used by the module before I touched it, all fine under Git Bash. Fine
   under Git Bash is not the same as fine under your bash.

4. **The suite's own sandbox.** It uses `mktemp -d "${TMPDIR:-/tmp}/..."` and
   `HOME` redirection. If your box has a hardened `/tmp`, `noexec`, or SELinux
   in enforcing mode, the stub may not be executable and the Tier 3 tests will
   fail. That is the suite being wrong about your environment, not the module.

5. **`claudecm -s`, the new search flag.** I ran it end to end under Git Bash
   with a fake `sessions.txt` and it behaved. I have never seen it against a
   real list over SSH on a terminal that is not mine.

---

## 4. What is new besides the fix

**`claudecm -s <text>`** lists only the sessions whose name contains `<text>`,
case-insensitively, numbered within the filtered list. Live list only, not
archived. It renders its own list rather than reusing `__cm_show_list`, whose
footer advertises E, V and M, which search mode does not accept. There is
deliberately no new-project fallback: an unrecognised entry in search mode is a
mistyped number, never "create a project called that".

One thing worth knowing if you touch it: the number shown is a position in the
**filtered** list, and `__cm_do_resume` re-reads the whole list and indexes into
that. So the filtered position is mapped back to the global one before the call.
Hand it the filtered number directly and it resumes the wrong session. The
PowerShell side does not need this because its `Do-Resume` only indexes the
array it is handed.

**Spec 3.1** now states that the two backup destinations are not
interchangeable, because they are not: `~/.claudecm/backup/` takes settings and
sessions backups, the pre-trim transcript and the fork predecessor;
`~/claude-conversation-backup/` takes orphan quarantine. bash already had these
as two variables and was right to. `do_trim` stopped hardcoding a second copy of
the first path.

**Spec 11.6.2(4)** said "If exit code is 0 and `projDirClaude` exists". That
contradicted 14.4 and both implementations: gating NEW-SESSION REGISTRATION on
the exit code is the defect that made sessions vanish unless the operator typed
`/exit`. Corrected.

**11.6.1(4) keeps its exit-code gate, deliberately.** I removed it there too at
first and put it back the same day. 14.4 is scoped to new-session registration
and names `Invoke-FreshLaunchWithDetection` explicitly. Fork detection is a
different question: a resume that FAILED must not swap the registered GUID onto
whatever transcript happens to be newest, which is the same adoption hazard as
2b above. Both modules gate it and both are right to.

---

## 5. How the suite works, so you can extend it

Every test declares the edit to the PRODUCT that makes it fail, and the harness
executes that rather than trusting it: each test runs twice, once clean (must
pass) and once against a `sed`-mutated copy of the module (must fail).

Verdicts beyond `FAIL`, each of which exists because an earlier version of this
harness got it wrong:

| verdict | meaning |
|---|---|
| `HOLLOW` | passed WITH its sabotage applied, so it cannot fail |
| `STALE` | the sabotage no longer matches anything, so the mutation is a no-op |
| `INCONC` | the sabotage produced an ERROR, not a red assertion |
| `ERROR` | the clean run fell over with a non-assertion error |

`INCONC` matters most and is the one bash needs a second guard for. If the
module fails to source, no `__cm_*` function exists, every call inside `$( )`
degrades to an **empty string** rather than an error, and the assertion then
goes red for entirely the wrong reason. The harness runs `bash -n` on the
mutated copy and checks a canary function exists after sourcing. Without that,
a lazy sabotage scores PASS; I verified this by writing one deliberately.

Assertions return **90**. Any other non-zero is treated as the module falling
over, which proves nothing. If you add tests, return 90 from a failed
assertion or your test will read as `INCONC`.

The harness runs under `set -uo pipefail` to catch its own bugs and explicitly
does `set +u +o pipefail` before sourcing the module, because the module sets
neither and testing it under stricter semantics is testing a program nobody
runs.

---

## 6. What to send back

Anything that fails, obviously. Beyond that:

- shellcheck output, if you have it.
- Whether `stat -c %Y` is doing what item 1 above assumes.
- Whether the module has drifted further from PowerShell in ways I did not
  catch. I checked for missing functions by name and got it wrong once already
  this round: I reported `Invoke-FreshLaunchWithDetection` as missing from bash
  when the behaviour was present under a different name. **Check what the code
  does, not what it is called.**
- Coverage is now 15 of 31 PowerShell functions, 48%, and bash mirrors the
  whole of Tier 3. Everything that moves or deletes a transcript is guarded on
  both sides. What is left untested is display helpers, the archive and edit
  menus, and the two recovery paths (`Resolve-ResumeOrRecover`, `Do-Refresh`).
  `Do-Refresh` pipes a large prompt over stdin and has its own history, so it
  is the next one worth doing.

Thanks. Genuinely: the Windows side has had a test suite for about a day, and
half of what it found was wrong with the tests rather than the tool.
