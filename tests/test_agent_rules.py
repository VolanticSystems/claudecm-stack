"""Subagent rules: govern how delegation is asked for, do not ban it.

Bob rejected the ban outright: "Sometimes I will use Fable or Opus and say I
want you to do what you can with Sonnet. This prevents that... throwing out the
baby with the bathwater is an immature and stupid way to address the problem."

He was right. The risk was never that an agent ran, it was what it was asked for
and what came back. Three things are visible before a launch (the type, the
model, and the whole prompt), so the discipline goes there.

The primitive that makes this possible is a NEGATED pattern, `!x`, which fires
when x is MISSING. That is what lets a rule require something rather than only
forbid it. It is refused on any surface except the two agent ones, because a
negated rule on a general surface would fire on every unrelated tool call.
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS = os.path.join(REPO, "hooks")
sys.path.insert(0, HOOKS)
import lib_agreement  # noqa: E402

GUARD = os.path.join(HOOKS, "guard-tool.py")
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


def agreement(tmp, rows, name="a.md"):
    body = ["<!-- AGREEMENT:BEGIN -->", "",
            "| slug | surface | pattern | action | why |",
            "|---|---|---|---|---|"] + rows + ["", "<!-- AGREEMENT:END -->"]
    p = os.path.join(tmp, name)
    io.open(p, "w", encoding="utf-8", newline="\n").write("\n".join(body) + "\n")
    return p


def launch(prompt, agreement_path, subagent_type="Explore", model="sonnet"):
    payload = json.dumps({
        "tool_name": "Agent",
        "tool_input": {"subagent_type": subagent_type, "model": model,
                       "prompt": prompt},
        "session_id": "t"})
    p = subprocess.run([sys.executable, GUARD], input=payload,
                       capture_output=True, text=True,
                       env=dict(os.environ, CLAUDE_AGREEMENT_PATH=agreement_path))
    if p.returncode != 0:
        return "NONZERO", p.stderr[:120]
    if not p.stdout.strip():
        return "allow", ""
    try:
        d = json.loads(p.stdout)
        return (d.get("hookSpecificOutput", {}).get("permissionDecision")
                or "note"), p.stdout
    except Exception:
        return "unparseable", p.stdout[:120]


tmp = tempfile.mkdtemp(prefix="agentrules-")

EVID = ("| agent-must-be-checkable | agent_prompt | "
        "`!(line number\\|file:line\\|quote the\\|test that\\|command that proves)` "
        "| deny | the answer must be checkable |")
VIS = "| agent-is-visible | tool | `^Agent$` | warn | announce every launch |"

print("")
print("agent rules: the launch is governed, not banned")
print("")

a = agreement(tmp, [EVID, VIS])

got, out = launch(
    "Sweep every repo for calls to Get-Sessions. Report each as path and "
    "line number with the matching line quoted.", a)
check("a launch asking for checkable evidence is allowed", got == "note", out[:160])
check("and it announces itself", "agent-is-visible" in out, out[:200])

got, out = launch("Review the code and tell me if there are any bugs.", a)
check("a launch asking for a VERDICT is refused", got == "deny", out[:200])
check("and says what is missing", "missing" in out.lower(), out[:250])

got, out = launch(
    "Implement the parser from the spec below, then run the command that "
    "proves it works: pytest tests/test_parser.py", a,
    subagent_type="general-purpose")
check("a WRITING agent stating what proves it works is allowed",
      got == "note", out[:160])

got, out = launch("Go fix the failing tests.", a, subagent_type="general-purpose")
check("a writing agent with no acceptance test is refused", got == "deny", out[:160])

got, out = launch("", a)
check("an empty prompt is refused, not waved through", got == "deny", out[:160])

print("")
print("agent rules: Bob's own case must work")
print("")

got, out = launch(
    "Read every file under src/ and list each TODO as file:line with the "
    "line quoted. Do not draw conclusions.", a, model="sonnet")
check("handing grunt work to Sonnet passes cleanly", got == "note", out[:160])
check("and the model is visible in the note", "Agent" in out, out[:200])

print("")
print("agent rules: a negated pattern is confined to the agent surfaces")
print("")

bad = agreement(tmp, ["| oops | bash | `!something` | deny | wrong surface |"],
                name="bad.md")
rules, problems = lib_agreement.load(bad)
check("a negated rule on `bash` is refused at load", not rules, str(rules))
check("and the reason names the allowed surfaces",
      any("agent_type" in p for p in problems), str(problems))

ok = agreement(tmp, ["| fine | agent_prompt | `!needle` | deny | right surface |"],
               name="ok.md")
rules, problems = lib_agreement.load(ok)
check("a negated rule on agent_prompt loads", len(rules) == 1, str(problems))
check("and is marked negated", rules and rules[0].negated)

hits, _ = lib_agreement.evaluate("this has the needle in it", "agent_prompt", ok)
check("present: does not fire", not hits, str(hits))
hits, _ = lib_agreement.evaluate("this does not have it", "agent_prompt", ok)
check("absent: fires", len(hits) == 1, str(hits))

print("")
print("agent rules: ordinary tools are untouched by any of this")
print("")

for tool, ti in [("Bash", {"command": "ls"}), ("Read", {"file_path": "x"})]:
    payload = json.dumps({"tool_name": tool, "tool_input": ti, "session_id": "t"})
    p = subprocess.run([sys.executable, GUARD], input=payload,
                       capture_output=True, text=True,
                       env=dict(os.environ, CLAUDE_AGREEMENT_PATH=a))
    check("%s is not affected by the agent rules" % tool,
          p.returncode == 0 and not p.stdout.strip(), p.stdout[:120])

shutil.rmtree(tmp, ignore_errors=True)

print("")
print("%d check(s): %d pass, %d fail" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
