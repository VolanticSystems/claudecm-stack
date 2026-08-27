# ClaudeCM test plan

First test suite for a project that had none, at 3,303 lines across two
implementations after five months of daily use.

Written 2026-08-26. Informed by an adversarial model panel run over
`claudecm-powershell.ps1` plus the spec, and by direct reading of both modules.
The write-up of that panel round is feedback on a separate, unpublished tool and
lives with that tool, not here.

---

## 1. The governing rule

**Before you write the assertion, name the edit to the PRODUCT that makes this
test fail. Name the file, the construct, and the change. If you cannot name
one, you are not writing a test.**

This project has already shipped guards that could never fire. So here that
rule is not documentation, it is executed: every test declares a mutation of
the product source, and the harness runs each test twice, once clean (must
pass) and once mutated (must fail). A test that passes under its own sabotage
is reported `HOLLOW` and the suite exits non-zero.

Both harnesses report four failure kinds beyond a plain `FAIL`, and each one
exists because the naive version of this harness got it wrong:

| verdict | meaning |
|---|---|
| `HOLLOW` | the test passed WITH its sabotage applied, so it cannot fail |
| `STALE-SABOTAGE` | the sabotage anchor no longer exists in the product, so the mutation is a no-op and the test looks verified forever |
| `INCONCLUSIVE` | the sabotage produced an ERROR rather than a red assertion, which proves nothing |
| `ERROR` | the clean run threw a non-assertion error: harness or product fault |

Any of them fails the suite.

**`INCONCLUSIVE` is the one that matters most and it was missing at first.** The
doctrine says a sabotage "must leave the test running and its assertion
evaluating. Deleting the file or making it unparseable does not count: an error
is not a red assertion." The first harness could not tell those apart: it read
ANY error during the sabotage pass as proof the test can fail. A lazy sabotage
that merely broke the module would have certified a hollow test as sound, which
is the exact escape hatch the rule names.

PowerShell assertion failures now carry a sentinel string; anything thrown
without it is `INCONCLUSIVE`. bash assertions return exit code 90; any other
non-zero code is `INCONCLUSIVE`.

**bash needed a second guard that PowerShell did not.** If the module fails to
source, no `__cm_*` function exists, and every call inside `$( )` degrades to an
empty string rather than an error. The assertion then goes red for entirely the
wrong reason and the test scores PASS. The harness now runs `bash -n` on the
mutated copy and checks a canary function exists after sourcing. **Both
detectors were verified by deliberately writing a lazy sabotage and confirming
it reads `INCONCLUSIVE`**, on both platforms, rather than assuming the fix
worked.

## 2. The seam problem, and why the two harnesses differ

The two modules are not equally testable and this is the single most important
structural fact about testing ClaudeCM.

**bash is directly testable.** All 42 `__cm_*` functions are defined at top
level and the file ends with the standard `BASH_SOURCE` guard, so sourcing it
exposes everything and runs nothing. `tests/run-tests.sh` sources a copy with
`HOME` repointed at a sandbox, and sabotages by `sed`-mutating that copy.

**PowerShell is not.** 31 of its 34 functions are nested inside the single
`claudecm` function. Dot-sourcing the module exposes only `claudecm`, `lst`
and `grep`. Every function worth testing is unreachable from outside.

`tests/Invoke-ClaudeCMTests.ps1` solves this without touching the product: it
parses the module with the PowerShell AST, lifts each nested function's source
text, and re-defines it in an isolated scope alongside the enclosing-scope
variables it closes over (`$cmDir`, `$sessionsFile`, `$backupDir`). Sabotage
is a textual mutation applied to the lifted source before it is defined.

**Consequence worth stating plainly:** the PowerShell module is testable today
only because an AST harness can reach inside it. That is a workaround, not a
design. If the nested functions were ever moved to module scope, this harness
gets simpler and the tests stay identical.

## 3. Tiers, by what it costs to reach them

