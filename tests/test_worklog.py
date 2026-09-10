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
    shutil.rmtree(lib_worklog.RECORDS_DIR, ignore_errors=True)
    os.makedirs(lib_worklog.STATE_DIR, exist_ok=True)
    os.makedirs(lib_worklog.RECORDS_DIR, exist_ok=True)


def said(text, prompt_id="p1", session="t"):
    subprocess.run([sys.executable, RECORD],
                   input=json.dumps({"prompt": text, "session_id": session,
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
    # NOTE: `python tests/test_worklog.py` is deliberately NOT here. Since the
    # guard reads the script it is asked to run, a suite that creates scratch
    # files is correctly seen as changing the machine, and needs a task like
    # anything else. That is real friction on a common action, and it is the
    # honest reading of "only Bob creates work" rather than a carve-out by
    # filename, which anyone could then use by calling a file test_something.
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
print("work record: an unfounded citation is worthless however it got written")
print("")

# 2026-09-10. The task file is an exempt path, so it can be written directly
# with the Write tool, which skips the library call that validates the citation.
# A task was opened that way citing a sentence CLAUDE had written rather than
# anything Bob said, and nothing caught it. The check now runs at USE.
fresh()
said("Go and finish the backup script.")
io.open(lib_worklog.TASK_FILE, "w", encoding="utf-8", newline="\n").write(
    json.dumps({"what": "do whatever I like",
                "citation": "Permission to rewrite the whole system",
                "opened_at": time.time()}))
got, out = call("Write", {"file_path": "C:/Users/Bob/thing.md", "content": "x"})
check("a hand-written task with an invented citation is refused",
      got == "deny", got)
check("and the refusal quotes the bogus citation",
      "Permission to rewrite" in out, out[:250])

io.open(lib_worklog.TASK_FILE, "w", encoding="utf-8", newline="\n").write(
    json.dumps({"what": "finish the backup script",
                "citation": "Go and finish the backup script",
                "opened_at": time.time()}))
got, _ = call("Write", {"file_path": "C:/Users/Bob/thing.md", "content": "x"})
check("the same file with a real quote is honoured", got == "allow", got)

print("")
print("work record: a short approval is citable when it is the whole message")
print("")

# "Yes, do that" is real authorisation and is under the twelve-character floor,
# so requiring a substring match would have made his most common approval
# uncitable. It counts only as an entire message, which keeps it unambiguous.
fresh()
said("Yes, do that.")
ok, why = lib_worklog.citation_matches("Yes, do that.")
check("his whole short message is a valid citation", ok, why)
check("and says so", "whole message" in why, why)

ok, why = lib_worklog.citation_matches("yes")
check("but a fragment of it is not", not ok, why)

fresh()
said("Go ahead and rebuild the installer, then run the suite.")
ok, why = lib_worklog.citation_matches("rebuild the installer")
check("a long-enough substring of a long message still works", ok, why)

print("")
print("work record: a task belongs to ONE session")
print("")

# Found 2026-09-10 while investigating a hook collision in another project. The
# first version kept a single global task file, so three instances in three
# projects shared one licence: A opened a task and B inherited it, which is the
# exact opposite of what this is for.
fresh()
said("Go and build the output guard for me.", session="alpha")
lib_worklog.open_task("build the output guard",
                      "Go and build the output guard", session_id="alpha")

check("the session that opened it has a task",
      lib_worklog.current_task("alpha") is not None)
check("a DIFFERENT session does not inherit it",
      lib_worklog.current_task("beta") is None)


def call_as(session, tool, tool_input):
    p = subprocess.run([sys.executable, GUARD],
                       input=json.dumps({"tool_name": tool,
                                         "tool_input": tool_input,
                                         "session_id": session}),
                       capture_output=True, text=True)
    if not p.stdout.strip():
        return "allow"
    try:
        return json.loads(p.stdout).get(
            "hookSpecificOutput", {}).get("permissionDecision", "allow")
    except Exception:
        return "unparseable"


w = {"file_path": "C:/Users/Bob/thing.md", "content": "x"}
check("the owning session may change state", call_as("alpha", "Write", w) == "allow")
check("another session may NOT", call_as("beta", "Write", w) == "deny")

lib_worklog.close_task("done", "alpha")
check("closing it clears only that session's task",
      lib_worklog.current_task("alpha") is None)

print("")
print("work record: CLEARING STATE MUST NOT DESTROY THE RECORD")
print("")

# 2026-09-10. Records and ephemeral state shared a directory, so clearing stuck
# task files also wiped the prompt history. Older authorisations then silently
# stopped being citable, and the guard refused a commit because the message that
# authorised it no longer existed. Nothing had said one of them was precious.
fresh()
said("Go and rebuild the installer for me please.")
lib_worklog.open_task("rebuild the installer",
                      "Go and rebuild the installer", session_id="s1")
lib_worklog.log("SOMETHING", "an entry that must survive")

check("records and state are different directories",
      os.path.dirname(lib_worklog.PROMPTS_FILE)
      != os.path.dirname(lib_worklog.TASK_FILE))

# The exact move that caused the incident.
shutil.rmtree(lib_worklog.STATE_DIR, ignore_errors=True)

check("the task is gone, which is the point of clearing state",
      lib_worklog.current_task("s1") is None)
check("the prompt history SURVIVES", len(lib_worklog.recent_prompts()) >= 1,
      str(lib_worklog.recent_prompts()))
ok, why = lib_worklog.citation_matches("Go and rebuild the installer")
check("so an old authorisation is still citable", ok, why)
check("and the audit trail survives",
      "an entry that must survive" in io.open(
          lib_worklog.LOG_FILE, encoding="utf-8").read())

print("")
print("work record: the old layout migrates rather than being lost")
print("")

fresh()
shutil.rmtree(lib_worklog.RECORDS_DIR, ignore_errors=True)
os.makedirs(lib_worklog.STATE_DIR, exist_ok=True)
legacy = os.path.join(lib_worklog.STATE_DIR, "prompts.jsonl")
io.open(legacy, "w", encoding="utf-8", newline="\n").write(
    json.dumps({"at": time.time(), "session": "old", "prompt_id": "old",
                "text": "Fix the thing I asked about earlier."}) + "\n")
io.open(os.path.join(lib_worklog.STATE_DIR, "worklog.md"), "w",
        encoding="utf-8", newline="\n").write("- an old audit line\n")

lib_worklog.record_prompt("a new message", "s2", "p2")

check("the legacy prompt history is carried across",
      any("Fix the thing I asked about earlier" in (e.get("text") or "")
          for e in lib_worklog.recent_prompts()),
      str(lib_worklog.recent_prompts()))
check("an old authorisation still works after the move",
      lib_worklog.citation_matches("Fix the thing I asked about earlier")[0])
check("the legacy audit trail is carried across too",
      "an old audit line" in io.open(lib_worklog.LOG_FILE,
                                     encoding="utf-8").read())
check("and the legacy file is gone, not duplicated", not os.path.isfile(legacy))

print("")
print("work record: the audit trail rotates instead of growing forever")
print("")

fresh()
io.open(lib_worklog.LOG_FILE, "w", encoding="utf-8", newline="\n").write(
    "x" * (3 * 1024 * 1024))
lib_worklog.log("AFTER", "written after the roll")
body = io.open(lib_worklog.LOG_FILE, encoding="utf-8").read()
check("a large log is rolled, not appended to", len(body) < 1024, len(body))
check("and the new entry lands in the fresh file", "written after the roll" in body)
rolled = [f for f in os.listdir(lib_worklog.RECORDS_DIR)
          if f.startswith("worklog-") and f.endswith(".md")]
check("the old content is kept under a dated name", len(rolled) == 1, str(rolled))

print("")
print("work record: a named script is READ, not guessed at")
print("")

# This was written off as unclosable: `python somescript.py` may read or may
# rewrite the disk, and the command line does not say which. That gave up one
# step early. The command line does not say; the FILE does.
fresh()
scratch = os.path.join(REPO, "temp", "worklog-script-tests")
shutil.rmtree(scratch, ignore_errors=True)
os.makedirs(scratch, exist_ok=True)


def script(name, body):
    p = os.path.join(scratch, name)
    io.open(p, "w", encoding="utf-8", newline="\n").write(body)
    return p


reader = script("reads.py", "import io\nprint(io.open('x.txt').read())\n")
writer = script("writes.py", "import io\nio.open('x.txt','w').write('hi')\n")
remover = script("removes.py", "import os\nos.remove('x.txt')\n")
mover = script("moves.py", "import shutil\nshutil.move('a','b')\n")
ps_writer = script("writes.ps1", "Set-Content -Path x.txt -Value hi\n")
node_writer = script("writes.js", "require('fs').writeFileSync('x','y')\n")

for label, path, want in [
    ("a script that only reads", reader, "allow"),
    ("a script that opens a file for writing", writer, "deny"),
    ("a script that removes a file", remover, "deny"),
    ("a script that moves a file", mover, "deny"),
    ("a PowerShell script that writes", ps_writer, "deny"),
    ("a node script that writes", node_writer, "deny"),
]:
    runner = "pwsh -File" if path.endswith(".ps1") else (
        "node" if path.endswith(".js") else "python")
    got, _ = call("Bash", {"command": "%s %s" % (runner, path)})
    check("%s -> %s" % (label, want), got == want, got)

# Unreadable means mutating: the safe direction. Being wrong costs one sentence
# opening a task; the opposite costs a silent change to Bob's machine.
got, _ = call("Bash", {"command": "python %s/does-not-exist.py" % scratch})
check("a script that cannot be found is assumed to write", got == "deny", got)

# The reading script must stay allowed even with arguments and redirection of
# stderr, which is how these are actually invoked.
got, _ = call("Bash", {"command": "python %s --flag 2>/dev/null | tail -1" % reader})
check("a reading script with args and 2>/dev/null stays allowed",
      got == "allow", got)

shutil.rmtree(scratch, ignore_errors=True)

print("")
print("work record: THE WEDGE. One session must not evict another's licence")
print("")

# 2026-09-10, the worst defect in this design. All sessions appended to one
# 60-entry prompt file, so a busy session pushed every other session's history
# out. A blikje session running overnight under an explicit multi-hour
# authorization from Bob was wedged: its genuine licence had been evicted by a
# different session's traffic, so its real citation read as invented, and the
# task could not be withdrawn either because the remedy was inside the gate.
fresh()

LICENCE = ("work through the repair plan. Spin off sonnet agents if it looks "
           "like it's something they can handle. I'll leave it to you.")
said(LICENCE, prompt_id="overnight")            # session "t", the long one

# Another session now talks a great deal.
for i in range(120):
    subprocess.run([sys.executable, RECORD],
                   input=json.dumps({"prompt": "chatter number %d about "
                                               "something else entirely" % i,
                                     "session_id": "noisy",
                                     "prompt_id": "n%d" % i}),
                   capture_output=True, text=True)

ok, why = lib_worklog.citation_matches(LICENCE, "t")
check("the overnight licence SURVIVES another session's traffic", ok, why)
check("and the noisy session cannot cite it",
      not lib_worklog.citation_matches(LICENCE, "noisy")[0])

print("")
print("work record: the remedy is never inside the gate")
print("")

# Their Call 2 and Call 4: writing the task file from Bash, and deleting it,
# were both refused as "a change" while no task was open, which is the exact
# state the refusal message tells you to leave.
fresh()
state = lib_worklog.STATE_DIR.replace("\\", "/")
for label, cmd in [
    ("writing the task file from Bash",
     'cat > "%s/current-task.json" <<JSON\n{}\nJSON' % state),
    ("deleting the task file", 'rm -f "%s/current-task.json"' % state),
    ("clearing the whole state dir", 'rm -rf "%s"' % state),
]:
    got, _ = call("Bash", {"command": cmd})
    check("with NO task open: %s" % label, got == "allow", got)

got, out = call("Write", {"file_path": lib_worklog.TASK_FILE, "content": "{}"})
check("and the Write tool agrees (the gate is consistent)", got == "allow", got)

print("")
print("work record: a refusal always says how to get out")
print("")

fresh()
said("Go and do the thing I asked about.")
io.open(lib_worklog.TASK_FILE, "w", encoding="utf-8", newline="\n").write(
    json.dumps({"what": "something", "citation": "words he never said at all",
                "opened_at": time.time()}))
got, out = call("Write", {"file_path": "C:/Users/Bob/thing.md", "content": "x"})
check("an unmatched citation still refuses", got == "deny", got)
check("but the refusal names the file to delete",
      "current-task.json" in out, out[:400])
check("and says the state directory is exempt",
      "exempt" in out.lower(), out[:400])
check("and does not assume the licence was invented",
      "record is short" in out.lower() or "repeat it" in out.lower(), out[:500])

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
