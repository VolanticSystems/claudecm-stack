"""Stop hook: check what was just written against the `output` rules.

THIS WAS DECLARED UNBUILDABLE THIS MORNING, ON AN UNTESTED ASSUMPTION.

The claim was that reading Claude's own prose needs the transcript, which the
docs say can lag the turn, so the two writing-style rules were fenced off in the
menu as "NOT YET WIRED". Probing an actual Stop hook took two minutes and showed
the payload carries `last_assistant_message` directly: the exact text, no
transcript read, no lag. The rules were unenforced for a day because a guess was
never checked.

WHAT IT ENFORCES
  Rules on the `output` surface in agreement.md. Today that is Bob's two
  standing writing rules, no em dashes and no sincerity language, both of which
  he has had to correct by hand more often than anything else.

  `deny` blocks the turn from ending, and Claude rewrites. `warn` notes it and
  lets it stand.

THE LOOP HAZARD, WHICH IS THE ONLY DANGEROUS PART
  Blocking a Stop makes the model continue, which produces another Stop. If that
  blocks too, the session spins forever. The payload carries `stop_hook_active`,
  true when a Stop hook has already fired for this turn, and this hook refuses
  to block twice on the strength of it. So the worst case is one rewrite, and a
  second offending message is allowed through with a note rather than trapping
  the session.

ALWAYS EXITS 0. Every failure path lets the turn end. A guard on style must
never be able to stop Bob getting an answer.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

try:
    import lib_agreement
except Exception:
    sys.exit(0)

SURFACE = "output"

BLOCK = """\
Your reply breaks a standing writing rule. Rewrite it and send it again.

{hits}
The rule lives in ~/.claude/agreement.md and Bob owns it. Fix the prose; do not
argue with the rule, and do not send the same text again with an apology
attached."""


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    message = payload.get("last_assistant_message")
    if not isinstance(message, str) or not message.strip():
        return 0

    try:
        hits, problems = lib_agreement.evaluate(message, SURFACE)
    except Exception:
        return 0

    if not hits:
        return 0

    action = lib_agreement.worst(hits)
    lines = []
    for rule, matched in hits:
        lines.append("  %s  matched %r" % (rule.slug, matched))
        if rule.why:
            lines.append("      %s" % rule.why)
    detail = "\n".join(lines) + "\n"

    # Already blocked once this turn: note it and let it go, rather than
    # spinning. One rewrite is the most this will ever ask for.
    if action == "deny" and not payload.get("stop_hook_active"):
        sys.stdout.write(json.dumps({
            "decision": "block",
            "reason": BLOCK.format(hits=detail),
        }))
        return 0

    note = "work agreement (output): " + ", ".join(
        sorted({r.slug for r, _ in hits}))
    if action == "deny" and payload.get("stop_hook_active"):
        note += " (already rewritten once this turn; letting it stand)"
    sys.stdout.write(json.dumps({"systemMessage": note}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
