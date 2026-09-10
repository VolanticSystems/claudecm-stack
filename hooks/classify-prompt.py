"""UserPromptSubmit hook: decide whether this turn may contain tool calls.

Writes a verdict that guard-authorization.py reads on the first tool call.
Decides nothing itself and never blocks a prompt.

THE PUBLISH IS THE RENAME. The verdict is written to a sibling temp file and
moved into place with os.replace, so a guard reading concurrently sees either
the old verdict or the new one, never half of either. Learned from the-regents,
who hit exactly this race.

THE VERDICT NAMES ITS PROMPT. Every PreToolUse payload carries a prompt_id, so
the guard can refuse to act on a verdict belonging to an earlier message. Without
that, a verdict written for message N blocks a tool call from message N+1, which
is how a stale-state guard turns into a session that cannot work.

FAILURE IS SILENT AND HARMLESS. If anything here breaks, no verdict is written,
and a missing verdict means the guard allows. A hook that decides whether work
may happen must never be the reason work cannot happen.
"""
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

try:
    import lib_authorization
except Exception:
    sys.exit(0)

STATE_DIR = os.path.join(HERE, "state")


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    prompt = None
    for key in ("prompt", "user_prompt", "message", "text"):
        v = payload.get(key)
        if isinstance(v, str) and v.strip():
            prompt = v
            break

    session = str(payload.get("session_id") or "unknown")
    prompt_id = payload.get("prompt_id") or payload.get("tool_use_id")

    try:
        verdict, reason = lib_authorization.classify(prompt)
    except Exception as exc:
        verdict, reason = "work", "classifier failed (%s); allowing" % exc

    state = {
        "verdict": verdict,
        "reason": reason,
        "prompt_id": str(prompt_id) if prompt_id else None,
        "at": datetime.datetime.now().timestamp(),
        "excerpt": (prompt or "")[:160],
    }

    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        final = os.path.join(STATE_DIR, "turn-%s.json" % session)
        tmp = final + ".tmp-%d-%s" % (os.getpid(), os.urandom(8).hex())
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(state))
        os.replace(tmp, final)          # the rename IS the publish
    except Exception:
        pass                            # no verdict means the guard allows

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
