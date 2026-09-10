"""PreToolUse guard for Bash. Matches the command against the work agreement.

WHAT IT IS FOR
  Rule 4: use the right tool. The shell shapes that mangle content silently,
  the commit flags that carry an attribution trailer, the destructive command
  built out of an unquoted variable. Every one of those is a PROHIBITION: a
  literal pattern that must not appear. Prohibitions are the half of the work
  agreement a machine can check, so they are checked here instead of being
  described in CLAUDE.md and read 200 times a session.

IT ALWAYS EXITS 0
  A non-zero exit from a PreToolUse hook blocks the tool call. Measured
  2026-09-09: a hook pointed at a missing script stopped a real session dead,
  alive but unable to act, and Claude cannot repair that because repairing
  means editing a file and editing is a tool call. So every decision travels as
  JSON and every internal failure allows. The one thing this guard must never
  do is break the machine it is guarding.

  The corollary: if the agreement file is missing, nothing is enforced. That is
  said out loud in a systemMessage rather than being silent.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import lib_agreement
except Exception:  # the guard is optional; the session is not
    sys.exit(0)

SURFACE = "bash"


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0  # unreadable input is not grounds to block anything

    tool = payload.get("tool_name") or ""
    if tool != "Bash":
        return 0

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command:
        return 0

    try:
        hits, problems = lib_agreement.evaluate(command, SURFACE)
    except Exception as exc:
        _emit_note("work agreement could not be evaluated (%s); the command was allowed." % exc)
        return 0

    if not hits:
        if problems:
            _emit_note("work agreement: " + "; ".join(problems))
        return 0

    action = lib_agreement.worst(hits)
    if action == "warn":
        _emit_note(_summary(hits, "allowed, but note"))
        return 0

    reason = _summary(hits, "BLOCKED" if action == "deny" else "HELD FOR BOB")
    if problems:
        reason += "\n\n(also: " + "; ".join(problems) + ")"

    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": action,
            "permissionDecisionReason": reason,
        },
        "systemMessage": "work agreement: %s a Bash command (%s)." % (
            "blocked" if action == "deny" else "held",
            ", ".join(sorted({r.slug for r, _ in hits}))),
    }
    sys.stdout.write(json.dumps(out))
    return 0


def _summary(hits, headline):
    lines = [headline + ". This command matches the work agreement:", ""]
    for rule, matched in hits:
        lines.append("  %s  matched %r" % (rule.slug, matched))
        if rule.why:
            lines.append("      %s" % rule.why)
    lines.append("")
    lines.append("The rule lives in ~/.claude/agreement.md and Bob owns it. Do the thing")
    lines.append("the right way rather than rephrasing the command to slip past the match.")
    return "\n".join(lines)


def _emit_note(message):
    sys.stdout.write(json.dumps({"systemMessage": message}))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # never block on our own bug