**Tier 0, structural.** Asserts on the module source rather than its
behaviour. Currently one test per module, guarding that the orphan quarantine
root and the trim backup directory stay two different places (spec 3.1). It
cannot prove a file lands in the right directory, only that the two have not
been silently unified, which is the change most likely to be made in the name
of tidying up. The behavioural version needs the Tier 3 stub. **Implemented.**

**Tier 1, pure transformations, no filesystem.** `Format-Tokens`,
`Format-Size`, `Format-DateShort`, `Get-ProjectKey`, and the bash twins.
Cheapest tests in the project and they guard a spec section with exact
required output. **Implemented.**

**Tier 2, state on disk in a sandbox.** `Parse-SessionLine`, `Get-Sessions`,
`Get-ArchivedSessions`, `Write-SessionsAtomic`, `Save-Sessions`,
`Move-SessionToTop`, `Sync-SessionIndex`, `Get-SessionInfo`. Everything that
reads or writes `sessions.txt` or the project key directory. **Partly
implemented**: the sessions.txt path is covered, `Sync-SessionIndex` and
`Get-SessionInfo` are not yet.

**Tier 3, needs a stubbed child process.** `Do-PostExit`, `Do-Trim`,
`Do-Refresh`, `Invoke-FreshLaunchWithDetection`,
`Invoke-ResumeWithForkDetection`, `Test-CleanExitTail`,
`Resolve-ResumeOrRecover`. These spawn `claude` or `cmv` and react to what
happened. **Partly implemented**, and this is where every historical data-loss
incident lives.

`tests/stubs/claude-stub.ps1` stands in for the real binary. It is driven
entirely by environment variables, accepts and ignores every real argument, and
does the only two things ClaudeCM observes afterwards: write a `<GUID>.jsonl`
into the project key directory, and return a chosen exit code. `$claudeExe` in
the product scope points at it, and `USERPROFILE` is repointed at the sandbox
for the duration because these functions build the key path themselves.

`cmv` needs no stub yet. `Do-PostExit` guards every cmv call with
`Test-Path $cmvExe`, so pointing that at a nonexistent path skips the snapshot
and the benchmark and leaves the registration logic reachable on its own. That
is the part worth testing; cmv is somebody else's program.

Covered: `Invoke-FreshLaunchWithDetection` (both invariants), `Do-PostExit`
(MRU bump), `Test-CleanExitTail`. Still open: `Do-Trim`,
`Invoke-ResumeWithForkDetection`, `Do-Refresh`, `Resolve-ResumeOrRecover`.

**Tier 4, interactive menus.** `Show-List`, `Do-OrphanScan`, `Do-EditList`,
`Do-ViewArchived`. Need stdin injection and output capture. **Not
implemented**, lowest value per unit of effort, but `Do-OrphanScan`'s
quarantine action mutates disk and belongs in Tier 3 rather than here.

## 4. What is implemented, and what each test guards

44 tests: 27 PowerShell, 17 bash. The Tier 0 to 2 tests are deliberately
mirrored so divergence shows up as a different result on the same named test.
Tier 3 exists on both platforms and is deeper on PowerShell.

**Behavioural coverage: 14 of 31 PowerShell functions, 45%**, up from 22% when
the suite was first written. **All six** of the functions the panel most often
proposed testing are now covered.

More usefully: every function that MOVES OR DELETES a transcript now has a
behavioural test with a named product edit that makes it fail. That is
`Do-Trim`, `Do-OrphanScan`, `Invoke-ResumeWithForkDetection`,
`Invoke-FreshLaunchWithDetection` and `Do-PostExit`. The untested 17 are
display helpers, the archive and edit menus, `Sync-SessionIndex`, and the two
recovery paths: things that would annoy rather than destroy.

