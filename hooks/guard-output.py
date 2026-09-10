"""Stop hook: check what was just written against the `output` rules.

INTERACTIVE HONOURS THE BLOCK. HEADLESS DOES NOT. Measured 2026-09-10, both.

  interactive  a `deny` rule matched, the guard returned {"decision":"block"},
               and the harness sent the message back to be rewritten. The
               original never reached Bob. Proved with a throwaway rule on a
               nonsense token rather than by writing prose that broke a real
               rule, so the mechanism was tested without the side effect.
  headless     `claude -p` under the same flag: the guard returned the same
               block, the transcript shows one assistant message, and the
               offending text stood. The decision was discarded.

That is the same asymmetry as `ask` on PreToolUse, and it points the same way:
this guard is real where Bob actually works and decorative in scripted runs. Do
not rely on it to keep anything out of a headless pipeline.

The log at worklog\output-guard.log records every invocation, not just the ones
that fire, because "never ran", "ran without the message" and "ran and was
ignored" need different fixes and could not otherwise be told apart.

THIS WAS DECLARED UNBUILDABLE ONE MORNING, ON AN UNTESTED ASSUMPTION.

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
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
_LOG_DIR = os.path.join(HERE, "worklog")

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


def _note(kind, hits):
    """Record a decision beside the invocation log, so 'it fired and was
    ignored' is distinguishable from 'it never fired' after the fact."""
    try:
        os.makedirs(_LOG_DIR, exist_ok=True)
        with open(os.path.join(_LOG_DIR, "output-guard.log"), "a",
                  encoding="utf-8") as fh:
            fh.write("%s\t%s\t%s\n" % (
                datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), kind,
                ", ".join("%s:%r" % (r.slug, m) for r, m in hits)[:160]))
    except Exception:
        pass


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    message = payload.get("last_assistant_message")

    # EVERY invocation is logged, not just the ones that fire.
    #
    # Driven through a headless session this guard returned a correct block and
    # the em dash stood anyway, and there was no way to tell whether the hook
    # had not run, had not been given the message, or had run and been ignored.
    # Those need different fixes, so the log records all three separately.
    try:
        os.makedirs(_LOG_DIR, exist_ok=True)
        with open(os.path.join(_LOG_DIR, "output-guard.log"), "a",
                  encoding="utf-8") as fh:
            fh.write("%s\tfired\tmsg=%s\tstop_active=%s\n" % (
                datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                (len(message) if isinstance(message, str) else "NONE"),
                payload.get("stop_hook_active")))
    except Exception:
        pass

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
        _note("BLOCKED", hits)
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
