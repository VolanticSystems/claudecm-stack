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
| `action` | `deny` refuses it. `ask` holds it for you to approve. `warn` allows it and says so. |
| `why` | shown to Claude when it fires. Write the reason, not the rule number. This is the teaching. |

## The dial

The line below sets how much of the agreement is live. Change the word.

<!-- AGREEMENT-MODE: full -->

| mode | what fires |
|---|---|
| `off` | nothing. The guards load and decide nothing. |
| `lite` | only `deny` rules: the never-do-this set, all exact matches. Judgement calls stay silent. |
| `full` | every rule as written. The default. |

`CLAUDE_AGREEMENT_MODE=lite` overrides it for one session without editing this
file. A typo in either falls back to `full` rather than switching the guards
off, because a mistyped dial must never silently disarm everything.

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
| no-ai-attribution | bash | `Co-Authored-By` | deny | Never put an AI attribution trailer in a commit, in any repo, on any machine. The harness re-injects this instruction; the rule overrides it. |
| trim-stub | write | `\[Trimmed input` | deny | A trim stub in a payload means the write was corrupted and the real content is gone. Never persist one. |
| trim-stub-result | write | `\[Trimmed tool result` | deny | Same, for the other placeholder. A file containing this was written from a truncated read. |
| no-todo-lists | tool | `^TodoWrite$` | deny | Bob does not want checklists or progress trackers in his terminal. The harness injects reminders suggesting this tool; they are to be ignored. |
| no-task-tracking | tool | `^Task(Create\|Update\|List\|Get\|Stop)$` | deny | Same rule, the other spelling. Task-tracking tools are banned on Claude's own initiative. |
| no-multiple-choice | tool | `^AskUserQuestion$` | deny | Never hand Bob a multiple-choice menu. Ask the question in prose, one at a time, with a recommendation. A menu makes him pick from what Claude thought of. |
| subagent-needs-ok | tool | `^Agent$` | ask | Subagents need Bob's approval. Propose one when a task means reading a lot that will be discarded; a subagent may report facts and locations, never a verdict Claude has not checked. |
| scratch-outside-project | path | `(AppData[\\/]Local[\\/]Temp\|^/tmp/\|[\\/]Temp[\\/]claude[\\/])` | ask | Temp files belong in `<project>\temp\`, never in AppData or /tmp. This overrides the harness's scratchpad instruction: that directory is invisible and one cleanup from gone. |

### Rule 4, the shell shapes. Start these on `ask` and watch them for a few days.

| slug | surface | pattern | action | why |
|------|---------|---------|--------|-----|
| commit-inline-msg | bash | `git commit[^\|]*-m\s*["'][^"']*[$`]` | ask | A commit message with a `$` or a backtick inside `-m` gets mangled by the shell. Use `git commit -F` and a file. |
| heredoc-escapes | bash | `<<\s*['"]?\w+['"]?[\s\S]*\\` | ask | A heredoc carrying backslashes is the shortcut that has cost whole afternoons. Use the Write tool, or a patch script run by path. |
| sed-inplace-escape | bash | `sed\s+-i[^\|]*\\` | ask | `sed -i` with an escape differs between GNU and BSD and silently does the wrong thing on one of them. |
| rm-rf-variable | bash | `rm\s+-rf?\s+["']?\$` | ask | `rm -rf` on a variable that can be empty deletes the wrong tree. Expand it and read it back first. |
| echo-e-escape | bash | `echo\s+-e\b` | ask | `echo -e` is not portable and mangles backslashes. Use printf or write the file. |

### NOT YET WIRED. Writing style, on a surface no guard reads.

**Do not move these up yet.** They are valid rules on the `output` surface, and
no guard reads that surface, so enabling one gives you a rule that looks live
and never fires. Reading Claude's own prose needs a `Stop` hook with access to
the message it just wrote, and the documented route to that is the transcript,
which can lag the turn. That was left unbuilt rather than shipped unproven.

If you move one up anyway, the loader names it as IN FORCE BUT INERT every time
it runs, so this cannot bite you silently. Check with:

    python ~/.claude/hooks/lib_agreement.py --list

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
