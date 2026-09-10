"""The Stop hook that checks Claude's own prose.

Declared unbuildable this morning on an untested assumption, that reading the
assistant's message needs the transcript and the transcript lags. Probing an
actual Stop hook showed the payload carries `last_assistant_message` directly.
The two writing rules sat unenforced for a day because of a guess.

The dangerous part is the loop: blocking a Stop makes the model continue, which
produces another Stop. `stop_hook_active` is what stops that spinning, and it is
asserted here, because a style guard that can trap a session is worse than no
style guard at all.
"""
import io
import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS = os.path.join(REPO, "hooks")
GUARD = os.path.join(HOOKS, "guard-output.py")

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


def make_agreement(tmp, rows):
    body = ["<!-- AGREEMENT:BEGIN -->", "",
            "| slug | surface | pattern | action | why |",
            "|---|---|---|---|---|"] + rows + ["", "<!-- AGREEMENT:END -->"]
    path = os.path.join(tmp, "agreement.md")
    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(body) + "\n")
    return path


def run(message, agreement, stop_active=False):
    payload = {
        "hook_event_name": "Stop",
        "last_assistant_message": message,
        "stop_hook_active": stop_active,
        "session_id": "t",
    }
    p = subprocess.run([sys.executable, GUARD], input=json.dumps(payload),
                       capture_output=True, text=True,
                       env=dict(os.environ, CLAUDE_AGREEMENT_PATH=agreement))
    if p.returncode != 0:
        return "NONZERO", p.stderr[:120]
    if not p.stdout.strip():
        return "allow", ""
    try:
        d = json.loads(p.stdout)
        return d.get("decision") or "note", p.stdout
    except Exception:
        return "unparseable", p.stdout[:120]


tmp = tempfile.mkdtemp(prefix="outguard-")

DASH = "| no-em-dash | output | `[—–]` | deny | no em dashes in prose |"
TIC = ("| no-honesty-tic | output | `\\b(honestly\\|frankly\\|candidly)\\b` "
       "| deny | sincerity language reads as an AI tell |")
WARNONLY = "| soft | output | `maybe` | warn | just a note |"

print("")
print("output guard: it can read what was just written")
print("")

a = make_agreement(tmp, [DASH, TIC])

got, out = run("This sentence — with an em dash — is wrong.", a)
check("an em dash blocks the turn", got == "block", out[:200])
check("and names the rule", "no-em-dash" in out, out[:200])
check("and quotes what matched", "matched" in out, out[:200])

got, out = run("Honestly, this is the thing.", a)
check("sincerity language blocks the turn", got == "block", out[:160])

got, out = run("This sentence is clean, with commas and a semicolon; nothing else.", a)
check("clean prose passes silently", got == "allow", out[:160])

got, out = run("The word honest is the subject here, not an emphasis crutch.", a)
check("'honest' as a subject is not the banned tic", got == "allow", out[:160])

print("")
print("output guard: THE LOOP HAZARD")
print("")

got, out = run("Another — dash.", a, stop_active=True)
check("it will NOT block twice in one turn", got != "block", out[:200])
check("but it still says so", "no-em-dash" in out, out[:200])
check("and explains why it let it stand", "stand" in out, out[:250])

print("")
print("output guard: warn does not block")
print("")

b = make_agreement(tmp, [WARNONLY])
got, out = run("maybe this is fine", b)
check("a warn rule notes rather than blocking", got == "note", out[:160])

print("")
print("output guard: fail-open")
print("")

got, out = run("", a)
check("an empty message: allows", got == "allow", out[:120])

p = subprocess.run([sys.executable, GUARD], input="{ not json",
                   capture_output=True, text=True)
check("malformed stdin: exits 0 and allows",
      p.returncode == 0 and not p.stdout.strip(), (p.returncode, p.stdout[:80]))

got, out = run("This — dash.", os.path.join(tmp, "missing.md"))
check("a missing agreement: allows rather than blocking", got != "block", out[:160])

payload = json.dumps({"hook_event_name": "Stop", "session_id": "t"})
p = subprocess.run([sys.executable, GUARD], input=payload,
                   capture_output=True, text=True,
                   env=dict(os.environ, CLAUDE_AGREEMENT_PATH=a))
check("no last_assistant_message at all: allows",
      p.returncode == 0 and not p.stdout.strip(), p.stdout[:80])

import shutil
shutil.rmtree(tmp, ignore_errors=True)

print("")
print("%d check(s): %d pass, %d fail" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
