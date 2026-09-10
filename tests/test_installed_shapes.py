"""Verify the rule-4 shell shapes against the INSTALLED guard, not a fixture.

Every other test here drives the repo copy against a synthetic agreement. This
one drives ~/.claude/hooks/guard-bash.py against ~/.claude/agreement.md, which
is the thing that actually decides whether a command runs. Measuring a pattern
in a fixture and then enabling it in the live file are two different claims, and
on 2026-09-10 the second one was made without the first being checked.

Skips cleanly when nothing is installed, so it is safe to run anywhere.

The two `deny` rules were additionally proved by running them for real in a live
session and being refused: `echo -e` and `rm -rf "$var"` both blocked. That part
cannot be automated here without the harness, and it is recorded in the commit.
"""
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
GUARD = os.path.join(HOME, ".claude", "hooks", "guard-bash.py")
AGREEMENT = os.path.join(HOME, ".claude", "agreement.md")

if not (os.path.isfile(GUARD) and os.path.isfile(AGREEMENT)):
    print("\nSKIP: the work agreement is not installed on this machine.\n")
    sys.exit(0)

PASS = [0]
FAIL = [0]


def check(name, cond, detail=""):
    if cond:
        print("  PASS      %s" % name)
        PASS[0] += 1
    else:
        print("  **FAIL**  %s" % name)
        if detail:
            print("            %s" % detail)
        FAIL[0] += 1


def decide(command):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command},
                          "session_id": "test", "prompt_id": "test"})
    r = subprocess.run([sys.executable, GUARD], input=payload,
                       capture_output=True, text=True)
    if r.returncode != 0:
        return "NONZERO-EXIT", r.stderr[:120]
    if not r.stdout.strip():
        return "allow", ""
    try:
        d = json.loads(r.stdout)
        action = d.get("hookSpecificOutput", {}).get("permissionDecision")
        return (action or "warn"), d.get("systemMessage", "")
    except Exception:
        return "unparseable", r.stdout[:120]


# slug, the shape it must catch, the action expected, an ordinary command
CASES = [
    ("commit-inline-msg", 'git commit -m "fix $HOME thing"', "warn",
     "git commit -F temp/msg.txt"),
    ("heredoc-escapes", "cat <<'EOF' > f.py\nx = 'a\\nb'\nEOF", "warn",
     "cat <<EOF > f.txt\nplain text\nEOF"),
    ("sed-inplace-escape", r"sed -i 's/a/\n/' file.txt", "warn",
     "sed -n '1,20p' file.txt"),
    ("rm-rf-variable", 'rm -rf "$target"', "deny", "rm -rf temp/scratch-dir"),
    ("echo-e-escape", r'echo -e "a\nb"', "deny", "echo hello world"),
]

print("")
print("rule 4 shell shapes, against the INSTALLED guard")
print("")

for slug, trap, expected, ordinary in CASES:
    got, msg = decide(trap)
    check("%s fires on the shape it is for (%s)" % (slug, expected),
          got == expected and slug in msg, "got %s / %s" % (got, msg[:90]))
    got2, _ = decide(ordinary)
    check("%s ignores an ordinary command" % slug, got2 == "allow",
          "%r -> %s" % (ordinary.split("\n")[0][:44], got2))

print("")
print("commands actually run on 2026-09-10: none may fire")
print("")

REAL = [
    "git add -A && git commit -F temp/msg.txt",
    "python tests/test_authorization.py 2>&1 | tail -22",
    "rm -rf temp/rule1 temp/count-calls.py hooks/state",
    "git fetch origin 2>&1 | tail -1",
    "cp hooks/guard-write.py /c/Users/Bob/.claude/hooks/guard-write.py",
    "grep -n 'AGREEMENT:END' /c/Users/Bob/.claude/agreement.md",
    "ls -la /f/Backups/GitHubFiles/*.zip",
    "echo MY_SESSION_STILL_WORKS",
    "sed -n '1,16p' /c/Users/Bob/.claude/CLAUDE.md",
    "wc -l < /c/Users/Bob/.claude/CLAUDE.md",
    "python temp/verify-shapes.py",
    "bash tests/run-tests.sh 2>&1 | tail -1",
]
fired = [c for c in REAL if decide(c)[0] != "allow"]
check("%d real commands, none fire" % len(REAL), not fired,
      "fired: " + "; ".join(c[:50] for c in fired))

print("")
print("%d check(s): %d pass, %d fail" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