| test | spec | sabotage that proves it can fail |
|---|---|---|
| tokens: millions, thousands, empty | 7 | move the 1000000 threshold; add a decimal to the K format; return `0 tok` for empty |
| size: megabytes | 7 | raise the 1MB threshold to 1GB |
| project key: dots, POSIX paths | 6 | narrow the character class so `.` or `/` survives |
| parse: 4 fields | 5 | drop the 4th field from the split |
| parse: spaces in DIR and DESC (bash) | 5 | remove `IFS='\|'` so the default IFS splits on whitespace |
| atomic write leaves no .tmp | 5.1 | replace the rename with a copy |
| save preserves row order | 5 | sort by Desc before writing |
| Get-Sessions returns an array | 14.3 | drop the comma from `return ,$sessions` |
| blank lines ignored | 5 | remove the blank-line filter |
| `[archived]` ends the main list (bash) | 5 | change the break to a continue |
| `-s` filters by name, case-insensitively | 11.1.1 | change `Contains` to `StartsWith` / substring test to equality |
| `-s` never offers the new-project fallback | 11.1.1 | break the no-match branch so it falls through |
| `-s` leaves sessions.txt byte-identical (bash) | 11.1.1 | truncate the file while rendering the header |
| the two backup destinations stay distinct | 3.1 | point the orphan scan at the trim backup dir |
| new-session detection survives a non-zero exit | 14.4 | gate the GUID assignment on `$exitCode -eq 0` |
| new-session detection uses set-diff not newest-mtime | 11.6.2 | drop the `-not $before.ContainsKey` clause |
| `Do-PostExit` bumps the exited session to row 1 | 5 | write the list back without reordering |
| `Test-CleanExitTail` recognises a trailing /exit | 11.6.1 | narrow the tail pattern |
| a launch producing no transcript adopts nothing (bash) | 11.6.2 | make `comm` treat pre-existing files as new |
| the module never spawns powershell.exe | n/a | point Start-Process back at powershell.exe |
| the harness supplies every enclosing-scope variable it lifts | n/a | have the product read an undefined enclosing name |
| `Do-Trim` files the pre-trim transcript to the backup | 11.13 s11 | delete the Move-Item |
| `Do-Trim` swaps the GUID onto the row and keeps the name | 11.13 | skip the GUID assignment |
| a forked resume follows the fork and files the predecessor | 11.6.1 | delete the predecessor Move-Item |
| a resume that did NOT fork changes nothing | 11.6.1 | treat the newest transcript as a fork unconditionally |
| `Do-OrphanScan` stays silent when nothing is wrong | 14.3 | make the directory comparison always disagree |
| `Do-OrphanScan` quarantines to the quarantine root | 3.1 | send it to the trim backup instead |
| `Do-OrphanScan` refuses to quarantine the registered session | 11.5 | remove the guard |

**Status: 44 pass, 0 fail, 0 error, 0 hollow, 0 stale-sabotage, 0 inconclusive.**

The last three are Tier 2b: whole-module integration through the `claudecm`
entry point. They exist because the `-s` dispatch lives inside `claudecm`
itself, not in a nested function, so the AST-lift seam cannot reach it. The
PowerShell harness runs these by copying the module, mutating the copy,
dot-sourcing it in a child pwsh with `USERPROFILE` repointed, and shadowing
`Read-Host` so the interactive pick returns immediately.

**Capturing output requires `6>&1`.** The module speaks only through
`Write-Host`, which writes to the information stream and not the success
pipeline. A test that pipes `claudecm ... | Out-String` captures an empty
string and every assertion against it passes vacuously. That is a test that
cannot fail, and it is an easy one to write by accident: the first draft of
these two did exactly that.

## 5. What the writing of this suite already found

**The array-nesting trap is still live and still easy to hit.** While writing
the blank-lines test I wrote `$s = @(Get-Sessions)`. Re-wrapping a
comma-returned array nests it: `$s` became one element that was itself the
array, and two sessions read as one whose `Desc` was `"One Two"`. That is
exactly spec 14.3 and commit `49b3c45`. The product was correct; the test was
wrong, in the precise way the project has been wrong before. The test now
carries a comment saying so.

**The hollow detector caught a hollow test on its first real outing.** The
bash test asserting that `-s` leaves `sessions.txt` intact originally
sabotaged the number-pick branch, while the test itself answers `q` and quits
before reaching it. The mutation never executed, so the test stayed green
under its own sabotage and was reported `HOLLOW`. The sabotage now truncates
the file while rendering the header, which the quitting path does reach.
**A sabotage must sit on the path the test actually walks**, and that is not
obvious when you write it.

