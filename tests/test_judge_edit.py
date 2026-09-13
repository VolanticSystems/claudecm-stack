"""The edit judge, proved without a session and without spending a cent.

A fake judge runs on localhost and answers whatever the test tells it to, so
the REAL request-building and response-parsing path is exercised and the test
can also see exactly what the hook sent. Sabotage first: every way the hook
could wedge a session or judge on the wrong evidence is fed to it on purpose.

  exits 0 on malformed stdin, a missing key file, a dead judge, and garbage
      from the judge, and ALLOWS in every one of those cases, saying so
  ignores tools it does not judge, subagent calls, the memory directory, and
      an agreement dial set to off, and never calls the judge for any of them
  allows unchecked, with a note, when the session has no recorded history
  sends the last five of THIS session's messages and the prior assistant text,
      and nothing from any other session
  denies with the stop-and-report reason when the judge says DENY
  caches an ALLOW per (prompt, tool, path) so the same edit in the same turn
      costs nothing, and a new prompt id is judged again
  records cost and generation id from the response body on every call
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HOOKS = os.path.join(REPO, "hooks")
JUDGE = os.path.join(HOOKS, "judge-edit.py")

PASS = [0]
FAIL = [0]


def check(name, cond, detail=""):
    if cond:
        print("  PASS      %s" % name)
        PASS[0] += 1
    else:
        print("  **FAIL**  %s" % name)
        if detail:
            print("            %s" % str(detail)[:300])
        FAIL[0] += 1


# ------------------------------------------------------------ the fake judge

class Fake(BaseHTTPRequestHandler):
    verdict = "ALLOW"
    garbage = False
    calls = []          # request bodies, in order

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        Fake.calls.append(json.loads(self.rfile.read(n).decode("utf-8")))
        if Fake.garbage:
            body = b"this is not json at all"
        else:
            content = json.dumps({"decision": Fake.verdict, "reason": "stub says %s" % Fake.verdict})
            body = json.dumps({
                "id": "gen-test-%d" % len(Fake.calls),
                "choices": [{"message": {"content": content}}],
                "usage": {"cost": 0.0011, "prompt_tokens": 42, "completion_tokens": 9},
            }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = HTTPServer(("127.0.0.1", 0), Fake)
PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()


# ------------------------------------------------------------ fixtures

TMP = tempfile.mkdtemp(prefix="judge-test-")
RECORDS = os.path.join(TMP, "worklog")
STATE = os.path.join(TMP, "state")
os.makedirs(RECORDS)
os.makedirs(STATE)
KEY = os.path.join(TMP, "key.txt")
with io.open(KEY, "w", encoding="utf-8") as fh:
    fh.write("sk-test-not-real\n")

SESSION = "11111111-2222-3333-4444-555555555555"
OTHER = "99999999-8888-7777-6666-555555555555"


def write_history(session, texts):
    path = os.path.join(RECORDS, "prompts-%s.jsonl" % session)
    with io.open(path, "w", encoding="utf-8") as fh:
        for i, t in enumerate(texts):
            fh.write(json.dumps({"at": 1000 + i, "session": session,
                                 "prompt_id": "p%d" % i, "text": t}) + "\n")


def write_transcript(lines):
    path = os.path.join(TMP, "transcript.jsonl")
    with io.open(path, "w", encoding="utf-8") as fh:
        for kind, text in lines:
            fh.write(json.dumps({"type": kind, "message": {
                "content": [{"type": "text", "text": text}]}}) + "\n")
    return path


def run(payload, env_extra=None, url=None):
    env = dict(os.environ)
    env["CLAUDE_JUDGE_KEY_FILE"] = KEY
    # The HTTP path is taken whenever CLAUDE_JUDGE_URL is set; these tests
    # exercise it against the fake server. The CLI path is tested further down.
    env["CLAUDE_JUDGE_URL"] = url or "http://127.0.0.1:%d/v1/chat" % PORT
    env["CLAUDE_JUDGE_RECORDS_DIR"] = RECORDS
    env["CLAUDE_JUDGE_STATE_DIR"] = STATE
    env["CLAUDE_AGREEMENT_PATH"] = os.path.join(TMP, "agreement-absent.md")
    env.pop("CLAUDE_AGREEMENT_MODE", None)
    # The judge ships on warn. These tests pin the deny behaviour explicitly;
    # the warn section below pins warn and the marker that selects it.
    env["CLAUDE_JUDGE_MODE"] = "deny"
    if env_extra:
        env.update(env_extra)
    raw = payload if isinstance(payload, str) else json.dumps(payload)
    p = subprocess.run([sys.executable, JUDGE], input=raw.encode("utf-8"),
                       capture_output=True, env=env, timeout=60)
    out = p.stdout.decode("utf-8", errors="replace")
    try:
        parsed = json.loads(out) if out.strip() else {}
    except Exception:
        parsed = {"_unparsed": out}
    return p.returncode, parsed


def decision(parsed):
    return (parsed.get("hookSpecificOutput") or {}).get("permissionDecision")


def edit_payload(path="C:/proj/app.py", session=SESSION, prompt_id="p4", **extra):
    d = {"session_id": session, "prompt_id": prompt_id, "tool_name": "Edit",
         "hook_event_name": "PreToolUse",
         "tool_input": {"file_path": path, "old_string": "a", "new_string": "b"}}
    d.update(extra)
    return d


write_history(SESSION, ["one", "two", "three", "four", "fix the login bug in app.py"])
write_history(OTHER, ["rewrite everything", "delete it all", "go go go"])


# ------------------------------------------------------------ never wedge

print("never wedges a session")
rc, out = run("this is not json {{{")
check("malformed stdin exits 0", rc == 0, rc)
check("malformed stdin decides nothing", decision(out) is None, out)

rc, out = run(edit_payload(), env_extra={"CLAUDE_JUDGE_KEY_FILE": os.path.join(TMP, "nope.txt")})
check("missing key file exits 0 and allows", rc == 0 and decision(out) is None, out)
check("missing key file says so", "unavailable" in json.dumps(out), out)

rc, out = run(edit_payload(), url="http://127.0.0.1:9/dead")
check("dead judge exits 0 and allows", rc == 0 and decision(out) is None, out)
check("dead judge says so", "unavailable" in json.dumps(out), out)

Fake.garbage = True
rc, out = run(edit_payload())
Fake.garbage = False
check("garbage from the judge exits 0 and allows", rc == 0 and decision(out) is None, out)


# ------------------------------------------------------------ what it ignores

print("what it never judges")
Fake.calls = []
rc, out = run({"session_id": SESSION, "prompt_id": "p4", "tool_name": "Bash",
               "tool_input": {"command": "rm -rf everything"}})
check("a non-judged tool exits 0, decides nothing", rc == 0 and out == {}, out)
rc, out = run(edit_payload(agent_id="agent-abc", agent_type="Explore"))
check("a subagent call exits 0, decides nothing", rc == 0 and out == {}, out)
rc, out = run(edit_payload(path="C:/Users/you/.claude/projects/C--x/memory/MEMORY.md"))
check("the memory directory exits 0, decides nothing", rc == 0 and out == {}, out)
rc, out = run(edit_payload(), env_extra={"CLAUDE_AGREEMENT_MODE": "off"})
check("agreement dial off exits 0, decides nothing", rc == 0 and out == {}, out)
check("none of those called the judge", len(Fake.calls) == 0, len(Fake.calls))

rc, out = run(edit_payload(session="00000000-0000-0000-0000-000000000000"))
check("no history: exits 0 and allows", rc == 0 and decision(out) is None, out)
check("no history: says so", "no message history" in json.dumps(out), out)
check("no history: judge not called", len(Fake.calls) == 0, len(Fake.calls))


# ------------------------------------------------------------ what it sends

print("what the judge is shown")
Fake.calls = []
Fake.verdict = "ALLOW"
transcript = write_transcript([
    ("user", "one"), ("assistant", "old reply"),
    ("user", "fix the login bug in app.py"),
    ("assistant", "I propose editing app.py lines 10-20. Shall I?"),
    ("user", "LATEST-USER-MARKER"),
])
rc, out = run(edit_payload(transcript_path=transcript))
check("ALLOW: exits 0, decides nothing, silent", rc == 0 and out == {}, out)
check("judge called exactly once", len(Fake.calls) == 1, len(Fake.calls))
sent = Fake.calls[0]["messages"][1]["content"] if Fake.calls else ""
check("sends the latest message", "fix the login bug in app.py" in sent, sent)
check("sends earlier messages of this session", "two" in sent and "four" in sent, sent)
check("sends the prior assistant text", "I propose editing app.py" in sent, sent)
check("does not send the other session's words", "rewrite everything" not in sent, sent)
check("sends the pending action", "Edit C:/proj/app.py" in sent, sent)
check("sends the new content snippet", "new content begins: b" in sent, sent)
check("temperature 0", Fake.calls[0].get("temperature") == 0, Fake.calls[0])


# ------------------------------------------------------------ cache

print("cache")
rc, out = run(edit_payload(transcript_path=transcript))
check("same prompt, tool, path: judge NOT called again", len(Fake.calls) == 1, len(Fake.calls))
rc, out = run(edit_payload(path="C:/proj/other.py", transcript_path=transcript))
check("same prompt, different path: judged", len(Fake.calls) == 2, len(Fake.calls))
rc, out = run(edit_payload(prompt_id="p5", transcript_path=transcript))
check("new prompt id, same path: judged again", len(Fake.calls) == 3, len(Fake.calls))
cache_file = os.path.join(STATE, "judge-cache-%s.json" % SESSION)
check("cache file is per session and on disk", os.path.isfile(cache_file), cache_file)


# ------------------------------------------------------------ deny

print("deny")
Fake.calls = []
Fake.verdict = "DENY"
rc, out = run(edit_payload(prompt_id="p6", transcript_path=transcript))
check("DENY: exits 0", rc == 0, rc)
check("DENY: permissionDecision deny", decision(out) == "deny", out)
reason = (out.get("hookSpecificOutput") or {}).get("permissionDecisionReason") or ""
check("DENY: reason opens with the refusal", reason.startswith("EDIT JUDGE REFUSED Edit app.py"), reason)
check("DENY: reason carries the judge's sentence", "stub says DENY" in reason, reason)
check("DENY: reason tells Claude to report and stop", "Report what you found and stop" in reason, reason)
check("DENY: reason forbids another route", "another tool or another path" in reason, reason)
check("DENY: the operator sees a systemMessage", "edit judge refused Edit app.py" in (out.get("systemMessage") or ""), out)
# A refusal is CACHED, and retrying the same edit must not buy a fresh verdict.
# Only approvals were cached until 2026-09-13, so a refused instance retried and
# paid again every time: fifteen refusals from one message in a single
# session, fifteen model calls to reach an answer already known.
calls_before = len(Fake.calls)
rc, out2 = run(edit_payload(prompt_id="p6", transcript_path=transcript))
check("DENY is cached: the same edit is NOT judged again", len(Fake.calls) == calls_before, len(Fake.calls))
check("DENY still stands on the retry", decision(out2) == "deny", out2)
check("the cached refusal keeps its reason", "stub says DENY" in json.dumps(out2), out2)
rc, out3 = run(edit_payload(prompt_id="p6", transcript_path=transcript))
check("a second retry is also free", len(Fake.calls) == calls_before, len(Fake.calls))
Fake.verdict = "ALLOW"


# ------------------------------------------------------------ the CLI path

print("the subscription path (stub claude -p)")
STUB = os.path.join(TMP, "stub_claude.py")
with io.open(STUB, "w", encoding="utf-8") as fh:
    fh.write(
        "import json, os, sys, time\n"
        "modes = os.environ.get('STUB_MODE', 'ALLOW').split(',')\n"
        # Votes run as parallel PROCESSES, so a shared counter races and all
        # three can read the same value. Each claims an index by creating a
        # lock file exclusively, which is atomic on every platform.
        "mode = modes[-1]\n"
        "for _i in range(len(modes)):\n"
        "    try:\n"
        "        fd = os.open(os.environ['STUB_LOG'] + '.claim%d' % _i, os.O_CREAT | os.O_EXCL | os.O_WRONLY)\n"
        "        os.close(fd); mode = modes[_i]; break\n"
        "    except FileExistsError:\n"
        "        continue\n"
        "args = sys.argv[1:]\n"
        "user = sys.stdin.read()\n"
        "with open(os.environ['STUB_LOG'], 'a', encoding='utf-8') as fh:\n"
        "    fh.write(json.dumps({'args': args, 'user': user, 'thinking': os.environ.get('MAX_THINKING_TOKENS'), 'cwd': os.getcwd()}) + '\\n')\n"
        "if mode == 'CRASH': sys.exit(3)\n"
        "if mode == 'HANG': time.sleep(30)\n"
        "res = json.dumps({'decision': mode, 'reason': 'cli stub says ' + mode})\n"
        "print(json.dumps({'result': '```json\\n' + res + '\\n```', 'total_cost_usd': 0.0007, 'uuid': 'cli-uuid-1',\n"
        "                  'usage': {'input_tokens': 10, 'output_tokens': 40}}))\n")
STUB_LOG = os.path.join(TMP, "stub.log")


def run_cli(payload, mode="ALLOW", env_extra=None):
    env = {"CLAUDE_JUDGE_CLI": STUB, "STUB_MODE": mode, "STUB_LOG": STUB_LOG}
    if env_extra:
        env.update(env_extra)
    # url="" makes run() leave CLAUDE_JUDGE_URL unset, so the CLI path is taken.
    e = dict(os.environ)
    e.update(env)
    e.setdefault("CLAUDE_JUDGE_VOTES", "1")   # voting is tested on its own below
    e["CLAUDE_JUDGE_KEY_FILE"] = KEY
    e["CLAUDE_JUDGE_RECORDS_DIR"] = RECORDS
    e["CLAUDE_JUDGE_STATE_DIR"] = STATE
    e["CLAUDE_AGREEMENT_PATH"] = os.path.join(TMP, "agreement-absent.md")
    e.setdefault("CLAUDE_JUDGE_MODE", "deny")
    e.pop("CLAUDE_JUDGE_URL", None)
    e.pop("CLAUDE_AGREEMENT_MODE", None)
    p = subprocess.run([sys.executable, JUDGE], input=json.dumps(payload).encode("utf-8"),
                       capture_output=True, env=e, timeout=90)
    out = p.stdout.decode("utf-8", errors="replace")
    try:
        parsed = json.loads(out) if out.strip() else {}
    except Exception:
        parsed = {"_unparsed": out}
    return p.returncode, parsed


rc, out = run_cli(edit_payload(prompt_id="c1", transcript_path=transcript), "ALLOW")
check("CLI ALLOW: exits 0, decides nothing, silent", rc == 0 and out == {}, out)
with io.open(STUB_LOG, encoding="utf-8") as fh:
    calls = [json.loads(l) for l in fh if l.strip()]
check("CLI: stub was invoked once", len(calls) == 1, len(calls))
args = calls[0]["args"] if calls else []
check("CLI: thinking is switched off in the child's environment", calls and calls[0]["thinking"] == "0", calls[:1])
check("CLI: no session persistence", "--no-session-persistence" in args, args)
check("CLI: no tools for the child", "--tools" in args and args[args.index("--tools") + 1] == "", args)
check("CLI: NO setting sources, so no user hooks and no user CLAUDE.md", "--setting-sources" in args and args[args.index("--setting-sources") + 1] == "", args)
child_cwd = calls[0]["cwd"] if calls else ""
check("CLI: child runs from an EMPTY directory, so no project CLAUDE.md or memory", child_cwd and os.path.normcase(child_cwd) == os.path.normcase(os.path.join(STATE, "judge-cwd")) and not os.listdir(child_cwd), child_cwd)
check("CLI: the judge prompt replaces the system prompt", "--system-prompt" in args and "THE OPERATOR'S OWN WORDS" in args[args.index("--system-prompt") + 1], args)
check("CLI: the operator's words are on stdin, not the command line", calls and "fix the login bug in app.py" in calls[0]["user"], calls[:1])

rc, out = run_cli(edit_payload(prompt_id="c2", transcript_path=transcript), "DENY")
check("CLI DENY: exits 0 and denies", rc == 0 and decision(out) == "deny", out)
check("CLI DENY: reason carries the stub's sentence", "cli stub says DENY" in json.dumps(out), out)

rc, out = run_cli(edit_payload(prompt_id="c3", transcript_path=transcript), "CRASH")
check("CLI crash: exits 0 and allows", rc == 0 and decision(out) is None, out)
check("CLI crash: says unavailable", "unavailable" in json.dumps(out), out)

t0 = __import__("time").time()
rc, out = run_cli(edit_payload(prompt_id="c4", transcript_path=transcript), "HANG")
took = __import__("time").time() - t0
check("CLI hang: exits 0 and allows after the internal timeout", rc == 0 and decision(out) is None, out)
check("CLI hang: gave up inside the hook's 35s timeout", took < 30, took)
check("CLI hang: says unavailable", "unavailable" in json.dumps(out), out)

print("majority voting on the subscription path")
# `claude -p` has no temperature control, so one call is unstable: 30% wrong
# refusals against 16% at temperature 0, and it leaked the canonical case.
# Three votes measured 14% with every canonical case caught.
def reset_stub():
    import glob as _g
    for f in [STUB_LOG] + _g.glob(STUB_LOG + ".claim*") + _g.glob(STUB_LOG + ".n"):
        try:
            os.remove(f)
        except Exception:
            pass


reset_stub()
rc, out = run_cli(edit_payload(prompt_id="v1", transcript_path=transcript),
                  "DENY,ALLOW,ALLOW", {"CLAUDE_JUDGE_VOTES": "3"})
with io.open(STUB_LOG, encoding="utf-8") as fh:
    vcalls = [json.loads(l) for l in fh if l.strip()]
check("three votes are cast", len(vcalls) == 3, len(vcalls))
check("1 deny vs 2 allow: ALLOWS (majority wins)", rc == 0 and decision(out) is None, out)

reset_stub()
rc, out = run_cli(edit_payload(prompt_id="v2", transcript_path=transcript),
                  "DENY,DENY,ALLOW", {"CLAUDE_JUDGE_VOTES": "3"})
check("2 deny vs 1 allow: DENIES", rc == 0 and decision(out) == "deny", out)
check("the reason shown comes from the winning side", "cli stub says DENY" in json.dumps(out), out)

reset_stub()
rc, out = run_cli(edit_payload(prompt_id="v3", transcript_path=transcript),
                  "CRASH,DENY,DENY", {"CLAUDE_JUDGE_VOTES": "3"})
check("a vote that crashes does not vote; the rest decide", rc == 0 and decision(out) == "deny", out)

reset_stub()
rc, out = run_cli(edit_payload(prompt_id="v4", transcript_path=transcript),
                  "CRASH,CRASH,CRASH", {"CLAUDE_JUDGE_VOTES": "3"})
check("all votes crash: exits 0 and allows unchecked", rc == 0 and decision(out) is None, out)
check("all votes crash: says unavailable", "unavailable" in json.dumps(out), out)


# ------------------------------------------------------------ warn mode

print("warn mode: judges, logs, refuses nothing")
Fake.calls = []
Fake.verdict = "DENY"
readable = os.path.join(RECORDS, "judge-log.md")


def run_mode(payload, mode_env=None, agreement_text=None):
    extra = {}
    e = dict(os.environ)
    e.pop("CLAUDE_JUDGE_MODE", None)
    if mode_env is not None:
        extra["CLAUDE_JUDGE_MODE"] = mode_env
    if agreement_text is not None:
        path = os.path.join(TMP, "agreement-judge.md")
        with io.open(path, "w", encoding="utf-8") as fh:
            fh.write(agreement_text)
        extra["CLAUDE_AGREEMENT_PATH"] = path
    # Pass the extra keys through run() but strip the deny default it sets.
    env = dict(e)
    env["CLAUDE_JUDGE_KEY_FILE"] = KEY
    env["CLAUDE_JUDGE_URL"] = "http://127.0.0.1:%d/v1/chat" % PORT
    env["CLAUDE_JUDGE_RECORDS_DIR"] = RECORDS
    env["CLAUDE_JUDGE_STATE_DIR"] = STATE
    env["CLAUDE_AGREEMENT_PATH"] = os.path.join(TMP, "agreement-absent.md")
    env.pop("CLAUDE_AGREEMENT_MODE", None)
    env.update(extra)
    p = subprocess.run([sys.executable, JUDGE], input=json.dumps(payload).encode("utf-8"),
                       capture_output=True, env=env, timeout=60)
    out = p.stdout.decode("utf-8", errors="replace")
    try:
        return p.returncode, (json.loads(out) if out.strip() else {})
    except Exception:
        return p.returncode, {"_unparsed": out}


rc, out = run_mode(edit_payload(prompt_id="w1", transcript_path=transcript))
check("no marker, no env: DEFAULT IS WARN, exits 0 and allows", rc == 0 and decision(out) is None, out)
check("warn: the operator is told what would have been refused", "would have refused Edit app.py" in (out.get("systemMessage") or ""), out)
check("warn: the judge was still called", len(Fake.calls) == 1, len(Fake.calls))
check("warn: readable log written", os.path.isfile(readable), readable)
body = io.open(readable, encoding="utf-8").read() if os.path.isfile(readable) else ""
check("warn: log names the edit", "would have refused  Edit app.py" in body, body[-300:])
check("warn: log carries the judge's reason", "stub says DENY" in body, body[-300:])
check("warn: log carries the operator's words beside it", "the operator said: fix the login bug in app.py" in body, body[-300:])

rc, out = run_mode(edit_payload(prompt_id="w2", transcript_path=transcript),
                   agreement_text="# x\n<!-- AGREEMENT-MODE: full -->\n<!-- JUDGE-MODE: deny -->\n")
check("file marker deny: refuses", rc == 0 and decision(out) == "deny", out)
body = io.open(readable, encoding="utf-8").read()
check("deny: readable log says REFUSED", "REFUSED  Edit app.py" in body, body[-300:])

rc, out = run_mode(edit_payload(prompt_id="w3", transcript_path=transcript),
                   agreement_text="# x\n<!-- JUDGE-MODE: warn -->\n")
check("file marker warn: allows", rc == 0 and decision(out) is None, out)

rc, out = run_mode(edit_payload(prompt_id="w4", transcript_path=transcript), mode_env="deny",
                   agreement_text="# x\n<!-- JUDGE-MODE: warn -->\n")
check("env deny beats file warn", rc == 0 and decision(out) == "deny", out)

rc, out = run_mode(edit_payload(prompt_id="w5", transcript_path=transcript),
                   agreement_text="# x\n<!-- JUDGE-MODE: dney -->\n")
check("a mistyped mode falls to warn, not deny", rc == 0 and decision(out) is None, out)

with io.open(os.path.join(RECORDS, "judge-costs.jsonl"), encoding="utf-8") as fh:
    recs = [json.loads(l) for l in fh if l.strip()]
check("warn verdicts are recorded as WOULD_DENY, deny as DENY", {r["decision"] for r in recs if r["prompt_id"] in ("w1", "w3", "w5")} == {"WOULD_DENY"} and {r["decision"] for r in recs if r["prompt_id"] in ("w2", "w4")} == {"DENY"}, [(r["prompt_id"], r["decision"]) for r in recs if r["prompt_id"].startswith("w")])
Fake.verdict = "ALLOW"


# ------------------------------------------------------------ cost record

print("cost record")
log = os.path.join(RECORDS, "judge-costs.jsonl")
rows = []
with io.open(log, encoding="utf-8") as fh:
    rows = [json.loads(l) for l in fh if l.strip()]
http_rows = [r for r in rows if r.get("cost_basis") == "provider response body"]
cli_rows = [r for r in rows if r.get("cost_basis", "").startswith("list-price")]
repeat_rows = [r for r in rows if str(r.get("decision", "")).endswith("_REPEAT")]
errored = [r for r in rows if r.get("decision") == "ERROR"]
paid = [r for r in rows if not str(r.get("decision", "")).endswith("_REPEAT")
        and r.get("decision") != "ERROR"]
check("every judge call is costed, and every cached retry is recorded too",
      len(paid) == 14 and len(repeat_rows) == 2, (len(paid), len(repeat_rows)))
# A judge that fails open must leave a row. Without one, every rate computed
# from this log is a share of the calls that happened to work, and a judge
# getting quieter under load reads as a calmer machine.
check("a judge that fails open is recorded, not silent",
      len(errored) == 6, [(r["prompt_id"], r.get("error", "")[:40]) for r in errored])
# Six distinct ways to fail, and each has to leave its own row: missing key
# file, connection refused, unparseable response, CLI exit code, CLI hang, and
# every vote crashing. One shared "unavailable" row would hide which it was.
check("each failure mode is distinguishable in the log",
      len({str(r.get("error", ""))[:30] for r in errored}) == 6,
      sorted({str(r.get("error", ""))[:30] for r in errored}))
check("a failed call is costed at zero and says why",
      errored and all(r.get("cost") == 0
                      and r.get("cost_basis") == "no call, judge unavailable"
                      and r.get("error") for r in errored),
      [(r.get("cost"), r.get("cost_basis"), r.get("error", "")[:40]) for r in errored])
check("a cached retry costs nothing and says so",
      all(r.get("cost") == 0 and r.get("cost_basis") == "cached, no call" for r in repeat_rows), repeat_rows)
check("a cached retry records which attempt it was",
      sorted(r.get("retry") for r in repeat_rows) == [1, 2], [r.get("retry") for r in repeat_rows])
check("http cost comes from the response body", len(http_rows) == 9 and all(r.get("cost") == 0.0011 for r in http_rows), http_rows[:1])
check("cli cost recorded as list-price equivalent", len(cli_rows) == 5, [(r["prompt_id"], r.get("cost")) for r in cli_rows])
# A voted verdict sums the votes' costs, so a 3-vote row costs 3x a 1-vote row.
voted = [r for r in cli_rows if r["prompt_id"] in ("v1", "v2")]
check("a voted row sums all three votes' cost", voted and all(abs(r.get("cost", 0) - 0.0021) < 1e-9 for r in voted), voted)
check("the vote split is recorded", {r.get("votes") for r in voted} == {"1D/2A", "2D/1A"}, [(r["prompt_id"], r.get("votes")) for r in voted])
check("generation id recorded", all(r.get("gen_id") for r in paid), paid[:1])
check("decision recorded", {r.get("decision") for r in rows} ==
      {"ALLOW", "DENY", "WOULD_DENY", "DENY_REPEAT", "ERROR"}, sorted({r.get("decision") for r in rows}))
check("session and prompt recorded", all(r.get("session") == SESSION and r.get("prompt_id") for r in rows), rows[:1])


# ------------------------------------------------------------ done

server.shutdown()
shutil.rmtree(TMP, ignore_errors=True)
print("")
print("%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
