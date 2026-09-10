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
    """Writing the record itself, or scratch inside the project's temp."""
    for key in ("file_path", "notebook_path", "path"):
        v = (tool_input or {}).get(key)
        if not isinstance(v, str) or not v:
            continue
        try:
            p = os.path.realpath(os.path.abspath(v)).replace("\\", "/").lower()
        except Exception:
            continue
        state = os.path.realpath(lib_worklog.STATE_DIR).replace("\\", "/").lower()
        if p.startswith(state):
            return True
        if "/temp/" in p or p.endswith("/temp"):
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
        task = lib_worklog.current_task()
    except Exception:
        return 0                                  # our bug is not his problem

    if task:
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
