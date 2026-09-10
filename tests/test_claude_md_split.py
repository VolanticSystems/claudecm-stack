"""Guard against silently losing a rule from CLAUDE.md.

On 2026-09-10 CLAUDE.md was cut from 4,401 words to about 1,700 by moving the
incident narratives to casebook.md and turning the mechanical prohibitions into
patterns in agreement.md. The risk in a refactor like that is not that it
breaks loudly, it is that one rule quietly stops existing and nobody notices for
a month.

So every load-bearing concept is asserted to survive in at least one of the
three files. Re-run this after any edit to CLAUDE.md.

Plain substring matching, deliberately: an earlier version used regex and blew
up on the backslashes in Windows paths, which is the wrong tool for "does this
text appear".
"""
import io
import os
import sys

HOME = os.path.join(os.path.expanduser("~"), ".claude")


def read(name):
    try:
        return io.open(os.path.join(HOME, name), encoding="utf-8").read().lower()
    except Exception:
        return ""


# (label, [any one of these substrings counts as present])
CHECKS = [
    ("work or words", ["work or words", "work-or-words"]),
    ("question does not revoke authorization", ["revoke", "hold off"]),
    ("standing authorization starts with a tool call", ["first thing in the turn"]),
    ("brake and gas / false close", ["false close"]),
    ("answer first", ["asks twice", "answer-first"]),
    ("no multiple choice", ["multiple-choice", "multiple choice"]),
    ("no todo / task tools", ["todowrite"]),
    ("subagent policy", ["subagent"]),
    ("laziness vs confusion", ["i misunderstood"]),
    ("look up the WHOLE thing", ["whole thing"]),
    ("done means done", ["done-means-done", "done means"]),
    ("test what you changed", ["test what you changed"]),
    ("verdict NOT GOOD TO GO", ["not good to go"]),
    ("verdict GOOD TO GO, TESTED", ["good to go, tested"]),
    ("verdict GOOD TO GO, UNTESTED", ["good to go, untested"]),
    ("banned softening language", ["standing down"]),
    ("no razzmatazz", ["razzmatazz"]),
    ("no em dashes", ["em dash"]),
    ("no honesty tic", ["candidly", "real talk"]),
    ("live vs sandbox", ["is live", "live state"]),
    ("approval per change", ["back it up first"]),
    ("stay in scope", ["stay in scope", "stay-in-scope"]),
    ("right tool / heredocs", ["heredoc"]),
    ("the judgement is the shortcut", ["judgement is the"]),
    ("pointer to the shell-shapes doc", ["why-i-always-use-the-right-tool"]),
    ("temp files in the project", ["temp-in-project", "\\temp\\"]),
    ("overrides harness scratchpad", ["scratchpad"]),
    ("trim stub regression watch", ["trim bug", "trim-stub"]),
    ("metered cost from the response body", ["response body", "usage.cost"]),
    ("generation id", ["generation id"]),
    ("reconcile against the provider meter", ["reconcile"]),
    ("litellm hidden params", ["_hidden_params"]),
    ("pwsh not powershell.exe", ["powershell.exe"]),
    ("raster font reason", ["raster"]),
    ("output capture trap", ["$script:"]),
    ("white text only", ["white text", "white only"]),
    ("no AI attribution", ["co-authored-by"]),
    ("credentials location", ["api_key.txt", ".config"]),
    ("no keys in bashrc", ["bashrc"]),
    ("notify.ps1 path", ["notify.ps1"]),
    ("notify needs single quotes", ["single quotes"]),
    ("no Notification hook", ["notification hook"]),
    ("email mailbox", ["claude123@"]),
    ("email recipient", ["bob.human@"]),
    ("email config file", ["config.toml"]),
    ("local git repos path", ["gitrepos"]),
    ("compact command one line", ["one continuous line"]),
    ("A4 documents", ["a4"]),
    ("chrome tab cleanup", ["tabs_close_mcp"]),
    ("chrome collapsed group chips", ["collapsed"]),
    ("CSHARP.md pointer", ["csharp.md"]),
    ("NinjaTrader caveat", ["ninjatrader"]),
    ("confidence rating", ["confidence"]),
]

new = read("claude.md")
case = read("casebook.md")
agree = read("agreement.md")
everywhere = " ".join((new, case, agree))

passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        print("  PASS      %s" % name)
        passed += 1
    else:
        print("  **FAIL**  %s" % name)
        if detail:
            print("            %s" % detail)
        failed += 1


print("")
print("CLAUDE.md split: nothing lost")
print("")

check("CLAUDE.md exists and is not empty", len(new) > 100, "%d chars" % len(new))
check("casebook.md exists (the narratives have somewhere to live)",
      len(case) > 100, "%d chars" % len(case))
check("agreement.md exists (the prohibitions have somewhere to live)",
      len(agree) > 100, "%d chars" % len(agree))

missing = [label for label, needles in CHECKS
           if not any(n in everywhere for n in needles)]
check("all %d load-bearing concepts survive somewhere" % len(CHECKS),
      not missing, "missing: " + ", ".join(missing))

# Anthropic's documented guideline is under 200 lines, because the file loads in
# full every session and a longer one measurably reduces adherence. Bob raised
# the ceiling to 250 on 2026-09-10 after adding `fixed-is-a-claim`, which is his
# call: a rule that earns its place beats a round number from a doc. The check
# stays because the point is to notice growth, not to hit a particular figure.
MAX_LINES = 250
lines = len(read("claude.md").splitlines())
words = len(new.split())
check("CLAUDE.md is within the %d-line ceiling" % MAX_LINES,
      lines <= MAX_LINES, "%d lines" % lines)
check("and well under its pre-split size", words < 2500, "%d words" % words)

# No file may carry a real corruption stub. Checked by the same signature the
# trim-stub rule uses: the placeholder followed by an actual digit count.
for name in ("claude.md", "casebook.md", "agreement.md"):
    body = read(name)
    bad = False
    for kind in ("input", "tool result"):
        marker = "[trimmed %s: ~" % kind
        i = body.find(marker)
        if i >= 0 and body[i + len(marker):i + len(marker) + 1].isdigit():
            bad = True
    check("%s carries no corruption stub" % name, not bad)

print("")
print("%d check(s): %d pass, %d fail" % (passed + failed, passed, failed))
sys.exit(1 if failed else 0)
