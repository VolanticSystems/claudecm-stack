"""The work record: only Bob creates work.

The design this replaces classified Bob's messages with word lists and refused
tool calls on turns it judged unauthorised. It produced four false positives in
one afternoon, every one blocking a READ, and never caught the failure it was
built for. These tests exist to stop that design coming back:

  - reads are asserted ungated, repeatedly and deliberately
  - nothing here asserts anything about how Bob phrases a message

The failure being guarded is a SEQUENCE: reading surfaces a defect, and the
defect becomes its own instruction. So the gate is on state changes, and the
key is that a citation must be words Bob actually said.
"""
import io
import json
import os
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS = os.path.join(REPO, "hooks")
sys.path.insert(0, HOOKS)

import lib_worklog  # noqa: E402

GUARD = os.path.join(HOOKS, "guard-worklog.py")
RECORD = os.path.join(HOOKS, "record-prompt.py")

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


def fresh():
    shutil.rmtree(lib_worklog.STATE_DIR, ignore_errors=True)
    os.makedirs(lib_worklog.STATE_DIR, exist_ok=True)


def said(text, prompt_id="p1"):
    subprocess.run([sys.executable, RECORD],
                   input=json.dumps({"prompt": text, "session_id": "t",
                                     "prompt_id": prompt_id}),
                   capture_output=True, text=True)


def call(tool, tool_input):
    p = subprocess.run([sys.executable, GUARD],
                       input=json.dumps({"tool_name": tool,
                                         "tool_input": tool_input,
                                         "session_id": "t"}),
                       capture_output=True, text=True)
    if p.returncode != 0:
        return "NONZERO", p.stderr[:120]
    if not p.stdout.strip():
        return "allow", ""
    try:
        d = json.loads(p.stdout)
        return d.get("hookSpecificOutput", {}).get("permissionDecision", "allow"), p.stdout
    except Exception:
        return "unparseable", p.stdout[:120]


print("")
print("work record: READS ARE NEVER GATED")
print("")

fresh()   # no task open at all: the strictest case for a read

for tool, ti in [
    ("Read", {"file_path": "C:/anything.md"}),
    ("Grep", {"pattern": "x"}),
    ("Glob", {"pattern": "**/*.py"}),
    ("WebFetch", {"url": "https://example.com"}),
    ("Bash", {"command": "ls -la /c/Users/Bob"}),
    ("Bash", {"command": "cat somefile.txt"}),
    ("Bash", {"command": "grep -rn 'thing' ."}),
    ("Bash", {"command": "git status --short"}),
    ("Bash", {"command": "git log --oneline -5"}),
    ("Bash", {"command": "python tests/test_worklog.py"}),
    ("Bash", {"command": "find . -name '*.md'"}),
    ("Bash", {"command": "wc -l < file.txt"}),
]:
    got, _ = call(tool, ti)
    check("%s %s" % (tool, str(ti)[:46]), got == "allow", got)

print("")
print("work record: state changes need an open task")
print("")

fresh()
for tool, ti in [
    ("Write", {"file_path": "C:/Users/Bob/thing.md", "content": "x"}),
    ("Edit", {"file_path": "C:/Users/Bob/thing.md", "old_string": "a", "new_string": "b"}),
    ("Bash", {"command": "rm -rf C:/Users/Bob/something"}),
    ("Bash", {"command": "git commit -F msg.txt"}),
    ("Bash", {"command": "git push origin master"}),
    ("Bash", {"command": "echo hello > out.txt"}),
    ("Bash", {"command": "pip install requests"}),
    ("Bash", {"command": "cp a.txt b.txt"}),
]:
    got, _ = call(tool, ti)
    check("refused with no task: %s %s" % (tool, str(ti)[:40]), got == "deny", got)

print("")
print("work record: redirects. A discard is a read; a file is a write")
print("")

# 2026-09-10: the first version of the redirect pattern matched `2>/dev/null`,
# so `ls -la x 2>/dev/null` was refused as a state change. A guard blocking a
# read is the precise failure this design exists to avoid, and it was shipped by
# the guard built to avoid it. Three spellings of discard, one per shell.
fresh()
for cmd in [
    "ls -la /c/Users/Bob/.claude/hooks/state/ 2>/dev/null",
    "cat payload.json 2>/dev/null",
    "grep -rn thing . 2>/dev/null",
    "git status --short 2>&1",
    "python tests/test_worklog.py 2>&1 | tail -1",
    "ls -d /f/Backups/* 2>$null",
    "find . -name '*.md' 2>/dev/null | head",
    "wc -l < somefile.txt",
]:
    got, _ = call("Bash", {"command": cmd})
    check("read, not gated: %s" % cmd[:52], got == "allow", got)

for cmd in [
    "echo hi > out.txt",
    "echo more >> log.txt",
    "python gen.py > report.md",
    "somecmd 2> errors.log",
]:
    got, _ = call("Bash", {"command": cmd})
    check("write, gated: %s" % cmd[:52], got == "deny", got)

print("")
print("work record: an inline interpreter that writes is a state change")
print("")

