"""This repo is public. Fail if anything identifying is tracked in it.

WHY THIS IS A TEST AND NOT A NOTE
  The rule used to live in a memory that said "before pushing, grep for the
  usual suspects". That is an intention, and it survives exactly as long as
  somebody remembers it. On 2026-09-13 a sweep found a home directory path in
  seven files, real project names used as test fixtures in two more, and a test
  that asserted on both of the operator's email addresses as literal substrings.
  All of it had been public for months. The history had to be rewritten.

THE TRICK THAT KEEPS THIS FILE HONEST
  The forbidden name is NOT written down here. Writing it down would put it
  back in the repo, which is the thing being prevented. It is derived from the
  home directory at run time, so the check is "does any tracked file mention
  whoever is running this", which is also why it works for anyone who clones
  the repo rather than only for its author.

A path filter cannot do this job. `.gitignore` decides which FILES are in the
repo; every leak found on 2026-09-13 was text inside a file that belonged here.

    python tests/test_repo_hygiene.py
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PASS = [0]
FAIL = [0]


def check(name, cond, detail=""):
    if cond:
        print("  PASS      %s" % name)
        PASS[0] += 1
    else:
        print("  **FAIL**  %s" % name)
        if detail:
            print("            %s" % str(detail)[:400])
        FAIL[0] += 1


def tracked():
    out = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True,
                         text=True)
    return [p for p in out.stdout.splitlines() if p.strip()]


SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".zip", ".pdf", ".docx",
            ".xlsx", ".pyc", ".exe", ".dll", ".woff", ".woff2", ".mp4"}


def readable(path):
    if os.path.splitext(path)[1].lower() in SKIP_EXT:
        return None
    try:
        return io.open(os.path.join(REPO, path), encoding="utf-8").read()
    except Exception:
        return None


FILES = [(p, readable(p)) for p in tracked()]
FILES = [(p, t) for p, t in FILES if t is not None]

print("")
print("repo hygiene: %d tracked text file(s)" % len(FILES))
print("")

# ---------------------------------------------------------------- the name
# Derived, never written down. A single-letter or obviously generic home
# directory name would produce nonsense, so those are skipped.
WHO = os.path.basename(os.path.expanduser("~"))
GENERIC = {"user", "users", "home", "root", "runner", "administrator", "you"}
if len(WHO) < 3 or WHO.lower() in GENERIC:
    print("  SKIP      home directory is generic (%r); name check not meaningful" % WHO)
else:
    pat = re.compile(r"\b%s\b" % re.escape(WHO), re.I)
    hits = ["%s:%d" % (p, i + 1)
            for p, t in FILES
            for i, line in enumerate(t.splitlines()) if pat.search(line)]
    check("no tracked file mentions the account name", not hits, hits[:8])

# ------------------------------------------------------------- home paths
# Placeholder user names are the whole point of a documentation example, so
# they are allowed. Anything else in that position is somebody's real account.
# Keep this list boring. The first version of it contained a made-up
# placeholder built out of a real domain fragment, which put the thing back in
# the repo inside the file written to keep it out. Found by re-scanning after
# the push, not by reading it back.
PLACEHOLDERS = "you|alice|user|username|someone|example|me"
HOME_PATH = re.compile(
    r"(?:[A-Za-z]:[\\/]|/)Users[\\/](?!(?:%s)[\\/])(?!<)[A-Za-z0-9._-]+[\\/]"
    % PLACEHOLDERS, re.I)
hits = ["%s:%d: %s" % (p, i + 1, line.strip()[:70])
        for p, t in FILES
        for i, line in enumerate(t.splitlines()) if HOME_PATH.search(line)]
check("no tracked file hardcodes a home directory path", not hits, hits[:6])

# ---------------------------------------------------------------- addresses
ALLOWED_DOMAINS = ("volantic.systems", "example.com", "anthropic.com",
                   "noreply.github.com", "users.noreply.github.com")
# Lowercase TLD of 2 to 10, so a shell expression like `s@s.cleanupPeriodDays`
# is not read as an address. That false positive is why the bound is here.
ADDR = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,10}\b")
hits = []
for p, t in FILES:
    for i, line in enumerate(t.splitlines()):
        for m in ADDR.findall(line):
            if not m.lower().endswith(ALLOWED_DOMAINS):
                hits.append("%s:%d: %s" % (p, i + 1, m))
check("no tracked file carries an address outside the allowlist", not hits, hits[:6])

# ------------------------------------------------------- transcript content
# The runtime logs hold whatever was typed. None of them may ever be tracked.
MUST_IGNORE = ("private/", ".claude/", "hooks/state/", "hooks/worklog/",
               ".regents/", "temp/")
gitignore = ""
try:
    gitignore = io.open(os.path.join(REPO, ".gitignore"), encoding="utf-8").read()
except Exception:
    pass
missing = [d for d in MUST_IGNORE if d not in gitignore]
check("every runtime-output directory is still ignored", not missing, missing)

tracked_runtime = [p for p, _ in FILES
                   if any(p.startswith(d) for d in MUST_IGNORE)
                   and p != "temp/README.md"]
check("and none of them is tracked anyway", not tracked_runtime, tracked_runtime[:6])

print("")
print("%d check(s): %d pass, %d fail" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
