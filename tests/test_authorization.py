"""The rule-1 classifier, tested against real messages from this session.

Every case below is something Bob actually typed on 2026-09-10, labelled with
what the classifier must say about it. Synthetic examples would prove nothing:
the failure this exists to stop came from his real phrasing, and his phrasing
is full of questions that look like orders.

THE CASE THAT MATTERS is marked THE BREAK. It is the message that broke rule 1
in the session that was building the machinery to enforce it. If that one ever
goes green as 'work' again, this guard is worthless.

The bias is deliberate: ambiguous means stop. A message classified 'words' that
was really an instruction costs Bob one keystroke. A message classified 'work'
that was really a question costs him a mess. Those are not symmetric and the
tests are not balanced.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "hooks"))
import lib_authorization  # noqa: E402

PASS = [0]
FAIL = [0]


def check(expected, prompt, note=""):
    got, reason = lib_authorization.classify(prompt)
    if got == expected:
        print("  PASS   %-9s %s" % (got, prompt[:64].replace("\n", " ")))
        PASS[0] += 1
    else:
        print("  **FAIL**  expected %-9s got %-9s  %s"
              % (expected, got, prompt[:60].replace("\n", " ")))
        print("            reason: %s   %s" % (reason, note))
        FAIL[0] += 1


print("")
print("rule 1: THE BREAK")
print("")

check("words",
      "was the curve shape thing before this that we were talking about you "
      "said you were going to work on? Replay that.",
      "THE BREAK. A question whose only imperative is a speech verb.")
check("words", "Replay that.", "speech imperative alone is never authorisation")
check("words", "Tell me what you did.")
check("words", "Explain the guards to me.")

print("")
print("rule 1: real instructions, must be allowed")
print("")

for p in [
    "Get rid of the part file Play the notification sound when it finishes.",
    "just do everything what isn't done yet. Keep going.",
    "please do all three items",
    "commit and push and all that good shit.",
    "Do all tests that do not interfere with the regents",
    "the regents instance has an orphan. explore issue",
    "So go ahead and clean everything else up.",
    "Make an architecturally sound plan.",
    "save memories for exit",
    "read it",
    "Get these articles from the repository and put them in library.",
    "Okay, for shell shapes. We're agreed. Do that shit.",
    "Fix the 5 plus 5.",
    "Prepare memories for exit.",
]:
    check("work", p)

print("")
print("rule 1: real questions, must NOT authorise")
print("")

for p in [
    "Are we done?",
    "what projects have venv?",
    "Is everything pushed?",
    "Are you secure that you have a good plan for all of this?",
    "I'm worried that a block might break shit. What do you think?",
    "Would you please say that again?",
    "What the fuck is sub-agent block?",
    "why was this there in the first place?",
    "So talk to me about these guards. Are they still in the fucking way?",
    "How about the Apple article? Talk about that",
    "So YouTube processor, is that the videos themselves or some other shit?",
    "Okay, well what about the shell shape? and the sub-agent block.",
    "Should we fix that?",
    "can you check whether the backup ran?",
    "Do you think the guards are in the way?",
    "How big is it and what are the three biggest directories?",
]:
    check("words", p)

print("")
print("rule 1: approval with nothing named, must ask for the scope")
print("")

for p in ["Go ahead", "go ahead", "yes", "ok", "sure", "yep", "Okay",
          "yes do it", "ok go", "fine, do that", "alright then", "do it now"]:
    check("name-it", p)

print("")
print("rule 1: both in one message, answer first then work")
print("")

check("work", "Fix the part file. Does that make sense?",
      "an instruction plus a question is BOTH, not words")
check("work", "Explain what you did, then commit it.",
      "speech verb AND action verb is BOTH")


# ---------------------------------------------------------------- the hooks
import json          # noqa: E402
import shutil        # noqa: E402
import subprocess    # noqa: E402

HOOKS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks")
CLASSIFY = os.path.join(HOOKS, "classify-prompt.py")
GUARD = os.path.join(HOOKS, "guard-authorization.py")
STATE = os.path.join(HOOKS, "state")


def run(script, payload):
    p = subprocess.run([sys.executable, script], input=json.dumps(payload),
                       capture_output=True, text=True)
    return p.returncode, p.stdout


def decision(stdout):
    if not stdout.strip():
        return None
    try:
        return json.loads(stdout).get("hookSpecificOutput", {}).get("permissionDecision")
    except Exception:
        return "unparseable"


def turn(prompt, session="t1", prompt_id="p1"):
    run(CLASSIFY, {"prompt": prompt, "session_id": session, "prompt_id": prompt_id})


def call(session="t1", prompt_id="p1", tool="Bash"):
    return run(GUARD, {"tool_name": tool, "tool_input": {"command": "echo x"},
                       "session_id": session, "prompt_id": prompt_id})


def hcheck(name, cond, detail=""):
    if cond:
        print("  PASS      %s" % name)
        PASS[0] += 1
    else:
        print("  **FAIL**  %s" % name)
        if detail:
            print("            %s" % detail)
        FAIL[0] += 1


if os.path.isdir(STATE):
    shutil.rmtree(STATE, ignore_errors=True)

print("")
print("rule 1: the hooks, end to end")
print("")

turn("was the shell shape thing we were talking about? Replay that.")
rc, out = call()
hcheck("THE BREAK is refused at the first tool call", decision(out) == "deny", out[:200])
hcheck("and the guard exits 0", rc == 0)
hcheck("and the refusal quotes his actual message", "Replay that" in out, out[:250])

# Found live on 2026-09-10: the first version consumed the verdict, so exactly
# one call was refused and the rest of a concurrent batch ran. Tool calls in one
# response are concurrent, so the guard must refuse all of them.
rc2, out2 = call()
hcheck("the SECOND call is ALSO refused (concurrent calls must not slip past)",
       decision(out2) == "deny", out2[:200])
rc3, out3 = call()
hcheck("and the third", decision(out3) == "deny", out3[:200])

# It must still not wedge anything: a new message clears it.
turn("now build the thing", prompt_id="p1b")
rc4, out4 = call(prompt_id="p1b")
hcheck("a NEW authorised message clears the refusal",
       decision(out4) is None, out4[:200])

turn("commit and push it", prompt_id="p2")
rc, out = call(prompt_id="p2")
hcheck("a real instruction is allowed silently", decision(out) is None, out[:200])

turn("go ahead", prompt_id="p3")
rc, out = call(prompt_id="p3")
hcheck("a bare approval is refused for scope", decision(out) == "deny", out[:200])
hcheck("and it asks him to name the work", "named" in out or "name" in out, out[:250])

print("")
print("rule 1: fail-open (must never be the reason work cannot start)")
print("")

shutil.rmtree(STATE, ignore_errors=True)
rc, out = call(session="never-seen")
hcheck("no verdict at all: allows", rc == 0 and decision(out) is None, (rc, out))

turn("what did you do?", session="t2", prompt_id="pA")
rc, out = call(session="t2", prompt_id="pB")
hcheck("a verdict for a DIFFERENT prompt does not block this one",
       decision(out) is None, out[:200])

turn("what did you do?", session="t3", prompt_id="pC")
sf = os.path.join(STATE, "turn-t3.json")
with open(sf, "w", encoding="utf-8") as fh:
    fh.write("{ not json")
rc, out = call(session="t3", prompt_id="pC")
hcheck("a corrupt verdict file: allows", rc == 0 and decision(out) is None, (rc, out))

turn("what did you do?", session="t4", prompt_id="pD")
sf = os.path.join(STATE, "turn-t4.json")
d = json.load(open(sf, encoding="utf-8"))
d["at"] = 0
json.dump(d, open(sf, "w", encoding="utf-8"))
rc, out = call(session="t4", prompt_id="pD")
hcheck("a stale verdict: allows", decision(out) is None, out[:200])

proc = subprocess.run([sys.executable, GUARD], input="{ not json",
                      capture_output=True, text=True)
hcheck("malformed stdin: exits 0 and allows",
       proc.returncode == 0 and decision(proc.stdout) is None,
       (proc.returncode, proc.stdout))

proc = subprocess.run([sys.executable, CLASSIFY], input="{ not json",
                      capture_output=True, text=True)
hcheck("the classifier survives malformed stdin", proc.returncode == 0,
       proc.returncode)

shutil.rmtree(STATE, ignore_errors=True)

print("")
print("%d check(s): %d pass, %d fail" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
