"""PreToolUse guard for the TOOL ITSELF: tools that must not be used at all.

WHAT IT IS FOR
  Some of Bob's rules are not about the content of a command or a file, they
  are about a tool existing. "Never use TodoWrite." "Do not use AskUserQuestion,
  ever, not once." "Subagents need my approval first." Those are prohibitions on
  a NAME, and a name is the cheapest thing in the world to match exactly.

  This matters more than it looks. The harness actively pushes back on two of
  them: it injects reminders suggesting TodoWrite, and CLAUDE.md has a whole
  section telling the model to ignore those reminders. A rule that has to be
  re-read and re-obeyed every turn against a system that keeps suggesting
  otherwise is exactly the rule worth moving out of prose.

  It also carries the `path` surface for writes, because "which file" is a
  different question from "what content" and deserves its own pattern. The only
  path rule intended is the scratch-file one: a temp file belongs in the
  project's temp/, not in AppData or /tmp. This is NOT a general
  outside-the-repo guard; see guard-write.py for why that idea is wrong.

IT ALWAYS EXITS 0
  See guard-bash.py. A non-zero exit blocks the tool call, and a guard that can
  wedge the session is worse than whatever it was guarding.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import lib_agreement
except Exception:
    sys.exit(0)

# Where a write is going, per tool. Read from the payload rather than assumed:
# the field name differs between the write-shaped tools.
PATH_FIELDS = ("file_path", "notebook_path", "path")


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    tool = payload.get("tool_name") or ""
    if not tool:
        return 0

    tool_input = payload.get("tool_input") or {}

    checks = [(tool, "tool")]
    for field in PATH_FIELDS:
        value = tool_input.get(field)
        if isinstance(value, str) and value:
            checks.append((value, "path"))

    # Subagent launches get two extra surfaces, and they are the only ones a
    # NEGATED rule may sit on. That is what makes delegation governable without
    # banning it: a launch can be refused unless its prompt asks for something
    # checkable, rather than the Agent tool being forbidden outright.
    #
    # The ban that used to be here was bad design. Bob: "Sometimes I will use
    # Fable or Opus and say I want you to do what you can with Sonnet. This
    # prevents that." Handing grunt work to a cheaper model is a thing he wants,
    # and the risk was never that an agent ran, it was what it was asked for and
    # what came back.
    if tool == "Agent":
        checks.append((tool_input.get("subagent_type") or "", "agent_type"))
        checks.append((tool_input.get("prompt") or "", "agent_prompt"))

    hits = []
    problems = []
    for text, surface in checks:
        try:
            found, more = lib_agreement.evaluate(text, surface)
        except Exception as exc:
            _emit_note("work agreement could not be evaluated (%s); allowed." % exc)
            return 0
        hits.extend(found)
        for p in more:
            if p not in problems:
                problems.append(p)

    if not hits:
        if problems:
            _emit_note("work agreement: " + "; ".join(problems))
        return 0

    action = lib_agreement.worst(hits)
    if action == "warn":
        _emit_note(_summary(hits, tool, "allowed, but note"))
        return 0

    reason = _summary(hits, tool,
                      "BLOCKED" if action == "deny" else "HELD FOR BOB")
    if problems:
        reason += "\n\n(also: " + "; ".join(problems) + ")"

    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": action,
            "permissionDecisionReason": reason,
        },
        "systemMessage": "work agreement: %s %s (%s)." % (
            "blocked" if action == "deny" else "held",
            tool,
            ", ".join(sorted({r.slug for r, _ in hits}))),
    }
    sys.stdout.write(json.dumps(out))
    return 0


def _summary(hits, tool, headline):
    lines = ["%s. Using %s matches the work agreement:" % (headline, tool), ""]
    for rule, matched in hits:
        lines.append("  %s  matched %r" % (rule.slug, matched))
        if rule.why:
            lines.append("      %s" % rule.why)
    lines.append("")
    lines.append("Do the thing another way. Do not reach for a different tool that")
    lines.append("achieves the same forbidden result.")
    return "\n".join(lines)


def _emit_note(message):
    sys.stdout.write(json.dumps({"systemMessage": message}))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
