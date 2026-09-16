"""Read the action log across rotations and say what it lost.

`guard-tool.py` writes one line per changing tool call to
~/.claude/hooks/worklog/action-log.jsonl, and lib_worklog rotates that file by
month once it passes 2 MB. A reader that opens only the current file silently
stops seeing history the day it rolls, so this globs every rotation.

IT COUNTS WHAT IT COULD NOT READ. Five instances append to one file at once.
The write is a single atomic os.write of well under 4 KB, which should not
tear, but "should not" is how the last three defects in this project were
described. Every unparseable line is counted and reported, so a torn row shows
up as a number rather than as a quietly shorter history.

    python action-report.py                 summary, all sessions
    python action-report.py --days 14       the last fortnight
    python action-report.py --by-session    who did what
    python action-report.py --list          every row, newest last
"""
import argparse
import datetime
import glob
import io
import json
import os
import sys
from collections import Counter

WORKLOG = os.path.join(os.path.expanduser("~"), ".claude", "hooks", "worklog")


def files():
    """Current log plus every rotation, oldest first."""
    out = sorted(glob.glob(os.path.join(WORKLOG, "action-log-*.jsonl")))
    current = os.path.join(WORKLOG, "action-log.jsonl")
    if os.path.isfile(current):
        out.append(current)
    return out


def load(since_ts):
    rows, bad, scanned = [], 0, 0
    for path in files():
        try:
            fh = io.open(path, encoding="utf-8", errors="replace")
        except Exception:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                scanned += 1
                try:
                    row = json.loads(line)
                except Exception:
                    bad += 1
                    continue
                if not isinstance(row, dict) or "at" not in row:
                    bad += 1
                    continue
                if float(row.get("at") or 0) >= since_ts:
                    rows.append(row)
    rows.sort(key=lambda r: r.get("at") or 0)
    return rows, bad, scanned


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=float, default=0, help="0 means everything")
    ap.add_argument("--by-session", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    import time
    since = time.time() - a.days * 86400 if a.days else 0
    rows, bad, scanned = load(since)

    print("files read      %d" % len(files()))
    print("lines scanned   %d" % scanned)
    print("unreadable      %d%s" % (bad, "" if not bad else
                                    "   <-- torn or corrupt rows, investigate"))
    print("rows in window  %d" % len(rows))
    if not rows:
        return 0
    first = datetime.datetime.fromtimestamp(rows[0]["at"])
    last = datetime.datetime.fromtimestamp(rows[-1]["at"])
    print("covering        %s to %s" % (first.strftime("%Y-%m-%d %H:%M"),
                                        last.strftime("%Y-%m-%d %H:%M")))
    print()
    print("by kind")
    for k, n in Counter(r.get("kind") for r in rows).most_common():
        label = {"shell?": "shell, unknown whether it wrote"}.get(k, k)
        print("  %-32s %d" % (label, n))
    print()
    print("turns that changed something: %d"
          % len({(r.get("session"), r.get("prompt_id")) for r in rows}))

    if a.by_session:
        print()
        print("by session")
        per = Counter(r.get("session", "")[:8] for r in rows)
        for s, n in per.most_common():
            proj = ""
            for r in rows:
                if r.get("session", "").startswith(s) and r.get("cwd"):
                    proj = os.path.basename(r["cwd"].rstrip("/\\"))
                    break
            print("  %-10s %5d  %s" % (s, n, proj))

    if a.list:
        print()
        for r in rows:
            t = datetime.datetime.fromtimestamp(r["at"]).strftime("%m-%d %H:%M:%S")
            print("%s  %-8s %-6s %-12s %s" % (
                t, r.get("session", "")[:8], r.get("kind"), r.get("tool"),
                (r.get("target") or "")[:90]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