# Found while dogfooding on 2026-09-10: a `python -c` that opens a file for
# writing walked through a gate that had just refused the identical Edit.
fresh()
for cmd in [
    """python -c "open('x.md','w').write('hi')" """,
    """python -c "import io; io.open(p,'w',encoding='utf-8').write(t)" """,
    """pwsh -Command "Set-Content -Path x.txt -Value y" """,
    """python -c "import os; os.remove('thing')" """,
]:
    got, _ = call("Bash", {"command": cmd})
    check("gated: %s" % cmd.strip()[:52], got == "deny", got)

# Reading with an interpreter is still a read.
for cmd in [
    """python -c "print(open('x.md').read())" """,
    """python -c "import json,io; print(json.load(io.open('c.json')))" """,
    "python tests/test_worklog.py",
]:
    got, _ = call("Bash", {"command": cmd})
    check("not gated: %s" % cmd.strip()[:52], got == "allow", got)

print("")
print("work record: the citation must be something Bob actually said")
print("")

fresh()
said("Fix your output surface and figure out a plan for the collisions.")

ok, why = lib_worklog.open_task("build the output guard",
                                "Fix your output surface")
check("a real quote opens a task", ok, why)

fresh()
said("Fix your output surface and figure out a plan for the collisions.")
ok, why = lib_worklog.open_task("refactor the whole agreement engine",
                                "rewrite everything from scratch")
check("an INVENTED citation is refused", not ok, why)
check("and says why", "do not appear" in why, why)

ok, why = lib_worklog.open_task("do a thing", "ok")
check("a citation too short to be a quote is refused", not ok, why)

# Punctuation and smart quotes must not defeat a genuine quote.
fresh()
said("Okay, so let's be clear \u2014 rip out whatever the fuck you did.")
ok, why = lib_worklog.open_task("remove the classifier",
                                "rip out whatever the fuck you did")
check("normalisation survives punctuation and dashes", ok, why)

print("")
print("work record: a task lets state changes through")
print("")

fresh()
said("Fix your output surface.")
lib_worklog.open_task("build the output guard", "Fix your output surface")
got, _ = call("Write", {"file_path": "C:/Users/Bob/thing.md", "content": "x"})
check("with a task open, a write is allowed", got == "allow", got)

print("")
print("work record: exemptions")
print("")

fresh()
got, _ = call("Write", {"file_path": lib_worklog.TASK_FILE, "content": "{}"})
check("writing the task file itself is exempt (bootstrap)", got == "allow", got)
got, _ = call("Write", {"file_path": os.path.join(REPO, "temp", "scratch.py"),
                        "content": "x"})
check("scratch in the project temp is exempt", got == "allow", got)
got, _ = call("Write", {"file_path": "C:/Users/Bob/.claude/CLAUDE.md", "content": "x"})
check("but a real file is still gated", got == "deny", got)

print("")
print("work record: Bob said stop")
print("")

fresh()
said("Go build the output guard.")
lib_worklog.open_task("build the output guard", "Go build the output guard")
said("stop. I never asked you to do that.", prompt_id="p2")

log = io.open(lib_worklog.LOG_FILE, encoding="utf-8").read()
check("the overreach is recorded in big red letters",
      "BOB SAID I WENT OVER THE LINE" in log, log[-300:])
check("with his words", "I never asked you" in log, log[-300:])
check("and the licence I was claiming at the time",
      "Go build the output guard" in log, log[-400:])
check("the task is closed, so the next change needs a fresh citation",
      lib_worklog.current_task() is None)

got, _ = call("Write", {"file_path": "C:/Users/Bob/thing.md", "content": "x"})
check("and a state change is refused again", got == "deny", got)

print("")
print("work record: fail-open")
print("")

shutil.rmtree(lib_worklog.STATE_DIR, ignore_errors=True)
got, _ = call("Read", {"file_path": "x"})
check("no state directory at all: reads allowed", got == "allow", got)

fresh()
with io.open(lib_worklog.TASK_FILE, "w", encoding="utf-8") as fh:
    fh.write("{ not json")
got, _ = call("Write", {"file_path": "C:/Users/Bob/thing.md", "content": "x"})
check("a corrupt task file refuses rather than crashing", got == "deny", got)

fresh()
said("Fix your output surface.")
lib_worklog.open_task("build it", "Fix your output surface")
task = json.load(io.open(lib_worklog.TASK_FILE, encoding="utf-8"))
task["opened_at"] = time.time() - (lib_worklog.TASK_MAX_AGE_HOURS + 2) * 3600
json.dump(task, io.open(lib_worklog.TASK_FILE, "w", encoding="utf-8"))
check("a stale task is not an open task", lib_worklog.current_task() is None)

p = subprocess.run([sys.executable, GUARD], input="{ not json",
                   capture_output=True, text=True)
check("malformed stdin: exits 0 and allows",
      p.returncode == 0 and not p.stdout.strip(), (p.returncode, p.stdout[:80]))

p = subprocess.run([sys.executable, RECORD], input="{ not json",
                   capture_output=True, text=True)
check("the recorder survives malformed stdin", p.returncode == 0, p.returncode)

shutil.rmtree(lib_worklog.STATE_DIR, ignore_errors=True)

print("")
print("%d check(s): %d pass, %d fail" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
