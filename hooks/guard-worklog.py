"""PreToolUse: a state change needs an open task citing something Bob said.

READS ARE NEVER GATED. Not once. Bob, 2026-09-10: "I never wanted you to not
read things." The previous guard blocked reads four times in an afternoon and
caught nothing; this one does not look at them at all.

What it gates is the second half of the sequence he actually complained about:
reading surfaces a defect, and the defect becomes its own instruction. So before
anything on his machine changes, there has to be an open task naming the work
and quoting the words of his that asked for it.

WHY THE CITATION IS THE MECHANISM
  It needs no judgement about phrasing. It never tries to interpret him. It asks
  one question a computer can answer: do these words appear in something Bob
  said? That is why it cannot false-positive on how he writes, which is the
  failure that killed the previous design.

SATISFIABLE BY ME, NEVER BY HIM
  A refusal here costs Bob nothing. The fix is that I open a task, which is a
  sentence. Compare the Agent ban, where the only way past was Bob editing a
  file: a rule I can satisfy by doing better work is free, a rule that needs him
  is friction. That distinction is why this one is `deny` without apology.

EXEMPT, DELIBERATELY
  The task file itself, or the file that records work could never be written.
  The state directory, same reason. And the project's `temp/`, because scratch
  written while investigating a question is part of reading, not part of doing,
  and gating it would put friction back on exactly the behaviour Bob wants.

ALWAYS EXITS 0. A missing task file, a corrupt one, an import that fails: all
allow. A guard governing whether work may proceed must never be the reason no
work can proceed.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

try:
    import lib_worklog
except Exception:
    sys.exit(0)

REFUSAL = """\
STOP. This changes something, and no task is open.

  About to: {tool}{target}

Only Bob creates work. A finding is not a mandate: reading something that
reveals a defect does not authorise fixing it, and neither does a plan you
wrote earlier or an error you just hit.

If he asked for this, open a task first by writing:

  {task_file}

  {{"what": "<what you are about to do>",
   "citation": "<his exact words that asked for it>",
   "opened_at": <unix seconds>}}

The citation is checked against what he actually said. If you cannot quote him,
that is the answer: you were not asked. Report what you found and stop.

To WITHDRAW a task, delete that file. Writing or deleting anything in that
directory is exempt from this guard, from any tool, so you are never stuck.
{extra}"""


def _target(tool_input):
    for key in ("file_path", "notebook_path", "path"):
        v = (tool_input or {}).get(key)
        if isinstance(v, str) and v:
            return "  ->  " + v
    cmd = (tool_input or {}).get("command")
    if isinstance(cmd, str) and cmd:
        return "  ->  " + " ".join(cmd.split())[:90]
    return ""


def _exempt(tool_input):
    """Writing the record itself, or scratch inside the project's temp.

    THE REMEDY MUST NOT BE INSIDE THE GATE. The refusal below tells the reader
    to write the task file, and until 2026-09-10 doing that from Bash was
    refused as "a change" while no task was open, which is the exact state the
    message is instructing you to leave. The Write tool succeeded on the same
    path, so the gate was inconsistent between tools and the one carrying the
    instructions was the one that would not carry it out. A blikje session was
    wedged by precisely that.

    So the state directory is exempt however it is reached: by path field, or
    by a shell command that names it.
    """
    state = os.path.realpath(lib_worklog.STATE_DIR).replace("\\", "/").lower()

    for key in ("file_path", "notebook_path", "path"):
        v = (tool_input or {}).get(key)
        if not isinstance(v, str) or not v:
            continue
        try:
            p = os.path.realpath(os.path.abspath(v)).replace("\\", "/").lower()
        except Exception:
            continue
        if p.startswith(state):
            return True
        if "/temp/" in p or p.endswith("/temp"):
            return True

    # A shell command touching the state directory: opening, closing or
    # clearing a task. Matched on the directory name so the spelling of the
    # path separator and the quoting do not matter.
    cmd = (tool_input or {}).get("command")
    if isinstance(cmd, str) and cmd:
        c = cmd.replace("\\", "/").lower()
        # Matched against the CONFIGURED state directory, not a hardcoded
        # ~/.claude path: the first version hardcoded it and so exempted
        # nothing when the directory was somewhere else, which is exactly the
        # kind of thing that only shows up on someone else's machine.
        for needle in (state, os.path.basename(state) + "/current-task.json",
                       "current-task.json", "task-"):
            if needle and needle in c:
                return True
    return False


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}

    try:
        if not lib_worklog.is_mutating(tool, tool_input):
            return 0                              # a read: never gated
        if _exempt(tool_input):
            return 0
        # Keyed by session: another instance's licence is not this one's.
        task = lib_worklog.current_task(payload.get("session_id"))
    except Exception:
        return 0                                  # our bug is not his problem

    if task:
        # THE CITATION IS CHECKED HERE, NOT ONLY WHEN THE TASK IS OPENED.
        #
        # The task file is an exempt path, so it can be written directly with
        # the Write tool, which skips the library function that validates the
        # citation. On 2026-09-10 a task was opened that way citing a sentence
        # Claude had written rather than anything Bob said, and nothing caught
        # it. Validating at USE closes that: an unfounded licence is worth
        # nothing however it got onto disk.
        try:
            ok, why = lib_worklog.citation_matches(
                task.get("citation") or "", payload.get("session_id"))
        except Exception:
            return 0                              # cannot check: do not block
        if ok:
            return 0
        reason = (
            "STOP. A task is open, but its citation cannot be matched.\n\n"
            "  task:     %s\n"
            "  citing:   %r\n"
            "  problem:  %s\n\n"
            "Usually that means the licence was written rather than quoted, and\n"
            "a licence you wrote for yourself is not a licence.\n\n"
            "BUT IT CAN ALSO MEAN THE RECORD IS SHORT, NOT THAT YOU INVENTED IT.\n"
            "The history only holds what this session has said since the guards\n"
            "were installed. If Bob really did say this, say so plainly and ask\n"
            "him to repeat it; do not pretend you were not asked.\n\n"
            "To withdraw this task, delete:\n"
            "  %s\n"
            "Writing or deleting anything in that directory is exempt from this\n"
            "guard, from any tool, so you are never stuck."
            % ((task.get("what") or "")[:120], (task.get("citation") or "")[:120],
               why, lib_worklog.TASK_FILE))
        try:
            lib_worklog.log("REFUSED", "unfounded citation: %s"
                            % (task.get("citation") or "")[:80])
        except Exception:
            pass
        sys.stdout.write(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            },
            "systemMessage": "work record: the open task cites nothing Bob said.",
        }))
        return 0

    reason = REFUSAL.format(
        tool=tool, target=_target(tool_input),
        task_file=lib_worklog.TASK_FILE,
        extra="")

    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        },
        "systemMessage": "no open task: a state change was refused (%s)." % tool,
    }
    try:
        lib_worklog.log("REFUSED", "%s %s" % (tool, _target(tool_input).strip()))
    except Exception:
        pass
    sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
