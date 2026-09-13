# The work agreement

This file is yours. The guards read it every time they run, so a change here is
live on the next tool call. No restart, no code, no involvement from Claude.

**Only rows between the two markers are in force.** Everything below them is a
menu of ready-made rules that are deliberately switched off. To turn one on,
cut the line and paste it above the END marker. To turn it off again, move it
back. That is the whole mechanism.

## Columns

| column | meaning |
|---|---|
| `slug` | short stable name. Quoted back at Claude when the rule fires. Names, not numbers, because numbers get renumbered and every citation breaks. |
| `surface` | `bash` a shell command, `write` the content of a file, `path` where a write is going, `tool` the tool's own name, `output` Claude's prose. Comma-separate for several. |
| `pattern` | a regular expression, matched case-insensitively. Backticks around it are optional and stripped. |
| `action` | `deny` refuses it. `warn` allows it and says so. `ask` prompts, and blocks in every mode; never use it on a headless path. |
| `why` | shown to Claude when it fires. Write the reason, not the rule number. This is the teaching. |

## The dial

The line below sets how much of the agreement is live. Change the word.

<!-- AGREEMENT-MODE: full -->
<!-- JUDGE-MODE: warn -->

The second line is the edit judge's own dial, separate from the rules table.
`warn` judges every edit, writes what it would have refused to
`hooks/worklog/judge-log.md` with your words beside it, and refuses nothing.
`deny` refuses. Start on warn, read the log, change the word. A typo falls to
warn, the direction that cannot block anyone. `CLAUDE_JUDGE_MODE` overrides it
for one session.

| mode | what fires |
|---|---|
| `off` | nothing. The guards load and decide nothing. |
| `lite` | only `deny` rules: the never-do-this set, all exact matches. Judgement calls stay silent. |
| `full` | every rule as written. The default. |

`CLAUDE_AGREEMENT_MODE=lite` overrides it for one session without editing this
file. A typo in either falls back to `full` rather than switching the guards
off, because a mistyped dial must never silently disarm everything.

## Authorization is not this file's job any more

Changed 2026-09-11. ClaudeCM used to launch every session with
`--dangerously-skip-permissions`. Bypass switches OFF plan mode and the
auto-mode classifier, which are Claude Code's own protections against an
instance acting beyond what was asked: *"Except in sessions with bypass
permissions available, edits stay blocked until you approve the plan."* So the
machine had no authorization layer, and one was built here by hand.

The interactive launches now use `--permission-mode auto`. A classifier model
reviews each action and blocks anything that escalates beyond the request, with
no routine prompts, which was the whole reason bypass was there. The homegrown
replacement measured a 13% leak against 100 hand-labelled messages; one model
trained for the job beats word lists.

**So this file is for preferences a classifier cannot know**: that the operator hates em
dashes and multiple-choice menus, that an AI attribution trailer must never
reach a commit, that a corrupted payload must never be written. Not for deciding
whether work was authorised.

The two headless `-p` launches keep bypass, because nobody is there to answer if
the classifier holds something.

**One gap the classifier leaves, and the edit judge that fills it.** Added
2026-09-12. The classifier never reviews an Edit or Write inside the working
directory; those are auto-approved before it is consulted. That is exactly
"read the bug report, then fix the bug". `judge-edit.py`, installed with
`install-hooks.ps1 -WithJudge`, hands a separate model (Haiku, headless on the
subscription, so nothing leaves the provider that already has every message)
the operator's last five messages and the pending edit and asks whether his words
directed it. It reads no rule from this table; the only thing here it honours
is the dial: `off` switches it off along with everything else. It fails open,
ignores subagents and the memory directory, and records every call in
`hooks/worklog/judge-costs.jsonl`.

## `ask` blocks in every mode. Corrected 2026-09-13.

**The 2026-09-10 measurement below was wrong and is kept only so nobody
re-derives it.** It said a hook returning `ask` was treated as allow in an
interactive `--dangerously-skip-permissions` session, so `ask` was no gate at
all. Re-measured 2026-09-13 on 2.1.269: **`ask` blocks in every mode, bypass
included.** It is a real gate.

Two things changed underneath that first reading. ClaudeCM no longer launches
with bypass at all; since 2026-09-11 interactive sessions start in
`--permission-mode auto`, so the bypass case is no longer the normal one. And
the original test could not distinguish "allowed" from "blocked with nothing
rendered", which is the shape of a measurement that needs a control.

**Use `deny` for anything that must be stopped** and lift it by moving the row
below the END marker. Use `warn` when a note is enough. `ask` is now usable
where a human decision is genuinely wanted, with one caveat that still holds:
in a **headless** `claude -p` session there is nobody to answer, so `ask` is an
unapprovable wall there. Never put `ask` on a path a script takes.

**Test a rule before you trust it**, without needing a session:

    python ~/.claude/hooks/lib_agreement.py --list
    python ~/.claude/hooks/lib_agreement.py --surface bash --test "git commit -m x"

A bad row is skipped and named, never fatal, and it never disarms the others.

## Rules in force

<!-- AGREEMENT:BEGIN -->

| slug | surface | pattern | action | why |
|------|---------|---------|--------|-----|

<!-- AGREEMENT:END -->

Nothing above means nothing is enforced. That is the intended state for a first
install: the machinery loads and decides nothing, so you can confirm your
sessions behave normally before any rule can misfire.

---

## Not in force: the menu

Move a line up into the table above to enable it.

### Safe to enable first. No judgement in them, so they cannot misfire.