**The sabotage replacement was silently corrupting itself.** PowerShell's
`-replace` takes a REGEX replacement string, where `$_` means the entire input,
`$&` the whole match and `$1` a capture group. A PowerShell sabotage almost
always contains `$_`, so `-replace` was splicing whole functions into
themselves and producing mutations that were nonsense but still parsed. Two
tests were passing for the wrong reason because of it. Both harnesses now use
literal `String.Replace`. This is the same family as trap 3 in the skill: the
oracle looked right and bound nothing.

**The harness was running the product under stricter semantics than
production.** The PowerShell suite sets `Set-StrictMode -Version Latest` to
catch its own bugs, and a created scriptblock inherits it; the product never
sets StrictMode. Concretely, `Parse-SessionLine` does `$parts[1]` on a
one-element array for a blank row: under StrictMode that throws, in production
it yields `$null` and ClaudeCM carries on. The suite was testing a program Bob
does not run. The generated product scope now sets `Set-StrictMode -Off`, and
the bash harness sets `set +u +o pipefail` for the same reason. **This is the
first concrete answer to "is the AST-lift seam faithful", and the answer was
no.** Others may remain.

**A test bound a comment, within an hour of the suite existing.** The bash
structural test read the whole function body including comments, and failed
against correct code because an explanatory comment inside `__cm_do_trim`
mentioned `$__cm_quarantine_root` in prose. That is a defect another
project in this stack hit in its own suite and fixed for the same reason. Both harnesses now strip
comments before matching. **A structural test that a comment can turn red is
not testing behaviour**, and the failure mode is invisible unless the comment
happens to disagree with the code.

**`$backupDir` means two different directories.** It is assigned at module top
level to `~/.claudecm/backup` and again inside `Do-OrphanScan` to
`~/documents/github/claude-conversation-backup`. `Do-Trim` (line 809) and
`Invoke-ResumeWithForkDetection` (line 1213) read it without assigning it.
PowerShell scoping makes the inner assignment local, so those two read the
top-level value and quarantine to `~/.claudecm/backup`, while `Do-OrphanScan`
quarantines somewhere else. Spec line 70 names
`claude-conversation-backup` as "destination for orphan quarantine and
explicit user-initiated quarantine", and spec line 638 names
`~/.claudecm/backup/<project-leaf>/` for the trim case. So the split may be
deliberate. **It is not tested either way and the variable name gives no hint
which is intended.** This wants a decision before it wants a test.

## 5a. A real defect the suite found in the product

**bash adopted a stranger's conversation when a launch produced nothing.**
`__cm_invoke_claude_launch` already implemented 11.6.2 set-diff detection, but
when the diff came back empty it fell through to
`ls -1t "$pd"/*.jsonl | head -1` and took whatever was newest in the project key
directory. The diff is empty precisely WHEN THE LAUNCH PRODUCED NOTHING, which
is when the user bailed at the splash screen. In that state the newest file
belongs to somebody else, and adopting it registers a real conversation under
the new session's name. The spec forbids exactly this in the 11.6.2
single-source rule and PowerShell had already removed it.

Also fixed: the multi-file case took `head -1` of a sorted list, which is first
alphabetically and unrelated to which session is ours. It now compares mtimes
across the new set only.

**And a spec contradiction.** Steps 11.6.1(4) and 11.6.2(4) both read "If exit
code is 0 and projDirClaude exists", which contradicted 14.4 and both shipped
implementations. Gating detection on the exit code is the exact defect that
made new sessions vanish unless the user typed `/exit`. Both steps corrected.

## 6. Known parity gaps between the modules

Found by reading, not yet by test, because Tier 3 is where they would be
caught.

- PowerShell has `Invoke-FreshLaunchWithDetection` (spec 11.6.2),
  `Move-SessionToTop` and `Test-CleanExitTail`. bash has no counterpart.
- bash has `__cm_auto_backup_sessions`. PowerShell does the same work inline
  in bootstrap rather than in a named function, so this one is cosmetic.
