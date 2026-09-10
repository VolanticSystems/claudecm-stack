"""UserPromptSubmit: record what Bob said, and shout when he says I overstepped.

This hook classifies NOTHING and blocks NOTHING. That is the whole point of it.
Its predecessor tried to judge whether a message authorised work, using word
lists, and produced four false positives in one afternoon while never catching
the failure it existed for. It was deleted.

Two jobs:

  1. Keep a short history of Bob's actual words, so a citation in a work task
     can be checked against something he really said. No interpretation, no
     vocabulary, no judgement about phrasing: only "did these words exist".

  2. When he says stop, record it loudly alongside whatever task was open and
     whatever licence was being claimed at the time. He asked for this directly.

Harness events are skipped, since a task-completion notification is not Bob
speaking and would otherwise pollute the citation history.
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

_strip = lib_worklog.strip_harness_envelopes


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
    if not prompt:
        return 0

    human, machine = _strip(prompt)
    if machine:
        return 0                       # a notification is not Bob speaking

    session = str(payload.get("session_id") or "unknown")
    prompt_id = payload.get("prompt_id") or payload.get("tool_use_id")

    lib_worklog.record_prompt(human, session, prompt_id)

    if lib_worklog.looks_like_stop(human):
        lib_worklog.record_stop(human, lib_worklog.current_task(session))
        # Whatever was running is no longer sanctioned. Closing it means the
        # next state change needs a fresh citation rather than coasting on the
        # licence he just objected to.
        lib_worklog.close_task("Bob said stop", session)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
