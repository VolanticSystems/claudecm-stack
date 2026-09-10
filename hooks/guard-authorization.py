"""PreToolUse guard: refuse the FIRST tool call when the turn was not authorised.

This is the rule-1 guard. Everything else in this directory asks "is this action
forbidden". This one asks "should this turn contain a tool call at all", which
is the question that broke on 2026-09-10.

IT REFUSES EVERY TOOL CALL FOR AN UNAUTHORISED MESSAGE, not just the first.
The first version refused one and got out of the way, and a live run showed
why that fails: "the guard caught one, two others had already run." Calls in a
single response are concurrent, so a one-shot guard stops one and watches the
rest do the work. If a turn should be prose, no number of tool calls is right.

It still cannot stop a determined mistake, and it is not trying to. The model
can always answer in text, and Bob's next message writes a fresh verdict. What
this buys is that the refusal lands in the model's context at the moment it was
about to act, and that Bob is told rather than finding out afterwards.

THREE VERDICTS, TWO OF WHICH STOP

  work      allowed, silently
  words     refused: the message was a question, answer it in prose
  name-it   refused: the approval was real but named nothing, so say what you
            are about to do and get agreement on THAT

`name-it` exists because "go ahead" is authorisation with no scope, and the
scope is where this went wrong twice in one day. Bob: "Don't say, are we good
to go? Say, are we agreed that I should build module X."

IT ALWAYS EXITS 0 AND ALWAYS FAILS OPEN. No verdict, a stale verdict, a verdict
for a different prompt, a corrupt file, a clock that moved: all allow. A guard
that governs whether work may start must never be the thing that stops all work.

ONE-SHOT, CLAIMED ATOMICALLY. The verdict file is renamed to a private name
before being acted on, so simultaneous first calls cannot all refuse. The claim
name carries a random token as well as the pid, so a leftover from a killed
guard can never alias a later claim.
"""
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.join(HERE, "state")

# A verdict older than this is assumed to belong to a turn that has moved on.
WINDOW_SECONDS = 900
# Tolerance for a clock that has stepped backwards.
SKEW_SECONDS = 5

WORDS_MESSAGE = """\
STOP. This turn should be words, not work.

  Bob's message: {excerpt}
  Read as: {reason}

Rule 1: decide whether he asked for work or words BEFORE doing either. A
question gets an answer in prose and ZERO tool calls. If you genuinely believe
work is needed, say what you would do and ask him to confirm it.

Every tool call for this message is refused, not just this one. Answer him.

IF THIS IS WRONG, SAY SO. The classifier is tuned to stop on anything
ambiguous, which is Bob's stated preference, so false stops are expected and
are not evidence you did anything wrong. Tell him the guard misfired and on
which phrasing; that is how the word lists get better. Do not quietly work
around it."""

NAME_IT_MESSAGE = """\
STOP. He approved something, but nothing was named.

  Bob's message: {excerpt}
  Read as: {reason}

Say what you are about to do, specifically, and get agreement on that. Not
"are we good to go" but "are we agreed I should build X". Authorisation
attaches to a named deliverable and is spent when that thing is finished.

Twice on 2026-09-10 a bare approval was read as licence for the wrong work.
Every tool call for this message is refused. Ask him first."""


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    session = str(payload.get("session_id") or "unknown")
    state_file = os.path.join(STATE_DIR, "turn-%s.json" % session)
    if not os.path.isfile(state_file):
        return 0                                    # nothing said: allow

    try:
        with open(state_file, encoding="utf-8") as fh:
            state = json.load(fh)
    except Exception:
        return 0                                    # unreadable: allow

    verdict = state.get("verdict")
    if verdict not in ("words", "name-it"):
        return 0

    # The verdict must belong to THIS prompt. Without this, a verdict written
    # for one message refuses a tool call from the next one.
    mine = str(payload.get("prompt_id") or "")
    theirs = str(state.get("prompt_id") or "")
    if mine and theirs and mine != theirs:
        return 0

    try:
        age = datetime.datetime.now().timestamp() - float(state.get("at") or 0)
    except Exception:
        return 0
    if age > WINDOW_SECONDS or age < -SKEW_SECONDS:
        return 0                                    # stale or skewed: allow

    # NOT one-shot, and this was found the hard way. The first version claimed
    # the verdict with an atomic rename so only one call could be refused,
    # copied from a guard whose job was different. Driven through a real
    # session on 2026-09-10 it reported: "the guard caught one, two others had
    # already run." Tool calls in one response are concurrent, so consuming the
    # verdict refuses exactly one of them and lets the rest do the work the turn
    # was not authorised for.
    #
    # So the verdict is left in place and EVERY call for this prompt is refused.
    # That makes it a stop rather than a speed bump, which is right: if the turn
    # should be prose, no number of tool calls is acceptable. The model can
    # still answer, and Bob's next message writes a new verdict.
    #
    # It cannot wedge a session: the verdict is scoped to one prompt_id and
    # expires by WINDOW_SECONDS, and every failure path above allows.

    template = WORDS_MESSAGE if verdict == "words" else NAME_IT_MESSAGE
    reason = template.format(
        excerpt=(state.get("excerpt") or "")[:140].replace("\n", " "),
        reason=state.get("reason") or "unclear")

    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        },
        "systemMessage": "rule 1: this turn was not authorised for work (%s)." % verdict,
    }
    sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
