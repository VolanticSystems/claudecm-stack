"""The work-agreement guards, proved before anything is installed.

WHAT IS PROVED HERE, at no cost and without the harness:

  lib_agreement   parses the table, honours the BEGIN/END markers so the menu
                  below them is NOT in force, survives escaped pipes (regex
                  alternation is a pipe), and SKIPS a bad row while naming it
                  rather than either crashing or disarming the other rows.
  every menu rule fires on a case it should catch and stays quiet on one it
                  should not. A menu of untested regexes is a trap, not a menu.
  guard-bash      denies, asks and warns per the table; ignores other tools;
                  and ALWAYS EXITS 0, including on malformed input, a missing
                  agreement, and an agreement that is a directory.
  guard-write     checks content across Write, Edit and MultiEdit shapes, and
                  does NOT match on the file path.

WHAT IS NOT PROVED HERE: that Claude Code enforces the decision. That needs a
live session, and it is proved separately by driving a real `claude -p` run.

The exit-code checks are the ones that matter most. A PreToolUse hook that
exits non-zero blocks the tool call, which leaves a session alive and unable to
act, and Claude cannot repair that because repairing is itself a tool call.
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HOOKS = os.path.join(REPO, "hooks")
AGREEMENT = os.path.join(HOOKS, "agreement.md")
GUARD_BASH = os.path.join(HOOKS, "guard-bash.py")
GUARD_WRITE = os.path.join(HOOKS, "guard-write.py")
GUARD_TOOL = os.path.join(HOOKS, "guard-tool.py")

sys.path.insert(0, HOOKS)
import lib_agreement  # noqa: E402

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


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def make_agreement(tmp, rows, name="agreement.md"):
    """A fixture agreement containing exactly `rows` between the markers."""
    body = ["# fixture", "", "<!-- AGREEMENT:BEGIN -->", "",
            "| slug | surface | pattern | action | why |",
            "|------|---------|---------|--------|-----|"]
    body.extend(rows)
    body.extend(["", "<!-- AGREEMENT:END -->", "",
                 "| ignored | bash | SHOULD_NEVER_MATCH | deny | below the marker |"])
    path = os.path.join(tmp, name)
    write(path, "\n".join(body) + "\n")
    return path


def run_hook(script, payload, agreement=None, mode=None):
    env = dict(os.environ)
    if agreement is not None:
        env["CLAUDE_AGREEMENT_PATH"] = agreement
    env.pop("CLAUDE_AGREEMENT_MODE", None)
    if mode is not None:
        env["CLAUDE_AGREEMENT_MODE"] = mode
    p = subprocess.run([sys.executable, script],
                       input=json.dumps(payload), capture_output=True,
                       text=True, env=env)
    return p.returncode, p.stdout, p.stderr


def decision(stdout):
    if not stdout.strip():
        return None
    try:
        return json.loads(stdout).get("hookSpecificOutput", {}).get("permissionDecision")
    except Exception:
        return "unparseable:" + stdout[:100]


def bash_payload(command):
    return {"tool_name": "Bash", "tool_input": {"command": command},
            "session_id": "test", "cwd": REPO}


def menu_row(slug):
    """Pull a row out of the real agreement.md so the tests exercise the
    shipped patterns, not copies of them that can drift."""
    with open(AGREEMENT, "r", encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("|") and s[1:].strip().startswith(slug + " "):
                return s
            if s.startswith("| " + slug + " "):
                return s
    return None


print("")
print("work agreement: loader")
print("")

tmp = tempfile.mkdtemp(prefix="agreement-tests-")
try:
    # ------------------------------------------------------------ markers
    rules, problems = lib_agreement.load(AGREEMENT)
    check("the shipped agreement is inert (no rules in force)", len(rules) == 0,
          "got %r" % rules)
    check("and reports no problems", problems == [], str(problems))

    hits, _ = lib_agreement.evaluate("Co-Authored-By: someone", "bash", AGREEMENT)
    check("a menu row below the END marker does NOT fire", hits == [], str(hits))

    # -------------------------------------------- rules nothing reads yet
    # The worst failure this system can have: a rule sitting above the marker,
    # looking enforced, that no guard reads. It must be impossible to hit
    # silently, so the loader names it every single time.
    # Every surface is wired as of 2026-09-10, so the mechanism is exercised by
    # declaring one unwired for the length of this check rather than by relying
    # on `output` being the odd one out. The protection is against a FUTURE
    # surface being added and left unread, which is what it was built for.
    p = make_agreement(tmp, [
        "| styled | output | `SOMETHING` | warn | pretend nothing reads this |",
        "| real | bash | `SOMETHING` | deny | this one does fire |",
    ])
    _saved = lib_agreement.UNWIRED_SURFACES
    lib_agreement.UNWIRED_SURFACES = ("output",)
    try:
        rules, problems = lib_agreement.load(p)
        check("an unwired-surface rule still loads (it is valid, just inert)",
              any(r.slug == "styled" for r in rules), str(rules))
        check("but it is reported as IN FORCE BUT INERT",
              any("INERT" in x and "styled" in x for x in problems), str(problems))
        check("and a wired rule beside it is NOT flagged",
              not any("real" in x for x in problems), str(problems))
    finally:
        lib_agreement.UNWIRED_SURFACES = _saved

    # And the regression that this replaced: with nothing unwired, an ordinary
    # command must carry NO note at all. Leaving `output` flagged after wiring
    # it made every single command emit one, which broke six other checks.
    rules, problems = lib_agreement.load(p)
    check("with every surface wired, no rule is flagged inert",
          not any("INERT" in x for x in problems), str(problems))
    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo harmless"), p)
    check("and an unmatched command emits nothing at all",
          out.strip() == "", out[:200])

    # The shipped file must not carry an inert rule above the marker.
    _, shipped_problems = lib_agreement.load(AGREEMENT)
    check("the SHIPPED agreement has no inert rule in force",
          not any("INERT" in x for x in shipped_problems), str(shipped_problems))

    # ------------------------------------------------------- escaped pipes
    p = make_agreement(tmp, [r"| alt | output | `\b(alpha\|beta)\b` | warn | alternation |"])
    rules, problems = lib_agreement.load(p)
    check("a pattern containing escaped pipes loads as ONE rule", len(rules) == 1,
          "%r problems=%r" % (rules, problems))
    hits, _ = lib_agreement.evaluate("this is beta here", "output", p)
    check("and the alternation actually matches", len(hits) == 1, str(hits))

    # ---------------------------------------------------------- bad rows
    p = make_agreement(tmp, [
        "| good | bash | GOODPATTERN | deny | fine |",
        "| badaction | bash | X | explode | nonsense action |",
        "| badsurface | telepathy | X | deny | nonsense surface |",
        "| badregex | bash | `[unclosed` | deny | will not compile |",
    ])
    rules, problems = lib_agreement.load(p)
    check("a bad row does not disarm the good row", len(rules) == 1 and rules[0].slug == "good",
          "%r" % rules)
    check("three bad rows are each named", len(problems) == 3, str(problems))
    check("the bad action is named", any("explode" in x for x in problems), str(problems))
    check("the bad surface is named", any("telepathy" in x for x in problems), str(problems))
    check("the uncompilable pattern is named", any("badregex" in x for x in problems), str(problems))

    # ------------------------------------------------------- missing file
    rules, problems = lib_agreement.load(os.path.join(tmp, "nope.md"))
    check("a missing agreement yields no rules", rules == [])
    check("and says so loudly rather than silently", any("NO rules" in x for x in problems),
          str(problems))

    # -------------------------------------------------------- precedence
    p = make_agreement(tmp, [
        "| w | bash | ZZZ | warn | w |",
        "| d | bash | ZZZ | deny | d |",
        "| a | bash | ZZZ | ask | a |",
    ])
    hits, _ = lib_agreement.evaluate("ZZZ", "bash", p)
    check("deny beats ask beats warn", lib_agreement.worst(hits) == "deny",
          lib_agreement.worst(hits))

    # ------------------------------------------------- every menu rule works
    print("")
    print("work agreement: the shipped menu")
    print("")

    cases = [
        ("no-ai-attribution", "bash", "git commit -m x\n\nCo-Authored-By: Claude", "git commit -F m.txt"),
        ("trim-stub", "write", "some text [Trimmed input: ~500 chars] more", "ordinary content"),
        ("trim-stub-result", "write", "[Trimmed tool result: ~9 chars]", "ordinary content"),
        ("commit-inline-msg", "bash", 'git commit -m "fix $HOME thing"', "git commit -F msg.txt"),
        ("heredoc-escapes", "bash", "cat <<'EOF' > f.py\nx = 'a\\nb'\nEOF", "cat <<EOF > f.txt\nplain\nEOF"),
        ("sed-inplace-escape", "bash", r"sed -i 's/a/\n/' file.txt", "sed -i 's/a/b/' file.txt"),
        ("rm-rf-variable", "bash", 'rm -rf "$target"', "rm -rf /tmp/literal-path"),
        ("echo-e-escape", "bash", r'echo -e "a\nb"', "echo hello"),
        ("no-em-dash", "output", "this thing \u2014 that thing", "this thing, that thing"),
        ("no-honesty-tic", "output", "Honestly, this works.", "This works."),
        ("no-todo-lists", "tool", "TodoWrite", "Write"),
        # TaskStop is the negative case on purpose. It kills a runaway
        # background process rather than tracking anything, and banning it once
        # left a spinning loop that Claude had started and could not stop.
        ("no-task-tracking", "tool", "TaskCreate", "TaskStop"),
        ("no-multiple-choice", "tool", "AskUserQuestion", "Read"),
        ("subagent-needs-ok", "tool", "Agent", "Agentic"),
        ("scratch-outside-project", "path",
         r"C:\Users\Bob\AppData\Local\Temp\claude\x\scratchpad\notes.md",
         r"C:\Users\Bob\Documents\GitHub\claudecm-stack\temp\notes.md"),
    ]

    for slug, surface, positive, negative in cases:
        row = menu_row(slug)
        if not row:
            check("menu rule '%s' exists in agreement.md" % slug, False)
            continue
        p = make_agreement(tmp, [row], name="menu-%s.md" % slug)
        rules, problems = lib_agreement.load(p)
        if len(rules) != 1:
            check("menu rule '%s' loads" % slug, False, "problems=%r" % problems)
            continue
        hits_pos, _ = lib_agreement.evaluate(positive, surface, p)
        hits_neg, _ = lib_agreement.evaluate(negative, surface, p)
        check("%s fires on what it should catch" % slug, len(hits_pos) == 1,
              "pattern=%r text=%r" % (rules[0].pattern, positive))
        check("%s stays quiet on what it should not" % slug, len(hits_neg) == 0,
              "pattern=%r text=%r matched=%r" % (rules[0].pattern, negative,
                                                 [m for _, m in hits_neg]))

    # ------------------------------------------------------------- guards
    print("")
    print("work agreement: guard-bash.py")
    print("")

    p = make_agreement(tmp, [
        "| deny-me | bash | FORBIDDEN | deny | never do this |",
        "| ask-me | bash | UNCERTAIN | ask | check with Bob |",
        "| warn-me | bash | NOTEWORTHY | warn | just noting |",
    ])

    rc, out, err = run_hook(GUARD_BASH, bash_payload("echo FORBIDDEN"), p)
    check("a deny row produces a deny", decision(out) == "deny", (rc, out, err))
    check("and still exits 0", rc == 0, (rc, err))
    check("and the reason quotes the slug", "deny-me" in out, out[:200])
    check("and the reason carries the why", "never do this" in out, out[:300])

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo UNCERTAIN"), p)
    check("an ask row produces an ask", decision(out) == "ask", out[:200])
    check("ask exits 0", rc == 0)

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo NOTEWORTHY"), p)
    check("a warn row does NOT block", decision(out) is None, out[:200])
    check("but it does say something", "warn-me" in out or "NOTEWORTHY" in out, out[:200])

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo harmless"), p)
    check("an unmatched command is silent", out.strip() == "", out[:200])
    check("and exits 0", rc == 0)

    rc, out, _ = run_hook(GUARD_BASH,
                          {"tool_name": "Read", "tool_input": {"file_path": "FORBIDDEN"}}, p)
    check("a non-Bash tool is ignored entirely", out.strip() == "" and rc == 0, (rc, out))

    # ------------------------------------------------- FAIL OPEN, the big one
    print("")
    print("work agreement: fail-open (a guard must never wedge the session)")
    print("")

    proc = subprocess.run([sys.executable, GUARD_BASH], input="", capture_output=True, text=True,
                          env=dict(os.environ, CLAUDE_AGREEMENT_PATH=p))
    check("empty stdin exits 0 and blocks nothing",
          proc.returncode == 0 and decision(proc.stdout) is None,
          (proc.returncode, proc.stdout))

    proc = subprocess.run([sys.executable, GUARD_BASH], input="{ not json",
                          capture_output=True, text=True,
                          env=dict(os.environ, CLAUDE_AGREEMENT_PATH=p))
    check("malformed stdin exits 0 and blocks nothing",
          proc.returncode == 0 and decision(proc.stdout) is None,
          (proc.returncode, proc.stdout))

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo FORBIDDEN"),
                          os.path.join(tmp, "does-not-exist.md"))
    check("a MISSING agreement allows rather than blocks",
          rc == 0 and decision(out) is None, (rc, out))
    check("and says the rules are not in force", "NO rules" in out, out[:200])

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo FORBIDDEN"), tmp)  # a directory
    check("an agreement path that is a DIRECTORY allows rather than blocks",
          rc == 0 and decision(out) is None, (rc, out))

    # ------------------------------------------------------------ guard-write
    print("")
    print("work agreement: guard-write.py")
    print("")

    pw = make_agreement(tmp, [
        r"| stub | write | `\[Trimmed input` | deny | corrupted payload |",
    ], name="write.md")

    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "Write",
        "tool_input": {"file_path": "C:/x/y.md", "content": "a [Trimmed input: ~9 chars] b"}}, pw)
    check("Write content is checked", decision(out) == "deny", out[:200])
    check("and the target file is named in the reason", "y.md" in out, out[:300])

    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "Edit",
        "tool_input": {"file_path": "C:/x/y.md", "old_string": "a",
                       "new_string": "[Trimmed input: ~9 chars]"}}, pw)
    check("Edit new_string is checked", decision(out) == "deny", out[:200])

    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "MultiEdit",
        "tool_input": {"file_path": "C:/x/y.md",
                       "edits": [{"old_string": "a", "new_string": "fine"},
                                 {"old_string": "b", "new_string": "[Trimmed input: x]"}]}}, pw)
    check("MultiEdit edits are checked", decision(out) == "deny", out[:200])

    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "Write",
        "tool_input": {"file_path": "C:/x/[Trimmed input.md", "content": "clean"}}, pw)
    check("the FILE PATH is not matched, only content", decision(out) is None, out[:200])

    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "Write",
        "tool_input": {"file_path": "C:/x/y.md", "content": "perfectly ordinary"}}, pw)
    check("clean content is silent", out.strip() == "" and rc == 0, (rc, out))

    proc = subprocess.run([sys.executable, GUARD_WRITE], input="{ not json",
                          capture_output=True, text=True,
                          env=dict(os.environ, CLAUDE_AGREEMENT_PATH=pw))
    check("guard-write fails open on malformed stdin",
          proc.returncode == 0 and decision(proc.stdout) is None,
          (proc.returncode, proc.stdout))

    # ------------------------------------------------ the bootstrap exemption
    # Found live on 2026-09-10, the first hour the guards ran: a rule row
    # necessarily contains the pattern it matches, so writing that row tripped
    # the rule and the agreement became uneditable. Without the exemption a bad
    # pattern can never be corrected.
    print("")
    print("work agreement: the agreement file is not subject to its own rules")
    print("")

    stub = "a [Trimmed input: ~%d chars] b" % 1523
    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "Write",
        "tool_input": {"file_path": pw, "content": stub}}, pw)
    check("writing the AGREEMENT file itself is exempt",
          decision(out) is None, out[:200])
    check("and the exemption is announced, never silent",
          "skipped" in out and "agreement" in out, out[:250])

    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "Write",
        "tool_input": {"file_path": os.path.join(tmp, "ordinary.md"), "content": stub}}, pw)
    check("the exemption does NOT leak to an ordinary file",
          decision(out) == "deny", out[:200])

    # A path that merely looks similar must not be exempt, or the carve-out is
    # a hole rather than a carve-out.
    rc, out, _ = run_hook(GUARD_WRITE, {
        "tool_name": "Write",
        "tool_input": {"file_path": pw + ".bak", "content": stub}}, pw)
    check("a lookalike path (agreement.md.bak) is NOT exempt",
          decision(out) == "deny", out[:200])

    # ------------------------- no-ai-attribution: the trailer vs mentioning it
    # Found live on 2026-09-10. The rule matched the bare string, so a command
    # grepping to CHECK for a trailer was refused, as was any command that
    # merely mentioned it. The rule is for a trailer landing in a commit
    # MESSAGE, so it is scoped to the inline -m form.
    print("")
    print("work agreement: no-ai-attribution catches the trailer, not the word")
    print("")

    attr_row = menu_row("no-ai-attribution")
    check("no-ai-attribution is present in the shipped menu", attr_row is not None)
    if attr_row:
        pa = make_agreement(tmp, [attr_row], name="attr.md")
        trailer = "Co-" + "Authored-By"
        for label, command, expected in [
            ("a real inline trailer",
             'git commit -m "fix\n\n%s: Claude <a@b>"' % trailer, "deny"),
            ("the same in single quotes",
             "git commit -m 'fix\n\n%s: Claude'" % trailer, "deny"),
            ("grepping to CHECK for one",
             'git log -1 --format=%%B | grep -iE "^%s"' % trailer, None),
            ("committing from a file, then verifying",
             'git commit -F m.txt; git log -1 | grep -i "%s"' % trailer, None),
            ("mentioning it while editing docs",
             'grep -rn "%s" docs/' % trailer, None),
            ("an ordinary commit", 'git commit -m "ordinary message"', None),
        ]:
            rc, out, _ = run_hook(GUARD_BASH, bash_payload(command), pa)
            check("no-ai-attribution: %s -> %s" % (label, expected or "allow"),
                  decision(out) == expected, out[:160])

    # --------------------------------- the trim pattern: real stub vs the docs
    print("")
    print("work agreement: trim-stub matches corruption, not documentation")
    print("")

    real_rows = [r for r in [menu_row("trim-stub"), menu_row("trim-stub-result")] if r]
    check("both trim rules are present in the shipped menu", len(real_rows) == 2)
    if len(real_rows) == 2:
        pt2 = make_agreement(tmp, real_rows, name="trim.md")
        target = os.path.join(tmp, "doc.md")

        for kind in ("input", "tool result"):
            corrupted = "before [Trimmed %s: ~4096 chars] after" % kind
            rc, out, _ = run_hook(GUARD_WRITE, {
                "tool_name": "Write",
                "tool_input": {"file_path": target, "content": corrupted}}, pt2)
            check("a REAL %s stub (with a digit count) is denied" % kind,
                  decision(out) == "deny", out[:160])

            documented = "the placeholder is [Trimmed %s: ~N chars] in prose" % kind
            rc, out, _ = run_hook(GUARD_WRITE, {
                "tool_name": "Write",
                "tool_input": {"file_path": target, "content": documented}}, pt2)
            check("but DOCUMENTING the %s placeholder is allowed" % kind,
                  decision(out) is None, out[:160])

    # ------------------------------------------------------------- guard-tool
    print("")
    print("work agreement: guard-tool.py (tool and path surfaces)")
    print("")

    pt = make_agreement(tmp, [
        "| banned-tool | tool | `^TodoWrite$` | deny | no checklists |",
        "| gated-tool | tool | `^Agent$` | ask | subagents need approval |",
        r"| bad-path | path | `AppData[\\/]Local[\\/]Temp` | ask | temp goes in the project |",
    ], name="tool.md")

    rc, out, _ = run_hook(GUARD_TOOL, {"tool_name": "TodoWrite",
                                       "tool_input": {"todos": []}}, pt)
    check("a banned tool is denied by NAME", decision(out) == "deny", out[:200])
    check("and exits 0", rc == 0)

    rc, out, _ = run_hook(GUARD_TOOL, {"tool_name": "Agent",
                                       "tool_input": {"prompt": "x"}}, pt)
    check("a gated tool asks", decision(out) == "ask", out[:200])

    rc, out, _ = run_hook(GUARD_TOOL, {"tool_name": "Write",
                                       "tool_input": {"file_path": "C:/proj/temp/x.md"}}, pt)
    check("an allowed tool with a good path is silent", out.strip() == "", out[:200])

    rc, out, _ = run_hook(GUARD_TOOL, {
        "tool_name": "Write",
        "tool_input": {"file_path": r"C:\Users\Bob\AppData\Local\Temp\claude\x\s.md"}}, pt)
    check("a scratch path outside the project is caught", decision(out) == "ask", out[:200])

    # The anchors matter: ^TodoWrite$ must not catch a tool whose name merely
    # contains it, or a future rename quietly widens the ban.
    rc, out, _ = run_hook(GUARD_TOOL, {"tool_name": "TodoWriteBatch",
                                       "tool_input": {}}, pt)
    check("an anchored tool rule does not catch a longer name",
          decision(out) is None, out[:200])

    proc = subprocess.run([sys.executable, GUARD_TOOL], input="{ not json",
                          capture_output=True, text=True,
                          env=dict(os.environ, CLAUDE_AGREEMENT_PATH=pt))
    check("guard-tool fails open on malformed stdin",
          proc.returncode == 0 and decision(proc.stdout) is None,
          (proc.returncode, proc.stdout))

    # ----------------------------------------------------------- the dial
    print("")
    print("work agreement: the intensity dial")
    print("")

    pm = make_agreement(tmp, [
        "| hard | bash | HARDBAN | deny | never |",
        "| soft | bash | SOFTCALL | ask | judgement |",
    ], name="mode.md")

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo HARDBAN"), pm, mode="full")
    check("full: a deny rule fires", decision(out) == "deny", out[:150])
    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo SOFTCALL"), pm, mode="full")
    check("full: an ask rule fires", decision(out) == "ask", out[:150])

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo HARDBAN"), pm, mode="lite")
    check("lite: the deny rule STILL fires", decision(out) == "deny", out[:150])
    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo SOFTCALL"), pm, mode="lite")
    check("lite: the ask rule is silent", decision(out) is None, out[:150])

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo HARDBAN"), pm, mode="off")
    check("off: nothing fires at all", decision(out) is None, out[:150])
    check("off: and it says so rather than being silently disarmed",
          "off" in out, out[:200])

    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo HARDBAN"), pm, mode="lyte")
    check("a MISTYPED mode falls back to full rather than disarming",
          decision(out) == "deny", out[:200])
    check("and names the typo", "lyte" in out, out[:250])

    # The file's own mode line, with no env var in play.
    body = io.open(pm, encoding="utf-8").read().replace(
        "<!-- AGREEMENT:BEGIN -->", "<!-- AGREEMENT-MODE: lite -->\n<!-- AGREEMENT:BEGIN -->")
    io.open(pm, "w", encoding="utf-8", newline="\n").write(body)
    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo SOFTCALL"), pm)
    check("a mode line IN THE FILE is honoured", decision(out) is None, out[:150])
    rc, out, _ = run_hook(GUARD_BASH, bash_payload("echo SOFTCALL"), pm, mode="full")
    check("and the env var overrides the file", decision(out) == "ask", out[:150])

finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("")
print("%d check(s): %d pass, %d fail" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
