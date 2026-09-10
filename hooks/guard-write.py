"""PreToolUse guard for Write, Edit and NotebookEdit. Checks what is being written.

WHAT IT IS FOR
  Content that must never reach a file. The original case is the trim-stub
  regression: a bug once replaced Write/Edit payloads with the placeholder
  "[Trimmed input: ~N chars]" while the tool still reported success, and it
  corrupted real markdown before anyone noticed. A rule for that cannot live in
  prose, because by the time prose is recalled the file is already wrong.

  It checks CONTENT, not paths. Deliberately: a path guard that refuses
  everything outside the repository also refuses the auto-memory directory,
  which breaks memory in every project. That guard belongs to a single project
  that wants it, not to this machine-wide agreement.

IT ALWAYS EXITS 0
  See guard-bash.py. Decisions travel as JSON; a non-zero exit would block the
  call, and a guard that can wedge the session is worse than the thing it
  guards. The exception this guard exists for, the trim stub, is expressed as a
  deny row in the agreement, not as a special exit code.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import lib_agreement
except Exception:
    sys.exit(0)

SURFACE = "write"
WATCHED = ("Write", "Edit", "MultiEdit", "NotebookEdit")

# BOOTSTRAP EXEMPTION. The agreement file is not subject to its own rules.
#
# Found the hard way on 2026-09-10, the first hour the guards were live. A rule
# row necessarily CONTAINS the pattern it matches, so writing that row trips the
# rule and the agreement becomes uneditable by the only means available. A bad
# pattern could then never be corrected: you would be locked out of the file
# that locks you out. Same reason a linter does not lint its own config.
#
# Narrow on purpose: the exemption is one exact path, it applies only to this
# content check, and every skip is announced rather than silent.


def _is_agreement(path):
    try:
        target = os.path.realpath(os.path.abspath(path))
        known = os.path.realpath(os.path.abspath(lib_agreement.default_agreement_path()))
        if target == known:
            return True
        # Also the repo copy, wherever this script was installed from.
        beside = os.path.realpath(os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "agreement.md"))
        return target == beside
    except Exception:
        return False

# Every field across the write-shaped tools that carries content the model
# authored. Read rather than assumed, because the names differ per tool and
# have changed between versions.
CONTENT_FIELDS = ("content", "new_string", "new_source", "replace_all_with")


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return 0

    if (payload.get("tool_name") or "") not in WATCHED:
        return 0

    tool_input = payload.get("tool_input") or {}

    target_path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if target_path and _is_agreement(target_path):
        _emit_note("work agreement: content checks skipped for the agreement file "
                   "itself (a rule row contains the pattern it matches, so the file "
                   "would otherwise be uneditable). Path: %s" % target_path)
        return 0

    chunks = []
    for field in CONTENT_FIELDS:
        value = tool_input.get(field)
        if isinstance(value, str) and value:
            chunks.append(value)
    # MultiEdit carries a list of edits rather than a flat field.
    for edit in (tool_input.get("edits") or []):
        if isinstance(edit, dict):
            for field in CONTENT_FIELDS:
                value = edit.get(field)
                if isinstance(value, str) and value:
                    chunks.append(value)

    if not chunks:
        return 0
    text = "\n".join(chunks)

    try:
        hits, problems = lib_agreement.evaluate(text, SURFACE)
    except Exception as exc:
        _emit_note("work agreement could not be evaluated (%s); the write was allowed." % exc)
        return 0

    if not hits:
        if problems:
            _emit_note("work agreement: " + "; ".join(problems))
        return 0

    action = lib_agreement.worst(hits)
    if action == "warn":
        _emit_note(_summary(hits, tool_input, "allowed, but note"))
        return 0

    reason = _summary(hits, tool_input,
                      "BLOCKED" if action == "deny" else "HELD FOR BOB")
    if problems:
        reason += "\n\n(also: " + "; ".join(problems) + ")"

    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": action,
            "permissionDecisionReason": reason,
        },
        "systemMessage": "work agreement: %s a write (%s)." % (
            "blocked" if action == "deny" else "held",
            ", ".join(sorted({r.slug for r, _ in hits}))),
    }
    sys.stdout.write(json.dumps(out))
    return 0


def _summary(hits, tool_input, headline):
    target = tool_input.get("file_path") or tool_input.get("notebook_path") or "(unknown file)"
    lines = ["%s. The content being written to %s matches the work agreement:" % (headline, target), ""]
    for rule, matched in hits:
        lines.append("  %s  matched %r" % (rule.slug, matched))
        if rule.why:
            lines.append("      %s" % rule.why)
    lines.append("")
    lines.append("Fix the content. Do not write it to a different path to get past this.")
    return "\n".join(lines)


def _emit_note(message):
    sys.stdout.write(json.dumps({"systemMessage": message}))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