| slug | surface | pattern | action | why |
|------|---------|---------|--------|-----|
| no-ai-attribution | bash | `git commit[^;\|&]*-m[^;\|&]*Co-Authored-By` | deny | Never put an AI attribution trailer in a commit, in any repo, on any machine. The harness re-injects this instruction; the rule overrides it. Scoped to an inline `-m` message, so a command that merely mentions the string (grepping to CHECK for one, for instance) is not refused. |
| trim-stub | write | `\[Trimmed input: ~\d+ chars\]` | deny | A corrupted payload: the real content is gone and the tool still reported success. Never persist one. Matches the real signature, which always carries a digit count, so a document *about* the bug can still quote it loosely. |
| trim-stub-result | write | `\[Trimmed tool result: ~\d+ chars\]` | deny | Same, for the other placeholder. A file containing this was written from a truncated read. |
| no-todo-lists | tool | `^TodoWrite$` | deny | the operator does not want checklists or progress trackers in his terminal. The harness injects reminders suggesting this tool; they are to be ignored. |
| no-task-tracking | tool | `^Task(Create\|Update\|List\|Get)$` | deny | Same rule, the other spelling. Task-tracking tools are banned on Claude's own initiative. **TaskStop is deliberately NOT here**: it kills a runaway background process, which is nothing to do with checklists, and banning it means a loop Claude started cannot be cleaned up by Claude. |
| no-multiple-choice | tool | `^AskUserQuestion$` | deny | Never hand the operator a multiple-choice menu. Ask the question in prose, one at a time, with a recommendation. A menu makes him pick from what Claude thought of. |
| subagent-needs-ok | tool | `^Agent$` | deny | Subagents need the operator's approval. Propose one in prose when a task means reading a lot that will be discarded; a subagent may report facts and locations, never a verdict Claude has not checked. To allow one, move this row below the END marker. |
| scratch-outside-project | path | `(AppData[\\/]Local[\\/]Temp\|^/tmp/\|[\\/]Temp[\\/]claude[\\/])` | deny | Temp files belong in `<project>\temp\`, never in AppData or /tmp. This overrides the harness's scratchpad instruction: that directory is invisible and one cleanup from gone. |

### Rule 4, the shell shapes.

These are regex rather than exact strings, so they are the ones with any real
chance of a false positive. Start a row on `warn`, which lets it speak without
stopping anything, and promote it to `deny` once you have watched it behave. Do
not use `ask`: see the note above.

On the operator's machine all five went in on 2026-09-10, three as `warn` and two as
`deny`, after each was triggered against the installed guard and watched to fire
while twelve commands actually run that day were checked to be sure none of them
did. `tests/test_installed_shapes.py` re-runs that check against whatever is
deployed, and skips cleanly where nothing is installed.

| slug | surface | pattern | action | why |
|------|---------|---------|--------|-----|
| commit-inline-msg | bash | `git commit[^\|]*-m\s*["'][^"']*[$`]` | warn | A commit message with a `$` or a backtick inside `-m` gets mangled by the shell. Use `git commit -F` and a file. |
| heredoc-escapes | bash | `<<\s*['"]?\w+['"]?[\s\S]*\\` | warn | A heredoc carrying backslashes is the shortcut that has cost whole afternoons. Use the Write tool, or a patch script run by path. |
| sed-inplace-escape | bash | `sed\s+-i[^\|]*\\` | warn | `sed -i` with an escape differs between GNU and BSD and silently does the wrong thing on one of them. |
| rm-rf-variable | bash | `rm\s+-rf?\s+["']?\$` | warn | `rm -rf` on a variable that can be empty deletes the wrong tree. Expand it and read it back first. |
| echo-e-escape | bash | `echo\s+-e\b` | warn | `echo -e` is not portable and mangles backslashes. Use printf or write the file. |

### Writing style. WIRED, and proved to block.

`guard-output.py` runs on `Stop` and reads `last_assistant_message` straight
from the payload, so Claude's own prose is checkable. This was written off as
unbuildable on the assumption that it needed the transcript and the transcript
lags; probing a real Stop hook took two minutes and showed otherwise.

Measured 2026-09-10, both directions:

- **interactive**: a `deny` match sends the message back to be rewritten, and
  the original never reaches the operator. Proved with a throwaway rule.
- **headless** (`claude -p`): the same block is discarded and the text stands.

So these rules are real where the operator works and decorative in scripted runs, the
same asymmetry as `ask` on PreToolUse. The guard cannot block twice in one turn,
so it can never spin a session.

| slug | surface | pattern | action | why |
|------|---------|---------|--------|-----|
| no-em-dash | output | `[—–]` | warn | No em dashes or en dashes in prose. Use a comma, semicolon, colon, period or parentheses. |
| no-honesty-tic | output | `\b(honestly\|to be honest\|the honest (answer\|truth\|read)\|candidly\|frankly\|real talk)\b` | warn | Sincerity language as an emphasis device reads as an AI tell and implies the rest should be trusted less. State the point directly. |

### Deliberately not offered

A path guard that refuses writes outside the current repository. It sounds
sensible and it breaks the auto-memory directory in every project, along with
edits to `~/.claude/CLAUDE.md` itself. It belongs to a single project that
wants it, not to a machine-wide agreement.

## One hazard worth knowing

A pattern that is slow can hit the hook timeout, and a timed-out hook blocks
the tool call. The `--test` command above prints how long a match took and
warns if it took over a second. Test anything with nested `*` or `+` before
enabling it.