- Spec 14.5 (crash-safe late registration) is implemented in PowerShell as
  `register-late-guid.ps1` and marked "bash port pending".

A parity test is worth more than either module's own tests, because bash
trails PowerShell and nothing currently notices when it falls further behind.

## 7. Build order for the next sitting

1. ~~Stub `claude`~~ done: `tests/stubs/claude-stub.ps1`.
2. ~~`Do-PostExit` and spec 14.4 exit-code independence~~ done.
3. ~~`Do-Trim` quarantine of the pre-trim file~~ done, with `stubs/cmv-stub.ps1`.
4. ~~`Invoke-ResumeWithForkDetection`~~ done, both the fork and the no-fork case.
5. ~~`Do-OrphanScan`~~ done. It needed no stdin injection: shadowing `Read-Host`
   inside the test body reaches it, the same seam `Do-PostExit` uses.
6. ~~Tier 3 on bash~~ done, two cases.
7. ~~Seam fidelity~~ answered, see section 2.
8. `Sync-SessionIndex` against a hand-written expected index. The oracle must
   be hand-built: regenerating it with the same function would bind nothing.
   This is the largest remaining single function.
9. `Resolve-ResumeOrRecover` and `Do-Refresh`, the two recovery paths. Both
   spawn children and `Do-Refresh` pipes a large prompt over stdin, which has
   its own history (the Windows 32K argument limit).
10. Mirror the deeper Tier 3 cases onto bash. PowerShell has seven, bash two.

## 8. Running them

    pwsh -File tests\Invoke-ClaudeCMTests.ps1
    bash tests/run-tests.sh

Both exit non-zero on any failure, hollow test, or stale sabotage. Neither
touches real state: both build a sandbox per test and delete it afterwards.

Useful switches: `-Only <substring>` / `ONLY=<substring>` to run one test,
`-SkipSabotage` to run only the clean pass.

Current, as of 2026-08-27:

    PowerShell   33 tests   33 pass, 0 fail, 0 error, 0 hollow, 0 stale, 0 inconclusive
    bash         30 tests   30 pass, 0 fail, 0 error, 0 hollow, 0 stale, 0 inconclusive

Coverage is 21 of 32 PowerShell functions, 66%, measured by asking which
functions any test names rather than by estimating. That is an upper bound:
naming a function is not the same as asserting on it. The eleven with no test
are the interactive surface (`Show-List`, `Do-EditList`, `Do-ViewArchived`,
`Do-DeleteSession`, `Do-Resume`, `Get-SessionDisplayName`), the archive writer
(`Save-ArchivedSessions`), `Ensure-CleanupPeriodDays`, and the two recovery
paths plus their prompt builder (`Resolve-ResumeOrRecover`, `Do-Refresh`,
`Build-RecoveryMetaPrompt`).

## 9. Two environment findings that are not product bugs

Both cost real time, so they are written down rather than remembered.

**Every `.sh` in this repo was stored with CRLF.** `core.autocrlf=true` and no
`.gitattributes`. Git Bash tolerates it, so the suite ran green here all
evening while the file that would land on Linux was broken: a CRLF shebang
sends the kernel looking for an interpreter named `bash`. Now pinned by
`.gitattributes` and the tree renormalised. The lesson is narrower than "check
line endings": **the working copy is not what git stores.** Verify the blob,
`git show ":path" | file -`, because the working copy is exactly what autocrlf
rewrites on checkout, so looking there can never reveal the problem.

**Git Bash ships no `flock`.** `__cm_acquire_lock` answers a missing `flock` by
spinning its full 50 x 0.2s retry, so every `sessions.txt` write cost ten
seconds and the suite looked like it was hanging. `tests/stubs/flock` stands in
when the real one is absent and the suite says so out loud. Real Linux has it
from util-linux and the module lists it as a dependency, so production is fine.

Worth noting what this implies for a minimal container, though: no `flock`
means every write stalls ten seconds and then proceeds *unlocked anyway*, which
is the worst of both. The module never checks for it at startup. That is a
plausible defect and is flagged in `LINUX-HANDOVER.md` rather than fixed here,
because it is a product change and this sitting was about tests.
