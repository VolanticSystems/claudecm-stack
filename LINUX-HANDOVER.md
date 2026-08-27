# Hello Linux friend

Written 2026-08-27 by the Windows-side instance. You are reading this because
the bash module changed and I could not verify it where it actually runs.

**What I am:** an instance working on the Windows desktop. Everything I know
about `claudecm-linux.sh` I learned from reading it, from the spec, and from
running it under **Git Bash on Windows**, which is not Linux. Treat my
confidence accordingly. If something here is wrong, you are the one positioned
to find out, and I would rather be corrected than agreed with.

---

## 0. If you pulled this repo BEFORE 2026-08-27, delete it and clone again

Everything below is secondary to this.

`core.autocrlf=true` on this machine and no `.gitattributes` meant **every `.sh`
in this repository was stored in git with CRLF**, `claudecm-linux.sh` included.
So whatever you cloned before today, the module in it had a `\r` on the end of
every line.

On Windows that is invisible. Git Bash does not care and the suite ran green
here for a full evening. On your box it is fatal and it fails in two different
disguises:

- **Executed:** the kernel reads the shebang literally and looks for an
  interpreter named `bash\r`, so you get
  `bad interpreter: No such file or directory` while staring at a line that
  plainly says `#!/usr/bin/env bash`.
- **Sourced from `.bashrc`:** no shebang involved, so instead the `\r` joins the
  last token on every line. Errors land on syntax that is obviously correct.

Fixed with a `.gitattributes` pinning `*.sh` to `eol=lf`, and the tree has been
renormalised. Verified at the blob level rather than in the working copy,
because the working copy is precisely what autocrlf rewrites on checkout:

    git show ":claudecm-linux.sh" | file -    # want "ASCII text", NOT "with CRLF line terminators"

A stale clone will not repair itself on `git pull`, because the file content
does not change: only the attributes do. `git rm -r --cached . && git reset
--hard`, or just re-clone. Re-cloning is faster than being unsure.

I owe you this one plainly: I could have caught it any time by checking a blob
instead of a working copy, and I did not, because everything I ran passed.

---

## 1. Start here

    git pull
    bash tests/run-tests.sh

Expected: `37 test(s): 37 pass, 0 fail, 0 error, 0 hollow, 0 stale-sabotage, 0
inconclusive`, and exit 0. Should take a few seconds.

**If it takes minutes, you have no `flock`.** Git Bash ships none, and
`__cm_acquire_lock` responds by spinning its full 50 x 0.2s retry and timing out
on *every* `sessions.txt` write: ten seconds a save. The suite prints a note and
falls back to `tests/stubs/flock` when the real one is missing, so on your box
you should see neither. If you DO see that note, that is a finding about the
machine worth acting on, because it means live ClaudeCM stalls ten seconds on
every write and then proceeds unlocked anyway. `util-linux` provides it. The
module has always listed it as a dependency and does not check for it at
startup, which is arguably the actual defect.

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

### 2c. A bug I found and did NOT fix, because it needs Bob's say-so

`__cm_ensure_cleanup_period_days` **announces success without checking whether
it did anything.** The structure is:

```bash
current=$("$node" -e "...read cleanupPeriodDays..." 2>/dev/null)
if [[ -z "$current" ]] || (( current < 1000 )); then
    cp -f "$settings" "$__cm_backup_dir/settings.json.$ts" 2>/dev/null
    "$node" -e "...write cleanupPeriodDays=100000..." 2>/dev/null
    __cm_say_c "$__CM_C_CYAN" "Protected session transcripts from ... auto-delete."
fi
```

Every node call is silenced and the message is printed unconditionally. If the
write fails for any reason the user is told their transcripts are protected
while `cleanupPeriodDays` is still 30, and Claude Code deletes them a month
later. Note also that a FAILED read produces an empty `current`, which the guard
treats as "needs fixing" and proceeds, so a broken read and a genuinely low
value are indistinguishable.

I watched it do exactly this. Under Git Bash the function printed its success
line and left `settings.json` byte-for-byte unchanged.

**The trigger I saw is Windows-only** and you will not hit it: node on Windows
cannot open the POSIX sandbox path that Git Bash hands it. On your box node
reads `/home/...` perfectly well, so the function almost certainly works. The
unconditional message is a real defect regardless of what triggers it, and it is
the same shape as 2a: `2>/dev/null` on a call whose failure looks like success.

Not fixed here. It is a product change rather than a test, so it is Bob's call.
The fix is small: read the value back after writing and only announce if it
actually changed.

**One test is therefore weaker than it looks.**
`ensure_cleanup_period_days backs up settings.json before rewriting it` asserts
only the backup, which is pure shell and binds everywhere. It deliberately does
NOT assert the resulting `cleanupPeriodDays`, because reading it back needs node
and on Git Bash that assertion could not bind no matter what the product did. A
test that cannot bind is worse than no test. **Please add the value assertion on
your side**, where it means something:

```bash
val=$(node -e "process.stdout.write(String(JSON.parse(require('fs').readFileSync(process.env.HOME+'/.claude/settings.json','utf8')).cleanupPeriodDays))")
# must be >= 1000, and must NEVER be 0: the code comments explain that 0
# disables persistence rather than extending it
```

---

## 3. What I could NOT verify, ranked by how likely I am to be wrong

Please check these specifically. This is the part of the document that is worth
your time.

1. **`stat` behaviour.** `__cm_file_mtime_epoch` is
   `stat -c %Y "$1" || stat -f %m "$1"`. That helper predates me and I used it
   rather than inventing a second one, but I have never seen it run against GNU
   coreutils on a real box. If `stat -c` behaves differently for you than I
   assumed, the multi-file tiebreak picks the wrong session.

   **Now partly self-answering.** `file_mtime_epoch returns a real epoch on this
   box` writes a file, reads its mtime back, and asserts the result is a bare
   integer within a day of `date +%s`. Its sabotage swaps BOTH branches to
   report the file SIZE instead, so the GNU path cannot quietly fall through to
   the BSD one and pass anyway. If that test goes green on your machine, this
   item is closed; if it goes red, it tells you the units directly. It is the
   one item on this list that no longer needs you to reason about it.

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
- Coverage, measured rather than estimated: **32 of 32** PowerShell functions
  are touched by at least one test, and **26 of 42** on bash, 61%. (34 `function` declarations minus
  `grep` and `lst`, which are Bob's shell helpers that happen to live in the
  same file.) Treat that as an upper bound: it counts a function as covered if
  any test names it, and naming is not the same as asserting.

  PowerShell is done. bash is where the gap is now, and it is a real one: the
  sixteen without tests are

      __cm_do_resume            __cm_do_refresh          __cm_do_post_exit
      __cm_resolve_resume_or_recover                     __cm_build_recovery_meta_prompt
      __cm_acquire_lock         __cm_release_lock        __cm_auto_backup_sessions
      __cm_resolve_node         __cm_resolve_jq          __cm_find_exe
      __cm_json_get             __cm_file_size           __cm_file_ctime_epoch
      __cm_say_c                __cm_blank

  The last two are cosmetic. The first five are not: they are the resume path,
  the refresh path, and post-exit registration, which between them decide
  whether a session survives. Their PowerShell twins all have tests now, so the
  sabotages are written and only need porting. That is the most useful thing you
  could do with this suite.

  `__cm_do_refresh` is the one to do first, and there is a specific trap in it.
  Its PowerShell twin pipes a large prompt over stdin instead of passing it as
  an argument, because Windows caps a command line near 32K and a refresh prompt
  carrying a skeleton goes well past it. That bug is correct on every small
  input and broken on every real one, which is how it survived long enough to
  cost a day. Linux's limit is far higher so you may never hit it, but the test
  is still worth porting: `tests/stubs/extract-skeleton.mjs` already emits an
  80KB skeleton, and the claude stub already records how many characters
  actually arrived on stdin. **Make the fixture big.** A small one passes and
  proves nothing.

Thanks. The Windows side has had a test suite for about a day, and most of what
it found was wrong with the TESTS rather than the tool. Three that are worth
knowing about, because they are the failure modes to expect in anything you add:

- A mutation applied with PowerShell's `-replace` spliced whole functions into
  themselves, because `$_` there means the entire input string. Two tests passed
  for the wrong reason.
- The harness imposed `Set-StrictMode` and `set -u`, which the product sets
  neither of. That is not testing the program anyone runs.
- Two assertions were written as `@(Get-Sessions).Count`. Spec 14.3: the
  function comma-returns so the array survives unrolling, which means `@()`
  around it nests it and `.Count` is 1 forever. Neither assertion could fail.
  There is now a structural check that refuses the idiom outright.

The last one is the one I would watch for. It is not a wrong test, it is a test
that LOOKS like coverage, and no per-test sabotage finds it because the fault is
in the assertion rather than in the product.
